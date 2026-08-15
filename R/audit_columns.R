## ---------------------------------------------------------------
## COLUMN AUDIT. Every column in every silver table, traced back to the export.
##
## The invention gate only inspected *_source / *_rule columns, which meant a
## FABRICATED COLUMN with an innocent name was invisible to it. `inactivated_date`
## sat in animals.parquet looking exactly like a CattleMax field; CattleMax has
## no such thing. I built it. (Caught by Nora, 2026-08-15.)
##
## So every column gets classified into exactly one of:
##   sourced   the name exists in the CattleMax export; value copied or parsed
##   derived   arithmetic or logic over sourced values - recomputable, asserts
##             no new information (age_days, days_at_risk, a flag_*)
##   invented  a value asserted where the export has none
##
## `sourced` is detected automatically by name. Everything else must be declared
## in reference/column_classification.csv or the audit fails.
##
##   Rscript R/audit_columns.R            report; write the proposal if missing
##   Rscript R/audit_columns.R propose    (re)write the proposal file for review
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
MODE <- if (any(commandArgs(trailingOnly=TRUE)=="propose")) "propose" else "report"
CLASS <- file.path(cfg$root,"reference","column_classification.csv")

## ---- the vocabulary CattleMax actually gives us -------------------------
raw <- unique(unlist(lapply(list.files(cfg$pull_dir, pattern="\\.csv$", full.names=TRUE),
  function(f) tryCatch(names(readr::read_csv(f, n_max = 0, name_repair = "minimal",
                                 progress = FALSE, show_col_types = FALSE)),
                       error=function(e) character(0)))))
cat("distinct column names across the export:", length(raw), "\n")

## ---- every silver column ------------------------------------------------
tabs <- sub("\\.parquet$","", list.files(cfg$silver, pattern="\\.parquet$"))
rows <- list()
for (tb in tabs) {
  d <- tryCatch(cm_read_silver(cfg, tb), error=function(e) NULL)
  if (is.null(d)) next
  for (cl in names(d)) {
    v <- d[[cl]]
    rows[[length(rows)+1]] <- data.frame(
      table = paste0(tb,".parquet"), column = cl,
      type  = class(v)[1],
      filled = if (is.logical(v)) sum(v, na.rm=TRUE) else sum(!is.na(v)),
      rows_in_table = nrow(d),
      name_in_export = cl %in% raw,
      stringsAsFactors = FALSE)
  }
}
C <- do.call(rbind, rows)

## ---- a PROPOSAL, never a verdict ---------------------------------------
## Name-matching can prove `sourced`. It cannot tell derived from invented -
## that needs a human who knows what the value claims. So the proposal marks
## everything else "REVIEW" rather than guessing.
C$proposed <- ifelse(C$name_in_export, "sourced",
              ifelse(grepl("^flag_", C$column), "derived",
              ifelse(grepl("_source$|_rule$|_anchor$", C$column), "derived", "REVIEW")))

if (MODE == "propose" || !file.exists(CLASS)) {
  out <- C[, c("table","column","type","filled","rows_in_table","name_in_export","proposed")]
  names(out)[names(out)=="proposed"] <- "classification"
  out$approved_by <- ""; out$approved_date <- ""; out$note <- ""
  out <- out[order(out$classification != "REVIEW", out$table, out$column), ]
  utils::write.csv(out, CLASS, row.names=FALSE, na="")
  cat("wrote proposal:", CLASS, "\n")
}

cat("\n=== EVERY SILVER COLUMN, TRACED ===\n")
cat("total columns:", nrow(C), "across", length(tabs), "tables\n")
print(table(C$proposed))

cat("\n=== NOT A CATTLEMAX COLUMN NAME - these are ours ===\n")
mine <- C[!C$name_in_export, ]
cat(nrow(mine), "of", nrow(C), "columns do not exist in the export by that name\n")
cat("  auto-classified derived (flags / provenance):",
    sum(mine$proposed=="derived"), "\n")
cat("  NEEDING REVIEW                              :",
    sum(mine$proposed=="REVIEW"), "\n\n")
r <- mine[mine$proposed=="REVIEW", ]
for (tb in unique(r$table)) {
  s <- r[r$table==tb, ]
  cat("--", tb, "(", nrow(s), "columns to review )\n")
  cat("   ", paste(s$column, collapse=", "), "\n")
}
if (file.exists(CLASS)) {
  AL <- as.data.frame(readr::read_csv(CLASS,
          col_types = readr::cols(.default = readr::col_character()),
          na = c(""), progress = FALSE, show_col_types = FALSE),
        stringsAsFactors = FALSE)
  AL$classification <- tolower(trimws(AL$classification))
  k <- paste(C$table, C$column); ka <- paste(AL$table, AL$column)
  C$declared <- AL$classification[match(k, ka)]
  unresolved <- C[is.na(C$declared) | C$declared %in% c("review",""), ]
  inv <- C[C$declared %in% "invented", ]
  cat("\n=== AGAINST THE CLASSIFICATION FILE ===\n")
  cat("declared invented:", nrow(inv), " still REVIEW / undeclared:", nrow(unresolved), "\n")
  if (nrow(inv)) print(inv[, c("table","column","filled")], row.names=FALSE)
}
