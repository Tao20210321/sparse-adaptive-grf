read_and_split_year <- function(cfg, paths) {
  if (!file.exists(paths$input_csv)) stop("Training CSV is missing: ", paths$input_csv)
  raw <- read.csv(paths$input_csv, check.names = TRUE, stringsAsFactors = FALSE)
  required <- unique(c(cfg$target, cfg$coord_cols, cfg$candidate_features))
  missing <- setdiff(required, names(raw))
  if (length(missing)) stop("CSV lacks required columns: ", paste(missing, collapse = ", "))

  # One synchronized mask, centred on the NPP response and all required predictors.
  work <- raw[, required, drop = FALSE]
  work$source_row <- seq_len(nrow(raw))
  for (nm in setdiff(names(work), "source_row")) work[[nm]] <- suppressWarnings(as.numeric(work[[nm]]))
  valid <- complete.cases(work[, required, drop = FALSE]) & apply(is.finite(as.matrix(work[, required, drop = FALSE])), 1L, all)
  work <- work[valid, , drop = FALSE]
  if (nrow(work) < 100L) stop("Fewer than 100 complete records remain after synchronized cleaning.")

  set_run_seed(cfg$seed)
  train_id <- sample.int(nrow(work), floor((1 - cfg$test_fraction) * nrow(work)))
  train <- work[train_id, , drop = FALSE]
  test <- work[-train_id, , drop = FALSE]

  # Estimate NPP-only outlier thresholds on training labels: no test-set leakage.
  y <- train[[cfg$target]]
  bounds <- switch(cfg$outlier_method,
    iqr = { q <- stats::quantile(y, c(.25, .75)); d <- 1.5 * diff(q); c(q[1] - d, q[2] + d) },
    `3sigma` = c(mean(y) - 3 * stats::sd(y), mean(y) + 3 * stats::sd(y)),
    NULL = c(-Inf, Inf),
    stop("outlier_method must be iqr, 3sigma, or NULL")
  )
  train <- train[train[[cfg$target]] >= bounds[1] & train[[cfg$target]] <= bounds[2], , drop = FALSE]
  if (nrow(train) < 100L) stop("Too few training records remain after NPP outlier filtering.")
  list(train = train, test = test, npp_bounds = bounds, n_complete = sum(valid))
}

make_rfe_seeds <- function(seed, folds, sizes) {
  set_run_seed(seed)
  c(replicate(folds, sample.int(1000000L, length(sizes) + 1L), simplify = FALSE), list(sample.int(1000000L, 1L)))
}

select_features_rfe <- function(train, cfg) {
  x <- train[, cfg$candidate_features, drop = FALSE]
  y <- train[[cfg$target]]
  sizes <- unique(c(seq(1L, ncol(x), by = 2L), ncol(x)))
  control <- caret::rfeControl(
    functions = caret::rfFuncs, method = "cv", number = cfg$rfe_folds,
    returnResamp = "final", verbose = FALSE,
    seeds = make_rfe_seeds(cfg$seed + 100L, cfg$rfe_folds, sizes)
  )
  fit <- caret::rfe(x = x, y = y, sizes = sizes, rfeControl = control, ntree = cfg$rfe_trees)
  list(features = fit$optVariables, results = fit$results)
}

tune_mtry <- function(formula, data, trees, seed) {
  scores <- lapply(seq_len(length(attr(stats::terms(formula), "term.labels"))), function(m) {
    model <- ranger::ranger(formula, data = data, num.trees = trees, mtry = m, num.threads = 1L, seed = seed + m)
    data.frame(mtry = m, OOB_RMSE = sqrt(model$prediction.error), OOB_R2 = model$r.squared)
  })
  out <- do.call(rbind, scores)
  out[order(out$OOB_RMSE), , drop = FALSE]
}

metric_row <- function(observed, predicted) {
  data.frame(
    RMSE = sqrt(mean((observed - predicted)^2)),
    MAE = mean(abs(observed - predicted)),
    R2 = 1 - sum((observed - predicted)^2) / sum((observed - mean(observed))^2)
  )
}

train_one_year <- function(cfg, year) {
  paths <- year_paths(cfg, year)
  prepare_output_dir(paths$output_dir, cfg$overwrite_outputs)
  split <- read_and_split_year(cfg, paths)
  rfe <- select_features_rfe(split$train, cfg)
  write.csv(data.frame(feature = rfe$features), paths$rfe_file, row.names = FALSE)
  write.csv(rfe$results, file.path(paths$output_dir, "rfe_cv_results.csv"), row.names = FALSE)

  train_df <- data.frame(NPP = split$train[[cfg$target]], split$train[, rfe$features, drop = FALSE], check.names = FALSE)
  test_df <- data.frame(NPP = split$test[[cfg$target]], split$test[, rfe$features, drop = FALSE], check.names = FALSE)
  formula <- stats::reformulate(rfe$features, response = "NPP")
  mtry_scores <- tune_mtry(formula, train_df, cfg$final_trees, cfg$seed + 200L)
  best_mtry <- mtry_scores$mtry[1]
  write.csv(mtry_scores, file.path(paths$output_dir, "mtry_oob.csv"), row.names = FALSE)

  train_coords <- as.matrix(split$train[, cfg$coord_cols, drop = FALSE])
  test_coords <- as.matrix(split$test[, cfg$coord_cols, drop = FALSE])
  coarse <- sparse_grf_bandwidth(formula, train_df, train_coords, cfg$bw_coarse$min, cfg$bw_coarse$max,
    cfg$bw_coarse$step, cfg$bw_coarse$trees, best_mtry, cfg$bw_coarse$anchors, cfg$seed + 300L)
  write.csv(coarse$scores, file.path(paths$output_dir, "bandwidth_coarse.csv"), row.names = FALSE)
  fine <- sparse_grf_bandwidth(formula, train_df, train_coords,
    max(cfg$bw_coarse$min, coarse$best - cfg$bw_fine_half_width),
    min(nrow(train_df) - 1L, coarse$best + cfg$bw_fine_half_width),
    cfg$bw_fine_step, cfg$final_trees, best_mtry, cfg$bw_fine_anchors, cfg$seed + 400L)
  write.csv(fine$scores, file.path(paths$output_dir, "bandwidth_fine.csv"), row.names = FALSE)

  model <- fit_sparse_grf(formula, train_df, train_coords, fine$best, cfg$final_trees, best_mtry,
    cfg$n_anchor_models, cfg$outer_workers, cfg$seed + 500L)
  saveRDS(model, paths$model_file)
  predicted <- predict.sparse_grf(model, test_df, test_coords, cfg$local_weight)
  metrics <- cbind(year = year, n_train = nrow(train_df), n_test = nrow(test_df), best_mtry = best_mtry,
    best_neighbors = fine$best, local_weight = cfg$local_weight, metric_row(test_df$NPP, predicted))
  write.csv(metrics, file.path(paths$output_dir, "test_metrics.csv"), row.names = FALSE)
  write.csv(data.frame(source_row = split$test$source_row, x = test_coords[, 1], y = test_coords[, 2],
    NPP_observed = test_df$NPP, NPP_predicted = predicted), file.path(paths$output_dir, "test_predictions.csv"), row.names = FALSE)
  write.csv(data.frame(method = cfg$outlier_method, lower = split$npp_bounds[1], upper = split$npp_bounds[2],
    complete_rows_before_split = split$n_complete), file.path(paths$output_dir, "npp_cleaning_rule.csv"), row.names = FALSE)
  write_run_provenance(cfg, year, paths, paste0("rfe_features=", paste(rfe$features, collapse = ",")))
  list(model = model, selected_features = rfe$features, metrics = metrics, paths = paths)
}

