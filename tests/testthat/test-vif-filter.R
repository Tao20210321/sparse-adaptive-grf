test_that("categorical predictors are retained but excluded from VIF", {
  cfg <- default_npp_config()
  cfg$candidate_features <- c("bio1", "bio12", "lc")
  cfg$vif_exclude_features <- "lc"
  dat <- data.frame(
    NPP = seq_len(40),
    bio1 = seq_len(40),
    bio12 = seq_len(40)^2,
    lc = rep(c(9, 10), 20)
  )

  selected <- filter_features_vif(dat, cfg)

  expect_true("lc" %in% selected$features)
  expect_true(is.na(selected$final_vif$VIF[selected$final_vif$feature == "lc"]))
  expect_identical(selected$final_vif$status[selected$final_vif$feature == "lc"], "excluded_from_vif")
})

