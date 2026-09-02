\name{run_npp_workflow}
\alias{default_npp_config}
\alias{validate_npp_config}
\alias{year_paths}
\alias{train_one_year}
\alias{predict_one_year_raster}
\alias{predict_dataframe_raster}
\alias{make_lc_class_mask}
\alias{run_npp_workflow}
\title{Configure and run annual NPP modelling workflows}
\usage{
default_npp_config(project_root = normalizePath(".", winslash = "/", mustWork = FALSE))

validate_npp_config(cfg, require_raster = FALSE)
year_paths(cfg, year)
train_one_year(cfg, year)
predict_one_year_raster(cfg, year, trained)
predict_dataframe_raster(model, raster_files, mask_file, output_file,
  local_weight, verbose = FALSE)
make_lc_class_mask(lc, codes)
run_npp_workflow(cfg)
}
\arguments{
  \item{project_root}{Project and default results root.}
  \item{cfg}{A configuration list. Input paths must be set explicitly.}
  \item{require_raster}{Whether raster input paths must be validated.}
  \item{year}{Integer year.}
  \item{trained}{Object returned by \code{train_one_year()}.}
  \item{model}{A fitted \code{sparse_grf} model.}
  \item{raster_files}{Named paths for each fitted predictor.}
  \item{mask_file}{Single-layer raster mask path.}
  \item{output_file}{Requested output GeoTIFF path.}
  \item{local_weight}{Weight assigned to local predictions.}
  \item{verbose}{Print prediction progress.}
  \item{lc}{Single-layer land-cover \code{SpatRaster}.}
  \item{codes}{Land-cover classes retained for prediction.}
}
\value{
\code{train_one_year()} returns the fitted model, selected predictors, metrics,
and output paths. \code{run_npp_workflow()} returns one metrics row per year.
}
\description{
Provides reproducible annual NPP training and raster prediction. Raster
prediction deliberately converts valid cells to a data frame before prediction;
it does not call \code{terra::predict()}.
}

