# NPP sparse adaptive GRF

This is a reproducible R workflow that trains a separate sparse adaptive geographically weighted random forest (SA-GRF) for each configured year, uses RFE to choose predictors, and predicts NPP for Tibetan-Plateau MCD12Q1 LC_Type1 classes 9 and 10.

## Quick start

1. Install R packages: `ranger`, `RANN`, `caret`, `randomForest`, `terra`, `sf`, and `ggplot2`.
2. Edit `R/00_config.R`: check paths, years, candidate features, available CPU/RAM, and any `custom_file_rules`.
3. In R, set this project as the working directory and run `source("run_pipeline.R")`.
4. Read `results/<year>/test_metrics.csv` and `results/all_year_model_performance.csv` before interpreting maps.

For a multi-year run, set `cfg$years <- 2001:2024` in `run_pipeline.R` (or in a small local caller). Each year must have a matching training CSV and the rasters required by that year's RFE-selected variables.

To smoke-test RFE/training with the committed 1,000-row sample, run `source("run_example.R")`. It deliberately lowers the neighbour range and disables raster prediction; after a 70/30 split, the full-run minimum of 1,000 neighbours would be impossible for this small sample.

## Repository contents

| Path | Purpose |
|---|---|
| `R/00_config.R` | Central paths, years, root seed, feature universe and model settings. |
| `R/01_reproducibility.R` | Package validation, deterministic RNG and per-run provenance. |
| `R/02_sparse_adaptive_grf.R` | Sparse kNN spatial search, bandwidth selection, local/global RF fitting and prediction. It avoids `as.matrix(dist(coords))`. |
| `R/03_training.R` | NPP-centred synchronized cleaning, leakage-safe split/outlier rule, RFE, mtry tuning, fitting and independent testing. |
| `R/04_raster_prediction.R` | Dynamic selected-variable discovery, BIO1-grid alignment, LC 9/10 mask, raster-to-data.frame prediction and safe output naming. |
| `run_pipeline.R` | One final entry point that calls every module year by year. |
| `run_example.R` | Small-data RFE/training smoke test with valid small-sample settings. |
| `scripts/create_example_data.R` | Creates the committed 2001 first-1,000-row demonstration table from a local full CSV. |
| `data/example/` | The deliberately limited, non-raster example input only. |
| `docs/TECHNICAL_GUIDE.md` | Inputs, outputs, assumptions, performance evidence and troubleshooting. |

## Data safety

Only `data/example/nature_database_2001_first1000.csv` is intended for version control. It contains the first 1,000 2001 table records after removal of the file's row-index column. Full training tables, rasters, RDS models and outputs are excluded by `.gitignore`.

## Interpretation boundary

The output is a model-based NPP estimate under observed annual environmental conditions. It is not automatically ecological potential NPP. If the calibration data were constrained to protected/stable/no-fire sites, the LC 9/10 map is a spatial extrapolation; report that explicitly and inspect extrapolation diagnostics before scientific use.

