required_packages <- c("ranger", "RANN", "caret", "randomForest", "terra", "ggplot2")

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
    extra, "", "sessionInfo:", utils::capture.output(utils::sessionInfo())
  )
  writeLines(txt, file.path(paths$output_dir, "run_provenance.txt"))
}

