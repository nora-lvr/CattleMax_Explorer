## ---------------------------------------------------------------
## STEP ZERO. Has CattleMax changed the shape of its export?
##
## Every build below this assumes columns that exist and mean what they meant
## last time. If CattleMax renames a field, drops one, or adds a file, the
## pipeline can keep running and quietly produce wrong numbers - a missing
## column reads as all-NA, and an all-NA column looks like "no animals had that"
## rather than "we stopped being told".
##
## So the FIRST thing the pipeline does is compare this pull's SCHEMA against a
## cached baseline that ships in the repo. Schema only - file names and column
## names. No values, no counts, nothing client-specific, which is why the
## baseline is safe to commit and why it does not have to come from the same
## farm. Any prior pull from any herd is a valid baseline.
##
##   Rscript R/check_schema.R           compare, and stop on a breaking change
##   Rscript R/check_schema.R accept    adopt this pull as the new baseline
##   Rscript R/check_schema.R warn      report everything but never stop
##
## BREAKING means a column the pipeline actually reads has gone. New files and
## new columns are reported but never stop a run - CattleMax adding a field
## cannot break us, and we want to know it happened.
## ---------------------------------------------------------------
options(width=200)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
.a <- commandArgs(trailingOnly = TRUE)
MODE <- if (any(.a == "accept")) "accept" else if (any(.a == "warn")) "warn" else "check"

BASE <- file.path(cfg$root, "reference", "cattlemax_schema.json")
dir.create(dirname(BASE), showWarnings = FALSE, recursive = TRUE)

## ---- this pull's schema -------------------------------------------------
## Header only: we never need a value to know the shape, and reading headers
## keeps this step near-instant even on a large pull.
files <- sort(list.files(cfg$pull_dir, pattern = "\\.csv$"))
now <- lapply(files, function(f) {
  h <- tryCatch(names(readr::read_csv(file.path(cfg$pull_dir, f), n_max = 0,
                                      name_repair = "minimal", progress = FALSE,
                                      show_col_types = FALSE)),
                error = function(e) character(0))
  list(file = f, cols = h)
})
names(now) <- files
cat("this pull:", length(files), "files,",
    sum(vapply(now, function(x) length(x$cols), numeric(1))), "columns\n")

## ---- which columns does the pipeline actually READ? ---------------------
## Scraped from the R sources, so it cannot drift from the code. A column named
## here that disappears is a genuine break; anything else is information.
src <- unlist(lapply(list.files(file.path(cfg$root, "R"), pattern = "\\.R$",
                                full.names = TRUE), readLines, warn = FALSE))
src <- paste(src, collapse = "\n")
used_cols <- unique(unlist(regmatches(src, gregexpr("\\$[A-Za-z_][A-Za-z0-9_]*", src))))
used_cols <- sub("^\\$", "", used_cols)

emit <- function(l) paste0("{", paste(mapply(function(k, v)
  paste0(jq(k), ":", v), names(l), l), collapse = ","), "}")
write_baseline <- function() {
  body <- paste(vapply(now, function(x)
    emit(list(file = jq(x$file),
              cols = jarr(vapply(x$cols, jq, character(1))))), character(1)),
    collapse = ",")
  j <- paste0("{", jq("captured"), ":", jq(format(Sys.Date())), ",",
              jq("fromPull"), ":", jq(cfg$pull), ",",
              jq("nFiles"), ":", length(now), ",",
              jq("files"), ":[", body, "]}")
  invisible(jsonlite::fromJSON(j))          # never write a payload that will not parse
  writeLines(j, BASE)
  cat("wrote baseline:", BASE, "\n")
}

if (!file.exists(BASE)) {
  cat("\nNo cached schema yet - adopting this pull as the baseline.\n")
  cat("Nothing is being checked on this run; the next run compares against it.\n")
  write_baseline()
  cat("\n=== SCHEMA CHECK: baseline created ===\n")
  quit(save = "no", status = 0)
}

B <- jsonlite::fromJSON(BASE, simplifyVector = FALSE)
base <- setNames(lapply(B$files, function(x) unlist(x$cols)),
                 vapply(B$files, function(x) x$file, character(1)))
cat("baseline  :", length(base), "files, captured", B$captured,
    "from", B$fromPull, "\n\n")

## ---- compare ------------------------------------------------------------
gone_files  <- setdiff(names(base), names(now))
new_files   <- setdiff(names(now), names(base))
both        <- intersect(names(base), names(now))
gone_cols <- new_cols <- list()
for (f in both) {
  g <- setdiff(base[[f]], now[[f]]$cols)
  n <- setdiff(now[[f]]$cols, base[[f]])
  if (length(g)) gone_cols[[f]] <- g
  if (length(n)) new_cols[[f]]  <- n
}
## a lost column only breaks us if something in R/ actually reads it
breaking <- lapply(gone_cols, function(v) intersect(v, used_cols))
breaking <- breaking[vapply(breaking, length, numeric(1)) > 0]

cat("=== SCHEMA CHECK ===\n")
say <- function(lab, v) cat(sprintf("%-26s %s\n", lab,
  if (!length(v)) "none" else paste(v, collapse = ", ")))
say("files removed", gone_files)
say("files added", new_files)
cat(sprintf("%-26s %d\n", "files with column changes", length(unique(c(names(gone_cols), names(new_cols))))))

if (length(gone_cols)) { cat("\n-- columns REMOVED --\n")
  for (f in names(gone_cols))
    cat(sprintf("  %-34s %s\n", f, paste(gone_cols[[f]], collapse = ", "))) }
if (length(new_cols)) { cat("\n-- columns ADDED (informational) --\n")
  for (f in names(new_cols))
    cat(sprintf("  %-34s %s\n", f, paste(new_cols[[f]], collapse = ", "))) }

if (MODE == "accept") {
  cat("\naccepting this pull as the new baseline\n")
  write_baseline()
  quit(save = "no", status = 0)
}

if (length(breaking)) {
  cat("\n*** BREAKING: a column the pipeline READS has gone ***\n")
  for (f in names(breaking))
    cat(sprintf("  %-34s %s\n", f, paste(breaking[[f]], collapse = ", ")))
  cat("\nFix the code that reads it, or run `Rscript R/check_schema.R accept`\n",
      "if the change is expected and the code already handles it.\n", sep = "")
  if (MODE != "warn") stop("schema changed in a way that breaks the pipeline")
}

if (!length(gone_files) && !length(new_files) && !length(gone_cols) && !length(new_cols)) {
  cat("\nunchanged - the export has the same shape as the baseline\n")
} else if (!length(breaking)) {
  cat("\nchanges found, but none touch a column the pipeline reads - continuing\n")
}
