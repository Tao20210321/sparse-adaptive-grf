read_and_split_year <- function(cfg, paths) {
  if (!file.exists(paths$input_csv)) stop("Training CSV is missing: ", paths$input_csv)
  raw <- read.csv(paths$input_csv, check.names = TRUE, stringsAsFactors = FALSE)
  required <- unique(c(cfg$target, cfg$coord_cols, cfg$candidate_features))
  missing <- setdiff(required, names(raw))
  if (length(missing)) stop("CSV lacks required columns: ", paste(missing, collapse = ", "))
  work <- raw[, required, drop = FALSE]; work$source_row <- seq_len(nrow(raw))
  for (nm in setdiff(names(work), "source_row")) work[[nm]] <- suppressWarnings(as.numeric(work[[nm]]))
  valid <- complete.cases(work[, required, drop = FALSE]) & apply(is.finite(as.matrix(work[, required, drop = FALSE])), 1L, all)
  work <- work[valid, , drop = FALSE]
  if (nrow(work) < 100L) stop("Fewer than 100 complete records remain after synchronized cleaning.")
  set_run_seed(cfg$seed)
  train_id <- sample.int(nrow(work), floor((1 - cfg$test_fraction) * nrow(work)))
  train <- work[train_id, , drop = FALSE]; test <- work[-train_id, , drop = FALSE]
  y <- train[[cfg$target]]
  bounds <- switch(cfg$outlier_method,
    iqr = { q <- stats::quantile(y, c(.25, .75)); d <- 1.5 * diff(q); c(q[1] - d, q[2] + d) },
    `3sigma` = c(mean(y) - 3 * stats::sd(y), mean(y) + 3 * stats::sd(y)), NULL = c(-Inf, Inf),
    stop("outlier_method must be iqr, 3sigma, or NULL"))
  train <- train[train[[cfg$target]] >= bounds[1] & train[[cfg$target]] <= bounds[2], , drop = FALSE]
  if (nrow(train) < 100L) stop("Too few training records remain after NPP outlier filtering.")
  list(train = train, test = test, npp_bounds = bounds, n_raw = nrow(raw), n_complete = sum(valid))
}

calculate_vif <- function(data, features) {
  if (!length(features)) stop("No predictors supplied for VIF.")
  if (length(features) == 1L) return(data.frame(feature = features, VIF = 1, stringsAsFactors = FALSE))
  scores <- vapply(features, function(feature) {
    others <- setdiff(features, feature)
    fit <- try(stats::lm(stats::reformulate(others, response = feature), data = data[, c(feature, others), drop = FALSE]), silent = TRUE)
    if (inherits(fit, "try-error")) return(Inf)
    r2 <- summary(fit)$r.squared
    if (!is.finite(r2) || r2 >= 1 - 1e-12) return(Inf)
    1 / (1 - r2)
  }, numeric(1))
  data.frame(feature = names(scores), VIF = unname(scores), stringsAsFactors = FALSE)
}

filter_features_vif <- function(train, cfg) {
  features <- cfg$candidate_features; min_features <- max(1L, min(as.integer(cfg$vif_min_features), length(features)))
  history <- list(); step <- 0L
  repeat {
    vif <- calculate_vif(train, features); worst <- vif[which.max(vif$VIF), , drop = FALSE]
    remove <- nrow(vif) > min_features && !is.na(worst$VIF) && worst$VIF > cfg$vif_threshold
    step <- step + 1L
    history[[step]] <- data.frame(step = step, n_features = nrow(vif), feature = worst$feature, VIF = worst$VIF, action = if (remove) "removed" else "retained")
    if (!remove) break
    features <- setdiff(features, worst$feature)
  }
  list(features = features, final_vif = calculate_vif(train, features), history = do.call(rbind, history))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
make_rfe_seeds <- function(seed, folds, sizes) { set_run_seed(seed); c(replicate(folds, sample.int(1000000L, length(sizes) + 1L), simplify = FALSE), list(sample.int(1000000L, 1L))) }

select_features_rfe <- function(train, cfg, features) {
  x <- train[, features, drop = FALSE]; y <- train[[cfg$target]]; sizes <- unique(c(seq(1L, ncol(x), by = 2L), ncol(x)))
  control <- caret::rfeControl(functions = caret::rfFuncs, method = "cv", number = cfg$rfe_folds, returnResamp = "final", verbose = isTRUE(cfg$verbose_progress), seeds = make_rfe_seeds(cfg$seed + 100L, cfg$rfe_folds, sizes))
  fit <- caret::rfe(x = x, y = y, sizes = sizes, rfeControl = control, ntree = cfg$rfe_trees)
  list(features = fit$optVariables, results = fit$results)
}

select_features_importance <- function(train, cfg, features) {
  formula <- stats::reformulate(features, response = cfg$target); rank_mtry <- cfg$importance_mtry %||% max(1L, floor(sqrt(length(features))))
  rank_model <- ranger::ranger(formula, data = train[, c(cfg$target, features), drop = FALSE], num.trees = cfg$importance_trees, mtry = min(rank_mtry, length(features)), importance = "permutation", num.threads = 1L, seed = cfg$seed + 150L, respect.unordered.factors = "order")
  ranking <- data.frame(feature = names(rank_model$variable.importance), importance = unname(rank_model$variable.importance))
  ranking <- ranking[order(-ranking$importance, ranking$feature), , drop = FALSE]
  sizes <- if (is.null(cfg$importance_subset_sizes)) seq_len(nrow(ranking)) else sort(unique(as.integer(cfg$importance_subset_sizes)))
  sizes <- sizes[sizes >= 1L & sizes <= nrow(ranking)]; if (!length(sizes)) stop("importance_subset_sizes has no valid values.")
  scores <- lapply(sizes, function(k) {
    selected <- ranking$feature[seq_len(k)]
    model <- ranger::ranger(stats::reformulate(selected, response = cfg$target), data = train[, c(cfg$target, selected), drop = FALSE], num.trees = cfg$importance_trees, mtry = max(1L, min(floor(sqrt(k)), k)), num.threads = 1L, seed = cfg$seed + 160L + k, respect.unordered.factors = "order")
    data.frame(n_features = k, OOB_RMSE = sqrt(model$prediction.error), OOB_R2 = model$r.squared)
  })
  scores <- do.call(rbind, scores); scores <- scores[order(scores$OOB_RMSE, scores$n_features), , drop = FALSE]
  list(features = ranking$feature[seq_len(scores$n_features[1])], ranking = ranking, subset_scores = scores)
}

tune_mtry <- function(formula, data, trees, seed) {
  p <- length(attr(stats::terms(formula), "term.labels"))
  out <- do.call(rbind, lapply(seq_len(p), function(m) {
    model <- ranger::ranger(formula, data = data, num.trees = trees, mtry = m, num.threads = 1L, seed = seed + m)
    data.frame(mtry = m, OOB_RMSE = sqrt(model$prediction.error), OOB_R2 = model$r.squared)
  }))
  out[order(out$OOB_RMSE), , drop = FALSE]
}

metric_row <- function(observed, predicted) data.frame(RMSE = sqrt(mean((observed - predicted)^2)), MAE = mean(abs(observed - predicted)), R2 = 1 - sum((observed - predicted)^2) / sum((observed - mean(observed))^2))

save_scientific_plot <- function(plot, stem, width_mm = 180, height_mm = 120) {
  w <- width_mm / 25.4; h <- height_mm / 25.4
  ggplot2::ggsave(paste0(stem, ".png"), plot, width = width_mm, height = height_mm, units = "mm", dpi = 300)
  svglite::svglite(paste0(stem, ".svg"), width = w, height = h)
  print(plot); grDevices::dev.off()
  grDevices::cairo_pdf(paste0(stem, ".pdf"), width = w, height = h, family = "Arial")
  print(plot); grDevices::dev.off()
  ragg::agg_tiff(paste0(stem, ".tiff"), width = w, height = h, units = "in", res = 600)
  print(plot); grDevices::dev.off()
}

save_diagnostic_plots <- function(selection, observed, predicted, figure_dir, cfg) {
  if (!isTRUE(cfg$save_diagnostic_plots)) return(invisible(NULL))
  dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
  theme_science <- ggplot2::theme_classic(base_size = 11, base_family = "Arial") + ggplot2::theme(plot.title = ggplot2::element_text(face = "bold"))
  vif <- selection$vif_final; vif$feature <- stats::reorder(vif$feature, vif$VIF)
  p_vif <- ggplot2::ggplot(vif, ggplot2::aes(feature, VIF)) + ggplot2::geom_col(fill = "#4C78A8") + ggplot2::coord_flip() + ggplot2::geom_hline(yintercept = cfg$vif_threshold, linetype = 2, colour = "#C44E52") + ggplot2::labs(title = "Final VIF after iterative filtering", x = NULL, y = "VIF") + theme_science
  save_scientific_plot(p_vif, file.path(figure_dir, "vif_final"))
  if (selection$method == "vif_rfe") {
    x <- selection$details$results
    p <- ggplot2::ggplot(x, ggplot2::aes(Variables, RMSE)) + ggplot2::geom_line(colour = "#4C78A8") + ggplot2::geom_point(colour = "#4C78A8") + ggplot2::labs(title = "RFE cross-validation", x = "Number of variables", y = "CV RMSE") + theme_science
    if ("RMSESD" %in% names(x)) p <- p + ggplot2::geom_errorbar(ggplot2::aes(ymin = RMSE - RMSESD, ymax = RMSE + RMSESD), width = 0.15, alpha = 0.5)
    save_scientific_plot(p, file.path(figure_dir, "rfe_cv_rmse"))
  } else {
    x <- selection$details$ranking; x$feature <- stats::reorder(x$feature, x$importance)
    p <- ggplot2::ggplot(x, ggplot2::aes(feature, importance)) + ggplot2::geom_col(fill = "#59A14F") + ggplot2::coord_flip() + ggplot2::labs(title = "Random-forest permutation importance", x = NULL, y = "Permutation importance") + theme_science
    save_scientific_plot(p, file.path(figure_dir, "rf_permutation_importance"))
    x <- selection$details$subset_scores
    p <- ggplot2::ggplot(x, ggplot2::aes(n_features, OOB_RMSE)) + ggplot2::geom_line(colour = "#4C78A8") + ggplot2::geom_point(colour = "#4C78A8") + ggplot2::labs(title = "Top-k importance subsets", x = "Number of top-ranked variables", y = "OOB RMSE") + theme_science
    save_scientific_plot(p, file.path(figure_dir, "rf_importance_subset_oob"))
  }
  d <- data.frame(observed = observed, predicted = predicted, residual = predicted - observed); lim <- range(c(d$observed, d$predicted), finite = TRUE)
  p <- ggplot2::ggplot(d, ggplot2::aes(observed, predicted)) + ggplot2::geom_point(alpha = .25, colour = "#4C78A8", size = 1) + ggplot2::geom_abline(slope = 1, intercept = 0, linetype = 2, colour = "#C44E52") + ggplot2::coord_equal(xlim = lim, ylim = lim) + ggplot2::labs(title = "Independent-test observed versus predicted NPP", x = "Observed NPP", y = "Predicted NPP") + theme_science
  save_scientific_plot(p, file.path(figure_dir, "independent_test_observed_vs_predicted"), height_mm = 150)
  p <- ggplot2::ggplot(d, ggplot2::aes(predicted, residual)) + ggplot2::geom_point(alpha = .25, colour = "#4C78A8", size = 1) + ggplot2::geom_hline(yintercept = 0, linetype = 2, colour = "#C44E52") + ggplot2::labs(title = "Independent-test residual diagnostic", x = "Predicted NPP", y = "Prediction residual") + theme_science
  save_scientific_plot(p, file.path(figure_dir, "independent_test_residuals"))
  invisible(NULL)
}

train_one_year <- function(cfg, year) {
  paths <- year_paths(cfg, year); prepare_output_dir(paths$output_dir, cfg$overwrite_outputs)
  split <- run_step(cfg$verbose_progress, "01/09 synchronized NPP cleaning and train/test split", read_and_split_year(cfg, paths))
  vif <- run_step(cfg$verbose_progress, "02/09 training-set VIF filtering", filter_features_vif(split$train, cfg))
  write.csv(vif$history, file.path(paths$output_dir, "vif_filter_history.csv"), row.names = FALSE); write.csv(vif$final_vif, file.path(paths$output_dir, "vif_final.csv"), row.names = FALSE)
  progress_note(cfg$verbose_progress, "VIF retained predictors", "INFO", paste(vif$features, collapse = ", "))
  selection <- if (cfg$feature_selection_method == "vif_rfe") {
    d <- run_step(cfg$verbose_progress, "03/09 RFE after VIF", select_features_rfe(split$train, cfg, vif$features)); write.csv(d$results, file.path(paths$output_dir, "rfe_cv_results.csv"), row.names = FALSE); list(method = "vif_rfe", features = d$features, details = d, vif_final = vif$final_vif)
  } else if (cfg$feature_selection_method == "vif_importance") {
    d <- run_step(cfg$verbose_progress, "03/09 random-forest importance after VIF", select_features_importance(split$train, cfg, vif$features)); write.csv(d$ranking, file.path(paths$output_dir, "rf_permutation_importance.csv"), row.names = FALSE); write.csv(d$subset_scores, file.path(paths$output_dir, "rf_importance_subset_oob.csv"), row.names = FALSE); list(method = "vif_importance", features = d$features, details = d, vif_final = vif$final_vif)
  } else stop("feature_selection_method must be 'vif_rfe' or 'vif_importance'.")
  write.csv(data.frame(feature = selection$features), paths$rfe_file, row.names = FALSE); write.csv(data.frame(method = selection$method, feature = selection$features), file.path(paths$output_dir, "feature_selection_summary.csv"), row.names = FALSE)
  progress_note(cfg$verbose_progress, "Selected predictors", "INFO", paste(selection$features, collapse = ", "))
  train_df <- data.frame(NPP = split$train[[cfg$target]], split$train[, selection$features, drop = FALSE], check.names = FALSE); test_df <- data.frame(NPP = split$test[[cfg$target]], split$test[, selection$features, drop = FALSE], check.names = FALSE); formula <- stats::reformulate(selection$features, response = "NPP")
  mtry_scores <- run_step(cfg$verbose_progress, "04/09 mtry OOB tuning", tune_mtry(formula, train_df, cfg$final_trees, cfg$seed + 200L)); best_mtry <- mtry_scores$mtry[1]; write.csv(mtry_scores, file.path(paths$output_dir, "mtry_oob.csv"), row.names = FALSE)
  train_coords <- as.matrix(split$train[, cfg$coord_cols, drop = FALSE]); test_coords <- as.matrix(split$test[, cfg$coord_cols, drop = FALSE])
  coarse <- run_step(cfg$verbose_progress, "05/09 coarse adaptive-neighbour search", sparse_grf_bandwidth(formula, train_df, train_coords, cfg$bw_coarse$min, cfg$bw_coarse$max, cfg$bw_coarse$step, cfg$bw_coarse$trees, best_mtry, cfg$bw_coarse$anchors, cfg$seed + 300L, verbose = cfg$verbose_progress)); write.csv(coarse$scores, file.path(paths$output_dir, "bandwidth_coarse.csv"), row.names = FALSE)
  fine <- run_step(cfg$verbose_progress, "06/09 fine adaptive-neighbour search", sparse_grf_bandwidth(formula, train_df, train_coords, max(cfg$bw_coarse$min, coarse$best - cfg$bw_fine_half_width), min(nrow(train_df) - 1L, coarse$best + cfg$bw_fine_half_width), cfg$bw_fine_step, cfg$final_trees, best_mtry, cfg$bw_fine_anchors, cfg$seed + 400L, verbose = cfg$verbose_progress)); write.csv(fine$scores, file.path(paths$output_dir, "bandwidth_fine.csv"), row.names = FALSE)
  model <- run_step(cfg$verbose_progress, "07/09 fit sparse adaptive GRF", fit_sparse_grf(formula, train_df, train_coords, fine$best, cfg$final_trees, best_mtry, cfg$n_anchor_models, cfg$outer_workers, cfg$seed + 500L, verbose = cfg$verbose_progress)); saveRDS(model, paths$model_file)
  predicted <- run_step(cfg$verbose_progress, "08/09 independent-test prediction", predict.sparse_grf(model, test_df, test_coords, cfg$local_weight, verbose = cfg$verbose_progress, label = "independent test"))
  metrics <- cbind(year = year, selection_method = selection$method, n_train = nrow(train_df), n_test = nrow(test_df), best_mtry = best_mtry, best_neighbors = fine$best, local_weight = cfg$local_weight, metric_row(test_df$NPP, predicted)); write.csv(metrics, file.path(paths$output_dir, "test_metrics.csv"), row.names = FALSE)
  write.csv(data.frame(source_row = split$test$source_row, x = test_coords[, 1], y = test_coords[, 2], NPP_observed = test_df$NPP, NPP_predicted = predicted), file.path(paths$output_dir, "test_predictions.csv"), row.names = FALSE); write.csv(data.frame(method = cfg$outlier_method, lower = split$npp_bounds[1], upper = split$npp_bounds[2], input_rows = split$n_raw, complete_rows_before_split = split$n_complete), file.path(paths$output_dir, "npp_cleaning_rule.csv"), row.names = FALSE)
  run_step(cfg$verbose_progress, "09/09 save selection and fit diagnostics", save_diagnostic_plots(selection, test_df$NPP, predicted, file.path(paths$output_dir, "figures"), cfg))
  write_run_provenance(cfg, year, paths, c(paste0("feature_selection_method=", selection$method), paste0("vif_features=", paste(vif$features, collapse = ",")), paste0("selected_features=", paste(selection$features, collapse = ","))))
  list(model = model, selected_features = selection$features, metrics = metrics, paths = paths)
}

