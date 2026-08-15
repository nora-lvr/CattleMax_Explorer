## ---------------------------------------------------------------
## THE INVENTION GATE. A value the pipeline manufactured is only allowed to
## exist if Nora has approved that exact variable, by name, in
## reference/approved_inventions.csv.
##
## Nora's standing rule, 2026-08-15:
##   "you are not allowed to make things up like this. We don't ever make up
##    data unless we have discussed it and I specifically approved it."
##
## An invented value is worse than a missing one. Missing is visible; invented
## is indistinguishable from real once it is downstream, and it silently becomes
## a denominator. This is a veterinary decision tool - a manufactured date can
## become a cull call.
##
## HOW IT WORKS. Two independent detectors, because one can be forgotten:
##   1. DATA  - every *_source / *_rule column in every silver table is read and
##              any value carrying an invention marker (EST, ASSUMED, fallback,
##              estimated, imputed, assumed) is collected with its row count.
##   2. CODE  - R/ is scanned for the same markers being ASSIGNED, so a new
##              invention is caught even before it reaches a source column.
## Anything found that is not approved in the csv fails the run, non-zero.
##
##   Rscript R/test_no_invention.R          enforce; stop on anything unapproved
##   Rscript R/test_no_invention.R list     just list what was found, never stop
## ---------------------------------------------------------------
options(width=210)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
MODE <- if (any(commandArgs(trailingOnly=TRUE) == "list")) "list" else "enforce"

ALLOW <- file.path(cfg$root, "reference", "approved_inventions.csv")
MARKERS <- "EST|ASSUMED|fallback|estimated|imputed|assumed|inferred|placeholder"

## ---- 1. what the DATA admits to ----------------------------------------
tabs <- sub("\\.parquet$", "", list.files(cfg$silver, pattern="\\.parquet$"))
found <- list()
for (tb in tabs) {
  d <- tryCatch(cm_read_silver(cfg, tb), error=function(e) NULL)
  if (is.null(d) || !nrow(d)) next
  ## the columns whose whole job is to say where a value came from
  prov <- grep("_source$|_rule$|_anchor$", names(d), value=TRUE)
  ## EVERY distinct value, not only the ones carrying a marker word. A regex
  ## looking for EST/ASSUMED missed `first_calving-283d`, which manufactures a
  ## season start by subtracting the gestation constant. If a value is not
  ## classified in the allow list, the run fails - silence is never approval.
  for (cl in prov) {
    v <- d[[cl]]; v <- v[!is.na(v)]
    if (!length(v)) next
    for (h in unique(v)) found[[length(found)+1]] <- data.frame(
      table=paste0(tb,".parquet"), column=cl, marker=h, n=sum(v == h),
      via="provenance column", stringsAsFactors=FALSE)
  }
  ## A flag that says "this value was assumed" is the same admission again, not
  ## a second invention - it is only reported when NO provenance column in this
  ## table already accounts for it, which is the case worth catching.
  fl <- grep("^flag_.*(assumed|estimated|inferred|imputed)", names(d), value=TRUE)
  for (cl in fl) {
    n <- sum(d[[cl]], na.rm=TRUE); if (!n) next
    prov_n <- sum(vapply(found, function(z)
      if (z$table == paste0(tb,".parquet") && z$via == "provenance column") z$n else 0, numeric(1)))
    if (n > prov_n) found[[length(found)+1]] <- data.frame(
      table=paste0(tb,".parquet"), column=cl, marker=cl, n=n,
      via="flag with no provenance column", stringsAsFactors=FALSE)
  }
}
F <- if (length(found)) do.call(rbind, found) else
     data.frame(table=character(), column=character(), marker=character(),
                n=integer(), via=character())

## ---- 2. what the CODE is doing, whether or not it reached the data ------
## Catches an invention added today that has not been rebuilt yet.
srcf <- list.files(file.path(cfg$root,"R"), pattern="\\.R$", full.names=TRUE)
code <- list()
for (f in srcf) {
  if (basename(f) == "test_no_invention.R") next     # this file defines the markers
  ln <- readLines(f, warn=FALSE)
  ## an assignment of a literal that carries a marker, e.g.  wsrc[i] <- "...(EST 205d)"
  i <- grep(paste0('<-\\s*"[^"]*(', MARKERS, ')[^"]*"'), ln)
  i <- setdiff(i, grep("^\\s*##", ln))          # comments are not inventions
  for (k in i) code[[length(code)+1]] <- data.frame(
    file=basename(f), line=k, text=trimws(ln[k]), stringsAsFactors=FALSE)
}
CODE <- if (length(code)) do.call(rbind, code) else
        data.frame(file=character(), line=integer(), text=character())

## ---- 3. the allow list --------------------------------------------------
if (!file.exists(ALLOW)) stop("missing allow list: ", ALLOW)
## character throughout: an approval file is text, and a marker whose value is
## "NA" must not be read as missing
AL <- as.data.frame(readr::read_csv(ALLOW,
        col_types = readr::cols(.default = readr::col_character()),
        na = c(""), progress = FALSE, show_col_types = FALSE),
      stringsAsFactors = FALSE)
AL$approved <- toupper(trimws(AL$approved))
AL$kind    <- tolower(trimws(AL$kind))
F$key <- paste(F$table, F$column, F$marker)
key_al <- paste(AL$table, AL$column, AL$marker)
F$listed   <- F$key %in% key_al
F$kind     <- AL$kind[match(F$key, key_al)]
F$approved <- ifelse(is.na(F$kind), FALSE,
              ifelse(F$kind == "observed", TRUE,
                     F$key %in% key_al[AL$approved == "YES"]))

cat("=== INVENTION GATE ===\n")
cat("allow list:", ALLOW, "\n")
cat("classified:", nrow(AL), " observed:", sum(AL$kind=="observed"),
    " invented:", sum(AL$kind=="invented"),
    " of which approved:", sum(AL$kind=="invented" & AL$approved=="YES"), "\n\n")

if (!nrow(F)) {
  cat("no manufactured values found in any silver table\n")
} else {
  o <- F[order(F$kind, -F$n), c("table","column","marker","n","kind","approved")]
  o$kind[is.na(o$kind)] <- "UNCLASSIFIED"
  print(o, row.names=FALSE)
}

bad <- F[!F$approved, ]
new <- F[!F$listed, ]

if (nrow(new)) {
  cat("\n*** UNCLASSIFIED - not in the allow list at all ***\n")
  print(new[, c("table","column","marker","n")], row.names=FALSE)
}

if (nrow(bad)) {
  cat("\n*** NOT CLEARED TO SHIP:", sum(bad$n), "records across",
      nrow(bad), "variables ***\n")
  for (i in seq_len(nrow(bad)))
    cat(sprintf("  %-26s %-16s %-26s %6d rows\n",
        bad$table[i], bad$column[i], bad$marker[i], bad$n[i]))
  cat("\nNothing here may ship until Nora approves each variable BY NAME in\n")
  cat(ALLOW, "\n(set approved = YES, with who and when).\n")
  cat("The alternative is to stop manufacturing the value and leave it NA.\n")
}

if (nrow(CODE)) {
  cat("\n-- code that assigns an invention marker (backstop) --\n")
  for (i in seq_len(nrow(CODE)))
    cat(sprintf("  %-22s :%-4d %s\n", CODE$file[i], CODE$line[i],
        substr(CODE$text[i], 1, 96)))
}

if (MODE == "enforce" && nrow(bad)) {
  stop(sprintf("invention gate failed: %d unapproved manufactured values", sum(bad$n)))
}
if (!nrow(bad)) cat("\nPASS - every manufactured value is approved by name\n")
