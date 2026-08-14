## ---------------------------------------------------------------
## disease_cases.parquet : one row per DISEASE CASE, with its OUTCOME.
##
## A treatment event is not a case. An animal treated on three consecutive
## days for pinkeye has ONE case and three treatments; counting treatments as
## cases inflates incidence by however often the practice re-treats.
##
## A case is: a run of therapeutic treatments on one animal for one disease
## category, separated from the next run by more than CASE_GAP_DAYS.
##
## Outcome is resolved from what happened AFTER the case: died, sold, still
## here, or relapsed. That is the half CattleMax does not record.
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
PULL <- cfg$pull_date
source(file.path(cfg$root,"R","exclusions.R")); excl_reset()

## ---- TUNABLE PARAMETERS --------------------------------------------------
## A new episode of the same disease starts after this many treatment-free
## days, and a death within DEATH_WINDOW_DAYS of a case is attributed to it.
## Both are clinical judgement calls, so both are RUNTIME PARAMETERS:
##
##   Rscript R/build_disease.R                 # defaults, 14 and 60
##   Rscript R/build_disease.R 21              # 21-day episode gap
##   Rscript R/build_disease.R 21 45           # gap 21, death window 45
##
## or from another script:  CASE_GAP_DAYS <- 30; source("R/build_disease.R")
##
## The chosen values are stamped onto every row of disease_cases.parquet, so a
## report can never present cases built under one setting as if they were
## built under another.
.args <- commandArgs(trailingOnly = TRUE)
.args <- suppressWarnings(as.numeric(.args[grepl("^[0-9]+$", .args)]))
if (!exists("CASE_GAP_DAYS"))
  CASE_GAP_DAYS <- if (length(.args) >= 1) .args[1] else 14
if (!exists("DEATH_WINDOW_DAYS"))
  DEATH_WINDOW_DAYS <- if (length(.args) >= 2) .args[2] else 60
stopifnot(CASE_GAP_DAYS >= 0, DEATH_WINDOW_DAYS >= 0)
cat("case gap    :", CASE_GAP_DAYS, "treatment-free days start a new episode\n")
cat("death window:", DEATH_WINDOW_DAYS, "days after a case still counts as its death\n\n")

A  <- cm_read_silver(cfg, "animals")
TX <- cm_read_silver(cfg, "treatments")

## ---- only therapeutic events define a case ------------------------------
th <- TX[TX$treatment_intent %in% "Therapeutic", ]
excl_add("disease_cases.parquet", "treatment is not therapeutic",
         nrow(TX) - nrow(th),
         detail = "vaccines, antiparasitics and supportive care are not disease cases",
         recoverable = FALSE)
th <- th[!is.na(th$animal_id) & !is.na(th$treatment_date), ]
## a therapeutic event with no diagnosis still IS a case - it is just unnamed.
## NEVER dropped: it is reported as "Unknown disease" so it stays visible.
th$dx <- ifelse(is.na(th$disease_category), "Unknown disease", th$disease_category)
cat("therapeutic events:", nrow(th), " animals:", length(unique(th$animal_id)),
    " named diseases:", length(setdiff(unique(th$dx), "Undiagnosed")), "\n")

## ---- collapse treatment runs into cases ---------------------------------
th <- th[order(th$animal_id, th$dx, th$treatment_date), ]
key <- paste(th$animal_id, th$dx)
newcase <- c(TRUE, key[-1] != key[-length(key)] |
             as.numeric(diff(th$treatment_date)) > CASE_GAP_DAYS)
th$case_id <- cumsum(newcase)

agg <- function(f, ...) tapply(..., th$case_id, f)
C <- data.frame(
  case_id        = sort(unique(th$case_id)),
  animal_id      = as.character(agg(function(v) v[1], th$animal_id)),
  disease        = as.character(agg(function(v) v[1], th$dx)),
  start_date     = .deinf(agg(min, as.integer(th$treatment_date))),
  end_date       = .deinf(agg(max, as.integer(th$treatment_date))),
  n_treatments   = as.integer(agg(length, th$treatment_id)),
  substances     = as.character(agg(function(v) paste(sort(unique(v)), collapse="/"), th$active_substance)),
  max_temp       = as.numeric(agg(function(v) if(all(is.na(v))) NA else max(v,na.rm=TRUE), th$temperature)),
  phase_at_start = as.character(agg(function(v) v[1], th$phase_at_treatment)),
  stringsAsFactors = FALSE)
C$duration_days <- as.numeric(C$end_date - C$start_date) + 1
cat("cases:", nrow(C), " from", nrow(th), "therapeutic events",
    sprintf(" (%.2f treatments per case)\n", nrow(th)/nrow(C)))

## ---- animal context ------------------------------------------------------
m <- match(C$animal_id, A$animal_id)
C$sex        <- A$sex[m]
C$birth_date <- A$birth_date[m]
C$exit_date  <- A$exit_date[m]
C$exit_reason_group <- A$exit_reason_group[m]
C$status     <- A$status[m]
C$age_days_at_onset <- as.numeric(C$start_date - C$birth_date)
C$age_months_at_onset <- round(C$age_days_at_onset/30.44, 1)

## ---- WHERE was she when it started? -------------------------------------
LOC <- cm_read_silver(cfg, "locations")
loc_at <- function(aid, dt) {
  s <- LOC[LOC$animal_id == aid & LOC$from_date <= dt & LOC$to_date >= dt, ]
  if (!nrow(s)) return(c(NA_character_, NA_character_))
  c(s$pasture_id[1], s$pasture_name[1])
}
lp <- vapply(seq_len(nrow(C)), function(i) loc_at(C$animal_id[i], C$start_date[i]),
             character(2))
C$pasture_id   <- lp[1, ]
C$pasture_name <- lp[2, ]

## ---- WHERE IN THE PHASE did it strike? ----------------------------------
## The producer's clock: days since birth for a calf, days since weaning for a
## grower. This is what makes "BRD hits at day 40 of the calf phase" sayable.
PR <- cm_read_silver(cfg, "phase_risk")
PRk <- split(seq_len(nrow(PR)), PR$animal_id)
ph_at <- function(aid, dt) {
  ix <- PRk[[aid]]
  if (is.null(ix)) return(c(NA_character_, NA_real_, NA_real_))
  hit <- ix[PR$phase_start[ix] <= dt & PR$phase_end[ix] >= dt]
  if (!length(hit)) return(c(NA_character_, NA_real_, NA_real_))
  h <- hit[1]
  c(PR$phase[h], as.numeric(dt - PR$phase_start[h]), PR$days_at_risk[h])
}
pa <- vapply(seq_len(nrow(C)), function(i) ph_at(C$animal_id[i], C$start_date[i]), character(3))
C$phase_at_onset   <- pa[1, ]
C$day_of_phase     <- as.numeric(pa[2, ])   # 0 = the day the phase began
C$phase_length_days<- as.numeric(pa[3, ])
## keep the treatment-derived phase too; they can disagree and that is worth seeing
C$flag_phase_disagrees <- !is.na(C$phase_at_onset) & !is.na(C$phase_at_start) &
                          C$phase_at_onset != C$phase_at_start

## ---- OUTCOME -------------------------------------------------------------
## What happened after the case ended. This is the question the raw export
## cannot answer, and the whole reason for building a case table.
died_after <- !is.na(C$exit_date) & C$status %in% "Dead" &
              C$exit_date >= C$start_date &
              as.numeric(C$exit_date - C$end_date) <= DEATH_WINDOW_DAYS
sold_after <- !is.na(C$exit_date) & C$status %in% "Sold" &
              C$exit_date >= C$start_date &
              as.numeric(C$exit_date - C$end_date) <= DEATH_WINDOW_DAYS
## relapse: another case of the SAME disease in the same animal, later
C <- C[order(C$animal_id, C$disease, C$start_date), ]
k2 <- paste(C$animal_id, C$disease)
relapsed <- c(k2[-length(k2)] == k2[-1], FALSE)

C$outcome <- ifelse(died_after, "Died",
             ifelse(sold_after, "Sold soon after",
             ifelse(relapsed,   "Relapsed",
             ifelse(is.na(C$exit_date), "Survived, still here", "Survived, later left"))))
C$days_to_death <- ifelse(died_after, as.numeric(C$exit_date - C$end_date), NA_real_)
C$case_fatal    <- died_after

## ---- flags ---------------------------------------------------------------
C$flag_no_diagnosis   <- C$disease == "Unknown disease"
C$flag_no_location    <- is.na(C$pasture_id)
C$flag_no_birth_date  <- is.na(C$birth_date)
C$flag_single_treatment <- C$n_treatments == 1
C$flag_long_case      <- C$duration_days > 30

## stamp the settings onto every row: a case built at a 14-day gap is not the
## same object as one built at 30, and a report must be able to tell
C$case_gap_days      <- CASE_GAP_DAYS
C$death_window_days  <- DEATH_WINDOW_DAYS

C <- C[order(C$start_date, C$animal_id), ]
cm_write_silver(C, cfg, "disease_cases")

cat("\n=== CASES BY DISEASE ===\n")
d <- as.data.frame(table(C$disease)); names(d) <- c("disease","cases")
d$animals <- as.integer(tapply(C$animal_id, C$disease, function(v) length(unique(v)))[d$disease])
d$fatal   <- as.integer(tapply(C$case_fatal, C$disease, sum)[d$disease])
d$case_fatality_pct <- round(100*d$fatal/d$cases, 1)
d$median_treatments <- as.numeric(tapply(C$n_treatments, C$disease, median)[d$disease])
print(d[order(-d$cases), ], row.names=FALSE)

cat("\n=== OUTCOMES ===\n")
print(sort(table(C$outcome), decreasing=TRUE))
cat("\noverall case fatality:", sum(C$case_fatal), "of", nrow(C),
    sprintf(" = %.1f%%\n", 100*mean(C$case_fatal)))
cat("days from end of treatment to death:\n")
print(round(summary(C$days_to_death[!is.na(C$days_to_death)])))

cat("\n=== CASES BY PHASE AT ONSET ===\n")
print(table(C$phase_at_start, C$disease, useNA="ifany")[, head(names(sort(table(C$disease),
      decreasing=TRUE)), 6), drop=FALSE])

cat("\n=== DAY OF PHASE AT ONSET ===\n")
for (ph in c("Calf","Growing","Cow","Breeding")) {
  s <- C[C$phase_at_onset %in% ph, ]
  if (!nrow(s)) next
  cat(sprintf("\n%s (%s), n=%d\n", ph, PR$phase_clock[match(ph, PR$phase)], nrow(s)))
  print(round(summary(s$day_of_phase)))
  top <- head(sort(table(s$disease), decreasing=TRUE), 4)
  for (dz in names(top)) {
    v <- s$day_of_phase[s$disease == dz]
    cat(sprintf("   %-24s n=%-4d median day %3.0f   IQR %3.0f-%3.0f\n",
        dz, length(v), median(v, na.rm=TRUE),
        quantile(v, .25, na.rm=TRUE), quantile(v, .75, na.rm=TRUE)))
  }
}

cat("\n=== INCIDENCE PER PHASE ===\n")
cat("PREDOMINANT METRIC: attack rate = % of animals entering the phase that\n")
cat("had at least one case during it. Risk is NOT uniform across a phase -\n")
cat("BRD in Growing peaks around day 33 while pinkeye peaks around day 87 -\n")
cat("so a time-normalised rate, which assumes constant hazard, understates\n")
cat("the early-onset diseases and overstates the late ones.\n")
cat("The per-100-median-stays rate is reported alongside as a cross-check.\n\n")
inc <- do.call(rbind, lapply(c("Calf","Growing","Cow","Breeding"), function(ph){
  pr <- PR[PR$phase == ph, ]; if (!nrow(pr)) return(NULL)
  cs <- C[C$phase_at_onset %in% ph, ]
  med <- median(pr$days_at_risk); tot <- sum(pr$days_at_risk)
  n_all  <- nrow(pr); n_done <- sum(pr$completed)
  done_ids <- pr$animal_id[pr$completed]
  do.call(rbind, lapply(sort(unique(cs$disease)), function(dz){
    k   <- cs[cs$disease == dz, ]
    aff <- length(unique(k$animal_id))
    aff_done <- length(unique(k$animal_id[k$animal_id %in% done_ids]))
    data.frame(phase=ph, disease=dz,
      ## ---- the headline ----
      attack_rate_pct = round(100*aff/n_all, 1),
      animals_affected= aff,
      animals_in_phase= n_all,
      ## ---- censoring-free view: animals that finished the phase ----
      ## suppressed when too few animals finished the phase for it to mean
      ## anything - a 0.0% on a denominator of 90 is not a finding
      attack_completed_pct = if (n_done >= 100) round(100*aff_done/n_done, 1) else NA_real_,
      completed_in_phase   = n_done,
      ## ---- secondary, time-normalised ----
      cases = nrow(k),
      rate_per_100_median_stays = round(100*nrow(k)*med/tot, 2),
      median_days = round(med),
      ## ---- when in the phase ----
      median_day_of_onset = round(median(k$day_of_phase, na.rm=TRUE)),
      fatal = sum(k$case_fatal),
      stringsAsFactors=FALSE)}))
}))
inc <- inc[order(inc$phase, -inc$attack_rate_pct), ]
print(inc[, c("phase","disease","attack_rate_pct","animals_affected","animals_in_phase",
              "attack_completed_pct","completed_in_phase","cases",
              "rate_per_100_median_stays","median_day_of_onset","fatal")], row.names=FALSE)
## the incidence table is a deliverable in its own right
utils::write.csv(inc, file.path(cfg$derived, "disease_incidence_by_phase.csv"),
                 row.names=FALSE, na="")
cat("\nwrote disease_incidence_by_phase.csv\n")
cat("\nattack_rate_pct uses EVERY animal that entered the phase, including\n")
cat("those censored part way through, so it is a floor. attack_completed_pct\n")
cat("uses only animals that finished the phase and is the unbiased figure;\n")
cat("where the two diverge, censoring is doing the work.\n")

cat("\n=== FLAGS ===\n"); print(sapply(C[,grep("^flag_",names(C))], sum, na.rm=TRUE))
excl_write(cfg$silver)
