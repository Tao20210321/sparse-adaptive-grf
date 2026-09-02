# Sequential, reproducible entry point. Run this file from the project root.
# Configure only R/00_config.R; this file reports progress while it calls each module.
project_root <- "."
source(file.path(project_root, "R", "00_config.R"))
source(file.path(project_root, "R", "01_reproducibility.R"))
source(file.path(project_root, "R", "02_sparse_adaptive_grf.R"))
source(file.path(project_root, "R", "03_training.R"))
source(file.path(project_root, "R", "04_raster_prediction.R"))

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

