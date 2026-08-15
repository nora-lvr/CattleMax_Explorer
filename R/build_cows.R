## ---------------------------------------------------------------
## cow_lactations.parquet : one row per COW-SEASON.
## A season ENDS each time a calf is born; the next season starts there.
## Season 1 starts when she enters the breeding herd (first service, else entry).
## The final season is left OPEN (still running) or closed by her exit.
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
rd     <- function(f) cm_read(cfg, f)
SILVER <- cfg$silver
PULL   <- cfg$pull_date
GEST   <- cfg$gestation_days

M   <- cm_read_silver(cfg, "animals")
aAll<- rd("animals.csv"); br <- rd("breedings.csv"); pc <- rd("pregnancy_checks.csv")
br$bdate <- d10(br$breeding_date); br <- br[!is.na(br$bdate), ]
pc$cdate <- d10(pc$check_date)

## ---- RECORD HORIZON -------------------------------------------------
## CattleMax recording started only a few years ago; births before that were
## back-filled as pedigree. Anything starting before the horizon has an
## incomplete history and must be flagged, never silently averaged in.
mv <- rd("movements.csv"); ms <- rd("measurements.csv"); tx <- rd("treatments.csv")
horiz <- c(breeding    = min(br$bdate, na.rm=TRUE),
           movement    = min(d10(mv$movement_date), na.rm=TRUE),
           measurement = min(d10(ms$measure_date),  na.rm=TRUE),
           treatment   = min(d10(tx$treatment_date),na.rm=TRUE))
cat("=== earliest operational record per table ===\n")
print(as.Date(horiz, origin="1970-01-01"))
## the horizon is where the OPERATIONAL record starts: first breeding recorded
HORIZON <- as.Date(min(horiz[c("breeding","movement")]), origin="1970-01-01")
cat("RECORD HORIZON used:", format(HORIZON), "\n\n")

## ---- every calving event: who actually CARRIED the calf ----------------
## VERIFIED against the Oct-2024 recipient purchase block:
##   dam_animal_id      = the female who CARRIED and calved  <- use this
##   real_dam_animal_id = the registry/genetic dam; for ET calves it equals
##                        genetic_dam_animal_id in 453 of 458 cases (the DONOR)
## Using real_dam credits the donor with her recipients' calvings and makes a
## recipient herd look barren, so it must NOT be used as the calving dam.
## The real_dam FALLBACK has been REMOVED. It fired on 28 calf records and
## every one of them had real_dam == genetic_dam, i.e. it credited a DONOR
## with a calving - precisely the trap this comment block exists to prevent.
## A calf with no dam_animal_id has no known carrier and must be dropped from
## the cow-season table rather than attributed to the wrong female.
## APPROVED BY NORA 2026-08-14: attribute ET calves to the RECIPIENT.
## Three routes, in order:
##   1. breeding_id -> breedings.animal_id = the female actually SERVED. This
##      is the recipient for an ET, and it is the only route that can correct
##      a dam field pointing at the donor (73 ET calves disagree with it).
##   2. dam_animal_id, UNLESS it equals genetic_dam - that means the dam field
##      is naming the donor, not the carrier (104 ET calves).
##   3. otherwise no known carrier: DROP and flag. Never credit a donor.
realdam <- aAll$real_dam_animal_id
gdam    <- aAll$genetic_dam_animal_id
recip   <- br$animal_id[match(aAll$breeding_id, br$id)]
dam_is_donor <- !is.na(aAll$dam_animal_id) & !is.na(gdam) & aAll$dam_animal_id == gdam

dam_use <- rep(NA_character_, nrow(aAll)); dam_src <- rep(NA_character_, nrow(aAll))
i <- !is.na(recip);                      dam_use[i] <- recip[i];                 dam_src[i] <- "breeding_id(recipient)"
i <- is.na(dam_use) & !is.na(aAll$dam_animal_id) & !dam_is_donor
dam_use[i] <- aAll$dam_animal_id[i];     dam_src[i] <- "dam_animal_id(carrier)"

nonref_calf <- !(aAll$status %in% "Reference") & !is.na(d10(aAll$birth_date))
cat("=== calf -> carrier attribution ===\n")
print(table(dam_src[nonref_calf], useNA="ifany"))
cat("ET calves re-attributed away from the dam field:",
    sum(!is.na(recip) & !is.na(aAll$dam_animal_id) & recip != aAll$dam_animal_id), "\n\n")

source(file.path(cfg$root,"R","exclusions.R")); excl_reset()
excl_add("cow_lactations.parquet", "calf: dam field names the ET donor, no recipient recoverable",
         sum(nonref_calf & is.na(dam_use) & dam_is_donor),
         detail="dam_animal_id == genetic_dam_animal_id; crediting it would credit the donor",
         recoverable=TRUE)
excl_add("cow_lactations.parquet", "calf: no dam link of any kind",
         sum(nonref_calf & is.na(dam_use) & !dam_is_donor),
         detail="no dam_animal_id and no breeding_id; carrier unknown", recoverable=FALSE)
calves <- data.frame(calf_id = aAll$id,
                     dam     = dam_use,
                     dam_source = dam_src,
                     genetic_dam = gdam,
                     cbd     = d10(aAll$birth_date),
                     csex    = aAll$sex,
                     cstatus = aAll$status,
                     cmethod = aAll$conception_method,
                     stringsAsFactors = FALSE)
calves <- calves[!is.na(calves$dam) & !is.na(calves$cbd), ]
calves <- calves[order(calves$dam, calves$cbd), ]
cat("calving events by dam source:\n"); print(table(calves$dam_source))

## ---- collapse same-birth clusters (twins / multiples) into ONE calving ----
## Two defects fixed here, both found in review 2026-08-14:
##  (a) the cluster window must be measured from the FIRST calf of the cluster,
##      not the previous calf. cumsum(diff(d) > W) chains, so calves 5 days
##      apart in a run merged into one 34-day "event" of up to 19 calves.
##  (b) the collapsed EVENT DATE has to be written back onto each calf row.
##      Previously only n_born was merged back, so the season loop still saw
##      the original per-calf dates: a 3-calf cluster on 3 consecutive days
##      emitted 3 seasons EACH claiming 3 calves. Calf counts ran ~36% high
##      (4,420 real records reported as 6,453) and produced 1-day intervals.
TWIN_WINDOW_DAYS <- cfg$twin_window_days   # NOT YET VALIDATED - PLAN.md 8
calves$grp <- NA_integer_
for (ix in split(seq_len(nrow(calves)), calves$dam)) {
  d <- calves$cbd[ix]; g <- integer(length(d)); k <- 1L; anchor <- d[1]
  for (i in seq_along(d)) {
    if (as.numeric(d[i] - anchor) > TWIN_WINDOW_DAYS) { k <- k + 1L; anchor <- d[i] }
    g[i] <- k
  }
  calves$grp[ix] <- g
}
cl <- aggregate(cbd ~ dam + grp, calves, min); names(cl)[3] <- "event_date"
nb <- aggregate(calf_id ~ dam + grp, calves, length); names(nb)[3] <- "n_born"
cl <- merge(cl, nb, by=c("dam","grp"))
cl <- cl[order(cl$dam, cl$event_date), ]
cat("\ncalving EVENTS after collapsing multiples:", nrow(cl),
    " (from", nrow(calves), "calf records)\n")
cat("events with >1 calf (twins/multiples):", sum(cl$n_born>1),
    " max calves in one event:", max(cl$n_born), "\n")
cat("widest cluster span (days):",
    max(tapply(as.numeric(calves$cbd), paste(calves$dam,calves$grp),
               function(v) max(v)-min(v))), "\n\n")
## event_date now travels with every calf row, so the season loop groups on it
calves <- merge(calves, cl[,c("dam","grp","event_date","n_born")],
                by=c("dam","grp"), all.x=TRUE)

## ---- which females get seasons: ever calved OR ever exposed ----
ever_calved  <- unique(calves$dam)
ever_exposed <- unique(br$animal_id)
fem <- M[M$sex %in% "Heifer" & (M$animal_id %in% ever_calved | M$animal_id %in% ever_exposed), ]
cat("females with at least one calving or exposure:", nrow(fem), "\n")

svc_by <- split(br, br$animal_id)
cal_by <- split(calves, calves$dam)
pc_by  <- split(pc, pc$animal_id)

## NB: start empty. This was pre-allocated to nrow(fem) and then appended to,
## leaving 1,993 leading NULLs that only survived because do.call(rbind, ...)
## silently drops them - it would break under rbindlist/bind_rows.
rows <- list(); n_zero_len <- 0L
for (k in seq_len(nrow(fem))) {
  f  <- fem[k, ]; aid <- f$animal_id
  cs <- cal_by[[aid]]; sv <- svc_by[[aid]]; pk <- pc_by[[aid]]
  ## one entry per calving EVENT. Group on event_date (the cluster's first
  ## calf), never on the raw per-calf date, or multiples re-expand into
  ## separate seasons.
  ev <- if (!is.null(cs)) unique(cs[order(cs$event_date), c("grp","event_date","n_born")]) else NULL
  cdates <- if (!is.null(ev)) ev$event_date else as.Date(character(0))

  ## season 1 start: entry into the breeding herd
  s1 <- if (!is.null(sv) && nrow(sv)) min(sv$bdate, na.rm=TRUE) else f$entry_date
  s1rule <- if (!is.null(sv) && nrow(sv)) "first_service" else "entry_date"
  ## if she calved before any recorded service, back up to conception
  if (length(cdates) && !is.na(s1) && cdates[1] < s1) { s1 <- cdates[1]-GEST; s1rule <- paste0("first_calving-",GEST,"d") }

  starts <- c(s1, cdates)
  ends   <- c(cdates, NA)                      # last season left open
  nsz    <- length(starts)
  for (i in seq_len(nsz)) {
    st <- starts[i]; en <- ends[i]
    calved <- !is.na(en)
    ## an open season is closed by her exit, or censored at the pull date
    if (!calved) {
      if (!is.na(f$exit_date)) { en <- f$exit_date; outcome <- "Exited without calving" }
      else                     { en <- PULL;        outcome <- "Open at pull date" }
    } else outcome <- "Calved"
    ## a zero-length season carries no information and produced 24 junk rows
    ## (2 of them flagged as calvings); drop them rather than emit them
    if (is.na(st) || is.na(en) || en <= st) {
      if (!is.na(st) && !is.na(en) && en <= st) n_zero_len <- n_zero_len + 1L
      next
    }

    ## Half-open window [start, end): a service recorded ON a calving date
    ## belongs to the NEXT season, not to both. Closed-both-ends previously
    ## double-counted 17 services.  The final open season keeps its end
    ## inclusive so nothing falls off the end of the timeline.
    lastseason <- (i == nsz)
    s <- if (!is.null(sv) && nrow(sv)) {
           sv[sv$bdate >= st & (if (lastseason) sv$bdate <= en else sv$bdate < en),
              , drop=FALSE]
         } else br[0, , drop=FALSE]
    npc   <- if (!is.null(pk)) sum(pk$cdate >= st & pk$cdate <= en, na.rm=TRUE) else 0L
    calf  <- if (calved) cs[cs$event_date == en, ][1, ] else NULL

    rows[[length(rows)+1]] <- data.frame(
      animal_id   = aid,
      ear_tag     = f$ear_tag,
      parity      = i - 1L,                      # 0 = pre-first-calving season
      season_index= i,
      season_start= st,
      season_end  = en,
      start_rule  = if (i==1) s1rule else "previous_calving",
      outcome     = outcome,
      calved      = calved,
      season_days = as.numeric(en - st),
      calving_interval_days = if (i > 1 && calved) as.numeric(en - st) else NA_real_,
      age_at_start_days = if (!is.na(f$birth_date)) as.numeric(st - f$birth_date) else NA_real_,
      exposed     = nrow(s) > 0,
      n_services  = nrow(s),
      first_service = if (nrow(s)) min(s$bdate) else as.Date(NA),
      last_service  = if (nrow(s)) max(s$bdate) else as.Date(NA),
      methods     = if (nrow(s)) paste(sort(unique(s$breeding_method)), collapse="/") else NA_character_,
      any_et      = if (nrow(s)) any(!is.na(s$embryo_id)) else FALSE,
      days_to_first_service = if (nrow(s)) as.numeric(min(s$bdate) - st) else NA_real_,
      n_preg_checks = npc,
      calf_id     = if (calved && !is.null(calf)) calf$calf_id else NA_character_,
      calf_birth_date = if (calved) en else as.Date(NA),
      calf_sex    = if (calved && !is.null(calf)) calf$csex else NA_character_,
      n_calves_born = if (calved && !is.null(calf)) as.integer(calf$n_born) else NA_integer_,
      dam_link_source = if (calved && !is.null(calf)) calf$dam_source else NA_character_,
      conception_method = if (calved && !is.null(calf)) calf$cmethod else NA_character_,
      gestation_days = if (calved && nrow(s)) as.numeric(en - max(s$bdate)) else NA_real_,
      dam_status  = f$status,
      ## why she left, carried down so a lost season can say what went wrong
      exit_date   = f$exit_date,
      exit_reason = f$exit_reason,
      exit_reason_group = f$exit_reason_group,
      donor       = !is.na(f$donor_start)     && f$donor_start     <= en,
      recipient   = !is.na(f$recipient_start) && f$recipient_start <= en,
      censored    = outcome == "Open at pull date",
      stringsAsFactors = FALSE)
  }
}
CS <- do.call(rbind, rows)
CS <- CS[order(CS$animal_id, CS$season_index), ]
CS$flag_no_service_record <- CS$exposed == FALSE
CS$flag_long_interval     <- !is.na(CS$calving_interval_days) & CS$calving_interval_days > 450
CS$flag_short_interval    <- !is.na(CS$calving_interval_days) & CS$calving_interval_days < 300

## ---- CENSORING / RAGGED-START FLAGS ------------------------------------
## CattleMax recording began at HORIZON. A season that opens before it may be
## missing prior calvings and services entirely: it is LEFT-censored and must
## be excluded from interval and rate averages unless deliberately included.
CS$record_horizon      <- HORIZON
CS$flag_left_censored  <- CS$season_start < HORIZON
CS$flag_spans_horizon  <- CS$season_start < HORIZON & CS$season_end >= HORIZON
CS$flag_right_censored <- CS$censored
## first season opening before the horizon: her earlier calvings may be unrecorded,
## so "parity" is a floor, not a true parity
CS$flag_parity_unknown <- CS$season_index == 1 & CS$season_start < HORIZON
CS$flag_no_dam_birthdate <- is.na(CS$age_at_start_days)
CS$flag_multiple_birth <- !is.na(CS$n_calves_born) & CS$n_calves_born > 1
## >3 calves in one "event" is not a birth - it is an ET donor credited with her
## flush, or a block of placeholder birth dates. Never a real calving.
CS$flag_implausible_multiple <- !is.na(CS$n_calves_born) & CS$n_calves_born > 3
CS$age_at_calving_yrs <- (CS$age_at_start_days + CS$season_days)/365.25
CS$flag_impossible_age <- CS$calved & !is.na(CS$age_at_calving_yrs) & CS$age_at_calving_yrs < 1.5
## a season is ANALYSIS-READY only if it is closed by a calving and fully inside the record
## ---- TWO READINESS GATES, each meaning exactly one thing ----------------
## These replace the single `analysis_ready`, which required calved == TRUE and
## was therefore useless for any rate: filtering on it deleted every failure
## before the rate was computed, so calved/analysis_ready was 100% by
## construction while the honest rate was 77.5%.
##
## A readiness gate is NOT a denominator. It decides whether a season is
## trustworthy enough to use at all. Having passed the gate you still choose
## the denominator: EXPOSED (every female served) or RETAINED (still present at
## her due date). The two axes compose; see PLAN.md 6.
##
## interval_ready - she calved, is fully inside the record, and the interval is
##   biologically plausible. USE FOR: calving interval, age at first calving,
##   gestation. Includes calved by necessity: no calving, no interval.
CS$interval_ready <- CS$calved & !CS$flag_left_censored & !CS$flag_right_censored &
                     !CS$flag_implausible_multiple & !CS$flag_impossible_age &
                     !CS$flag_short_interval & !CS$flag_long_interval
## rate_ready - she was exposed and her season is fully inside the record.
##   Says NOTHING about whether she calved, so failures stay in the
##   denominator. USE FOR: % calved, calves per exposed, conception rate.
CS$rate_ready <- !is.na(CS$first_service) & !CS$flag_left_censored &
                 !CS$flag_right_censored & !CS$flag_implausible_multiple
## kept only so older code fails loudly rather than silently returning 100%
CS$analysis_ready <- NULL

## ---- EXPOSED vs RETAINED ------------------------------------------------
## She was exposed, but did she stay long enough to be able to calve?
## due = first service + one gestation. If she left before that without a calf
## she is LOST: she belongs in the exposed denominator (the herd paid for her)
## but not in the retained one (she never had the chance to calve).
CS$due_date <- CS$first_service + GEST
CS$lost_before_calving <- !CS$calved & !is.na(CS$exit_date) & !is.na(CS$due_date) &
                          CS$exit_date < CS$due_date
CS$retained_to_due <- !CS$lost_before_calving

## ---- BREEDING SEASON and CALF CROP ---------------------------------------
## Derived once, here, so every consumer groups on the same stored label
## rather than re-deriving it. A season joins a cohort by when she was first
## served; the crop is named for when those calves DROP (breeding year + 1),
## which is how the industry names a calf crop.
## Windows set from the CALVING distribution, not assumed (Nora's rule:
## roll a month into the block it is contiguous with; split it out only if
## the calving pattern is genuinely separated).
## The calving year has exactly two contiguous blocks:
##     Spring calving  1 Jan - 22 Apr   (1,136 calvings)
##     Fall calving    30 Jul - 25 Nov  (1,501 calvings)
## with real gaps late Apr - late Jul and late Nov - Dec.
## March-bred females calve 9 Jan (median) - inside the Spring block and
## contiguous with April-bred (7 Feb), so MARCH IS SPRING, not a third season.
## The single February season calves 24 Oct, inside the Fall block.
## Aug/Sep/Oct remain unmapped (3 seasons) and are SURFACED, never dropped.
bm <- as.integer(format(CS$first_service,"%m"))
by <- as.integer(format(CS$first_service,"%Y"))
CS$breeding_type <- ifelse(is.na(bm), NA,
                    ifelse(bm>=11 | bm<=2, "Fall",
                    ifelse(bm>=3  & bm<=7, "Spring", NA)))
## a Fall season running Nov..Feb is labelled by the year it STARTED
byear <- ifelse(!is.na(CS$breeding_type) & CS$breeding_type=="Fall" & bm<=2, by-1L, by)
CS$breeding_season <- ifelse(is.na(CS$breeding_type), NA, paste0(byear, " ", CS$breeding_type))
CS$crop_type <- CS$breeding_type
CS$crop_year <- ifelse(is.na(CS$breeding_type), NA_integer_, byear + 1L)
CS$calf_crop <- ifelse(is.na(CS$breeding_type), NA, paste0(CS$crop_type, " ", CS$crop_year))

## ---- record everything that did not make it into this table ----
fem_all <- M[M$sex %in% "Heifer", ]
excl_add("cow_lactations.parquet", "female: never calved and never exposed",
         nrow(fem_all) - nrow(fem),
         n_animals = nrow(fem_all) - nrow(fem),
         detail="no calving event and no breeding record, so she has no season",
         recoverable=TRUE)
excl_add("cow_lactations.parquet", "animal: not sex == Heifer",
         sum(!(M$sex %in% "Heifer")), n_animals = sum(!(M$sex %in% "Heifer")),
         detail="bulls, steers and 24 animals with no sex; there is no bull-side table yet",
         recoverable=TRUE)
excl_add("cow_lactations.parquet", "season: zero length (start == end)", n_zero_len,
         detail="carries no information; 2 of them were flagged as calvings", recoverable=FALSE)
excl_write(cfg$silver)

cm_write_silver(CS, cfg, "cow_lactations")
cat(" cows:", length(unique(CS$animal_id)), "\n\n")

cat("=== outcome ===\n");       print(table(CS$outcome))
cat("\n=== parity (0 = season before her first calf) ===\n"); print(table(pmin(CS$parity,8)))
cat("\n=== exposed within the season ===\n"); print(table(CS$exposed))
cat("\n=== calving interval, ALL vs INTERVAL-READY (days) ===\n")
cat("all intervals       (n=", sum(!is.na(CS$calving_interval_days)), "):\n", sep="")
print(round(summary(CS$calving_interval_days[!is.na(CS$calving_interval_days)])))
ar <- CS$calving_interval_days[CS$interval_ready & !is.na(CS$calving_interval_days)]
cat("interval_ready only (n=", length(ar), "):\n", sep="")
print(round(summary(ar)))

cat("\n=== the two readiness gates ===\n")
cat("interval_ready :", sum(CS$interval_ready), " (calved, in-record, plausible interval)\n")
cat("rate_ready     :", sum(CS$rate_ready), " (exposed, in-record; says nothing about calving)\n")
cat("  of rate_ready, calved:", sum(CS$rate_ready & CS$calved),
    sprintf(" = %.1f%%  <-- a real rate that can move\n", 100*mean(CS$calved[CS$rate_ready])))
cat("  (the old analysis_ready would have reported 100% here, by construction)\n")

cat("\n=== censoring ===\n")
print(c(left_censored=sum(CS$flag_left_censored), spans_horizon=sum(CS$flag_spans_horizon),
        right_censored=sum(CS$flag_right_censored), parity_unknown=sum(CS$flag_parity_unknown)))
cat("\n=== seasons per calendar year of season_end, with analysis-ready share ===\n")
yy <- format(CS$season_end,"%Y")
print(data.frame(year=names(table(yy)), seasons=as.integer(table(yy)),
                 ready=as.integer(table(factor(yy[CS$interval_ready], levels=names(table(yy))))),
                 row.names=NULL))
cat("\n=== age at first calving (years) ===\n")
f1 <- CS[CS$season_index==1 & CS$calved, ]
print(round(summary((f1$age_at_start_days + f1$season_days)/365.25),2))
cat("\n=== gestation from last service (days) ===\n")
print(round(summary(CS$gestation_days[!is.na(CS$gestation_days) & CS$gestation_days>150 & CS$gestation_days<330])))
cat("\n=== flags ===\n")
print(c(no_service_record=sum(CS$flag_no_service_record), long_interval=sum(CS$flag_long_interval),
        short_interval=sum(CS$flag_short_interval), censored=sum(CS$censored)))
