\name{filter_features_vif}
\alias{filter_features_vif}
\alias{select_features_rfe}
\alias{select_features_importance}
\title{Select predictors after VIF filtering}
\usage{
filter_features_vif(train, cfg)
select_features_rfe(train, cfg, features)
select_features_importance(train, cfg, features)
}
\arguments{
  \item{train}{Training data frame produced by synchronized NPP cleaning.}
  \item{cfg}{A configuration list.}
  \item{features}{Predictor names retained after VIF filtering.}
}
\value{
Each function returns selected predictors and method-specific diagnostics.
}
\description{
\code{filter_features_vif()} iteratively removes high-VIF numeric predictors.
Predictors listed in \code{cfg$vif_exclude_features}, such as categorical land
cover, are retained but excluded from numeric VIF regressions. RFE uses
cross-validation; importance ranking selects the top-k subset by training OOB
RMSE without using the independent test set.
}

