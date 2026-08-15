## ---------------------------------------------------------------
## Shared helpers. Defined once here rather than redeclared in every script.
## ---------------------------------------------------------------

## Read a CattleMax CSV with a real quoted parser. Golden rule 5: free-text
## fields contain commas and embedded newlines, so naive splitting corrupts
## rows (animals.csv has 17,054 lines but 17,052 records; pregnancy_checks has
## 861 more lines than records).
##
## readr, not read.csv (Nora, 2026-08-15: "use tidyverse when possible, it is
## safest"). Two rules that matter more than the choice of parser:
##
##   EVERY COLUMN AS CHARACTER. Nothing is type-guessed. A column of ear tags
##   that happens to look numeric stays text; dates and numbers are converted
##   deliberately, downstream, where the conversion can be checked.
##
##   ONLY "" IS MISSING - never the text "NA". sale_tickets.csv carries an
##   invoice whose literal value is "NA"; treating that string as missing would
##   delete a real value. Whatever the client typed, we read.
cm_read <- function(cfg, file) {
  p <- file.path(cfg$pull_dir, file)
  if (!file.exists(p)) stop("missing export file: ", p)
  as.data.frame(
    readr::read_csv(p, col_types = readr::cols(.default = readr::col_character()),
                    na = c(""), progress = FALSE, show_col_types = FALSE,
                    name_repair = "minimal"),
    stringsAsFactors = FALSE)
}

## CattleMax timestamps are "YYYY-MM-DD HH:MM:SS -0600"; take the date part.
d10 <- function(x) as.Date(substr(x, 1, 10))

num <- function(x) suppressWarnings(as.numeric(x))

## tapply(min/max, na.rm=TRUE) returns +/-Inf for an all-NA group. Unguarded,
## arrow writes that to parquet as the year -5877641. De-Inf inside the
## helpers so no caller can forget.
.deinf <- function(v) { v <- as.numeric(v); v[!is.finite(v)] <- NA_real_
                        as.Date(v, origin = "1970-01-01") }

## earliest / latest dated child record per animal, aligned to `ids`
cm_min_date <- function(df, id_col, date_col, ids) {
  v <- suppressWarnings(tapply(as.integer(d10(df[[date_col]])), df[[id_col]], min, na.rm = TRUE))
  .deinf(v[ids])
}
cm_max_date <- function(df, id_col, date_col, ids) {
  v <- suppressWarnings(tapply(as.integer(d10(df[[date_col]])), df[[id_col]], max, na.rm = TRUE))
  .deinf(v[ids])
}

## pmin/pmax over Dates that never leaks Inf
cm_pmin <- function(...) .deinf(suppressWarnings(pmin(..., na.rm = TRUE)))
cm_pmax <- function(...) .deinf(suppressWarnings(pmax(..., na.rm = TRUE)))

## Write a silver table. Parquet is the artefact; the CSV twin is written only
## when asked, for eyeballing.
cm_write_silver <- function(df, cfg, name, csv = TRUE) {
  fp <- file.path(cfg$silver, paste0(name, ".parquet"))
  arrow::write_parquet(df, fp, compression = "snappy")
  cat("WROTE", fp, sprintf("(%.0f KB)", file.size(fp) / 1024), "\n")
  if (csv) {
    fc <- file.path(cfg$silver, paste0(name, ".csv"))
    utils::write.csv(df, fc, row.names = FALSE, na = "")
  }
  cat(" rows:", nrow(df), " cols:", ncol(df), "\n")
  invisible(fp)
}

cm_read_silver <- function(cfg, name) {
  fp <- file.path(cfg$silver, paste0(name, ".parquet"))
  if (!file.exists(fp)) stop("silver table not built yet: ", fp,
                             "\nRun the build scripts in the order given in R/README.md")
  as.data.frame(arrow::read_parquet(fp))
}

## JSON helpers. p() builds ONE "key":value pair - passing key, ":" and value
## as separate args to a comma-joining helper emits malformed JSON and renders
## a blank page, which has happened once already.
jq   <- function(x) paste0('"', gsub('"', '\\\\"', ifelse(is.na(x), "", as.character(x))), '"')
jarr <- function(x) paste0("[", paste(x, collapse = ","), "]")
jp   <- function(k, v) paste0(jq(k), ":", v)
jobj <- function(...) paste0("{", paste(c(...), collapse = ","), "}")

## Never write a payload that does not parse.
cm_write_json <- function(json, path, expect = list()) {
  chk <- tryCatch(jsonlite::fromJSON(json, simplifyVector = FALSE),
                  error = function(e) stop("refusing to write malformed JSON to ", path,
                                           ": ", conditionMessage(e)))
  for (nm in names(expect)) {
    if (length(chk[[nm]]) != expect[[nm]])
      stop("JSON check failed for ", path, ": '", nm, "' has ",
           length(chk[[nm]]), ", expected ", expect[[nm]])
  }
  writeLines(json, path)
  cat("wrote", basename(path), " bytes:", nchar(json), " (validated)\n")
  invisible(path)
}
