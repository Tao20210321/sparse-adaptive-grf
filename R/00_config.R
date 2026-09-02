# Central configuration. Set the three input paths before a production run.

default_npp_config <- function(project_root = normalizePath(".", winslash = "/", mustWork = FALSE)) {
  list(
    project_root = project_root,
    data_root = NA_character_,
    boundary_file = NA_character_,
    training_csv_pattern = NA_character_,
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
    # Categorical predictors are retained for selection but excluded from numeric VIF models.
    vif_exclude_features = c("lc"),
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

validate_npp_config <- function(cfg, require_raster = FALSE) {
  required <- c("target", "coord_cols", "candidate_features", "training_csv_pattern", "result_root")
  missing <- required[!required %in% names(cfg)]
  if (length(missing)) stop("Configuration is missing fields: ", paste(missing, collapse = ", "))
  if (!is.character(cfg$training_csv_pattern) || length(cfg$training_csv_pattern) != 1L || is.na(cfg$training_csv_pattern) || !nzchar(cfg$training_csv_pattern)) {
    stop("Set cfg$training_csv_pattern to a sprintf-compatible annual CSV path before training.")
  }
  if (!is.character(cfg$result_root) || length(cfg$result_root) != 1L || is.na(cfg$result_root) || !nzchar(cfg$result_root)) {
    stop("Set cfg$result_root to a writable directory.")
  }
  excluded <- if (is.null(cfg$vif_exclude_features)) character() else cfg$vif_exclude_features
  unknown_excluded <- setdiff(excluded, cfg$candidate_features)
  if (length(unknown_excluded)) stop("vif_exclude_features are not candidate_features: ", paste(unknown_excluded, collapse = ", "))
  if (isTRUE(require_raster)) {
    for (field in c("data_root", "boundary_file")) {
      value <- cfg[[field]]
      if (!is.character(value) || length(value) != 1L || is.na(value) || !nzchar(value)) stop("Set cfg$", field, " before raster prediction.")
    }
  }
  invisible(TRUE)
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

