## ---------------------------------------------------------------
## INDEPENDENT presence reconciliation.
##
## The old check compared phase counts against status=="Active". That could
## never fail: exit_date is written only for Sold/Dead animals, so
## "present at the pull" was identical to status=="Active" by construction.
## It re-read CattleMax's own answer instead of reconstructing it.
##
## This rebuilds presence from DATED EVIDENCE ONLY - birth, purchase,
## movements, sale tickets, sale and death dates - and never consults
## `status`. It is therefore allowed to disagree, and every disagreement is
## itemised below.
## ---------------------------------------------------------------
options(width=200)
D      <- "C:/GIT/CattleMax_Explorer/data/81258_joe_mertz_202607291020"
SILVER <- "C:/GIT/CattleMax_Explorer/data/silver-data"
rd  <- function(f) read.csv(file.path(D,f), stringsAsFactors=FALSE, colClasses="character", na.strings=c("","NA"))
d10 <- function(x) as.Date(substr(x,1,10))
PULL <- as.Date("2026-07-29")

a  <- rd("animals.csv"); mv <- rd("movements.csv"); st <- rd("sale_tickets.csv")
A  <- as.data.frame(arrow::read_parquet(file.path(SILVER,"animals.parquet")))
a  <- a[!(a$status %in% "Reference"), ]      # the one status use: see note below
cat("NOTE: status is used ONLY to drop Reference animals (a settled rule).\n")
cat("      Presence itself is derived from dates alone.\n\n")

## ---- ENTRY from dated evidence ----
bd <- d10(a$birth_date); pd <- d10(a$purchase_date)
fm <- as.Date(tapply(as.integer(d10(mv$movement_date)), mv$animal_id, min, na.rm=TRUE)[a$id],
              origin="1970-01-01"); fm[!is.finite(as.numeric(fm))] <- NA
entry <- as.Date(ifelse(!is.na(pd), pd, bd), origin="1970-01-01")
entry <- as.Date(ifelse(!is.na(entry), entry, fm), origin="1970-01-01")

## ---- DEPARTURE from dated evidence ONLY ----
tick  <- setNames(d10(st$sale_date), st$id)
left  <- suppressWarnings(pmin(d10(a$sale_date), d10(a$death_date),
                               tick[a$sale_ticket_id], na.rm=TRUE))
left[!is.finite(as.numeric(left))] <- NA
left <- as.Date(left, origin="1970-01-01")

present <- !is.na(entry) & entry <= PULL & (is.na(left) | left > PULL)
cat("=== INDEPENDENT COUNT (dates only, status never consulted) ===\n")
cat("present at", format(PULL), ":", sum(present), "\n")
cm <- sum(a$status %in% "Active")
cat("CattleMax status == Active  :", cm, "\n")
cat("difference                  :", sum(present)-cm, "\n\n")

## ---- itemise every disagreement ----
cat("=== DISAGREEMENTS ===\n")
d1 <- present & !(a$status %in% "Active")
d2 <- !present & (a$status %in% "Active")
cat("A. dates say PRESENT, CattleMax says not Active:", sum(d1), "\n")
if (any(d1)) print(table(a$status[d1]))
cat("\n   why: these left with NO dated evidence of leaving\n")
cat("   of those, status Sold/Dead with no sale/death/ticket date:",
    sum(d1 & a$status %in% c("Sold","Dead")), "\n")

cat("\nB. dates say GONE, CattleMax says Active:", sum(d2), "\n")
if (any(d2)) {
  x <- data.frame(id=a$id[d2], tag=a$ear_tag[d2], status=a$status[d2],
                  entry=format(entry[d2]), left=format(left[d2]),
                  sale=a$sale_date[d2], death=a$death_date[d2], stringsAsFactors=FALSE)
  print(utils::head(x, 20), row.names=FALSE)
}

## ---- the substrate's own answer, for comparison ----
cat("\n=== THREE ANSWERS SIDE BY SIDE ===\n")
liveA <- !is.na(A$entry_date) & A$entry_date<=PULL & (is.na(A$exit_date)|A$exit_date>=PULL)
cat("1. CattleMax status == Active        :", cm, "\n")
cat("2. animals.parquet presence interval :", sum(liveA), "\n")
cat("3. independent, dates only           :", sum(present), "\n")
cat("\n(2) is expected to track (1) closely because the exit rule falls back to\n")
cat("status when no date exists. (3) is the one free to disagree, and the gap\n")
cat("between (1) and (3) IS the count of departures with no recorded date.\n")

## ---- historical spot checks: no status column can help here ----
cat("\n=== HISTORICAL AS-OF COUNTS (dates only) ===\n")
for (d in as.Date(c("2020-07-29","2022-07-29","2024-07-29","2026-07-29"))) {
  d <- as.Date(d, origin="1970-01-01")
  n <- sum(!is.na(entry) & entry<=d & (is.na(left) | left>d))
  cat(sprintf("  %s : %5d present\n", format(d), n))
}
cat("\nThese cannot be reconciled against CattleMax at all - it publishes only a\n")
cat("current status - so they are the real test of the interval reconstruction.\n")
