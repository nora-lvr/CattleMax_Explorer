## Payload for the emailable disease report.
options(width=210)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
C  <- cm_read_silver(cfg, "disease_cases")
PR <- cm_read_silver(cfg, "phase_risk")
A  <- cm_read_silver(cfg, "animals")
EX <- tryCatch(cm_read_silver(cfg, "exclusions"), error=function(e) NULL)

## ---- COHORT GRANULARITY --------------------------------------------------
##   season  Spring and Fall groups kept apart. Truest to how the herd is
##           managed, but halves n per point and can read as sporadic.
##   year    the two calvings pooled into one annual cohort. Roughly doubles
##           n per point and smooths the line, at the cost of blending two
##           groups that are managed separately.
##
##   Rscript R/export_disease_report.R            # season (default)
##   Rscript R/export_disease_report.R year       # pooled annual cohorts
.a <- commandArgs(trailingOnly = TRUE)
COHORT_MODE <- {
  if (exists("COHORT_MODE")) COHORT_MODE
  else if (any(.a == "year")) "year"
  else "season"
}
stopifnot(COHORT_MODE %in% c("season","year"))
if (COHORT_MODE == "year") {
  PR$cohort      <- as.character(PR$cohort_year)
  PR$cohort_sort <- PR$cohort_year
  SUFFIX <- "_annual"
  STEPBACK <- 1                      # one unit of cohort_sort = one year
} else {
  SUFFIX <- ""
  STEPBACK <- 10                     # cohort_sort is year*10 + season
}
cat("cohort granularity:", COHORT_MODE,
    if (COHORT_MODE=="year") " (Spring and Fall pooled)" else " (Spring and Fall separate)", "\n\n")

PHASES <- c("Calf","Growing","Cow","Breeding")
emit <- function(l) jobj(paste(mapply(function(k,v)
  jp(k, if (is.numeric(v) || is.logical(v)) ifelse(is.na(v),"null",tolower(as.character(v))) else jq(v)),
  names(l), l), collapse=","))

## ---- incidence per phase x disease --------------------------------------
inc <- list()
for (ph in PHASES) {
  pr <- PR[PR$phase == ph, ]; if (!nrow(pr)) next
  cs <- C[C$phase_at_onset %in% ph, ]
  med <- median(pr$days_at_risk); tot <- sum(pr$days_at_risk)
  n_all <- nrow(pr); n_done <- sum(pr$completed)
  done <- pr$animal_id[pr$completed]
  for (dz in sort(unique(cs$disease))) {
    k <- cs[cs$disease == dz, ]
    aff <- length(unique(k$animal_id))
    inc[[length(inc)+1]] <- emit(list(
      phase=ph, disease=dz,
      attack=round(100*aff/n_all,1), affected=aff, inPhase=n_all,
      attackDone=if (n_done>=100) round(100*length(unique(k$animal_id[k$animal_id %in% done]))/n_done,1) else NA_real_,
      completed=n_done,
      cases=nrow(k), fatal=sum(k$case_fatal),
      cfr=round(100*mean(k$case_fatal),1),
      relapsed=sum(k$outcome=="Relapsed"),
      ## timing uses day_of_phase_clean: NA for animals bought after the
      ## anchoring event, whose clock runs from purchase and is not comparable
      medDay=round(median(k$day_of_phase_clean, na.rm=TRUE)),
      q1Day=round(quantile(k$day_of_phase_clean,.25,na.rm=TRUE)),
      q3Day=round(quantile(k$day_of_phase_clean,.75,na.rm=TRUE)),
      timedCases=sum(!is.na(k$day_of_phase_clean)),
      per100=round(100*nrow(k)*med/tot,2),
      medianDays=round(med)))
  }
}

## ---- phase summary -------------------------------------------------------
phs <- lapply(PHASES, function(ph){
  pr <- PR[PR$phase==ph,]; if(!nrow(pr)) return(NULL)
  cs <- C[C$phase_at_onset %in% ph,]
  emit(list(phase=ph, animals=nrow(pr), completed=sum(pr$completed),
            censored=sum(!pr$completed),
            medianDays=round(median(pr$days_at_risk)),
            animalDays=sum(pr$days_at_risk),
            clock=pr$phase_clock[1],
            clockTrue=sum(pr$clock_true), clockOnPurchase=sum(!pr$clock_true),
            timedCases=sum(!is.na(cs$day_of_phase_clean)),
            cases=nrow(cs), affected=length(unique(cs$animal_id)),
            anyDisease=round(100*length(unique(cs$animal_id))/nrow(pr),1),
            fatal=sum(cs$case_fatal)))
})
phs <- Filter(Negate(is.null), phs)

## ---- onset histogram: cases by day-of-phase, per phase -------------------
BIN <- 14
hist <- list()
for (ph in PHASES) {
  ## only true-anchor cases: a purchased animal's day 40 is 40 days after we
  ## bought her, not 40 days after birth/weaning, so it cannot share this axis
  cs <- C[C$phase_at_onset %in% ph & !is.na(C$day_of_phase_clean), ]
  if (!nrow(cs)) next
  top <- names(head(sort(table(cs$disease), decreasing=TRUE), 5))
  hi  <- min(max(cs$day_of_phase_clean, na.rm=TRUE), 730)
  brk <- seq(0, hi + BIN, by = BIN)
  for (dz in top) {
    v <- cs$day_of_phase_clean[cs$disease == dz]; v <- v[v <= hi]
    if (!length(v)) next
    cnt <- as.integer(table(cut(v, brk, right=FALSE)))
    hist[[length(hist)+1]] <- jobj(jp("phase",jq(ph)), jp("disease",jq(dz)),
      jp("bin",BIN), jp("counts", jarr(cnt)))
  }
}

## ---- outcomes ------------------------------------------------------------
out <- lapply(names(sort(table(C$outcome), decreasing=TRUE)), function(o)
  emit(list(outcome=o, n=sum(C$outcome==o), pct=round(100*mean(C$outcome==o),1))))

## ---- overall disease table ----------------------------------------------
dis <- lapply(names(sort(table(C$disease), decreasing=TRUE)), function(dz){
  s <- C[C$disease==dz,]
  emit(list(disease=dz, cases=nrow(s), animals=length(unique(s$animal_id)),
            fatal=sum(s$case_fatal), cfr=round(100*mean(s$case_fatal),1),
            relapsed=sum(s$outcome=="Relapsed"),
            medianTx=median(s$n_treatments)))
})

## ---- TREND: attack rate by entry cohort ---------------------------------
## Cohorts that entered a phase together, oldest first. A cohort still in the
## phase is marked open: its attack rate is a floor and will rise.
CS_ph <- split(C, C$phase_at_onset)
trend <- list(); current <- list()
for (ph in PHASES) {
  pr <- PR[PR$phase == ph, ]; if (!nrow(pr)) next
  cs <- CS_ph[[ph]]; if (is.null(cs)) cs <- C[0, ]
  ## trended reports start at cfg$report_from_year; earlier cohorts sit in the
  ## ragged start of the record and are excluded here, and named below
  ords <- sort(unique(pr$cohort_sort[pr$cohort_year >= cfg$report_from_year]))
  ## the top diseases for this phase, so a trend line means something
  top <- names(head(sort(table(cs$disease), decreasing = TRUE), 5))
  for (o in ords) {
    grp <- pr[pr$cohort_sort == o, ]
    if (nrow(grp) < 15) next                     # too thin to trend, named below
    ids <- grp$animal_id
    k   <- cs[cs$animal_id %in% ids, ]
    ## STILL IN FLIGHT is not the same as "did not complete the phase". A
    ## grower that was SOLD never completes Growing, but her figure is final -
    ## she can never be treated again. Only an animal still in the phase at the
    ## pull date can still add cases, so that is what makes a point provisional.
    ## Using !completed made 60-80% of every historic Growing cohort look open.
    open  <- sum(!grp$completed)
    still <- sum(grp$ended_by == "still in phase at pull")
    trend[[length(trend)+1]] <- emit(list(
      phase = ph, cohort = grp$cohort[1], sort = o,
      animals = nrow(grp), openInPhase = open,
      stillIn = still, pctStillIn = round(100*still/nrow(grp), 0),
      leftMidPhase = sum(grp$ended_by == "left the herd"),
      pctOpen = round(100*open/nrow(grp), 0),
      medianDays = round(median(grp$days_at_risk)),
      anyDisease = round(100*length(unique(k$animal_id))/nrow(grp), 1),
      cases = nrow(k), fatal = sum(k$case_fatal),
      cfr = if (nrow(k)) round(100*mean(k$case_fatal), 1) else 0))
    for (dz in top) {
      kk <- k[k$disease == dz, ]
      trend[[length(trend)+1]] <- emit(list(
        phase = ph, cohort = grp$cohort[1], sort = o, disease = dz,
        animals = nrow(grp), openInPhase = open, stillIn = still,
        attack = round(100*length(unique(kk$animal_id))/nrow(grp), 1),
        cases = nrow(kk), fatal = sum(kk$case_fatal),
        medDay = if (nrow(kk)) round(median(kk$day_of_phase_clean, na.rm=TRUE)) else NA_real_))
    }
  }
  ## the MOST RECENT cohort with a usable number of animals
  ok <- ords[vapply(ords, function(o) sum(pr$cohort_sort == o) >= 15, logical(1))]
  if (length(ok)) {
    o <- max(ok); grp <- pr[pr$cohort_sort == o, ]; ids <- grp$animal_id
    k <- cs[cs$animal_id %in% ids, ]
    dz <- if (nrow(k)) sort(table(k$disease), decreasing = TRUE) else integer(0)
    current[[length(current)+1]] <- emit(list(
      phase = ph, cohort = grp$cohort[1],
      animals = nrow(grp), openInPhase = sum(!grp$completed),
      medianDays = round(median(grp$days_at_risk)),
      anyDisease = round(100*length(unique(k$animal_id))/nrow(grp), 1),
      cases = nrow(k), fatal = sum(k$case_fatal),
      topDisease = if (length(dz)) names(dz)[1] else "none recorded",
      topAttack = if (length(dz)) round(100*length(unique(k$animal_id[k$disease==names(dz)[1]]))/nrow(grp),1) else 0,
      topMedDay = if (length(dz)) round(median(k$day_of_phase_clean[k$disease==names(dz)[1]], na.rm=TRUE)) else NA_real_))
  }
}

## ---- WHAT EACH CATEGORY IS MADE OF --------------------------------------
## The grouped names are ours, not CattleMax's. Show the raw diagnoses behind
## every category so a reader can see exactly what was rolled together, and
## challenge it.
TXa <- cm_read_silver(cfg, "treatments")
th2 <- TXa[TXa$treatment_intent %in% "Therapeutic", ]
th2$cat <- ifelse(is.na(th2$disease_category), "Unknown disease", th2$disease_category)
th2$raw <- ifelse(is.na(th2$diagnosis), "(no diagnosis recorded)", th2$diagnosis)
## Use over time per raw diagnosis, so a term the practice has stopped using
## is visible rather than being silently carried forward as if current.
th2$yr <- as.integer(format(th2$treatment_date, "%Y"))
YRS <- seq(min(th2$yr, na.rm=TRUE), max(th2$yr, na.rm=TRUE))
comp <- list()
for (k in names(sort(table(th2$cat), decreasing = TRUE))) {
  s <- th2[th2$cat == k, ]
  tb <- sort(table(s$raw), decreasing = TRUE)
  parts <- vapply(names(tb), function(rw) {
    r <- s[s$raw == rw, ]
    cnt <- as.integer(table(factor(r$yr, levels = YRS)))
    last_yr <- max(r$yr, na.rm=TRUE)
    jobj(jp("raw", jq(rw)), jp("events", nrow(r)),
         jp("animals", length(unique(r$animal_id))),
         jp("first", jq(format(min(r$treatment_date)))),
         jp("last",  jq(format(max(r$treatment_date)))),
         jp("lastYear", last_yr),
         ## dormant = not used in the most recent full year or since
         jp("dormant", tolower(as.character(last_yr < max(YRS) - 1))),
         jp("series", jarr(cnt)))
  }, character(1))
  comp[[length(comp)+1]] <- jobj(
    jp("disease", jq(k)),
    jp("events",  nrow(s)),
    jp("nRaw",    length(tb)),
    jp("dormantRaw", sum(vapply(names(tb), function(rw)
        max(s$yr[s$raw == rw], na.rm=TRUE) < max(YRS) - 1, logical(1)))),
    jp("parts",   jarr(parts)))
}

## ---- HEADLINE KPIs, trended by year --------------------------------------
## Chosen with Nora: the two diseases that kill (BRD, enteric) reported as
## case fatality, and the two that dominate volume (BRD, pinkeye) reported as
## incidence. Year of case onset, so the trend is readable at a glance.
KY <- seq(cfg$report_from_year, as.integer(format(cfg$pull_date, "%Y")))
## denominator: distinct animals with any time at risk in that year
at_risk <- vapply(KY, function(y){
  y1 <- as.Date(paste0(y,"-01-01")); y2 <- as.Date(paste0(y,"-12-31"))
  length(unique(PR$animal_id[PR$phase_start <= y2 & PR$phase_end >= y1]))
}, numeric(1))
C$onset_year <- as.integer(format(C$start_date, "%Y"))

kpi_fatality <- function(dz){
  vapply(KY, function(y){
    k <- C[C$disease == dz & C$onset_year == y, ]
    if (!nrow(k)) return(NA_real_)
    round(100*mean(k$case_fatal), 1)}, numeric(1))
}
kpi_incidence <- function(dz){
  vapply(seq_along(KY), function(i){
    y <- KY[i]
    k <- C[C$disease == dz & C$onset_year == y, ]
    if (!at_risk[i]) return(NA_real_)
    round(100*length(unique(k$animal_id))/at_risk[i], 1)}, numeric(1))
}
kpi_n <- function(dz, fatal=FALSE){
  vapply(KY, function(y){
    k <- C[C$disease == dz & C$onset_year == y, ]
    if (fatal) sum(k$case_fatal) else nrow(k)}, numeric(1))
}
## A year built on a handful of cases is not a trend. 100% BRD fatality in
## 2021 was one case and one death. Such years are still SHOWN - nothing is
## hidden - but they are marked unreliable so the report can draw them faintly
## and, critically, never take the headline value or the direction arrow from
## them.
MIN_CASES <- 10
mkkpi <- function(label, dz, kind, unit){
  s <- if (kind == "fatality") kpi_fatality(dz) else kpi_incidence(dz)
  n <- kpi_n(dz)                                   # cases, the stability driver
  rel <- !is.na(s) & n >= MIN_CASES
  ## headline and direction come only from years that clear the threshold
  ok  <- which(rel)
  cur <- if (length(ok)) s[max(ok)] else NA_real_
  prev<- if (length(ok) > 1) s[ok[length(ok)-1]] else NA_real_
  cy  <- if (length(ok)) KY[max(ok)] else NA_integer_
  jobj(jp("label", jq(label)), jp("disease", jq(dz)), jp("kind", jq(kind)),
       jp("unit", jq(unit)),
       jp("current", ifelse(is.na(cur), "null", cur)),
       jp("previous", ifelse(is.na(prev), "null", prev)),
       jp("currentYear", ifelse(is.na(cy), "null", cy)),
       jp("partial", tolower(as.character(!is.na(cy) && cy == max(KY)))),
       jp("minCases", MIN_CASES),
       jp("thinYears", sum(!is.na(s) & n < MIN_CASES)),
       jp("series", jarr(ifelse(is.na(s), "null", s))),
       jp("reliable", jarr(tolower(as.character(rel)))),
       jp("counts", jarr(n)),
       jp("fatalCounts", jarr(kpi_n(dz, fatal = TRUE))),
       jp("denom",  jarr(at_risk)))
}
kpis <- c(
  mkkpi("BRD case fatality",      "Respiratory (BRD)", "fatality",  "%"),
  mkkpi("Enteric case fatality",  "Enteric",           "fatality",  "%"),
  mkkpi("BRD incidence",          "Respiratory (BRD)", "incidence", "%"),
  mkkpi("Pinkeye incidence",      "Ocular (pinkeye)",  "incidence", "%"))

## ---- CURRENT GROUP vs THE LAST THREE YEARS, at the same day of phase ----
## A rate on its own cannot say whether to worry. What matters is where this
## group sits at the SAME point in the phase as the groups before it, because
## the current group has not finished and its final rate is unknowable.
##
## For each phase and disease we build a cumulative incidence curve against
## day-of-phase, with the denominator at day d being animals still at risk at
## day d - so a group only part way through is never compared against a full
## phase. The comparison is made at the day the current group has actually
## reached, and nowhere beyond it.
BASE_YEARS <- 3
first_case <- C[order(C$animal_id, C$disease, C$start_date), ]
first_case <- first_case[!duplicated(paste(first_case$animal_id, first_case$disease,
                                           first_case$phase_at_onset)), ]
cum_curve <- function(ids, dz, days_at_risk, maxday, step) {
  fc <- first_case[first_case$animal_id %in% ids & first_case$disease == dz &
                   !is.na(first_case$day_of_phase_clean), ]
  grid <- seq(0, maxday, by = step)
  vapply(grid, function(d) {
    atrisk <- sum(days_at_risk >= d)
    if (!atrisk) return(NA_real_)
    round(100 * sum(fc$day_of_phase_clean <= d) / atrisk, 2)
  }, numeric(1))
}
watch <- list()
watch_excluded <- list()
for (ph in PHASES) {
  pr <- PR[PR$phase == ph, ]; if (!nrow(pr)) next
  ## A day-of-phase curve can only hold animals whose clock is on its true
  ## anchor. Dropping their CASES but keeping them in the denominator would
  ## deflate the rate, so they leave BOTH sides together - and are counted here.
  keep <- pr$clock_true & !pr$flag_pre_horizon_birth
  if (sum(!keep)) watch_excluded[[length(watch_excluded)+1]] <- emit(list(
    phase = ph, dropped = sum(!keep), of = nrow(pr),
    onPurchase = sum(!pr$clock_true),
    preHorizon = sum(pr$flag_pre_horizon_birth & pr$clock_true)))
  pr <- pr[keep, ]; if (nrow(pr) < 15) next
  cs <- C[C$phase_at_onset %in% ph & C$animal_id %in% pr$animal_id, ]; if (!nrow(cs)) next
  ords <- sort(unique(pr$cohort_sort[pr$cohort_year >= cfg$report_from_year]))
  ords <- ords[vapply(ords, function(o) sum(pr$cohort_sort == o) >= 15, logical(1))]
  if (length(ords) < 2) next
  cur_o  <- max(ords)
  base_o <- ords[ords < cur_o & ords >= cur_o - BASE_YEARS*STEPBACK]
  if (!length(base_o)) next
  curg  <- pr[pr$cohort_sort == cur_o, ]
  baseg <- pr[pr$cohort_sort %in% base_o, ]
  ## how far into the phase this group has actually got
  now <- round(median(curg$days_at_risk))
  maxday <- max(round(quantile(baseg$days_at_risk, .75)), now)
  step <- max(7, round(maxday/40))
  top <- names(head(sort(table(cs$disease[cs$animal_id %in% curg$animal_id]),
                         decreasing = TRUE), 4))
  top <- top[top != ""]
  for (dz in top) {
    cc <- cum_curve(curg$animal_id,  dz, curg$days_at_risk,  now,    step)
    bb <- cum_curve(baseg$animal_id, dz, baseg$days_at_risk, maxday, step)
    i_now <- length(cc)
    cur_at <- cc[i_now]; base_at <- bb[min(i_now, length(bb))]
    ratio <- if (!is.na(base_at) && base_at > 0) round(cur_at/base_at, 2) else NA_real_
    n_cur <- sum(first_case$animal_id %in% curg$animal_id & first_case$disease == dz)
    ## flag only when the gap is both proportionally and absolutely material,
    ## and rests on enough cases to mean something
    alarm <- !is.na(ratio) && ratio >= 1.3 && (cur_at - base_at) >= 2 && n_cur >= 10
    better<- !is.na(ratio) && ratio <= 0.7 && (base_at - cur_at) >= 2 && n_cur >= 5
    watch[[length(watch)+1]] <- jobj(
      jp("phase", jq(ph)), jp("disease", jq(dz)),
      jp("cohort", jq(curg$cohort[1])),
      jp("baseCohorts", jq(paste(sort(unique(baseg$cohort)), collapse=", "))),
      jp("nCur", nrow(curg)), jp("nBase", nrow(baseg)),
      jp("casesCur", n_cur),
      jp("now", now), jp("step", step), jp("maxday", maxday),
      jp("curAt", ifelse(is.na(cur_at),"null",cur_at)),
      jp("baseAt", ifelse(is.na(base_at),"null",base_at)),
      jp("ratio", ifelse(is.na(ratio),"null",ratio)),
      jp("alarm", tolower(as.character(alarm))),
      jp("better", tolower(as.character(better))),
      jp("cur",  jarr(ifelse(is.na(cc),"null",cc))),
      jp("base", jarr(ifelse(is.na(bb),"null",bb))))
  }
}

json <- jobj(
  jp("watch", jarr(unlist(watch))),
  jp("watchExcluded", jarr(unlist(watch_excluded))),
  jp("baseYears", BASE_YEARS),
  jp("cohortMode", jq(COHORT_MODE)),
  jp("kpis",  jarr(kpis)),
  jp("kpiYears", jarr(KY)),
  jp("composition", jarr(unlist(comp))),
  jp("compYears", jarr(YRS)),
  jp("trend",   jarr(unlist(trend))),
  jp("current", jarr(unlist(current))),
  jp("incidence", jarr(unlist(inc))),
  jp("phases",    jarr(unlist(phs))),
  jp("hist",      jarr(unlist(hist))),
  jp("outcomes",  jarr(unlist(out))),
  jp("diseases",  jarr(unlist(dis))),
  jp("totalCases", nrow(C)),
  jp("totalAnimals", length(unique(C$animal_id))),
  jp("unknownCases", sum(C$disease=="Unknown disease")),
  jp("unknownCfr", round(100*mean(C$case_fatal[C$disease=="Unknown disease"]),1)),
  jp("caseGap", C$case_gap_days[1]),
  jp("deathWindow", C$death_window_days[1]),
  jp("cfr", round(100*mean(C$case_fatal),1)),
  jp("noLocation", sum(C$flag_no_location)),
  jp("fromYear", cfg$report_from_year),
  jp("cohortsBefore", sum(PR$cohort_year < cfg$report_from_year)),
  jp("herd", jq(cfg$herd)), jp("pull", jq(cfg$pull)),
  jp("pulled", jq(format(cfg$pull_date))),
  jp("brand", jq(cfg$brand)), jp("brandDeep", jq(cfg$brand_deep)),
  jp("firstCase", jq(format(min(C$start_date)))),
  jp("lastCase",  jq(format(max(C$start_date)))))
cm_write_json(json, file.path(cfg$derived, paste0("disease_report", SUFFIX, ".json")),
              expect=list(incidence=length(inc), phases=length(phs)))
cat("incidence rows:", length(inc), " phases:", length(phs), " hist series:", length(hist), "\n")
