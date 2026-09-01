# Small-data smoke test for the committed 2001 first-1,000-row example.
# It tests training/RFE only; it cannot create a plateau raster without local raster inputs.
# Keep paths relative here: some Windows R builds mishandle a non-ASCII absolute working directory.
project_root <- "."
source(file.path(project_root, "R", "00_config.R"))
source(file.path(project_root, "R", "01_reproducibility.R"))
source(file.path(project_root, "R", "02_sparse_adaptive_grf.R"))
source(file.path(project_root, "R", "03_training.R"))

cfg <- default_npp_config(project_root)
cfg$training_csv_pattern <- file.path(project_root, "data", "example", "nature_database_2001_first1000.csv")
cfg$result_root <- file.path(project_root, "example_results")
cfg$run_raster_prediction <- FALSE
cfg$rfe_folds <- 5L
cfg$rfe_trees <- 100L
cfg$bw_coarse <- list(min = 100L, max = 500L, step = 100L, trees = 100L, anchors = 40L)
cfg$bw_fine_half_width <- 50L
cfg$bw_fine_step <- 25L
cfg$bw_fine_anchors <- 60L
cfg$final_trees <- 100L
cfg$n_anchor_models <- 100L
cfg$outer_workers <- 1L

ensure_packages()
set_run_seed(cfg$seed)
result <- train_one_year(cfg, 2001L)
print(result$metrics)

