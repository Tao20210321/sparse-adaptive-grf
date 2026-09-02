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
predict_dataframe_raster <- function(model, raster_files, mask_file, output_file, local_weight) {
  layers <- lapply(raster_files[model$predictors], terra::rast)
  env <- terra::rast(layers); names(env) <- model$predictors
  env <- terra::mask(env, terra::rast(mask_file))
  template <- env[[1]]
  df <- terra::as.data.frame(env, xy = TRUE, na.rm = TRUE)
  x <- as.matrix(df[, model$predictors, drop = FALSE]); storage.mode(x) <- "double"
  df <- df[apply(is.finite(x), 1L, all), , drop = FALSE]
  if (!nrow(df)) stop("No valid prediction cells.")
  coords <- as.matrix(df[, c("x", "y")])
  pred <- predict.sparse_grf(model, df[, model$predictors, drop = FALSE], coords, local_weight)
  values <- rep(NA_real_, terra::ncell(template))
  values[terra::cellFromXY(template, coords)] <- pred
  output <- terra::rast(template); terra::values(output) <- values; names(output) <- "NPP_predicted"
  output_file <- resolve_new_filename(output_file)
  terra::writeRaster(output, output_file, overwrite = FALSE, wopt = list(datatype = "FLT4S", gdal = "COMPRESS=LZW"))
  output_file
}

predict_one_year_raster <- function(cfg, year, trained) {
  idx <- index_tifs(cfg$data_root); boundary <- terra::vect(cfg$boundary_file)
  bio1 <- source_file_for_feature("bio1", year, idx, cfg$custom_file_rules)
  template <- terra::mask(terra::crop(terra::rast(bio1), boundary), boundary)
  year_dir <- trained$paths$output_dir; predictor_dir <- file.path(year_dir, "predictors")
  dir.create(predictor_dir, recursive = TRUE, showWarnings = FALSE)
  files <- setNames(character(length(trained$selected_features)), trained$selected_features)
  for (feature in trained$selected_features) {
    source <- source_file_for_feature(feature, year, idx, cfg$custom_file_rules)
    target <- file.path(predictor_dir, paste0(feature, "_", year, ".tif"))
    terra::writeRaster(align_feature(source, template, boundary, feature == "lc"), target, overwrite = cfg$overwrite_outputs,
      wopt = list(datatype = "FLT4S", gdal = "COMPRESS=LZW"))
    files[[feature]] <- target
  }
  lc_source <- source_file_for_feature("lc", year, idx, cfg$custom_file_rules)
  lc <- align_feature(lc_source, template, boundary, TRUE)
  mask_file <- file.path(year_dir, sprintf("TP_LC9_10_mask_%d.tif", year))
  terra::writeRaster(make_lc_class_mask(lc, cfg$grassland_lc_codes), mask_file, overwrite = cfg$overwrite_outputs,
    wopt = list(datatype = "INT1U", gdal = "COMPRESS=LZW"))
  prediction_file <- predict_dataframe_raster(trained$model, files, mask_file, trained$paths$prediction_file, cfg$local_weight)
  write.csv(data.frame(feature = names(files), raster_file = unname(files)), file.path(year_dir, "predictor_manifest.csv"), row.names = FALSE)
  writeLines(c(paste0("prediction_file=", normalizePath(prediction_file, winslash = "/")),
    paste0("grassland_lc_codes=", paste(cfg$grassland_lc_codes, collapse = ","))), file.path(year_dir, "prediction_metadata.txt"))
  prediction_file
}

