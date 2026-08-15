## Payload for the emailable cow scorecard report.
options(width=210)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
S  <- cm_read_silver(cfg, "cow_scorecard")
CF <- cm_read_silver(cfg, "calf_fates")
A  <- cm_read_silver(cfg, "animals")
K  <- cm_read_silver(cfg, "cows")
PULL <- cfg$pull_date

emit <- function(l) jobj(paste(mapply(function(k,v)
  jp(k, if (is.numeric(v) || is.logical(v)) ifelse(is.na(v),"null",tolower(as.character(v))) else jq(v)),
  names(l), l), collapse=","))

E <- S[S$rankable, ]
stopifnot(nrow(E) > 0)
## every cow ships; the report filters to the ones still in the herd
HERE <- E[E$here, ]

## ---- the ladder, over every calving -------------------------------------
LAD <- c("transitioned: sold","transitioned: calved","transitioned: used as sire",
         "alive, weaned, not yet transitioned","alive, not yet weaned",
         "died by day 7","died before weaning","died after weaning, before transition",
         "died, age not usable","no animal record")
ladder <- lapply(LAD, function(o) { k <- CF$outcome == o
  emit(list(outcome=o, n=sum(k),
            stage=if (!any(k)) "final" else CF$outcome_stage[which(k)[1]])) })

## ---- the scorecard, one row per scored cow ------------------------------
rows <- lapply(seq_len(nrow(E)), function(i) { r <- E[i, ]; emit(list(
  id = r$animal_id, tag = if (is.na(r$ear_tag)) "" else r$ear_tag,
  age = r$age_yrs, status = r$status,
  exitReason = if (is.na(r$exit_reason_group)) "" else r$exit_reason_group,
  seasons = r$seasons, final = r$final, prelim = r$preliminary,
  calvings = r$calvings,
  delivered = r$delivered, sold = r$sold, intoHerd = r$into_herd,
  here = r$here, openKnown = r$open_record_complete,
  leftOpen = r$left_open, pctLeftOpen = r$pct_left_open,
  slipped = r$slipped, intervals = r$intervals, medInterval = r$med_interval,
  pctSlipped = r$pct_slipped, lost = r$lost,
  lostBirth = r$lost_birth, lostPre = r$lost_preWean, lostPost = r$lost_postWean,
  pctDelivered = r$pct_delivered, mode = r$failure_mode,
  firstSeason = format(r$first_season), lastSeason = format(r$last_season))) })

## ---- per-calf detail for every scored cow that lost one -----------------
flag_ids <- E$animal_id[E$lost > 0]
det <- lapply(which(CF$animal_id %in% flag_ids), function(i) { r <- CF[i, ]; emit(list(
  dam = r$animal_id, parity = r$parity, calf = r$calf_id,
  born = format(r$calf_birth_date), sex = if (is.na(r$c_sex)) "" else r$c_sex,
  outcome = r$outcome, ageDays = r$c_age_exit,
  weaned = r$weaned,
  reason = if (is.na(r$c_reason)) "" else r$c_reason,
  lossType = if (is.na(r$loss_type)) "" else r$loss_type)) })

## ---- when calves die, and of what --------------------------------------
d <- CF[!is.na(CF$loss_type) & CF$loss_type != "age not usable", ]
LT <- c("at birth","before weaning","after weaning")
grp <- ifelse(is.na(d$c_reason_group), "Not recorded", d$c_reason_group)
GRPS <- names(sort(table(grp), decreasing=TRUE))
bands <- lapply(LT, function(b) emit(c(
  list(band = b, total = sum(d$loss_type == b),
       medDay = if (any(d$loss_type==b & !is.na(d$c_age_exit)))
                  round(median(d$c_age_exit[d$loss_type==b], na.rm=TRUE)) else NA_real_),
  setNames(as.list(vapply(GRPS, function(g) sum(d$loss_type == b & grp == g), numeric(1))),
           paste0("g", seq_along(GRPS))))))

rr <- table(ifelse(is.na(d$c_reason) | !nzchar(d$c_reason), "(blank)", d$c_reason))
reasons <- lapply(names(sort(rr, decreasing=TRUE)), function(n) emit(list(
  reason = n, n = as.integer(rr[[n]]),
  birth = sum(d$c_reason %in% n & d$loss_type == "at birth"),
  pre   = sum(d$c_reason %in% n & d$loss_type == "before weaning"),
  post  = sum(d$c_reason %in% n & d$loss_type == "after weaning"))))

modes <- lapply(names(sort(table(E$failure_mode), decreasing=TRUE)), function(n)
  emit(list(mode = n, n = sum(E$failure_mode == n))))

## ---- what fell out, named ----------------------------------------------

drop <- list(
  emit(list(what="cow-season not rate_ready", n=nrow(K)-sum(K$rate_ready),
    why="sits in the ragged start of the CattleMax record, where a missing calving means a missing record rather than an open cow")),
  emit(list(what="calving whose calf has no animal record", n=sum(!CF$calf_in_animals),
    why="a calf_id is on the calving but no animal row exists to follow; concentrated 2014-2019 and near zero after 2021")),
  emit(list(what="season still preliminary", n=sum(CF$outcome_stage=="preliminary"),
    why="the calf is alive and has not yet been sold or calved, so the season has no answer yet and is never counted as a failure")),
  emit(list(what="dead calf whose age is unusable", n=sum(CF$flag_exit_before_birth),
    why="exit date precedes the birth date; the death is counted, the age band is not")),
  emit(list(what="calf carrying a transition date after it left", n=sum(CF$flag_transition_after_exit),
    why="a sale or calving recorded after the animal's exit is a record error, not a success, and is not credited")),

  emit(list(what="cow with too little settled history", n=sum(!S$rankable & S$here & S$final < min(E$final)),
    why="fewer final seasons than the minimum; kept in the parquet, just not ranked")))

json <- jobj(
  jp("cows", jarr(unlist(rows))),
  jp("detail", jarr(unlist(det))),
  jp("ladder", jarr(unlist(ladder))),
  jp("bands", jarr(unlist(bands))),
  jp("bandGroups", jarr(vapply(GRPS, jq, character(1)))),
  jp("reasons", jarr(unlist(reasons))),
  jp("modes", jarr(unlist(modes))),
  jp("dropped", jarr(unlist(drop))),
  jp("nHere", nrow(HERE)), jp("nGone", sum(!E$here)),
  jp("leftOpen", sum(E$left_open)),
  jp("openKnownCows", sum(E$open_record_complete)),
  jp("openKnownSeasons", sum(E$final[E$open_record_complete])),
  jp("leftOpenKnown", sum(E$left_open[E$open_record_complete])),
  jp("slipped", sum(E$slipped)), jp("intervals", sum(E$intervals)),
  jp("slippedHere", sum(HERE$slipped)), jp("intervalsHere", sum(HERE$intervals)),
  jp("longInterval", E$long_interval_days[1]),
  jp("neonatalDays", CF$neonatal_days[1]),
  jp("minFinal", min(E$final)),
  jp("nScored", nrow(E)), jp("nCows", nrow(S)),
  jp("seasons", sum(E$seasons)), jp("final", sum(E$final)),
  jp("prelim", sum(E$preliminary)),
  jp("delivered", sum(E$delivered)), jp("sold", sum(E$sold)),
  jp("intoHerd", sum(E$into_herd)),
  jp("lostBirth", sum(E$lost_birth)), jp("lostPre", sum(E$lost_preWean)),
  jp("lostPost", sum(E$lost_postWean)), jp("lost", sum(E$lost)),
  jp("pctDelivered", round(100*sum(E$delivered)/sum(E$final),1)),
  jp("neverMissed", sum(E$pct_delivered == 100)),
  ## the calving hurdle is only observable on cows that have LEFT: a season in
  ## cows.parquet ends AT a calving, so a season with no calf only closes when
  ## she goes. On an active-only scorecard every cow reads 100% calved by
  ## construction, which is an artefact and must never be printed as a finding.

  jp("openSeasonsCensored", sum(!K$calved & K$flag_right_censored)),
  jp("herd", jq(cfg$herd)), jp("pull", jq(cfg$pull)),
  jp("pulled", jq(format(PULL))),
  jp("firstSeason", jq(format(min(E$first_season)))),
  jp("lastSeason",  jq(format(max(E$last_season)))))

cm_write_json(json, file.path(cfg$derived, "cow_scorecard.json"),
              expect = list(cows = length(rows), ladder = length(ladder)))
cat("scored cows:", length(rows), sprintf("(%d still here, %d gone)", nrow(HERE), sum(!E$here)),
    " calf rows:", length(det), " ladder:", length(ladder),
    " raw reasons:", length(reasons), "\n")
