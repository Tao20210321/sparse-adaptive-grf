# NPP sparse adaptive GRF

This is an installable R package and reproducible workflow that trains a separate sparse adaptive geographically weighted random forest (SA-GRF) for each configured year, uses RFE to choose predictors, and predicts NPP for Tibetan-Plateau MCD12Q1 LC_Type1 classes 9 and 10.

## Quick start

1. Install the package from its local source directory: `pak::local_install(".")`, or run `devtools::install(".")`. If Windows cannot install from a Chinese-path directory, copy the repository to an ASCII-only path such as `C:/Rpackages/sparse-adaptive-grf` first.
2. Create `cfg <- sparseAdaptiveGRF::default_npp_config()` and explicitly set `training_csv_pattern`, `result_root`, years, candidate features, and (for maps) `data_root`, `boundary_file`, and any `custom_file_rules`.
3. Run `sparseAdaptiveGRF::run_npp_workflow(cfg)`. For local development without installation, assign the configured object to `npp_cfg`, then run `source("00_run_workflow.R")`.
4. Read `results/<year>/test_metrics.csv` and `results/all_year_model_performance.csv` before interpreting maps.

For a multi-year run, set `cfg$years <- 2001:2024` in `R/00_config.R` (or in a small local caller). Each year must have a matching training CSV and the rasters required by that year's RFE-selected variables.

To smoke-test RFE/training with the committed 1,000-row sample, run `source("run_example.R")`. It deliberately lowers the neighbour range and disables raster prediction; after a 70/30 split, the full-run minimum of 1,000 neighbours would be impossible for this small sample.

## Repository contents

| Path | Purpose |
|---|---|
| `DESCRIPTION`, `NAMESPACE`, `man/` | Package metadata, public API and R help pages. |
| `R/00_config.R` | Central configuration constructor, validation, years, seed, feature universe and model settings. |
| `R/01_reproducibility.R` | Package validation, deterministic RNG and per-run provenance. |
| `R/02_sparse_adaptive_grf.R` | Sparse kNN spatial search, bandwidth selection, local/global RF fitting and prediction. It avoids `as.matrix(dist(coords))`. |
| `R/03_training.R` | NPP-centred synchronized cleaning, training-only VIF/selection, tuning, fitting, independent testing and diagnostic figures. |
| `R/04_raster_prediction.R` | Dynamic selected-variable discovery, BIO1-grid alignment, LC 9/10 mask, raster-to-data.frame prediction and safe output naming. |
| `R/05_workflow.R` | Public `run_npp_workflow()` orchestration function. |
| `00_run_workflow.R` | Sequential entry point with start/end timing messages for every major step. |
| `run_example.R` | Small-data RFE/training smoke test with valid small-sample settings. |
| `data/example/` | The deliberately limited, non-raster example input only. |
| `docs/TECHNICAL_GUIDE.md` | Inputs, outputs, assumptions, performance evidence and troubleshooting. |
| `docs/SHOWCASE_2001.md` | Public 2001 RFE and independent-test showcase, with interpretation limits. |

## Data safety

The public repository contains exactly 1,000 2001 records after removal of the file row-index column. To keep each web upload below the transport limit, they are stored as two ordered 500-row files in `data/example/`. `run_example.R` reconstructs the temporary one-table CSV automatically. Full training tables, rasters, RDS models and outputs are excluded by `.gitignore`.

## Feature selection and diagnostics

Set `feature_selection_method` in `R/00_config.R` to `"vif_rfe"` for iterative VIF filtering followed by cross-validated RFE, or `"vif_importance"` for iterative VIF filtering followed by random-forest permutation-importance ranking. The latter evaluates ranked top-k subsets with training-set OOB RMSE before selecting k; it does not use the independent test data.

`lc` is excluded from numeric VIF regression by default because land-cover codes are categorical labels, not continuous measurements. It remains available to RFE or importance selection. Add other categorical predictors to `cfg$vif_exclude_features` as needed.

SVG and 600-dpi TIFF figure exports are optional: install `svglite` and `ragg` to enable them. PNG and PDF diagnostics remain available when either optional package is absent.

Before a public package release, complete the author metadata in `DESCRIPTION` with the maintainer's real name and contact email. This repository is not configured as a CRAN submission.

Each completed year writes VIF tables, the selected variables, method-specific selection tables, independent-test metrics, and figures in `results/<year>/figures/`. The figures include final VIF, RFE or importance diagnostics, observed-versus-predicted NPP, and residual diagnostics.

## Interpretation boundary

The output is a model-based NPP estimate under observed annual environmental conditions. It is not automatically ecological potential NPP. If the calibration data were constrained to protected/stable/no-fire sites, the LC 9/10 map is a spatial extrapolation; report that explicitly and inspect extrapolation diagnostics before scientific use.

