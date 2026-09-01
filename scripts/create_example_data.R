# Create the version-controlled demonstration data only. It never changes the full input table.
args <- commandArgs(trailingOnly = TRUE)
source_csv <- if (length(args) >= 1L) args[1] else "C:/Users/Lenovo/Desktop/1km-degradation/natue_database_year/nature_database_2001.csv"
output_csv <- if (length(args) >= 2L) args[2] else "data/example/nature_database_2001_first1000.csv"

if (!file.exists(source_csv)) stop("Source CSV does not exist: ", source_csv)
dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
dat <- read.csv(source_csv, nrows = 1000L, check.names = FALSE, stringsAsFactors = FALSE)
if (nrow(dat) != 1000L) stop("Source contains fewer than 1,000 records.")
# read.csv converts a blank first-column header to X; it is only a file row index.
if (names(dat)[1] %in% c("", "X")) dat <- dat[, -1L, drop = FALSE]
write.csv(dat, output_csv, row.names = FALSE, na = "")
message("Wrote ", nrow(dat), " rows and ", ncol(dat), " columns to ", normalizePath(output_csv, winslash = "/"))

