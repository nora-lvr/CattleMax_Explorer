## ---------------------------------------------------------------
## EXCLUSIONS LEDGER
##
## Standing rule (Nora, 2026-08-14): nothing is ever silently discarded.
## If a record falls out of a table or a report, it must be recorded here
## with what it was, why it went, and how many.
##
## Usage in a build script:
##   source(".../exclusions.R"); excl_reset()
##   excl_add("cow_lactations.parquet", "no known carrier dam",
##            n_records = 485, n_animals = 485,
##            detail = "calf has no dam_animal_id and no recoverable recipient")
##   excl_write(SILVER)          # writes exclusions.parquet + .csv, prints a summary
##
## Reports read exclusions.parquet and must show it. A report that excludes
## records without naming them is not finished.
## ---------------------------------------------------------------

.EXCL <- new.env(parent = emptyenv())

excl_reset <- function() assign("rows", list(), envir = .EXCL)

excl_add <- function(table, reason, n_records, n_animals = NA_integer_,
                     detail = "", recoverable = FALSE) {
  r <- get0("rows", envir = .EXCL, ifnotfound = list())
  r[[length(r) + 1]] <- data.frame(
    table       = table,
    reason      = reason,
    n_records   = as.integer(n_records),
    n_animals   = as.integer(n_animals),
    detail      = detail,
    recoverable = recoverable,       # TRUE = we could get these back with a rule change
    stringsAsFactors = FALSE)
  assign("rows", r, envir = .EXCL)
  invisible(NULL)
}

excl_table <- function() {
  r <- get0("rows", envir = .EXCL, ifnotfound = list())
  if (!length(r)) return(data.frame())
  do.call(rbind, r)
}

excl_write <- function(silver_dir, stamp = Sys.Date()) {
  X <- excl_table()
  if (!nrow(X)) { cat("\n(no exclusions recorded)\n"); return(invisible(NULL)) }
  X$recorded <- as.Date(stamp)
  fp <- file.path(silver_dir, "exclusions.parquet")
  ## accumulate across build scripts rather than overwrite
  ## read via the CSV twin, not the parquet: arrow memory-maps on read and
  ## Windows then refuses to overwrite the file it still has mapped.
  ## read as character and convert deliberately - a `detail` that happens to
  ## look numeric, or a reason whose text is "NA", must survive the round trip
  fc_old <- file.path(silver_dir, "exclusions.csv")
  if (file.exists(fc_old)) {
    old <- as.data.frame(readr::read_csv(fc_old,
             col_types = readr::cols(.default = readr::col_character()),
             na = c(""), progress = FALSE, show_col_types = FALSE),
           stringsAsFactors = FALSE)
    if (nrow(old)) {
      old <- old[!(old$table %in% unique(X$table)), , drop = FALSE]  # replace this table's rows
      if (nrow(old)) {
        old$recorded    <- as.Date(old$recorded)
        old$n_records   <- as.numeric(old$n_records)
        old$n_animals   <- as.numeric(old$n_animals)
        old$recoverable <- as.logical(old$recoverable)
        X <- rbind(old[, names(X)], X)
      }
    }
  }
  arrow::write_parquet(X, fp, compression = "snappy")
  write.csv(X, file.path(silver_dir, "exclusions.csv"), row.names = FALSE, na = "")
  cat("\n=== EXCLUSIONS RECORDED (nothing is dropped silently) ===\n")
  print(X[order(X$table, -X$n_records), c("table","reason","n_records","recoverable")],
        row.names = FALSE)
  cat("total records excluded:", sum(X$n_records), "\n")
  invisible(X)
}
