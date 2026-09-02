# Sequential, reproducible entry point. Run this file from the project root.
# Configure only R/00_config.R; this file reports progress while it calls each module.
project_root <- "."
source(file.path(project_root, "R", "00_config.R"))
source(file.path(project_root, "R", "01_reproducibility.R"))
source(file.path(project_root, "R", "02_sparse_adaptive_grf.R"))
source(file.path(project_root, "R", "03_training.R"))
source(file.path(project_root, "R", "04_raster_prediction.R"))
source(file.path(project_root, "R", "05_workflow.R"))

cfg <- if (exists("npp_cfg", envir = .GlobalEnv, inherits = FALSE)) {
  get("npp_cfg", envir = .GlobalEnv, inherits = FALSE)
} else {
  default_npp_config(project_root)
}
progress_note(TRUE, "Load configuration", "DONE", paste0("feature selection = ", cfg$feature_selection_method))
run_npp_workflow(cfg)

