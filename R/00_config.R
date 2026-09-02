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
    overwrite_outputs = TRUE,
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

