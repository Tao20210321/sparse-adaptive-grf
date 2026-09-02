# Complete single-file annual NPP sparse adaptive GRF workflow.
# Configure the settings in default_npp_config() below, then run: source('00_complete_workflow.R')
# It writes results/<year>/ and prints progress for every major step.

# Central configuration. Edit this file for a new run.

default_npp_config <- function(project_root = normalizePath(".", winslash = "/", mustWork = FALSE)) {
  list(
    project_root = project_root,
    data_root = "F:/1km",
    boundary_file = "D:/Tibet/region/TPBoundary_HF/TPBoundary_HF_wgs84.shp",
    training_csv_pattern = "C:/Users/Lenovo/Desktop/1km-degradation/natue_database_year/nature_database_%d.csv",
    result_root = file.path(project_root, "results"),
    years = 2001L,
    target = "NPP",
    coord_cols = c("x", "y"),
    # RFE dynamically selects the final subset from this candidate universe.
    candidate_features = c(
      "bio1", "bio12", "lc", "dem", "bdod_0.5", "cec_0.5", "cfvo_0.5",
      "clay_0.5", "nitrogen_0.5", "phh2o_0.5", "sand_0.5", "silt_0.5", "soc_0.5"
    ),
    grassland_lc_codes = c(9L, 10L),
    seed = 42L,
    test_fraction = 0.30,
    outlier_method = "iqr",
    # Choose one: "vif_rfe" or "vif_importance".
    feature_selection_method = "vif_rfe",
    vif_threshold = 5,
    vif_min_features = 2L,
    rfe_folds = 10L,
    rfe_trees = 300L,
    importance_trees = 500L,
    importance_mtry = NULL,
    # NULL evaluates every ranked top-k subset by OOB RMSE; specify integers to reduce runtime.
    importance_subset_sizes = NULL,
    bw_coarse = list(min = 1000L, max = 5000L, step = 500L, trees = 300L, anchors = 300L),
    bw_fine_half_width = 100L,
    bw_fine_step = 25L,
    bw_fine_anchors = 500L,
    final_trees = 300L,
    n_anchor_models = 1000L,
    local_weight = 0.4,
    outer_workers = 4L,
    verbose_progress = TRUE,
    save_diagnostic_plots = TRUE,
    run_raster_prediction = TRUE,
    overwrite_outputs = FALSE,
    custom_file_rules = c()
  )
}

year_paths <- function(cfg, year) {
  out <- file.path(cfg$result_root, as.character(year))
  list(
    input_csv = sprintf(cfg$training_csv_pattern, year),
    output_dir = out,
    model_file = file.path(out, "sparse_grf_model.rds"),
    rfe_file = file.path(out, "rfe_selected_features.csv"),
    prediction_file = file.path(out, sprintf("NPP_simulated_TP_LC9_10_%d.tif", year))
  )
}

required_packages <- c("ranger", "RANN", "caret", "randomForest", "terra", "sf", "ggplot2", "svglite", "ragg")

progress_note <- function(enabled, label, state = "START", detail = NULL) {
  if (!isTRUE(enabled)) return(invisible(NULL))
  suffix <- if (is.null(detail) || !nzchar(detail)) "" else paste0(" | ", detail)
  message(sprintf("[%s] %s%s", state, label, suffix))
  invisible(NULL)
}

run_step <- function(enabled, label, expr) {
  progress_note(enabled, label, "START")
  started <- proc.time()[["elapsed"]]
  value <- force(expr)
  progress_note(enabled, label, "DONE", sprintf("%.1f s", proc.time()[["elapsed"]] - started))
  value
}

ensure_packages <- function(packages = required_packages) {
  missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) stop("Install required R packages before running: ", paste(missing, collapse = ", "))
  invisible(TRUE)
}

set_run_seed <- function(seed) {
  RNGkind(kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
  set.seed(as.integer(seed))
}

prepare_output_dir <- function(path, overwrite = FALSE) {
  if (dir.exists(path) && !overwrite && length(list.files(path, all.files = FALSE))) {
    stop("Output directory already contains files: ", path, ". Set overwrite_outputs=TRUE or choose a new result_root.")
  }
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  path
}

write_run_provenance <- function(cfg, year, paths, extra = character()) {
  txt <- c(
    paste0("year=", year), paste0("seed=", cfg$seed),
    paste0("input_csv=", normalizePath(paths$input_csv, winslash = "/", mustWork = TRUE)),
    paste0("candidate_features=", paste(cfg$candidate_features, collapse = ",")),
    paste0("local_weight=", cfg$local_weight), paste0("n_anchor_models=", cfg$n_anchor_models),
    extra, "", "sessionInfo:", capture.output(sessionInfo())
  )
  writeLines(txt, file.path(paths$output_dir, "run_provenance.txt"))
}

# Sparse adaptive geographically weighted random forest: no N by N distance matrix.
earth_radius_m <- 6371008.8

validate_lonlat <- function(coords, allow_missing = FALSE) {
  coords <- as.matrix(coords)
  storage.mode(coords) <- "double"
  if (ncol(coords) != 2L || (!allow_missing && any(!is.finite(coords)))) stop("Coordinates must be finite longitude/latitude columns.")
  keep <- apply(is.finite(coords), 1L, all)
  if (any(abs(coords[keep, 1]) > 180) || any(abs(coords[keep, 2]) > 90)) stop("Coordinates must be longitude/latitude in degrees.")
  coords
}

lonlat_to_xyz <- function(coords) {
  coords <- validate_lonlat(coords)
  lon <- coords[, 1] * pi / 180
  lat <- coords[, 2] * pi / 180
  cbind(earth_radius_m * cos(lat) * cos(lon), earth_radius_m * cos(lat) * sin(lon), earth_radius_m * sin(lat))
}

chord_to_distance <- function(chord) {
  z <- pmin(pmax(chord / (2 * earth_radius_m), 0), 1)
  2 * earth_radius_m * asin(z)
}

bisquare_weights <- function(distances) {
  h <- tail(distances, 1L)
  if (!is.finite(h) || h <= 0) return(rep(1, length(distances)))
  w <- (1 - (distances / h)^2)^2
  w[!is.finite(w) | w < 0] <- 0
  if (sum(w > 0) < 2L) w <- rep(1, length(w))
  w
}

formula_parts <- function(formula, data) {
  formula <- stats::as.formula(formula)
  response <- all.vars(formula[[2]])
  predictors <- attr(stats::terms(formula), "term.labels")
  if (length(response) != 1L || !all(c(response, predictors) %in% names(data))) stop("Formula columns are missing from data.")
  list(formula = formula, response = response, predictors = predictors, columns = c(response, predictors))
}

prepare_grf_data <- function(data, formula, coords) {
  parts <- formula_parts(formula, data)
  coords <- validate_lonlat(coords, allow_missing = TRUE)
  if (nrow(data) != nrow(coords)) stop("Data and coordinate row count differ.")
  dat <- data[, parts$columns, drop = FALSE]
  for (nm in names(dat)) dat[[nm]] <- suppressWarnings(as.numeric(dat[[nm]]))
  ok <- complete.cases(dat) & apply(is.finite(as.matrix(dat)), 1L, all) & apply(is.finite(coords), 1L, all)
  if (!any(ok)) stop("No complete rows remain.")
  list(data = dat[ok, , drop = FALSE], coords = coords[ok, , drop = FALSE], parts = parts)
}

spatial_anchors <- function(coords, n_anchors, seed) {
  n <- nrow(coords)
  if (n_anchors >= n) return(seq_len(n))
  side <- ceiling(sqrt(n_anchors))
  xr <- diff(range(coords[, 1])); yr <- diff(range(coords[, 2]))
  cell <- pmin(floor((coords[, 1] - min(coords[, 1])) / max(xr, 1e-12) * side), side - 1L) +
    side * pmin(floor((coords[, 2] - min(coords[, 2])) / max(yr, 1e-12) * side), side - 1L)
  ids <- vapply(split(seq_len(n), cell), function(ix) {
    centre <- colMeans(coords[ix, , drop = FALSE])
    ix[which.min(rowSums((coords[ix, , drop = FALSE] - centre)^2))]
  }, integer(1))
  if (length(ids) < n_anchors) {
    set.seed(seed)
    ids <- c(ids, sample(setdiff(seq_len(n), ids), n_anchors - length(ids)))
  }
  sort(ids[seq_len(min(length(ids), n_anchors))])
}

fit_local_forest <- function(data, formula, ids, distances, mtry, trees, seed) {
  ranger::ranger(
    formula = formula, data = data[ids, , drop = FALSE], num.trees = as.integer(trees),
    mtry = min(as.integer(mtry), ncol(data) - 1L), case.weights = bisquare_weights(distances),
    num.threads = 1L, seed = as.integer(seed), respect.unordered.factors = "order"
  )
}

sparse_grf_bandwidth <- function(formula, data, coords, minimum, maximum, step, trees, mtry, anchors, seed, verbose = FALSE) {
  z <- prepare_grf_data(data, formula, coords)
  n <- nrow(z$data); min_k <- max(20L, length(z$parts$predictors) + 2L)
  candidates <- seq.int(as.integer(minimum), as.integer(min(maximum, n - 1L)), by = as.integer(step))
  candidates <- candidates[candidates >= min_k]
  if (!length(candidates)) stop("No valid candidate neighbour counts. Check bandwidth limits and sample size.")
  focal <- spatial_anchors(z$coords, min(as.integer(anchors), n), seed)
  knn <- RANN::nn2(lonlat_to_xyz(z$coords), lonlat_to_xyz(z$coords[focal, , drop = FALSE]), k = max(candidates) + 1L)
  dm <- chord_to_distance(knn$nn.dists); y <- z$data[[z$parts$response]]
  scores <- lapply(seq_along(candidates), function(i) {
    k <- candidates[i]; p <- numeric(length(focal))
    if (isTRUE(verbose)) message(sprintf("  [bandwidth] candidate %d/%d: k=%d", i, length(candidates), k))
    for (j in seq_along(focal)) {
      use <- which(knn$nn.idx[j, ] != focal[j])[seq_len(k)]
      local <- fit_local_forest(z$data, z$parts$formula, knn$nn.idx[j, use], dm[j, use], mtry, trees, seed + i * 100000L + j)
      p[j] <- stats::predict(local, z$data[focal[j], z$parts$predictors, drop = FALSE])$predictions
    }
    obs <- y[focal]
    data.frame(neighbors = k, RMSE = sqrt(mean((obs - p)^2)), MAE = mean(abs(obs - p)), R2 = 1 - sum((obs - p)^2) / sum((obs - mean(obs))^2))
  })
  scores <- do.call(rbind, scores)
  scores <- scores[order(scores$RMSE, scores$MAE), , drop = FALSE]
  list(best = scores$neighbors[1], scores = scores)
}

fit_sparse_grf <- function(formula, data, coords, neighbors, trees, mtry, anchors, workers, seed, verbose = FALSE) {
  z <- prepare_grf_data(data, formula, coords); n <- nrow(z$data)
  if (neighbors < max(20L, length(z$parts$predictors) + 2L) || neighbors > n) stop("Invalid selected neighbour count.")
  anchor_ids <- spatial_anchors(z$coords, min(as.integer(anchors), n), seed)
  xyz <- lonlat_to_xyz(z$coords)
  knn <- RANN::nn2(xyz, xyz[anchor_ids, , drop = FALSE], k = as.integer(neighbors))
  distances <- chord_to_distance(knn$nn.dists)
  if (isTRUE(verbose)) message(sprintf("  [fit_sparse_grf] fitting %d local forests with k=%d", length(anchor_ids), neighbors))
  fit_one <- function(i) fit_local_forest(z$data, z$parts$formula, knn$nn.idx[i, ], distances[i, ], mtry, trees, seed + i)
  local_models <- if (workers <= 1L) lapply(seq_along(anchor_ids), fit_one) else {
    cl <- parallel::makePSOCKcluster(min(as.integer(workers), length(anchor_ids)))
    on.exit(parallel::stopCluster(cl), add = TRUE)
    parallel::clusterEvalQ(cl, library(ranger))
    parallel::clusterExport(cl, c("z", "knn", "distances", "mtry", "trees", "seed", "fit_local_forest", "bisquare_weights"), envir = environment())
    parallel::parLapply(cl, seq_along(anchor_ids), function(i) fit_local_forest(z$data, z$parts$formula, knn$nn.idx[i, ], distances[i, ], mtry, trees, seed + i))
  }
  global <- ranger::ranger(formula = z$parts$formula, data = z$data, num.trees = as.integer(trees),
    mtry = min(mtry, length(z$parts$predictors)), num.threads = 1L, seed = as.integer(seed), respect.unordered.factors = "order")
  structure(list(predictors = z$parts$predictors, anchor_xyz = xyz[anchor_ids, , drop = FALSE],
    local_models = local_models, global_model = global, neighbors = neighbors), class = "sparse_grf")
}

predict.sparse_grf <- function(object, newdata, newcoords, local_weight = 1, verbose = FALSE, label = "prediction") {
  if (!all(object$predictors %in% names(newdata))) stop("Prediction data lack model predictors.")
  if (nrow(newdata) != nrow(newcoords)) stop("Prediction data and coordinates differ in row count.")
  nearest <- RANN::nn2(object$anchor_xyz, lonlat_to_xyz(newcoords), k = 1L)$nn.idx[, 1]
  local <- numeric(nrow(newdata))
  anchor_groups <- unique(nearest)
  if (isTRUE(verbose)) message(sprintf("  [predict.sparse_grf] %s: %d rows across %d local models", label, nrow(newdata), length(anchor_groups)))
  report_every <- max(1L, ceiling(length(anchor_groups) / 20L))
  for (i in seq_along(anchor_groups)) {
    a <- anchor_groups[i]
    rows <- which(nearest == a)
    local[rows] <- stats::predict(object$local_models[[a]], newdata[rows, object$predictors, drop = FALSE])$predictions
    if (isTRUE(verbose) && (i %% report_every == 0L || i == length(anchor_groups))) message(sprintf("  [predict.sparse_grf] %s: local model %d/%d", label, i, length(anchor_groups)))
  }
  global <- stats::predict(object$global_model, newdata[, object$predictors, drop = FALSE])$predictions
  out <- local_weight * local + (1 - local_weight) * global
  out[!is.finite(out)] <- global[!is.finite(out)]
  out
}

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

index_tifs <- function(data_root) {
  files <- list.files(data_root, pattern = "\\.tif(f)?$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
  if (!length(files)) stop("No GeoTIFF files under: ", data_root)
  list(files = files, names = basename(files))
}

find_single_file <- function(index, pattern, label) {
  hit <- index$files[grepl(pattern, index$names, ignore.case = TRUE, perl = TRUE)]
  if (length(hit) != 1L) stop(label, ": expected exactly one file, found ", length(hit), "\n", paste(hit, collapse = "\n"))
  hit
}

soil_filename_pattern <- function(variable) {
  m <- regexec("^(bdod|cec|cfvo|clay|nitrogen|ocd|ocs|phh2o|sand|silt|soc)_([0-9]+)\\.([0-9]+)$", variable)
  p <- regmatches(variable, m)[[1]]
  if (length(p) != 4L) return(NULL)
  sprintf("^%s_%s-%scm_mean_1000\\.tif$", p[2], p[3], p[4])
}

source_file_for_feature <- function(feature, year, index, custom_rules = c()) {
  if (feature %in% names(custom_rules)) return(find_single_file(index, custom_rules[[feature]], feature))
  if (grepl("^bio([1-9]|1[0-9])$", feature)) return(find_single_file(index, sprintf("^china_%d_%s\\.tif$", year, feature), feature))
  if (feature == "lc") return(find_single_file(index, sprintf("^MCD12Q1_LC_ChinaBuffer_%d_500m\\.tif$", year), feature))
  if (feature == "dem") return(find_single_file(index, "^DEM1000_ncdc.*\\.tif$", feature))
  if (feature == "lai.max") return(find_single_file(index, sprintf("^maxLAI_%d\\.tif$", year), feature))
  soil <- soil_filename_pattern(feature)
  if (!is.null(soil)) return(find_single_file(index, soil, feature))
  stop("No safe raster-source rule for RFE feature: ", feature, ". Add an exact custom_file_rules entry.")
}

align_feature <- function(path, template, boundary, categorical = FALSE) {
  x <- terra::rast(path)
  if (!terra::compareGeom(x, template, stopOnError = FALSE)) x <- terra::project(x, template, method = if (categorical) "near" else "average")
  terra::mask(x, boundary)
}

# `%in%` is a base-vector operator and does not dispatch safely for SpatRaster.
# Build the mask with terra raster comparisons so it also works for >2 LC classes.
make_lc_class_mask <- function(lc, codes) {
  if (!inherits(lc, "SpatRaster") || terra::nlyr(lc) != 1L) stop("Land-cover input must be a single-layer SpatRaster.")
  codes <- as.integer(unlist(codes, use.names = FALSE))
  if (!length(codes) || any(!is.finite(codes))) stop("grassland_lc_codes must be a non-empty finite integer vector.")
  codes <- unique(codes)
  keep <- terra::ifel(lc == codes[1L], 1L, 0L)
  if (length(codes) > 1L) {
    for (code in codes[-1L]) keep <- terra::ifel(lc == code, 1L, keep)
  }
  terra::ifel(keep == 1L, 1L, NA_integer_)
}

resolve_new_filename <- function(file) {
  if (!file.exists(file)) return(file)
  stem <- tools::file_path_sans_ext(file); ext <- tools::file_ext(file)
  paste0(stem, "_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".", ext)
}

# Deliberately uses raster -> data.frame -> custom predictor; it never calls terra::predict().
predict_dataframe_raster <- function(model, raster_files, mask_file, output_file, local_weight, verbose = FALSE) {
  layers <- lapply(raster_files[model$predictors], terra::rast)
  env <- terra::rast(layers); names(env) <- model$predictors
  env <- terra::mask(env, terra::rast(mask_file))
  template <- env[[1]]
  df <- terra::as.data.frame(env, xy = TRUE, na.rm = TRUE)
  x <- as.matrix(df[, model$predictors, drop = FALSE]); storage.mode(x) <- "double"
  df <- df[apply(is.finite(x), 1L, all), , drop = FALSE]
  if (!nrow(df)) stop("No valid prediction cells.")
  if (isTRUE(verbose)) message(sprintf("  [raster prediction] %d valid raster cells converted to data.frame", nrow(df)))
  coords <- as.matrix(df[, c("x", "y")])
  pred <- predict.sparse_grf(model, df[, model$predictors, drop = FALSE], coords, local_weight, verbose = verbose, label = "raster cells")
  values <- rep(NA_real_, terra::ncell(template))
  values[terra::cellFromXY(template, coords)] <- pred
  output <- terra::rast(template); terra::values(output) <- values; names(output) <- "NPP_predicted"
  output_file <- resolve_new_filename(output_file)
  terra::writeRaster(output, output_file, overwrite = FALSE, wopt = list(datatype = "FLT4S", gdal = "COMPRESS=LZW"))
  output_file
}

predict_one_year_raster <- function(cfg, year, trained) {
  progress_note(cfg$verbose_progress, "Raster prediction: index and boundary", "START")
  idx <- index_tifs(cfg$data_root); boundary <- terra::vect(cfg$boundary_file)
  bio1 <- source_file_for_feature("bio1", year, idx, cfg$custom_file_rules)
  template <- terra::mask(terra::crop(terra::rast(bio1), boundary), boundary)
  year_dir <- trained$paths$output_dir; predictor_dir <- file.path(year_dir, "predictors")
  dir.create(predictor_dir, recursive = TRUE, showWarnings = FALSE)
  files <- setNames(character(length(trained$selected_features)), trained$selected_features)
  for (i in seq_along(trained$selected_features)) {
    feature <- trained$selected_features[i]
    progress_note(cfg$verbose_progress, sprintf("Raster predictor %d/%d", i, length(trained$selected_features)), "START", feature)
    source <- source_file_for_feature(feature, year, idx, cfg$custom_file_rules)
    target <- file.path(predictor_dir, paste0(feature, "_", year, ".tif"))
    terra::writeRaster(align_feature(source, template, boundary, feature == "lc"), target, overwrite = cfg$overwrite_outputs,
      wopt = list(datatype = "FLT4S", gdal = "COMPRESS=LZW"))
    files[[feature]] <- target
    progress_note(cfg$verbose_progress, sprintf("Raster predictor %d/%d", i, length(trained$selected_features)), "DONE", feature)
  }
  lc_source <- source_file_for_feature("lc", year, idx, cfg$custom_file_rules)
  lc <- align_feature(lc_source, template, boundary, TRUE)
  mask_file <- file.path(year_dir, sprintf("TP_LC9_10_mask_%d.tif", year))
  terra::writeRaster(make_lc_class_mask(lc, cfg$grassland_lc_codes), mask_file, overwrite = cfg$overwrite_outputs,
    wopt = list(datatype = "INT1U", gdal = "COMPRESS=LZW"))
  progress_note(cfg$verbose_progress, "Raster prediction: LC mask", "DONE")
  prediction_file <- predict_dataframe_raster(trained$model, files, mask_file, trained$paths$prediction_file, cfg$local_weight, verbose = cfg$verbose_progress)
  write.csv(data.frame(feature = names(files), raster_file = unname(files)), file.path(year_dir, "predictor_manifest.csv"), row.names = FALSE)
  writeLines(c(paste0("prediction_file=", normalizePath(prediction_file, winslash = "/")),
    paste0("grassland_lc_codes=", paste(cfg$grassland_lc_codes, collapse = ","))), file.path(year_dir, "prediction_metadata.txt"))
  progress_note(cfg$verbose_progress, "Raster prediction: write final GeoTIFF", "DONE", prediction_file)
  prediction_file
}

# ---- Sequential execution entry point ----
project_root <- "."
cfg <- default_npp_config(project_root)
progress_note(TRUE, "Load configuration", "DONE", paste0("feature selection = ", cfg$feature_selection_method))
ensure_packages()
set_run_seed(cfg$seed)

run_one_year <- function(year) {
  progress_note(cfg$verbose_progress, paste0("YEAR ", year, " training"), "START")
  trained <- train_one_year(cfg, year)
  print(trained$metrics)
  prediction_file <- NA_character_
  if (isTRUE(cfg$run_raster_prediction)) {
    progress_note(cfg$verbose_progress, paste0("YEAR ", year, " grassland raster prediction"), "START")
    prediction_file <- predict_one_year_raster(cfg, year, trained)
  }
  progress_note(cfg$verbose_progress, paste0("YEAR ", year, " complete"), "DONE")
  cbind(trained$metrics, prediction_file = prediction_file)
}

year_results <- do.call(rbind, lapply(as.integer(cfg$years), run_one_year))
dir.create(cfg$result_root, recursive = TRUE, showWarnings = FALSE)
write.csv(year_results, file.path(cfg$result_root, "all_year_model_performance.csv"), row.names = FALSE)
message("===== All configured years complete =====")
print(year_results)

