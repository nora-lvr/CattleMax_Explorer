## Calves per exposed female, computed from the cow-season table.
options(width=210)
SILVER <- "C:/GIT/CattleMax_Explorer/data/silver-data"
OUT <- "C:/Users/lives/AppData/Local/Temp/claude/C--GIT-CattleMax-Explorer/2076ae99-6a88-45b1-927a-6cdd341f08b4/scratchpad"
CS <- as.data.frame(arrow::read_parquet(file.path(SILVER,"cows.parquet")))
PULL <- as.Date("2026-07-29"); GEST <- 283

## Cohort labels, the due date and lost/retained are all computed once in
## build_cows.R and READ here. This script only aggregates - it must never
## re-derive a value that the silver table already stores.
E <- CS[!is.na(CS$calf_crop), ]
E$cohort <- E$breeding_season
## Name what is excluded rather than dropping it silently (PLAN.md 5.4).
exposed_all <- sum(!is.na(CS$first_service))
unmapped    <- CS[!is.na(CS$first_service) & is.na(CS$calf_crop), ]
cat("=== cohort coverage ===\n")
cat("cow-seasons total                    :", nrow(CS), "\n")
cat("  never served (no breeding record)  :", nrow(CS)-exposed_all, "\n")
cat("  served AND assigned to a calf crop :", nrow(E), "\n")
cat("  served but UNMAPPED month          :", nrow(unmapped),
    sprintf(" (%.1f%% of served)\n", 100*nrow(unmapped)/max(exposed_all,1)))
if (nrow(unmapped)) {
  cat("    their first-service months:", paste(names(table(format(unmapped$first_service,"%b"))),
      table(format(unmapped$first_service,"%b")), sep="=", collapse=", "), "\n")
  cat("    of which calved:", sum(unmapped$calved), " calves:",
      sum(unmapped$n_calves_born, na.rm=TRUE), "\n")
}
cat("\n")

## Two denominators, both reported:
##   EXPOSED  - every female served. Answers "what did the whole breeding
##              group deliver", and so carries attrition as a cost.
##   RETAINED - females still on the farm at their due date, i.e. those
##              actually able to calve. Answers "how did the ones we kept do".
## The gap between them IS the attrition, and is reported in its own right.
## lost_before_calving is computed once in build_cows.R and read straight off
## the cow-season table, so the two denominators can never drift apart.
agg <- do.call(rbind, lapply(sort(unique(E$cohort)), function(k){
  s <- E[E$cohort==k, ]
  lost <- sum(s$lost_before_calving); retained <- sum(s$retained_to_due)
  ## how much of this cohort the censoring gate would exclude, named not hidden
  n_rate_ready <- sum(s$rate_ready)
  n_censored   <- nrow(s) - n_rate_ready
  due <- min(s$first_service, na.rm=TRUE) + GEST      # first calves expected
  last_due <- max(s$first_service, na.rm=TRUE) + GEST # last calves expected
  data.frame(cohort=s$calf_crop[1],          # stored label, not re-derived
    year=s$crop_year[1], type=s$crop_type[1],
    breeding_season=k,
    bred_from=min(s$first_service, na.rm=TRUE),
    bred_to  =max(s$first_service, na.rm=TRUE),
    exposed=nrow(s),
    rate_ready=n_rate_ready, censored=n_censored,
    pct_calved_ready=ifelse(n_rate_ready>0,
        round(100*sum(s$calved[s$rate_ready])/n_rate_ready,1), NA_real_),
    lost=lost, retained=retained,
    pct_lost=round(100*lost/nrow(s),1),
    calved=sum(s$calved),
    calves=sum(ifelse(is.na(s$n_calves_born),0,s$n_calves_born)),
    cpe=round(sum(ifelse(is.na(s$n_calves_born),0,s$n_calves_born))/nrow(s),3),
    cpr=round(sum(ifelse(is.na(s$n_calves_born),0,s$n_calves_born))/max(retained,1),3),
    pct_calved=round(100*sum(s$calved)/nrow(s),1),
    pct_calved_ret=round(100*sum(s$calved)/max(retained,1),1),
    services=sum(s$n_services),
    spe=round(sum(s$n_services)/nrow(s),2),
    first_due=due, last_due=last_due,
    ## incomplete if calves from this cohort are still due after the pull date
    incomplete = last_due > PULL,
    pct_window_elapsed = round(100*pmin(1, as.numeric(PULL-due)/pmax(1,as.numeric(last_due-due))),0),
    left_censored=sum(s$flag_left_censored),
    stringsAsFactors=FALSE)
}))
## Spring calves drop before Fall calves within the same crop year, so the
## x axis must run Spring -> Fall, not alphabetically.
agg <- agg[order(agg$year, factor(agg$type, levels=c("Spring","Fall"))), ]
## compact breeding window: collapse the year when both ends share it
same <- format(agg$bred_from,"%Y") == format(agg$bred_to,"%Y")
agg$bred_window <- ifelse(same,
  paste0(format(agg$bred_from,"%b"), "-", format(agg$bred_to,"%b %y")),
  paste0(format(agg$bred_from,"%b %y"), "-", format(agg$bred_to,"%b %y")))
cat("\n=== CALVES PER FEMALE, both denominators, by CALF CROP ===\n")
print(agg[,c("cohort","bred_window","exposed","lost","pct_lost","retained",
             "calved","pct_calved","pct_calved_ret","cpe","cpr","incomplete")], row.names=FALSE)
cat("\n=== CENSORING GATE (rate_ready) - what each cohort would lose, named ===\n")
print(agg[,c("cohort","exposed","rate_ready","censored","pct_calved","pct_calved_ready")],
      row.names=FALSE)
cat("censored = season opens before the record horizon or is still open at the pull.\n")
cat("pct_calved_ready is the rate over uncensored seasons only; the gap between it\n")
cat("and pct_calved is what censoring was doing to the headline figure.\n")
cat("\nincomplete cohorts (calves still due after", format(PULL), "):",
    paste(agg$cohort[agg$incomplete], collapse=", "), "\n")

j <- function(x) paste0("[", paste(x, collapse=","), "]")
qs<- function(x) paste0('"', gsub('"','\\\\"',x), '"')
rows <- paste0('{"cohort":',qs(agg$cohort),',"year":',agg$year,',"type":',qs(agg$type),
  ',"bredWindow":',qs(agg$bred_window),',"breedingSeason":',qs(agg$breeding_season),
  ',"exposed":',agg$exposed,',"lost":',agg$lost,',"retained":',agg$retained,
  ',"pctLost":',agg$pct_lost,',"cpr":',agg$cpr,',"pctCalvedRet":',agg$pct_calved_ret,
  ',"calved":',agg$calved,',"calves":',agg$calves,
  ',"cpe":',agg$cpe,',"pctCalved":',agg$pct_calved,',"services":',agg$services,
  ',"spe":',agg$spe,',"incomplete":',tolower(as.character(agg$incomplete)),
  ',"leftCensored":',agg$left_censored,'}')
json <- paste0('{"cohorts":[',paste(rows,collapse=","),']',
  ',"pull":"2026-07-29","gestation":',GEST,
  ',"totalSeasons":',nrow(CS),',"intervalReady":',sum(CS$interval_ready),
  ',"rateReady":',sum(CS$rate_ready),
  ',"unmappedSeasons":',nrow(unmapped),',"unmappedCalved":',sum(unmapped$calved),
  ',"neverServed":',nrow(CS)-exposed_all,
  ',"horizon":"',format(CS$record_horizon[1]),'"',
  ',"medianInterval":',round(median(CS$calving_interval_days[CS$interval_ready & !is.na(CS$calving_interval_days)],na.rm=TRUE)),
  ',"flags":{',paste(sprintf('%s:%d', qs(sub("^flag_","",grep("^flag_",names(CS),value=TRUE))),
      sapply(grep("^flag_",names(CS),value=TRUE), function(f) sum(CS[[f]],na.rm=TRUE))), collapse=","),'}}')
writeLines(json, file.path(OUT,"exposure2.json"))
cat("\nwrote exposure2.json\n")
