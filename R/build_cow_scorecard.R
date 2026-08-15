## ---------------------------------------------------------------
## cow_scorecard.parquet : one row per COW.
## calf_fates.parquet    : one row per CALVING, on the outcome ladder below.
##
## THE OUTCOME IS SURVIVAL TO TRANSITION. A calf has succeeded when it becomes
## a product or a producer:
##     sold  |  first calving  |  first use as a sire
## What happens to that animal AFTERWARDS is its own record, not its dam's. A
## heifer who calved and then died at four years old is a calf her dam
## delivered; her death belongs to a cow-longevity metric, not to this one.
## (Nora, 2026-08-15. The earlier build counted those 46 animals as calves lost,
## which penalised exactly the dams whose daughters were kept as replacements.)
##
## EVERY CALVING REPORTS ITS EXACT CURRENT STATUS, and a status that can still
## change is flagged PRELIMINARY rather than forced past an age threshold:
##
##   final        left open, no calf   (terminal: she was exposed and left)
##                died by day 7                     (calving, dam, mothering)
##                died before weaning               (scours, pneumonia)
##                died after weaning, before transition
##                transitioned: sold / calved / used as sire
##   preliminary  alive, not yet weaned
##                alive, weaned, not yet transitioned
##   unknowable   calving whose calf has no animal record
##
## Rates are built on FINAL outcomes only. Preliminary seasons are carried
## alongside and never counted as failures - a calf still growing is not a loss.
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
##   Rscript R/build_cow_scorecard.R          # defaults 7 / 3
##   Rscript R/build_cow_scorecard.R 2        # neonatal window 2 days
##   Rscript R/build_cow_scorecard.R 7 4      # + min 4 final seasons to rank
.args <- suppressWarnings(as.numeric(commandArgs(trailingOnly=TRUE)))
.args <- .args[!is.na(.args)]
if (!exists("NEONATAL_DAYS")) NEONATAL_DAYS <- if (length(.args)>=1) .args[1] else 7
if (!exists("MIN_FINAL"))     MIN_FINAL     <- if (length(.args)>=2) .args[2] else 3
## EVERY cow with enough history is scored, gone or not. Filtering to the ones
## still in the herd is the REPORT's job, not the engine's: a cow that has left
## still carries the only complete calving record we will ever have of her, and
## dropping her here would delete the herd's history. (Nora, 2026-08-15.)
##
## LONG_INTERVAL_DAYS: a cow-season in cows.parquet ends AT a calving, so a cow
## that skips a year does NOT produce a "missed" season - she produces one long
## one. Verified on this pull: all 763 non-calving seasons are the cow's LAST
## season and none are mid-career, so "no calf" means SHE LEFT OPEN and nothing
## else. The real "she skipped" signal is the interval, and it is the only form
## of the calving hurdle that is observable on a cow still in the herd.
## Gestation is 283 d, so a cow rebreeding promptly lands near 365; 430 leaves
## roughly two months of slack before a season counts as slipped.
if (!exists("LONG_INTERVAL_DAYS")) LONG_INTERVAL_DAYS <- if (length(.args)>=3) .args[3] else 430
cat("neonatal window:", NEONATAL_DAYS, "days - a death inside it is a calving/dam loss\n")
cat("min final       :", MIN_FINAL, "settled seasons before a cow is ranked\n")
cat("long interval   :", LONG_INTERVAL_DAYS, "days - a season at or over this is a slipped season\n")
cat("scored          : every cow with enough history; filtering to active cows is the report's job\n\n")

A <- cm_read_silver(cfg, "animals")
K <- cm_read_silver(cfg, "cows")

## ---- every calving, placed on the ladder ---------------------------------
CV <- K[K$calved & !is.na(K$calf_id), ]
m <- match(CV$calf_id, A$animal_id)
CV$calf_in_animals <- !is.na(m)
CV$c_birth <- A$birth_date[m]
CV$c_birth[is.na(CV$c_birth)] <- CV$calf_birth_date[is.na(CV$c_birth)]
CV$c_status <- A$status[m]
CV$c_exit   <- A$exit_date[m]
CV$c_reason <- A$exit_reason[m]
CV$c_reason_group <- A$exit_reason_group[m]
CV$c_sex    <- A$sex[m]
CV$c_wean   <- A$weaning_date[m]
CV$c_wean_source <- A$weaning_source[m]
CV$c_age_exit <- as.numeric(CV$c_exit - CV$c_birth)
CV$c_age_now  <- as.numeric(PULL - CV$c_birth)

## the three ways a calf transitions, and which came first
CV$transition_date <- pmin(A$sale_date[m], A$first_calving_date[m],
                           A$first_sire_use_date[m], na.rm = TRUE)
CV$transition_kind <- with(list(t = CV$transition_date), ifelse(
  !is.na(A$sale_date[m]) & t == A$sale_date[m], "sold",
  ifelse(!is.na(A$first_calving_date[m]) & t == A$first_calving_date[m], "calved",
  ifelse(!is.na(A$first_sire_use_date[m]) & t == A$first_sire_use_date[m], "used as sire",
         NA_character_))))
## a transition only counts if it actually happened before she left: a dead
## calf carrying a later transition date is a record error, not a success
CV$transitioned <- !is.na(CV$transition_date) &
  (is.na(CV$c_exit) | CV$transition_date <= CV$c_exit | CV$c_status %in% "Sold")
CV$flag_transition_after_exit <- !is.na(CV$transition_date) & !is.na(CV$c_exit) &
  CV$transition_date > CV$c_exit & !CV$c_status %in% "Sold"
CV$age_at_transition <- as.numeric(CV$transition_date - CV$c_birth)
## weaning we actually observed, not the 205-day assumption; a calf that died
## before weaning has no weaning date to find and that is the honest signal
CV$weaned <- !is.na(CV$c_wean) & (is.na(CV$c_exit) | CV$c_wean <= CV$c_exit)
CV$flag_weaning_assumed <- !is.na(CV$c_wean_source) &
                           grepl("ASSUMED|EST", CV$c_wean_source)
## an exit date before the birth date is impossible: the death is real, the age
## is not, so it is never placed in an age band
CV$flag_exit_before_birth <- !is.na(CV$c_age_exit) & CV$c_age_exit < 0
died <- CV$calf_in_animals & CV$c_status %in% "Dead"

CV$outcome <- ifelse(!CV$calf_in_animals,       "no animal record",
  ifelse(CV$transitioned, paste0("transitioned: ", CV$transition_kind),
  ifelse(died & CV$flag_exit_before_birth,      "died, age not usable",
  ifelse(died & CV$c_age_exit <= NEONATAL_DAYS, "died by day 7",
  ifelse(died & !CV$weaned,                     "died before weaning",
  ifelse(died,                                  "died after weaning, before transition",
  ifelse(CV$weaned,                             "alive, weaned, not yet transitioned",
                                                "alive, not yet weaned")))))))
CV$outcome_final <- CV$transitioned | died
CV$outcome_stage <- ifelse(!CV$calf_in_animals, "unknowable",
                    ifelse(CV$outcome_final, "final", "preliminary"))
CV$delivered <- CV$transitioned
CV$loss_type <- ifelse(!died | CV$transitioned, NA_character_,
                ifelse(CV$flag_exit_before_birth, "age not usable",
                ifelse(CV$c_age_exit <= NEONATAL_DAYS, "at birth",
                ifelse(!CV$weaned, "before weaning", "after weaning"))))
CV$neonatal_days <- NEONATAL_DAYS

cm_write_silver(CV[, c("animal_id","season_index","parity","season_start","calf_id",
  "neonatal_days","calf_birth_date","c_birth","c_sex","c_status","c_exit","c_age_exit",
  "c_age_now","c_wean","c_wean_source","weaned","c_reason","c_reason_group",
  "transitioned","transition_kind","transition_date","age_at_transition",
  "outcome","outcome_stage","outcome_final","delivered","loss_type",
  "calf_in_animals","flag_exit_before_birth","flag_weaning_assumed","flag_transition_after_exit")], cfg, "calf_fates")

excl_add("calf_fates.parquet", "calving whose calf has no animal record",
         sum(!CV$calf_in_animals), n_animals = sum(!CV$calf_in_animals),
         detail = "calf_id present on the calving but no row in animals.parquet; concentrated 2014-2019, near zero after 2021",
         recoverable = TRUE)

## ---- per-cow scorecard ---------------------------------------------------
RR <- K[K$rate_ready, ]
excl_add("cow_scorecard.parquet", "cow-season not rate_ready",
         nrow(K) - nrow(RR),
         detail = "sits in the ragged start of the CattleMax record, where a missing calving means a missing record rather than an open cow",
         recoverable = FALSE)

key <- paste(CV$animal_id, CV$season_index)
i <- match(paste(RR$animal_id, RR$season_index), key)
RR$outcome   <- CV$outcome[i]
RR$loss_type <- CV$loss_type[i]
RR$stage     <- CV$outcome_stage[i]
RR$outcome[is.na(RR$outcome)] <- "left open, no calf"
RR$stage[is.na(RR$stage)]     <- "final"     # not calving IS a settled answer
RR$delivered <- RR$outcome %in% c("transitioned: sold","transitioned: calved",
                                  "transitioned: used as sire")
RR$final <- RR$stage == "final"

s <- split(seq_len(nrow(RR)), RR$animal_id)
S <- do.call(rbind, lapply(names(s), function(id) {
  g <- RR[s[[id]], ]
  data.frame(animal_id = id,
    seasons     = nrow(g),                   calvings = sum(g$calved),
    final       = sum(g$final),              preliminary = sum(g$stage == "preliminary"),
    unknowable  = sum(g$stage == "unknowable"),
    delivered   = sum(g$delivered),
    sold        = sum(g$outcome == "transitioned: sold"),
    into_herd   = sum(g$outcome %in% c("transitioned: calved","transitioned: used as sire")),
    ## "no calf" is TERMINAL - she was exposed and left without calving. It is
    ## never a mid-career miss, so it is named for what it is.
    left_open   = sum(g$outcome == "left open, no calf"),
    ## the observable form of "she skipped": seasons that ran long
    slipped     = sum(g$calving_interval_days >= LONG_INTERVAL_DAYS, na.rm=TRUE),
    intervals   = sum(!is.na(g$calving_interval_days)),
    med_interval= if (any(!is.na(g$calving_interval_days)))
                    round(median(g$calving_interval_days, na.rm=TRUE)) else NA_real_,
    lost_birth  = sum(g$loss_type %in% "at birth"),
    lost_preWean= sum(g$loss_type %in% "before weaning"),
    lost_postWean=sum(g$loss_type %in% "after weaning"),
    lost_unknown= sum(g$loss_type %in% "age not usable"),
    first_season= min(g$season_start), last_season = max(g$season_end),
    stringsAsFactors = FALSE)}))
S$lost <- S$lost_birth + S$lost_preWean + S$lost_postWean + S$lost_unknown

ai <- match(S$animal_id, A$animal_id)
S$ear_tag <- A$ear_tag[ai]; S$status <- A$status[ai]
S$exit_reason_group <- A$exit_reason_group[ai]
S$age_yrs <- round(as.numeric(PULL - A$birth_date[ai])/365.25, 1)
S$pct_calved    <- round(100*S$calvings/S$seasons)
## every rate is over FINAL seasons: a preliminary season has no answer yet and
## putting it in a denominator would read as a failure
S$pct_delivered <- ifelse(S$final > 0, round(100*S$delivered/S$final), NA_real_)
S$long_interval_days <- LONG_INTERVAL_DAYS
S$neonatal_days <- NEONATAL_DAYS
S$here <- S$status %in% "Active"
S$rankable <- S$final >= MIN_FINAL
## Whether she ever left open is only knowable once she has gone: an active
## cow's open season is her CURRENT one and is right-censored out. So the
## "left open" figure is reported ONLY for cows that have left, and is NA - not
## zero - for cows still here. Zero would read as "never missed" and be a lie.
S$open_record_complete <- !S$here
S$pct_left_open <- ifelse(S$open_record_complete & S$final > 0,
                          round(100*S$left_open/S$final), NA_real_)
S$pct_slipped <- ifelse(S$intervals > 0, round(100*S$slipped/S$intervals), NA_real_)
excl_add("cow_scorecard.parquet", "cow has fewer final seasons than the minimum",
         sum(S$final < MIN_FINAL), n_animals = sum(S$final < MIN_FINAL),
         detail = paste("fewer than", MIN_FINAL, "settled seasons; too little history to rank, kept in the parquet with rankable = FALSE"),
         recoverable = TRUE)
S$failure_mode <- ifelse(!S$rankable, "not enough final seasons",
  ifelse(S$pct_delivered == 100,                            "none - never missed",
  ifelse(S$lost == 0 & S$left_open > 0,                     "left open",
  ifelse(S$lost == 0,                                       "slipped seasons only",
  ifelse(S$lost_birth   >= pmax(S$lost_preWean, S$lost_postWean), "loses calves at birth",
  ifelse(S$lost_preWean >= S$lost_postWean,                 "loses calves before weaning",
                                                            "loses calves after weaning"))))))
S <- S[order(S$pct_delivered, -S$final), ]
cm_write_silver(S, cfg, "cow_scorecard")

## ---- what the numbers say ------------------------------------------------
E <- S[S$rankable, ]
cat("=== THE OUTCOME LADDER, every calving ===\n")
o <- sort(table(CV$outcome), decreasing = TRUE)
for (nm in names(o)) cat(sprintf("  %-42s %5d   %s\n", nm, o[[nm]],
  CV$outcome_stage[match(nm, CV$outcome)]))
cat(sprintf("\n  final %d | preliminary %d | unknowable %d | of %d calvings\n",
  sum(CV$outcome_final), sum(CV$outcome_stage=="preliminary"),
  sum(!CV$calf_in_animals), nrow(CV)))
cat("  dead calves that had ALREADY transitioned (not a loss):",
    sum(died & CV$transitioned), "\n")

cat("\n=== COW SCORECARD ===\n")
cat("cows with any rate_ready season:", nrow(S), " rankable (>=", MIN_FINAL, "final):", nrow(E), "\n\n")
cat(sprintf("of %d FINAL seasons on rankable cows:\n", sum(E$final)))
for (r in list(c("left open, no calf", sum(E$left_open)), c("lost at birth", sum(E$lost_birth)),
               c("lost before weaning", sum(E$lost_preWean)),
               c("lost after weaning", sum(E$lost_postWean)),
               c("lost, age not usable", sum(E$lost_unknown)),
               c("delivered - sold", sum(E$sold)),
               c("delivered - into the herd", sum(E$into_herd))))
  cat(sprintf("  %-28s %5s  %5.1f%%\n", r[1], r[2], 100*as.numeric(r[2])/sum(E$final)))
cat(sprintf("\n  DELIVERED %.1f%%   |   %d preliminary seasons carried, not counted\n",
    100*sum(E$delivered)/sum(E$final), sum(E$preliminary)))
cat("\nfailure mode:\n"); print(sort(table(E$failure_mode), decreasing=TRUE))
cat("\ncows that never missed:", sum(E$pct_delivered == 100), "\n")
cat("\n=== THE TWO CALVING SIGNALS, and who each is knowable for ===\n")
cat(sprintf("LEFT OPEN   only knowable once she has gone (an active cow's open season is\n"))
cat(sprintf("            her current one and is censored out). Complete records: %d of %d cows.\n",
    sum(E$open_record_complete), nrow(E)))
cat(sprintf("            of those, left open: %d (%.1f%%)\n",
    sum(E$left_open[E$open_record_complete]),
    100*sum(E$left_open[E$open_record_complete])/sum(E$final[E$open_record_complete])))
cat(sprintf("SLIPPED     knowable for EVERY cow, gone or not: a season of %d+ days.\n", LONG_INTERVAL_DAYS))
cat(sprintf("            %d of %d intervals slipped (%.1f%%), on %d of %d cows.\n",
    sum(E$slipped), sum(E$intervals), 100*sum(E$slipped)/sum(E$intervals),
    sum(E$slipped > 0), nrow(E)))
cat(sprintf("            still in the herd: %d slipped of %d intervals (%.1f%%)\n",
    sum(E$slipped[E$here]), sum(E$intervals[E$here]),
    100*sum(E$slipped[E$here])/sum(E$intervals[E$here])))
cat("\nrankable cows still in the herd:", sum(E$here), " gone:", sum(!E$here), "\n")

excl_write(cfg$silver)
