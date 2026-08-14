## Calves per exposed female, computed from the cow-season table.
options(width=210)
SILVER <- "C:/GIT/CattleMax_Explorer/data/silver-data"
OUT <- "C:/Users/lives/AppData/Local/Temp/claude/C--GIT-CattleMax-Explorer/2076ae99-6a88-45b1-927a-6cdd341f08b4/scratchpad"
CS <- as.data.frame(arrow::read_parquet(file.path(SILVER,"cows.parquet")))
PULL <- as.Date("2026-07-29"); GEST <- 283

## a season enters a breeding-season cohort by when she was first served
E <- CS[!is.na(CS$first_service), ]
mo <- as.integer(format(E$first_service,"%m")); yr <- as.integer(format(E$first_service,"%Y"))
typ <- ifelse(mo>=11 | mo<=1, "Fall", ifelse(mo>=4 & mo<=7, "Spring", NA))
sy  <- ifelse(typ=="Fall" & mo<=1, yr-1, yr)
E$cohort <- ifelse(is.na(typ), NA, paste0(sy," ",typ))
E <- E[!is.na(E$cohort), ]
cat("cow-seasons in a breeding cohort:", nrow(E), "of", nrow(CS), "\n")

agg <- do.call(rbind, lapply(sort(unique(E$cohort)), function(k){
  s <- E[E$cohort==k, ]
  due <- min(s$first_service, na.rm=TRUE) + GEST      # first calves expected
  last_due <- max(s$first_service, na.rm=TRUE) + GEST # last calves expected
  ## Label cohorts by CALF CROP, not by breeding season: a cow bred in the
  ## Nov 2025 - Jan 2026 window calves Aug-Oct 2026, which the industry (and
  ## Nora) calls the Fall 2026 calf crop. Crop year = breeding year + 1.
  byear <- as.integer(substr(k,1,4)); btype <- sub("^\\d+ ","",k)
  data.frame(cohort=paste0(btype," ",byear+1),
    year=byear+1L, type=btype,
    breeding_season=k,
    bred_from=min(s$first_service, na.rm=TRUE),
    bred_to  =max(s$first_service, na.rm=TRUE),
    exposed=nrow(s),
    calved=sum(s$calved),
    calves=sum(ifelse(is.na(s$n_calves_born),0,s$n_calves_born)),
    cpe=round(sum(ifelse(is.na(s$n_calves_born),0,s$n_calves_born))/nrow(s),3),
    pct_calved=round(100*sum(s$calved)/nrow(s),1),
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
cat("\n=== CALVES PER EXPOSED FEMALE, labelled by CALF CROP ===\n")
print(agg[,c("cohort","bred_window","exposed","services","spe","calved","pct_calved","calves","cpe","incomplete")], row.names=FALSE)
cat("\nincomplete cohorts (calves still due after", format(PULL), "):",
    paste(agg$cohort[agg$incomplete], collapse=", "), "\n")

j <- function(x) paste0("[", paste(x, collapse=","), "]")
qs<- function(x) paste0('"', gsub('"','\\\\"',x), '"')
rows <- paste0('{"cohort":',qs(agg$cohort),',"year":',agg$year,',"type":',qs(agg$type),
  ',"bredWindow":',qs(agg$bred_window),',"breedingSeason":',qs(agg$breeding_season),
  ',"exposed":',agg$exposed,',"calved":',agg$calved,',"calves":',agg$calves,
  ',"cpe":',agg$cpe,',"pctCalved":',agg$pct_calved,',"services":',agg$services,
  ',"spe":',agg$spe,',"incomplete":',tolower(as.character(agg$incomplete)),
  ',"leftCensored":',agg$left_censored,'}')
json <- paste0('{"cohorts":[',paste(rows,collapse=","),']',
  ',"pull":"2026-07-29","gestation":',GEST,
  ',"totalSeasons":',nrow(CS),',"analysisReady":',sum(CS$analysis_ready),
  ',"horizon":"',format(CS$record_horizon[1]),'"',
  ',"medianInterval":',round(median(CS$calving_interval_days[CS$analysis_ready & !is.na(CS$calving_interval_days)],na.rm=TRUE)),
  ',"flags":{',paste(sprintf('%s:%d', qs(sub("^flag_","",grep("^flag_",names(CS),value=TRUE))),
      sapply(grep("^flag_",names(CS),value=TRUE), function(f) sum(CS[[f]],na.rm=TRUE))), collapse=","),'}}')
writeLines(json, file.path(OUT,"exposure2.json"))
cat("\nwrote exposure2.json\n")
