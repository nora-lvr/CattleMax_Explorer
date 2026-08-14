## ---------------------------------------------------------------
## phase_risk.parquet : one row per ANIMAL-PHASE.
##
## The denominator a producer actually understands. Rather than "cases per
## 1,000 animal-days", this supports "X% of calves got BRD before weaning" -
## a cumulative incidence over a phase the producer manages as a unit.
##
## It also carries DAYS AT RISK per phase, so a rate is still available where
## the phases have very different lengths.
##
## Each row is one animal's stay in one production phase:
##   Calf     entry (birth or purchase) -> weaning
##   Growing  weaning                   -> first calving / first sire use / exit
##   Cow      first calving             -> exit
##   Breeding first use as a sire       -> exit
## clipped to her presence, and marked `completed` if she finished the phase
## rather than still being in it or leaving mid-phase.
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
PULL <- cfg$pull_date
source(file.path(cfg$root,"R","exclusions.R")); excl_reset()

A <- cm_read_silver(cfg, "animals")

## ---- phase boundaries, already stored as dates ---------------------------
## The end of a phase is the start of whichever phase follows it for THAT
## animal; a bull has no Cow phase and a female has no Breeding phase.
nxt <- function(i) {
  cand <- c(A$growing_start[i], A$cow_start[i], A$sire_start[i])
  cand <- cand[!is.na(cand)]
  cand
}
rows <- list()
for (i in seq_len(nrow(A))) {
  ent <- A$entry_date[i]; ex <- A$exit_date[i]
  if (is.na(ent)) next
  stop_at <- if (is.na(ex)) PULL else ex
  starts <- c(Calf = ent, Growing = A$growing_start[i],
              Cow = A$cow_start[i], Breeding = A$sire_start[i])
  starts <- starts[!is.na(starts)]
  starts <- sort(starts)
  ## a phase that begins after she left never happened
  starts <- starts[starts <= stop_at]
  if (!length(starts)) next
  nm <- names(starts)
  for (k in seq_along(starts)) {
    s <- as.Date(starts[[k]], origin="1970-01-01")
    e <- if (k < length(starts)) as.Date(starts[[k+1]], origin="1970-01-01") - 1 else stop_at
    if (e > stop_at) e <- stop_at
    if (is.na(s) || is.na(e) || e < s) next
    rows[[length(rows)+1]] <- data.frame(
      animal_id   = A$animal_id[i],
      phase       = nm[k],
      phase_start = s,
      phase_end   = e,
      days_at_risk= as.numeric(e - s) + 1,
      ## completed = she moved on to the next phase rather than the window
      ## being cut short by her exit or by the pull date
      completed   = k < length(starts),
      ended_by    = if (k < length(starts)) "moved to next phase"
                    else if (!is.na(ex)) "left the herd" else "still in phase at pull",
      stringsAsFactors = FALSE)
  }
}
P <- do.call(rbind, rows)

m <- match(P$animal_id, A$animal_id)
P$sex        <- A$sex[m]
P$birth_date <- A$birth_date[m]
P$status     <- A$status[m]
P$exit_date  <- A$exit_date[m]
P$age_days_at_phase_start <- as.numeric(P$phase_start - P$birth_date)
## the clock a producer thinks in: day 0 of the phase
P$phase_clock <- ifelse(P$phase == "Calf", "days since birth",
                 ifelse(P$phase == "Growing", "days since weaning",
                 ifelse(P$phase == "Cow", "days since first calving", "days since first sire use")))

## ---- COHORT: the group she entered the phase WITH -----------------------
## Animals move through a phase together, so a trend must compare groups that
## entered together rather than slicing a calendar year across two calvings.
## The calving year has two blocks (Spring 1 Jan - 22 Apr, Fall 30 Jul -
## 25 Nov), so a phase entry in Jan-Jun is a Spring group and Jul-Dec a Fall
## group. For Calf that is her birth crop; for Growing her weaning group; for
## Cow the season she first calved; for Breeding when he first went to work.
.mo <- as.integer(format(P$phase_start, "%m"))
.yr <- as.integer(format(P$phase_start, "%Y"))
P$cohort_season <- ifelse(.mo <= 6, "Spring", "Fall")
P$cohort_year   <- .yr
P$cohort        <- paste(P$cohort_season, P$cohort_year)
P$cohort_sort   <- .yr * 10 + ifelse(.mo <= 6, 1, 2)   # orders Spring before Fall

## ---- IS THE CLOCK ON ITS TRUE ANCHOR? -----------------------------------
## The phase clock is only "days since birth" / "days since weaning" when the
## animal was here for that event. A female bought at 3 years old has no
## recorded weaning we were present for, so her Growing clock starts at
## PURCHASE. Reports must say so rather than claim a weaning-based day.
.A <- A[match(P$animal_id, A$animal_id), ]
P$clock_true <- rep(TRUE, nrow(P))
## Calf: true only when the phase starts at birth
i <- P$phase == "Calf"
P$clock_true[i] <- !is.na(.A$birth_date[i]) & P$phase_start[i] == .A$birth_date[i]
## Growing: true only when it starts on the recorded weaning date
i <- P$phase == "Growing"
P$clock_true[i] <- !is.na(.A$weaning_date[i]) & P$phase_start[i] == .A$weaning_date[i]
## Cow / Breeding anchor on events that must have happened here
P$clock_anchor <- ifelse(P$clock_true, P$phase_clock, "days since purchase")
P$days_anchor_late <- ifelse(P$phase == "Growing" & !P$clock_true & !is.na(.A$weaning_date),
                             as.numeric(P$phase_start - .A$weaning_date),
                      ifelse(P$phase == "Calf" & !P$clock_true & !is.na(.A$birth_date),
                             as.numeric(P$phase_start - .A$birth_date), NA_real_))

P$flag_clock_not_true   <- !P$clock_true
## a phase that begins before the animal was born is impossible: purchase_date
## precedes birth_date on a handful of records
P$flag_start_before_birth <- !is.na(P$birth_date) & P$phase_start < P$birth_date
## born long before CattleMax recording began; their day-of-phase can run to
## decades and must never be plotted as if it were a current animal
P$flag_pre_horizon_birth <- !is.na(P$birth_date) &
                            P$birth_date < as.Date("2015-01-01")

P$flag_no_birth_date <- is.na(P$birth_date)
P$flag_censored      <- !P$completed
P$flag_zero_length   <- P$days_at_risk <= 1

P <- P[order(P$animal_id, P$phase_start), ]
cm_write_silver(P, cfg, "phase_risk")

cat("\n=== ANIMAL-PHASES ===\n")
cat("rows:", nrow(P), " animals:", length(unique(P$animal_id)), "\n")
tab <- do.call(rbind, lapply(c("Calf","Growing","Cow","Breeding"), function(ph){
  s <- P[P$phase == ph, ]
  if (!nrow(s)) return(NULL)
  data.frame(phase=ph, animals=nrow(s),
             completed=sum(s$completed),
             censored=sum(!s$completed),
             median_days=round(median(s$days_at_risk)),
             total_animal_days=sum(s$days_at_risk),
             stringsAsFactors=FALSE)}))
print(tab, row.names=FALSE)
cat("\n=== IS THE PHASE CLOCK ON ITS TRUE ANCHOR? ===\n")
ct <- do.call(rbind, lapply(c("Calf","Growing","Cow","Breeding"), function(ph){
  s <- P[P$phase == ph, ]; if (!nrow(s)) return(NULL)
  data.frame(phase=ph, rows=nrow(s), true_anchor=sum(s$clock_true),
             on_purchase=sum(!s$clock_true),
             median_days_late=if (any(!s$clock_true & !is.na(s$days_anchor_late)))
               round(median(s$days_anchor_late[!s$clock_true], na.rm=TRUE)) else NA_real_,
             stringsAsFactors=FALSE)}))
print(ct, row.names=FALSE)
cat("on_purchase = the animal was bought after the anchoring event, so her clock\n")
cat("starts at purchase. Her day-of-phase is NOT days since birth/weaning and a\n")
cat("report must not label it as such.\n")
cat("\nphase starts BEFORE the animal was born:", sum(P$flag_start_before_birth), "\n")
cat("born before 2015 (pre-recording):", sum(P$flag_pre_horizon_birth), "\n")

cat("\nCENSORED means the phase was cut short by her leaving or by the pull\n")
cat("date. Those animals were still at risk for the days they were in it, so\n")
cat("they belong in a days-at-risk denominator but NOT in a completed-phase\n")
cat("attack rate without saying so.\n")

excl_add("phase_risk.parquet", "animal has no entry date, so no phase window",
         sum(is.na(A$entry_date)), n_animals = sum(is.na(A$entry_date)),
         detail = "cannot place her on a timeline at all", recoverable = FALSE)
excl_write(cfg$silver)
