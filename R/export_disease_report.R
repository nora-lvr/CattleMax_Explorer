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
      medDay=round(median(k$day_of_phase, na.rm=TRUE)),
      q1Day=round(quantile(k$day_of_phase,.25,na.rm=TRUE)),
      q3Day=round(quantile(k$day_of_phase,.75,na.rm=TRUE)),
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
            cases=nrow(cs), affected=length(unique(cs$animal_id)),
            anyDisease=round(100*length(unique(cs$animal_id))/nrow(pr),1),
            fatal=sum(cs$case_fatal)))
})
phs <- Filter(Negate(is.null), phs)

## ---- onset histogram: cases by day-of-phase, per phase -------------------
BIN <- 14
hist <- list()
for (ph in PHASES) {
  cs <- C[C$phase_at_onset %in% ph & !is.na(C$day_of_phase), ]
  if (!nrow(cs)) next
  top <- names(head(sort(table(cs$disease), decreasing=TRUE), 5))
  hi  <- min(max(cs$day_of_phase, na.rm=TRUE), 730)
  brk <- seq(0, hi + BIN, by = BIN)
  for (dz in top) {
    v <- cs$day_of_phase[cs$disease == dz]; v <- v[v <= hi]
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
    open <- sum(!grp$completed)
    trend[[length(trend)+1]] <- emit(list(
      phase = ph, cohort = grp$cohort[1], sort = o,
      animals = nrow(grp), openInPhase = open,
      pctOpen = round(100*open/nrow(grp), 0),
      medianDays = round(median(grp$days_at_risk)),
      anyDisease = round(100*length(unique(k$animal_id))/nrow(grp), 1),
      cases = nrow(k), fatal = sum(k$case_fatal),
      cfr = if (nrow(k)) round(100*mean(k$case_fatal), 1) else 0))
    for (dz in top) {
      kk <- k[k$disease == dz, ]
      trend[[length(trend)+1]] <- emit(list(
        phase = ph, cohort = grp$cohort[1], sort = o, disease = dz,
        animals = nrow(grp), openInPhase = open,
        attack = round(100*length(unique(kk$animal_id))/nrow(grp), 1),
        cases = nrow(kk), fatal = sum(kk$case_fatal),
        medDay = if (nrow(kk)) round(median(kk$day_of_phase, na.rm=TRUE)) else NA_real_))
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
      topMedDay = if (length(dz)) round(median(k$day_of_phase[k$disease==names(dz)[1]], na.rm=TRUE)) else NA_real_))
  }
}

json <- jobj(
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
cm_write_json(json, file.path(cfg$derived, "disease_report.json"),
              expect=list(incidence=length(inc), phases=length(phs)))
cat("incidence rows:", length(inc), " phases:", length(phs), " hist series:", length(hist), "\n")
