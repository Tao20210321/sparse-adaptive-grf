\name{fit_sparse_grf}
\alias{fit_sparse_grf}
\alias{sparse_grf_bandwidth}
\alias{predict.sparse_grf}
\title{Fit, tune, and predict a sparse adaptive GRF}
\usage{
fit_sparse_grf(formula, data, coords, neighbors, trees, mtry, anchors,
  workers, seed, verbose = FALSE)

sparse_grf_bandwidth(formula, data, coords, minimum, maximum, step,
  trees, mtry, anchors, seed, verbose = FALSE)

\method{predict}{sparse_grf}(object, newdata, newcoords, local_weight = 1,
  verbose = FALSE, label = "prediction")
}
\arguments{
  \item{formula}{A model formula with one numeric response.}
  \item{data}{A data frame containing the formula columns.}
  \item{coords}{Two-column longitude/latitude coordinates in decimal degrees.}
  \item{neighbors}{Adaptive-neighbour count for each local forest.}
  \item{trees}{Number of trees in each forest.}
  \item{mtry}{Number of predictors sampled at each split.}
  \item{anchors}{Number of spatial anchor forests.}
  \item{workers}{Number of local-fitting worker processes.}
  \item{seed}{Integer random seed.}
  \item{verbose}{Print progress messages.}
  \item{minimum, maximum, step}{Integer range of neighbour candidates.}
  \item{object}{A \code{sparse_grf} object.}
  \item{newdata}{Prediction data containing the fitted predictors.}
  \item{newcoords}{Prediction coordinates matching \code{newdata}.}
  \item{local_weight}{Weight assigned to local predictions from zero to one.}
  \item{label}{Progress label.}
}
\value{
\code{sparse_grf_bandwidth()} returns the selected neighbour count and score table.
\code{fit_sparse_grf()} returns a \code{sparse_grf} object. Its \code{predict()}
method returns a numeric prediction vector.
}
\description{
Uses k-nearest-neighbour searches and spatial anchors rather than a dense
pairwise-distance matrix.
}

