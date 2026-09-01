# Final caller: train and optionally predict every configured year.
# Keep paths relative here: some Windows R builds mishandle a non-ASCII absolute working directory.
project_root <- "."
source(file.path(project_root, "R", "00_config.R"))
source(file.path(project_root, "R", "01_reproducibility.R"))
source(file.path(project_root, "R", "02_sparse_adaptive_grf.R"))
source(file.path(project_root, "R", "03_training.R"))
source(file.path(project_root, "R", "04_raster_prediction.R"))

cfg <- default_npp_config(project_root)
# Example for a full annual run: cfg$years <- 2001:2024
ensure_packages()
set_run_seed(cfg$seed)

run_one_year <- function(year) {
  message("===== Year ", year, ": training =====")
  trained <- train_one_year(cfg, year)
  prediction_file <- NA_character_
  if (isTRUE(cfg$run_raster_prediction)) {
    message("===== Year ", year, ": grassland raster prediction =====")
    prediction_file <- predict_one_year_raster(cfg, year, trained)
  }
  cbind(trained$metrics, prediction_file = prediction_file)
}

year_results <- do.call(rbind, lapply(as.integer(cfg$years), run_one_year))
dir.create(cfg$result_root, recursive = TRUE, showWarnings = FALSE)
write.csv(year_results, file.path(cfg$result_root, "all_year_model_performance.csv"), row.names = FALSE)
print(year_results)

