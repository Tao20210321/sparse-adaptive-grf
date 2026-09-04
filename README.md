# SA-GRF Model Application and Parameter Guide

General-purpose version for spatially non-stationary regression and
spatial extrapolation

Purpose. This guide presents Sparse Adaptive Geographically Weighted
Random Forest (SA-GRF) as a domain-independent spatial machine-learning
framework. It does not prescribe a particular data source, study area,
time period, or response variable. The focus is on applicability, input
requirements, modelling workflow, parameter meanings and setting rules,
validation, spatial prediction, and common risks so that users from
ecology, environmental science, agriculture, geography, public health,
resource assessment, and other spatial-prediction fields can adapt the
framework.

## 1. Model scope and suitable applications

SA-GRF is an ensemble regression framework for predicting spatially
continuous variables. It extends random forest by explicitly
incorporating spatial neighborhoods, adaptive bandwidths, and
distance-based case weights. Sparse spatial anchors reduce the
computational burden of conventional local modelling, while global-local
prediction fusion allows the model to learn both broad-scale
relationships and spatially varying local relationships.

SA-GRF is most appropriate when the problem has several of the following
characteristics:

The response is continuous, such as productivity, concentration, yield,
temperature, a soil property, or a risk index.

Predictor-response relationships may be nonlinear and involve complex
interactions.

The study domain is spatially heterogeneous, so the effect of a
predictor may vary among locations.

Training samples are spatially uneven, making one fixed-distance
neighborhood unsuitable for both dense and sparse areas.

Point or limited reference samples must be extrapolated to a continuous
spatial surface.

A fully local GRF/GWR workflow would be computationally expensive, so
local adaptability and large-area efficiency must be balanced.

Direct use is not recommended when the sample size is extremely small;
the response is non-continuous without adapting the loss/classification
component; predictors have poor spatial coverage; the prediction domain
is far outside the environmental support of the training data; or there
is no defensible reason to expect spatial non-stationarity.

## 2. Model structure

### 2.1 Global random forest

The global random forest uses all training samples to learn one common
mapping from predictors X to response Y. It is well suited to
nonlinearities, high-order interactions, and complex predictor
combinations, but assumes that the fitted relationship is shared across
the spatial domain. Within SA-GRF, the global model provides a stable
broad-scale estimate and a shrinkage target for local predictions.

$X \rightarrow  Y$

### 2.2 Adaptive local random forests

For each local center, SA-GRF uses the k geographically nearest training
samples instead of a fixed-distance radius. With a fixed k, the
effective geographic radius contracts in densely sampled areas and
expands in sparse areas, reducing fluctuations in local sample size
caused by uneven sampling density.

Within each neighborhood, samples receive a bisquare distance weight:

$wj = [1 - (djh)2]2$

where d_j is the distance from sample j to the local center and h is the
distance to the farthest sample in that local neighborhood
(equivalently, the kth neighbor under the implemented
adaptive-neighborhood definition). Nearby observations therefore receive
greater weight.

### 2.3 Sparse spatial anchors

A conventional GRF may fit a local model at every training point or even
every prediction location, causing the number of forests to increase
rapidly with sample size or raster size. SA-GRF first selects spatially
representative anchor points from the training samples and fits local
forests only at those anchors. At prediction time, a new location uses
the local forest associated with its nearest anchor. This converts
repeated location-by-location fitting into reuse of a finite set of
local models and avoids the need for a full pairwise distance matrix.

$N \times  N$

### 2.4 Global-local prediction fusion

The final prediction combines local and global estimates:

$Ŷs = \lambda Ŷlocal(s) + (1 - \lambda )Ŷglobal(s)$

where λ ∈ \[0,1\] controls the contribution of the local model. λ = 0
reduces the method to a global RF, whereas λ = 1 gives a purely local
prediction. Intermediate values trade local spatial adaptability against
global stability.

## 3. Input data requirements

  -----------------------------------------------------------------------
  Input                   Minimum requirement     Recommended practice
  ----------------------- ----------------------- -----------------------
  Response Y              Continuous numeric      Use a defensible range
                          observations for        and an explicit
                          training samples        outlier-handling rule.

  Predictors X            Same predictor fields   Use predictors with
                          in training and         clear meaning and
                          prediction data         adequate coverage of
                                                  the target domain.

  Spatial coordinates     Two-dimensional         For longitude/latitude,
                          coordinates for every   use spherical/geodesic
                          training sample         distance; for projected
                                                  coordinates, use an
                                                  appropriate regional
                                                  metric CRS.

  Prediction data         Variables with the same Keep units, temporal
                          names and meanings as   definitions,
                          training predictors     preprocessing, and
                                                  spatial alignment
                                                  consistent.

  Sample size             Sufficient to support   Prefer sample size far
                          local forests           larger than predictor
                                                  count and adequate
                                                  coverage of major
                                                  spatial/environmental
                                                  gradients.
  -----------------------------------------------------------------------

Key principle. Reliable extrapolation is limited to the environmental
space represented by the training samples. Geographic proximity does not
guarantee environmental similarity. Users should therefore examine
training-versus-prediction environmental coverage and, where
appropriate, construct an Area of Applicability (AOA) or another
extrapolation-risk mask.

## 4. Standard modelling workflow

### Step 1. Synchronized data cleaning

Check Y, coordinates, and all candidate X variables together and retain
only complete, finite records. Do not clean variables separately and
then recombine them, because row correspondence can be lost. Outlier
rules should be estimated from training data only.

### Step 2. Training and independent test split

Split the data before estimating outlier thresholds, selecting
variables, or tuning parameters to prevent information leakage. A
practical starting point is 70--80% for training and 20--30% for
independent testing. Spatial applications should additionally use a
spatial validation design.

### Step 3. Collinearity control

Iteratively calculate variance inflation factors (VIFs) for candidate
predictors. A threshold of 5 is a practical starting point. At each
iteration, remove the predictor with the largest VIF if it exceeds the
threshold, subject to a minimum-predictor stopping rule. VIF screening
is a stability tool and should not replace domain reasoning.

### Step 4. Feature selection

After VIF filtering, rank predictors using random-forest permutation
importance. Evaluate top-k predictor subsets and select a candidate
subset using minimum out-of-bag (OOB) RMSE or cross-validation error.
Recursive feature elimination (RFE) can be used as an alternative or
sensitivity analysis.

### Step 5. RF hyperparameter tuning

At minimum, tune mtry. With p retained predictors, mtry can be searched
from 1 to p and selected by minimum OOB or cross-validation RMSE. Use
enough trees for OOB error to stabilize; a moderate number can be used
during tuning and a larger stable number for final fitting.

### Step 6. Adaptive-neighborhood search

Define a broad candidate range for k and perform a coarse search, then
refine the search around the coarse optimum. For each candidate k,
perform local hold-out-style prediction at spatially representative
anchors and calculate RMSE, MAE, and R². RMSE can be the primary
selection criterion, with MAE used as a secondary criterion.

### Step 7. Fit anchor-based local forests

Select representative anchors across the spatial domain. For each
anchor, retrieve the optimal k nearest training samples, calculate
distances and bisquare weights, and fit a local RF. The number of
anchors controls the spatial resolution of local modelling and the
computational cost.

### Step 8. Fit the global forest

Fit a global RF using all training samples and the same final predictor
set. This provides the stable broad-scale component of the fused
prediction.

### Step 9. Determine λ and fuse predictions

Evaluate candidate λ values using independent validation or, preferably
for spatial extrapolation, spatial cross-validation. If λ has not been
tuned, report it explicitly as a prespecified parameter rather than an
optimal parameter.

### Step 10. Independent evaluation and spatial prediction

Report R², RMSE, MAE, and residual diagnostics on a completely isolated
test set. Apply the final model to the target domain. For each
prediction location, identify the nearest anchor local model and combine
its prediction with the global prediction using λ.

## 5. Key parameters and general setting rules

  --------------------------------------------------------------------------------------
  Parameter         Meaning           Practical starting   Setting rule
                                      point                
  ----------------- ----------------- -------------------- -----------------------------
  test_fraction     Independent test  0.20--0.30           Use \~0.30 with large
                    fraction                               samples; reduce when samples
                                                           are limited and strengthen
                                                           cross-validation. Spatial
                                                           prediction requires
                                                           additional spatial
                                                           validation.

  outlier_method    Response outlier  IQR / 3σ / robust    Choose from distributional
                    handling          rule                 and domain considerations;
                                                           estimate thresholds from
                                                           training data only. Avoid
                                                           mechanical 3σ filtering for
                                                           heavy-tailed responses.

  VIF threshold     Collinearity      5                    Use a stricter value when
                    threshold                              interpretability is
                                                           important. For
                                                           prediction-oriented RF, treat
                                                           VIF as a screening rule
                                                           rather than an absolute
                                                           requirement.

  importance trees  Trees for         \~500                Increase until importance
                    importance                             ranking and OOB error are
                    ranking                                sufficiently stable.

  final trees       Trees in final    \~300--1000          Increase until OOB/validation
                    forests                                error stabilizes; more trees
                                                           generally improve stability
                                                           but increase computation.

  mtry              Candidate         Search 1...p         Select using minimum OOB or
                    predictors per                         CV RMSE.
                    split                                  

  k / neighbors     Training samples  Data-driven search   Set a lower bound clearly
                    in each local                          larger than predictor count;
                    forest                                 a practical constraint is k ≥
                                                           max(20, p+2), then define the
                                                           search range from total
                                                           sample size, sampling
                                                           density, and spatial scale.

  coarse k step     Increment in      \~5--15% of          Use a larger step for a wide
                    coarse k search   candidate range      range to first locate the
                                                           error basin.

  fine k range      Local search      Centered on coarse   Choose range and step to
                    around coarse     optimum              resolve the local error
                    optimum                                minimum without repeating the
                                                           full coarse search.

  bandwidth anchors Anchors used to   Several hundred      Spatial coverage is more
                    evaluate k                             important than count alone;
                                                           increase anchors for more
                                                           complex or heterogeneous
                                                           domains.

  final anchors     Number of fitted  Hundreds to several  Choose from an
                    local forests     thousand             accuracy-versus-computation
                                                           curve. Too few anchors
                                                           oversmooth local variation;
                                                           too many approach the cost of
                                                           conventional GRF.

  kernel            Distance-weight   Bisquare             Appropriate when local
                    function                               proximity should be
                                                           emphasized. If the kernel
                                                           changes, retune k and
                                                           revalidate performance.

  λ / local_weight  Weight of local   Search 0--1          Coarse test 0, 0.2, 0.4, 0.6,
                    prediction                             0.8, 1.0, then refine; choose
                                                           using spatial validation
                                                           error.

  workers           Parallel          Hardware-dependent   Affects speed, not the
                    processes                              statistical definition. Avoid
                                                           nested parallelism that
                                                           exhausts memory.

  seed              Random seed       Fixed integer        Keep fixed and record it for
                                                           reproducibility.
  --------------------------------------------------------------------------------------

## 6. Recommended order of parameter tuning

Do not tune every parameter in one exhaustive grid. Because local
forests dominate SA-GRF computation, progressively reduce the search
space in the following order:

1.  Data cleaning and training/test isolation

2.  VIF filtering and predictor subset selection

3.  mtry and basic RF tree-number stability

4.  Coarse search for adaptive-neighborhood k

5.  Fine search for k

6.  Final number of anchors

7.  Global-local fusion weight λ

8.  Final independent testing and spatial cross-validation

As a general rule, determine lower-cost components before moving to more
expensive local-model tuning. If the predictor subset changes, reassess
mtry and k because the sample size required by local forests may change
with model dimensionality.

## 7. Model validation and experimental design

### 7.1 Minimum validation

Independent test set: report R², RMSE, and MAE.

Observed-versus-predicted plot: inspect systematic over- or
underprediction.

Residual-versus-predicted plot: inspect heteroscedasticity and nonlinear
residual structure.

Spatial residual map: inspect remaining spatial clustering.

### 7.2 Recommended spatial validation

For spatial extrapolation, random hold-out validation can overestimate
generalization when nearby training and test observations are spatially
autocorrelated. Use spatial block cross-validation, regional hold-out,
or distance-separated validation. Block size or separation distance
should be based on the spatial correlation scale of the response,
sampling density, and intended prediction resolution rather than a
universal fixed distance.

### 7.3 Recommended ablation and sensitivity experiments

  -----------------------------------------------------------------------
  Experiment              Setting                 Question addressed
  ----------------------- ----------------------- -----------------------
  Global RF               λ = 0                   What is the baseline
                                                  performance without
                                                  local relationships?

  Local-only              λ = 1                   Does pure localization
                                                  improve accuracy, and
                                                  does it reduce
                                                  stability?

  SA-GRF                  0 \< λ \< 1             Does fusion improve
                                                  both local adaptability
                                                  and stability?

  Anchor sensitivity      Vary number of anchors  What
                                                  accuracy-efficiency
                                                  trade-off is introduced
                                                  by sparsification?

  Bandwidth sensitivity   Vary k                  How robust is the model
                                                  to spatial neighborhood
                                                  scale?

  Feature-selection       Compare selection       Do predictions depend
  sensitivity             strategies              strongly on one
                                                  feature-selection
                                                  method?
  -----------------------------------------------------------------------

## 8. Spatial prediction requirements

Training and prediction must use exactly the same predictor names,
meanings, units, and preprocessing.

Categorical predictors require category-preserving resampling;
continuous predictors should not be processed with methods that alter
category meaning.

Every prediction location requires valid coordinates because local-model
assignment is spatial.

Environmental combinations outside the training support should be
flagged as high extrapolation risk rather than accepted solely because
the model returns a number.

For large rasters, block-wise prediction is recommended to control
memory use; blocking must not alter coordinates or predictor values.

Along with predictions, record model version, predictor list, k, mtry,
λ, anchor count, random seed, and validation metrics.

## 9. Common problems and diagnostics

  -----------------------------------------------------------------------
  Symptom                 Likely cause            Recommended action
  ----------------------- ----------------------- -----------------------
  High random-test        Spatial autocorrelation Use spatial CV as the
  accuracy but much lower or leakage              primary generalization
  spatial-CV accuracy                             evidence and inspect
                                                  train-test separation.

  Highly variable local   k too small, sparse     Increase k, increase
  predictions             samples, or λ too high  global contribution,
                                                  and inspect anchor
                                                  coverage.

  Overly smooth           Too few anchors, k too  Increase anchors,
  prediction surface      large, or λ too low     reduce k, or increase
                                                  local weight and
                                                  revalidate.

  Abnormal edge           Poor reference coverage Improve training
  predictions             or environmental        coverage, construct an
                          extrapolation           AOA/risk mask, and mask
                                                  high-risk areas if
                                                  necessary.

  Excessive runtime       k, anchor count, or     Use fewer anchors for
                          tree count too large    coarse tuning, remove
                                                  uninformative parameter
                                                  combinations, and
                                                  parallelize local
                                                  forests.

  Unstable variable       Strong collinearity,    Control collinearity,
  importance              too few trees, or       increase tree count,
                          heterogeneous samples   and assess ranking
                                                  stability with repeated
                                                  validation.

  Different results       Unfixed random seed or  Fix the seed and record
  across runs             parallel RNG            software environment
                                                  and model
                                                  configuration.
  -----------------------------------------------------------------------

## 10. General parameter configuration template

The following values are starting points for a first run, not universal
optima. Adjust them to sample size, spatial density, predictor count,
and spatial-validation results.

response: `<continuous target>`{=html}coordinates: \<x,
y\>test_fraction: 0.20--0.30VIF_threshold: 5feature_selection:
permutation importance + OOB subset selectionimportance_trees: 500
(increase until stable)final_trees: 300--1000mtry: search
1...pneighbor_k: coarse-to-fine data-driven searchminimum_k: max(20,
p+2)spatial_kernel: bisquarebandwidth_anchors: several hundred,
spatially representativefinal_anchors: several hundred to several
thousandlocal_weight_lambda: search 0...1validation: independent
hold-out + spatial cross-validationmetrics: R², RMSE, MAErandom_seed:
fixed and recorded

## 11. Interpretation boundaries

SA-GRF estimates a conditional expected response given predictors and
spatial location. It does not automatically produce a causal quantity, a
potential value, a maximum value, or a true undisturbed value. The
interpretation and name of the output must follow from the definition of
the training samples and the study design. If the training data
represent a specific reference state, predictions may be interpreted as
the expected response under that reference state. If the training data
are ordinary observations, the output should be interpreted only as a
prediction of the corresponding observational relationship.

Conceptually, the model targets:

$E[Y | X, s]$

Likewise, spatial weighting does not establish a causal effect of
geographic proximity. It is a statistical device that allows
relationships to vary spatially and gives nearby observations greater
influence on local fitting.

## 12. Minimum reproducibility checklist

Definition and units of the response variable.

Complete candidate-predictor list and final selected predictors.

Sample-cleaning and outlier rules.

Training/test split rule and random seed.

VIF threshold and feature-selection method.

mtry and number of trees.

Coarse k range and step, fine k range and step, and final k.

Number of bandwidth-search anchors and final anchors.

Spatial-distance definition and kernel function.

λ value and how it was selected.

Independent-test and spatial-validation designs.

R², RMSE, MAE, and runtime.

Software versions and computing environment.
