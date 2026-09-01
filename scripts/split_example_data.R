# Split the committed 1,000-row example into transport-friendly parts without changing records.
input_csv <- "data/example/nature_database_2001_first1000.csv"
output_dir <- "data/example"
if (!file.exists(input_csv)) stop("Example CSV does not exist: ", input_csv)

dat <- read.csv(input_csv, check.names = FALSE, stringsAsFactors = FALSE)
if (nrow(dat) != 1000L) stop("Expected exactly 1,000 rows, found ", nrow(dat))
breaks <- list(1:500, 501:1000)
for (i in seq_along(breaks)) {
  out <- file.path(output_dir, sprintf("nature_database_2001_first1000_part_%03d.csv", i))
  write.csv(dat[breaks[[i]], , drop = FALSE], out, row.names = FALSE, na = "")
}
message("Wrote two 500-row parts; their row order matches the input CSV.")

