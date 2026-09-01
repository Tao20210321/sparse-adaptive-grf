# Reconstruct the exact 1,000-row example table from the two version-controlled parts.
parts <- file.path("data", "example", sprintf("nature_database_2001_first1000_part_%03d.csv", 1:2))
if (!all(file.exists(parts))) stop("Both sample data parts are required.")
dat <- do.call(rbind, lapply(parts, read.csv, check.names = FALSE, stringsAsFactors = FALSE))
if (nrow(dat) != 1000L) stop("Expected exactly 1,000 reconstructed rows, found ", nrow(dat))
write.csv(dat, "data/example/nature_database_2001_first1000.csv", row.names = FALSE, na = "")
message("Reconstructed 1,000-row example CSV.")

