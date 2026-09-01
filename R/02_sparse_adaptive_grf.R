# Sparse adaptive geographically weighted random forest: no N by N distance matrix.
earth_radius_m <- 6371008.8

validate_lonlat <- function(coords, allow_missing = FALSE) {
  coords <- as.matrix(coords)
  storage.mode(coords) <- "double"
  if (ncol(coords) != 2L || (!allow_missing && any(!is.finite(coords)))) stop("Coordinates must be finite longitude/latitude columns.")
  keep <- apply(is.finite(coords), 1L, all)
  if (any(abs(coords[keep, 1]) > 180) || any(abs(coords[keep, 2]) > 90)) stop("Coordinates must be longitude/latitude in degrees.")
  coords
}

lonlat_to_xyz <- function(coords) {
  coords <- validate_lonlat(coords)
  lon <- coords[, 1] * pi / 180
  lat <- coords[, 2] * pi / 180
  cbind(earth_radius_m * cos(lat) * cos(lon), earth_radius_m * cos(lat) * sin(lon), earth_radius_m * sin(lat))
}

chord_to_distance <- function(chord) {
  z <- pmin(pmax(chord / (2 * earth_radius_m), 0), 1)
  2 * earth_radius_m * asin(z)
}

bisquare_weights <- function(distances) {
  h <- tail(distances, 1L)
  if (!is.finite(h) || h <= 0) return(rep(1, length(distances)))
  w <- (1 - (distances / h)^2)^2
  w[!is.finite(w) | w < 0] <- 0
  if (sum(w > 0) < 2L) w <- rep(1, length(w))
  w
}

formula_parts <- function(formula, data) {
  formula <- stats::as.formula(formula)
  response <- all.vars(formula[[2]])
  predictors <- attr(stats::terms(formula), "term.labels")
  if (length(response) != 1L || !all(c(response, predictors) %in% names(data))) stop("Formula columns are missing from data.")
  list(formula = formula, response = response, predictors = predictors, columns = c(response, predictors))
}

prepare_grf_data <- function(data, formula, coords) {
  parts <- formula_parts(formula, data)
  coords <- validate_lonlat(coords, allow_missing = TRUE)
  if (nrow(data) != nrow(coords)) stop("Data and coordinate row count differ.")
  dat <- data[, parts$columns, drop = FALSE]
  for (nm in names(dat)) dat[[nm]] <- suppressWarnings(as.numeric(dat[[nm]]))
  ok <- complete.cases(dat) & apply(is.finite(as.matrix(dat)), 1L, all) & apply(is.finite(coords), 1L, all)
  if (!any(ok)) stop("No complete rows remain.")
  list(data = dat[ok, , drop = FALSE], coords = coords[ok, , drop = FALSE], parts = parts)
}

spatial_anchors <- function(coords, n_anchors, seed) {
  n <- nrow(coords)
  if (n_anchors >= n) return(seq_len(n))
  side <- ceiling(sqrt(n_anchors))
  xr <- diff(range(coords[, 1])); yr <- diff(range(coords[, 2]))
  cell <- pmin(floor((coords[, 1] - min(coords[, 1])) / max(xr, 1e-12) * side), side - 1L) +
    side * pmin(floor((coords[, 2] - min(coords[, 2])) / max(yr, 1e-12) * side), side - 1L)
  ids <- vapply(split(seq_len(n), cell), function(ix) {
    centre <- colMeans(coords[ix, , drop = FALSE])
    ix[which.min(rowSums((coords[ix, , drop = FALSE] - centre)^2))]
  }, integer(1))
  if (length(ids) < n_anchors) {
    set.seed(seed)
    ids <- c(ids, sample(setdiff(seq_len(n), ids), n_anchors - length(ids)))
  }
  sort(ids[seq_len(min(length(ids), n_anchors))])
}

fit_local_forest <- function(data, formula, ids, distances, mtry, trees, seed) {
  ranger::ranger(
    formula = formula, data = data[ids, , drop = FALSE], num.trees = as.integer(trees),
    mtry = min(as.integer(mtry), ncol(data) - 1L), case.weights = bisquare_weights(distances),
    num.threads = 1L, seed = as.integer(seed), respect.unordered.factors = "order"
  )
}

sparse_grf_bandwidth <- function(formula, data, coords, minimum, maximum, step, trees, mtry, anchors, seed) {
  z <- prepare_grf_data(data, formula, coords)
  n <- nrow(z$data); min_k <- max(20L, length(z$parts$predictors) + 2L)
  candidates <- seq.int(as.integer(minimum), as.integer(min(maximum, n - 1L)), by = as.integer(step))
  candidates <- candidates[candidates >= min_k]
  if (!length(candidates)) stop("No valid candidate neighbour counts. Check bandwidth limits and sample size.")
  focal <- spatial_anchors(z$coords, min(as.integer(anchors), n), seed)
  knn <- RANN::nn2(lonlat_to_xyz(z$coords), lonlat_to_xyz(z$coords[focal, , drop = FALSE]), k = max(candidates) + 1L)
  dm <- chord_to_distance(knn$nn.dists); y <- z$data[[z$parts$response]]
  scores <- lapply(seq_along(candidates), function(i) {
    k <- candidates[i]; p <- numeric(length(focal))
    for (j in seq_along(focal)) {
      use <- which(knn$nn.idx[j, ] != focal[j])[seq_len(k)]
      local <- fit_local_forest(z$data, z$parts$formula, knn$nn.idx[j, use], dm[j, use], mtry, trees, seed + i * 100000L + j)
      p[j] <- stats::predict(local, z$data[focal[j], z$parts$predictors, drop = FALSE])$predictions
    }
    obs <- y[focal]
    data.frame(neighbors = k, RMSE = sqrt(mean((obs - p)^2)), MAE = mean(abs(obs - p)), R2 = 1 - sum((obs - p)^2) / sum((obs - mean(obs))^2))
  })
  scores <- do.call(rbind, scores)
  scores <- scores[order(scores$RMSE, scores$MAE), , drop = FALSE]
  list(best = scores$neighbors[1], scores = scores)
}

fit_sparse_grf <- function(formula, data, coords, neighbors, trees, mtry, anchors, workers, seed) {
  z <- prepare_grf_data(data, formula, coords); n <- nrow(z$data)
  if (neighbors < max(20L, length(z$parts$predictors) + 2L) || neighbors > n) stop("Invalid selected neighbour count.")
  anchor_ids <- spatial_anchors(z$coords, min(as.integer(anchors), n), seed)
  xyz <- lonlat_to_xyz(z$coords)
  knn <- RANN::nn2(xyz, xyz[anchor_ids, , drop = FALSE], k = as.integer(neighbors))
  distances <- chord_to_distance(knn$nn.dists)
  fit_one <- function(i) fit_local_forest(z$data, z$parts$formula, knn$nn.idx[i, ], distances[i, ], mtry, trees, seed + i)
  local_models <- if (workers <= 1L) lapply(seq_along(anchor_ids), fit_one) else {
    cl <- parallel::makePSOCKcluster(min(as.integer(workers), length(anchor_ids)))
    on.exit(parallel::stopCluster(cl), add = TRUE)
    parallel::clusterEvalQ(cl, library(ranger))
    parallel::clusterExport(cl, c("z", "knn", "distances", "mtry", "trees", "seed", "fit_local_forest", "bisquare_weights"), envir = environment())
    parallel::parLapply(cl, seq_along(anchor_ids), function(i) fit_local_forest(z$data, z$parts$formula, knn$nn.idx[i, ], distances[i, ], mtry, trees, seed + i))
  }
  global <- ranger::ranger(formula = z$parts$formula, data = z$data, num.trees = as.integer(trees),
    mtry = min(mtry, length(z$parts$predictors)), num.threads = 1L, seed = as.integer(seed), respect.unordered.factors = "order")
  structure(list(predictors = z$parts$predictors, anchor_xyz = xyz[anchor_ids, , drop = FALSE],
    local_models = local_models, global_model = global, neighbors = neighbors), class = "sparse_grf")
}

predict.sparse_grf <- function(object, newdata, newcoords, local_weight = 1) {
  if (!all(object$predictors %in% names(newdata))) stop("Prediction data lack model predictors.")
  if (nrow(newdata) != nrow(newcoords)) stop("Prediction data and coordinates differ in row count.")
  nearest <- RANN::nn2(object$anchor_xyz, lonlat_to_xyz(newcoords), k = 1L)$nn.idx[, 1]
  local <- numeric(nrow(newdata))
  for (a in unique(nearest)) {
    rows <- which(nearest == a)
    local[rows] <- stats::predict(object$local_models[[a]], newdata[rows, object$predictors, drop = FALSE])$predictions
  }
  global <- stats::predict(object$global_model, newdata[, object$predictors, drop = FALSE])$predictions
  out <- local_weight * local + (1 - local_weight) * global
  out[!is.finite(out)] <- global[!is.finite(out)]
  out
}

