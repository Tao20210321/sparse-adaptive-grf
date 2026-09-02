#' Run the configured annual NPP workflow
#'
#' Runs one independent training, evaluation, and optional raster prediction
#' workflow per configured year. Use [default_npp_config()] to create `cfg`, set
#' all input paths explicitly, then call this function.
#'
#' @param cfg A configuration list from [default_npp_config()].
#' @return A data frame of annual independent-test metrics, with a
#'   `prediction_file` column when raster prediction is enabled.
#' @export
run_npp_workflow <- function(cfg) {
  validate_npp_config(cfg, require_raster = isTRUE(cfg$run_raster_prediction))
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
  utils::write.csv(year_results, file.path(cfg$result_root, "all_year_model_performance.csv"), row.names = FALSE)
  message("===== All configured years complete =====")
  print(year_results)
  invisible(year_results)
}

