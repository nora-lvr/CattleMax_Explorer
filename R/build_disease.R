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

## A new episode of the same disease starts after this many treatment-free
## days. NOT YET VALIDATED BY NORA - see PLAN.md 8.
CASE_GAP_DAYS   <- 14
## How long after a case ends we still attribute a death to it.
DEATH_WINDOW_DAYS <- 60

A  <- cm_read_silver(cfg, "animals")
TX <- cm_read_silver(cfg, "treatments")

## ---- only therapeutic events define a case ------------------------------
th <- TX[TX$treatment_intent %in% "Therapeutic", ]
excl_add("disease_cases.parquet", "treatment is not therapeutic",
         nrow(TX) - nrow(th),
         detail = "vaccines, antiparasitics and supportive care are not disease cases",
         recoverable = FALSE)
th <- th[!is.na(th$animal_id) & !is.na(th$treatment_date), ]
## an undiagnosed therapeutic event still IS a case - it is just an unnamed one
th$dx <- ifelse(is.na(th$disease_category), "Undiagnosed", th$disease_category)
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
C$flag_no_diagnosis   <- C$disease == "Undiagnosed"
C$flag_no_location    <- is.na(C$pasture_id)
C$flag_no_birth_date  <- is.na(C$birth_date)
C$flag_single_treatment <- C$n_treatments == 1
C$flag_long_case      <- C$duration_days > 30

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

cat("\n=== FLAGS ===\n"); print(sapply(C[,grep("^flag_",names(C))], sum, na.rm=TRUE))
excl_write(cfg$silver)
