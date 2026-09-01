# Technical guide

## Model sequence

For each year the pipeline: (1) reads that year's table; (2) creates one joint finite/complete-case mask for NPP, coordinates and all candidate predictors; (3) makes a fixed random train/test split from the root seed; (4) learns NPP outlier limits using training labels only; (5) runs repeated-seed RFE; (6) tunes `mtry`; (7) selects adaptive neighbour count by coarse then fine anchor validation; (8) fits local sparse forests plus one global forest; and (9) evaluates the untouched test set.

The model uses 3-D Earth-centred coordinates and `RANN::nn2` to obtain only required neighbours. It never constructs the all-pairs distance matrix that causes `SpatialML::grf.bw()` to exceed R integer/memory limits on large samples.

## Input requirements

The annual CSV must contain `x`, `y`, `NPP`, and every entry in `candidate_features`. Coordinates must be WGS84 longitude/latitude degrees. Values must be numeric or safely convertible to numeric. The data-cleaning mask is synchronized, so a retained NPP record and all predictors always refer to the same original row. `source_row` in test outputs enables provenance back to the input table.

RFE does not use a fixed final variable list. It chooses from `candidate_features` independently for each year. The selected names are saved in `rfe_selected_features.csv`; raster prediction then requests only those rasters. Add a precise regular expression to `custom_file_rules` when an RFE variable does not follow an existing filename rule.

The included 2001 sample is a code smoke test, not a calibrated benchmark. Its 1,000 rows yield fewer than 1,000 training rows after the held-out split, so `run_example.R` uses a 100--500-neighbour search. Keep the larger settings in `R/00_config.R` for the full annual data.

## Raster prediction and resources

BIO1 defines the output grid. Numeric predictors are projected with average resampling; land cover uses nearest-neighbour resampling. The final mask retains only LC codes 9 and 10 as requested. Prediction deliberately converts the masked stack to one `data.frame` and calls the custom model predictor, rather than `terra::predict()`.

This choice avoids the earlier `terra::predict` argument/interface failures, but it is RAM-intensive. A masked 1.8-million-cell stack with 13 double predictors needs substantial multi-GB memory before model overhead. Close QGIS/ArcGIS files, keep `outer_workers` low on Windows (often 1--4), and first run one year. The code refuses to overwrite a pre-existing final TIFF: a timestamped filename is created instead.

## Outputs to inspect

| Output | Use |
|---|---|
| `rfe_selected_features.csv` | Selected variables for this year. |
| `rfe_cv_results.csv` | RFE cross-validation evidence. |
| `mtry_oob.csv` | Global RF OOB tuning table. |
| `bandwidth_coarse.csv`, `bandwidth_fine.csv` | RMSE/MAE/R2 evidence for neighbour selection. |
| `test_metrics.csv` | Independent test RMSE, MAE and R2. |
| `test_predictions.csv` | Test observations/predictions and source rows. |
| `npp_cleaning_rule.csv` | Cleaning/outlier bounds and complete-row count. |
| `run_provenance.txt` | Seed, inputs, selected variables and package session. |
| `NPP_simulated_*.tif` | Plateau LC 9/10 NPP prediction. |

## Scientific cautions

The MCD12Q1 class labels should be verified against the exact land-cover product/version before labelling outputs as "grassland"; code 9 and code 10 are kept because they are the explicit modelling scope. Strong random-split performance can be optimistic under spatial autocorrelation. For a publication claim, add spatial-block cross-validation, map environmental extrapolation, report response-source uncertainty, and compare against a non-spatial RF baseline.

