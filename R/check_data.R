## ---------------------------------------------------------------
## ONE CHECK, run before the builds and again after them.
##
## Replaces check_schema.R + test_no_invention.R + audit_columns.R, which were
## three scripts, three config files and three reports asking one question:
##
##        DOES EVERY VALUE TRACE BACK TO THE CATTLEMAX EXPORT?
##
## Three answers are allowed, and every column must give one:
##   sourced   the export has this column; value copied or parsed
##   derived   arithmetic or logic over sourced values; recomputable, claims
##             nothing new (age_days, days_at_risk, any flag_*)
##   invented  a value asserted where the export has none - needs Nora's
##             approval, by name, in reference/columns.csv
##
## Anything unclassified fails. Silence is never approval.
##
##   Rscript R/check_data.R           check; stop if anything is unapproved
##   Rscript R/check_data.R propose   write reference/columns.csv for review
##   Rscript R/check_data.R accept    adopt this pull's schema as the baseline
## ---------------------------------------------------------------
options(width = 210)
if (!exists("cfg")) {
  source(file.path("R", "config.R")); source(file.path("R", "common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
.a   <- commandArgs(trailingOnly = TRUE)
## `schema` runs BEFORE the builds: only asks whether the export changed shape.
## The full check runs AFTER, when there are silver tables to classify.
## run_pipeline.R sources this file rather than shelling out, so it sets
## CHECK_MODE instead of passing an argument.
## (Braces, not a bare `else` on a new line - R parses that as a top-level else
## and fails. This has bitten this repo three times now.)
MODE <- if (exists("CHECK_MODE")) {
  CHECK_MODE
} else if (any(.a == "propose")) {
  "propose"
} else if (any(.a == "accept")) {
  "accept"
} else if (any(.a == "schema")) {
  "schema"
} else {
  "check"
}
CFG   <- file.path(cfg$root, "reference", "columns.csv")
BASE  <- file.path(cfg$root, "reference", "cattlemax_schema.json")
dir.create(dirname(CFG), showWarnings = FALSE, recursive = TRUE)

rd_csv <- function(p) as.data.frame(readr::read_csv(p,
  col_types = readr::cols(.default = readr::col_character()),
  na = c(""), progress = FALSE, show_col_types = FALSE), stringsAsFactors = FALSE)

## ---- 1. has the export changed shape? -----------------------------------
hdr <- function(f) tryCatch(names(readr::read_csv(f, n_max = 0,
         name_repair = "minimal", progress = FALSE, show_col_types = FALSE)),
       error = function(e) character(0))
files <- sort(list.files(cfg$pull_dir, pattern = "\\.csv$"))
now   <- setNames(lapply(file.path(cfg$pull_dir, files), hdr), files)
export_cols <- unique(unlist(now))

schema_ok <- TRUE
if (MODE == "accept" || !file.exists(BASE)) {
  j <- jobj(jp("captured", jq(format(Sys.Date()))), jp("fromPull", jq(cfg$pull)),
       jp("files", jarr(vapply(names(now), function(f)
         jobj(jp("file", jq(f)), jp("cols", jarr(vapply(now[[f]], jq, character(1))))),
         character(1)))))
  cm_write_json(j, BASE, expect = list(files = length(now)))
  cat("schema baseline written from this pull\n")
} else {
  B <- jsonlite::fromJSON(BASE, simplifyVector = FALSE)
  old <- setNames(lapply(B$files, function(x) unlist(x$cols)),
                  vapply(B$files, function(x) x$file, character(1)))
  gone_f <- setdiff(names(old), names(now)); new_f <- setdiff(names(now), names(old))
  gone_c <- new_c <- list()
  for (f in intersect(names(old), names(now))) {
    g <- setdiff(old[[f]], now[[f]]); n <- setdiff(now[[f]], old[[f]])
    if (length(g)) gone_c[[f]] <- g
    if (length(n)) new_c[[f]]  <- n
  }
  ## a lost column only breaks us if the code reads it
  src  <- paste(unlist(lapply(list.files(file.path(cfg$root,"R"), pattern="\\.R$",
            full.names=TRUE), readLines, warn=FALSE)), collapse="\n")
  used <- sub("^\\$", "", unique(unlist(regmatches(src,
            gregexpr("\\$[A-Za-z_][A-Za-z0-9_]*", src)))))
  breaking <- Filter(length, lapply(gone_c, intersect, used))
  cat("SCHEMA  files +", length(new_f), "-", length(gone_f),
      " | columns +", length(unlist(new_c)), "-", length(unlist(gone_c)))
  if (length(breaking)) {
    cat("  *** BREAKING ***\n")
    for (f in names(breaking)) cat("   ", f, ":", paste(breaking[[f]], collapse=", "), "\n")
    schema_ok <- FALSE
  } else cat("  (nothing the code reads has gone)\n")
}

## The first pass runs before anything is built, so it stops after the schema
## question. It cannot quit() - the runner sources this file, and quitting would
## end the whole pipeline - so the rest of the file is guarded instead.
if (MODE == "schema" && !schema_ok) stop("check_data: the export lost a column the code reads")
if (MODE == "schema") cat("schema only - the full column check runs after the builds\n")
if (exists("CHECK_MODE", envir = globalenv())) rm("CHECK_MODE", envir = globalenv())

if (MODE != "schema") {

  ## ---- 2. classify every silver column ------------------------------------
  tabs <- sub("\\.parquet$", "", list.files(cfg$silver, pattern = "\\.parquet$"))
  rows <- list()
  for (tb in tabs) {
    d <- tryCatch(cm_read_silver(cfg, tb), error = function(e) NULL)
    if (is.null(d)) next
    for (cl in names(d)) rows[[length(rows) + 1]] <- data.frame(
      table = paste0(tb, ".parquet"), column = cl,
      in_export = cl %in% export_cols, stringsAsFactors = FALSE)
  }
  C <- do.call(rbind, rows)
  if (is.null(C)) { cat("no silver tables yet - nothing to classify\n"); quit(save="no", status=0) }

  if (MODE == "propose" || !file.exists(CFG)) {
    C$classification <- ifelse(C$in_export, "sourced",
                        ifelse(grepl("^flag_|_source$|_rule$|_anchor$", C$column),
                               "derived", "REVIEW"))
    out <- C[, c("table","column","classification")]
    out$approved <- ""; out$approved_by <- ""; out$approved_date <- ""; out$note <- ""
    ## NO COUNTS. This file is configuration and must be true for any herd; one
    ## farm's row counts would be wrong for the next client and stale for this one.
    readr::write_csv(out[order(out$classification != "REVIEW", out$table, out$column), ],
                     CFG, na = "")
    cat("wrote", CFG, "-", sum(out$classification == "REVIEW"), "columns to classify\n")
    if (MODE == "propose") quit(save = "no", status = 0)
  }

  L <- rd_csv(CFG)
  L$classification <- tolower(trimws(L$classification))
  L$approved       <- toupper(trimws(ifelse(is.na(L$approved), "", L$approved)))
  k <- paste(C$table, C$column); kl <- paste(L$table, L$column)
  C$classification <- L$classification[match(k, kl)]
  C$approved       <- L$approved[match(k, kl)]

  unclassified <- C[is.na(C$classification) | C$classification %in% c("", "review"), ]
  invented     <- C[C$classification %in% "invented", ]
  unapproved   <- invented[!invented$approved %in% "YES", ]

  cat(sprintf("COLUMNS %d | sourced %d  derived %d  invented %d  unclassified %d\n",
      nrow(C), sum(C$classification %in% "sourced", na.rm=TRUE),
      sum(C$classification %in% "derived", na.rm=TRUE), nrow(invented), nrow(unclassified)))

  ## ---- 3. count the invented values, live -------------------------------
  ## Counts are computed here and printed, never stored in the config.
  prov <- list(c("animals","weaning_date","weaning_source"),
               c("animals","entry_date","entry_rule"),
               c("animals","exit_date","exit_rule"),
               c("bulls","weaning_date","weaning_source"),
               c("bulls","entry_date","entry_rule"),
               c("bulls","exit_date","exit_rule"),
               c("cow_lactations","season_start","start_rule"))
  INVENTED_MARKERS <- "\\(EST|ASSUMED|-283d"
  tot <- 0
  for (p in prov) {
    d <- tryCatch(cm_read_silver(cfg, p[1]), error = function(e) NULL)
    if (is.null(d) || !p[3] %in% names(d)) next
    v <- d[[p[3]]]
    for (m in unique(v[!is.na(v) & grepl(INVENTED_MARKERS, v)])) {
      n <- sum(v == m, na.rm = TRUE); tot <- tot + n
      cat(sprintf("   invented  %-16s %-14s %-26s %5d\n", p[1], p[2], m, n))
    }
  }
  if (tot) cat(sprintf("   %d manufactured values in total\n", tot))

  ## ---- 4. verdict ---------------------------------------------------------
  fail <- FALSE
  if (!schema_ok) { cat("\nFAIL: the export lost a column the code reads\n"); fail <- TRUE }
  if (nrow(unclassified)) {
    cat("\nFAIL:", nrow(unclassified), "columns are not classified in", CFG, "\n")
    print(utils::head(unclassified[, c("table","column")], 20), row.names = FALSE)
    fail <- TRUE
  }
  if (nrow(unapproved)) {
    cat("\nFAIL:", nrow(unapproved), "invented columns are not approved:\n")
    print(unapproved[, c("table","column")], row.names = FALSE)
    cat("Set approved = YES in", CFG, "with who and when, or stop manufacturing the value.\n")
    fail <- TRUE
  }
  if (fail && MODE == "check") stop("check_data: the data is not cleared to ship")
  if (!fail) cat("\nPASS - every column traces to the export or to an approved rule\n")

}  ## end of the post-build check
