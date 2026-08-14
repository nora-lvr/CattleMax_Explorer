## ---------------------------------------------------------------
## animal_master : one row per animal, every event date that matters.
## This is the denominator substrate. Phases are derived from it.
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {                       # allow a caller to pass its own cfg
  source(file.path(cm_R <- "R", "config.R")); source(file.path(cm_R, "common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
rd   <- function(f) cm_read(cfg, f)
D8   <- function(n) as.Date(rep(NA_real_, n), origin="1970-01-01")
mn   <- function(df, idc, dtc, ids) cm_min_date(df, idc, dtc, ids)
mxd  <- function(df, idc, dtc, ids) cm_max_date(df, idc, dtc, ids)
PULL <- cfg$pull_date
SILVER <- cfg$silver

aAll<-rd("animals.csv"); st<-rd("sale_tickets.csv"); mv<-rd("movements.csv")
ms<-rd("measurements.csv"); tx<-rd("treatments.csv"); nt<-rd("animal_notes.csv")
br<-rd("breedings.csv"); em<-rd("embryos.csv"); fl<-rd("flushes.csv")
pc<-rd("pregnancy_checks.csv")

a  <- aAll[!(aAll$status %in% "Reference"), ]
id <- a$id; n <- nrow(a)
M  <- data.frame(animal_id=id, stringsAsFactors=FALSE)

## ---- identity ----
M$ear_tag <- a$ear_tag; M$name <- a$name
M$sex <- a$sex; M$animal_type <- a$animal_type; M$status <- a$status
M$category_id <- a$category_id

## ---- raw event dates ----
M$birth_date    <- d10(a$birth_date)
M$purchase_date <- d10(a$purchase_date)
M$purchased     <- a$purchased %in% "true"
M$sale_date     <- d10(a$sale_date)
M$death_date    <- d10(a$death_date)
tick            <- setNames(d10(st$sale_date), st$id)
M$sale_ticket_date <- tick[a$sale_ticket_id]

## ---- last activity across every dated child table ----
la <- suppressWarnings(pmax(
  mxd(mv,"animal_id","movement_date",id), mxd(ms,"animal_id","measure_date",id),
  mxd(tx,"animal_id","treatment_date",id), mxd(nt,"animal_id","note_date",id),
  mxd(br,"animal_id","breeding_date",id), na.rm=TRUE))
la[is.infinite(la)] <- NA
M$last_activity_date <- as.Date(la, origin="1970-01-01")
M$first_movement_date <- mn(mv,"animal_id","movement_date",id)

## ---- WEANING, by documented precedence ----
## Named constants, not buried literals, so they are configurable when this
## moves to Python. NEITHER IS VALIDATED BY NORA YET - see PLAN.md §8.
WEAN_FALLBACK_DAYS  <- cfg$wean_fallback_days
WEAN_ASSUME_AGE_MO  <- cfg$wean_assume_age_mo
mw   <- ms[grepl("^wean", ms$category, ignore.case=TRUE), ]
mwd  <- mn(mw,"animal_id","measure_date",id)
hasw <- function(x) !is.na(x)
wsrc <- rep(NA_character_,n); wdate <- D8(n)
take <- function(w,v,lab){ i<-is.na(w)&hasw(v); w[i]<-v[i]; wsrc[i]<<-lab; w }
wdate <- take(wdate, d10(a$weaning_date), "weaning_date")
wdate <- take(wdate, mwd,                 "weaning_measurement")
i <- is.na(wdate) & hasw(a$weaning_weight) & hasw(M$birth_date)
wdate[i] <- M$birth_date[i]+205; wsrc[i] <- "weaning_weight(EST 205d)"
## Age must be measured at the point the animal LEFT, not at the pull date.
## Measuring at the pull assumed 234 animals were weaned - median 34 days old
## at death - purely because they would have been over 8 months had they lived.
## exit_date is resolved further down, so recompute the raw departure here.
.left_on <- suppressWarnings(pmin(d10(a$sale_date), d10(a$death_date), na.rm=TRUE))
.left_on[!is.finite(as.numeric(.left_on))] <- NA
asof   <- as.Date(ifelse(is.na(.left_on), PULL, .left_on), origin="1970-01-01")
age_mo <- as.numeric(asof - M$birth_date)/30.44
i <- is.na(wdate) & !is.na(age_mo) & age_mo > WEAN_ASSUME_AGE_MO
wdate[i] <- M$birth_date[i]+WEAN_FALLBACK_DAYS; wsrc[i] <- "age>8mo(ASSUMED 205d)"
## never let an assumed weaning date land after the animal had already gone
i2 <- !is.na(wdate) & !is.na(.left_on) & wdate > .left_on & grepl("ASSUMED|EST", wsrc)
wdate[i2] <- NA; wsrc[i2] <- NA
wsrc[is.na(wdate)] <- "none(still nursing)"
M$weaning_date <- wdate; M$weaning_source <- wsrc

## ---- reproduction milestones ----
calf_bd <- d10(aAll$birth_date); dam <- aAll$dam_animal_id
ok <- !is.na(dam) & !is.na(calf_bd)
M$first_calving_date <- as.Date(tapply(as.integer(calf_bd[ok]), dam[ok], min)[id], origin="1970-01-01")
M$n_calves <- as.integer(table(factor(dam[ok], levels=id)))
M$first_service_date  <- mn(br,"animal_id","breeding_date",id)
M$last_service_date   <- mxd(br,"animal_id","breeding_date",id)
M$first_preg_check    <- mn(pc,"animal_id","check_date",id)
useb <- br[!is.na(br$bull_animal_id), ]
M$first_sire_use_date <- mn(useb,"bull_animal_id","breeding_date",id)

## ---- role (orthogonal to phase) ----
dstart <- suppressWarnings(pmin(mn(fl,"animal_id","flush_date",id),
                                mn(em,"animal_id","collection_date",id), na.rm=TRUE))
dstart[is.infinite(dstart)] <- NA
M$donor_start <- as.Date(dstart, origin="1970-01-01")
etb <- br[!is.na(br$embryo_id), ]
M$recipient_start <- mn(etb,"animal_id","breeding_date",id)

## ---- ENTRY ----
ent <- M$purchase_date; er <- rep("purchase_date",n)
i<-is.na(ent); ent[i]<-M$birth_date[i];         er[i]<-"birth_date"
i<-is.na(ent); ent[i]<-M$first_movement_date[i];er[i]<-"first_movement(EST)"
i<-is.na(ent); ent[i]<-d10(a$created_at)[i];    er[i]<-"created_at(EST)"
M$entry_date <- ent; M$entry_rule <- er

## ---- EXIT (documented precedence; never updated_at) ----
gone <- M$status %in% c("Sold","Dead")
ex <- D8(n); xr <- rep(NA_character_,n)
put <- function(e,v,lab){ i<-is.na(e)&!is.na(v); e[i]<-v[i]; xr[i]<<-lab; e }
ex <- put(ex, M$sale_date,        "sale_date")
ex <- put(ex, M$death_date,       "death_date")
ex <- put(ex, M$sale_ticket_date, "sale_ticket")
tmp <- M$last_activity_date; tmp[!gone] <- NA
ex <- put(ex, tmp,                "last_activity(EST)")
i <- gone & is.na(ex); ex[i] <- M$entry_date[i]; xr[i] <- "none(entry-only)"
xr[!gone] <- "open"
M$exit_date <- ex; M$exit_rule <- xr
## inactivated = left the herd with neither a sale nor a death date
M$inactivated_date <- as.Date(ifelse(gone & is.na(M$sale_date) & is.na(M$death_date) &
                                     is.na(M$sale_ticket_date), ex, NA), origin="1970-01-01")

## ---- PHASE BOUNDARIES ----
M$calf_start  <- M$entry_date
growing <- M$weaning_date
growing[!is.na(M$entry_date) & !is.na(growing) & growing < M$entry_date] <- M$entry_date[!is.na(M$entry_date) & !is.na(growing) & growing < M$entry_date]
M$growing_start  <- growing
M$cow_start   <- M$first_calving_date
M$sire_start  <- ifelse(M$sex %in% "Bull", M$first_sire_use_date, NA)
M$sire_start  <- as.Date(M$sire_start, origin="1970-01-01")

phase_at <- function(d){
  p <- rep(NA_character_, n)
  live <- !is.na(M$entry_date) & M$entry_date<=d & (is.na(M$exit_date) | M$exit_date>=d)
  p[live] <- "Calf"
  p[live & !is.na(M$growing_start) & M$growing_start<=d] <- "Growing"
  p[live & !is.na(M$sire_start) & M$sire_start<=d] <- "Breeding"
  p[live & !is.na(M$cow_start)  & M$cow_start<=d]  <- "Cow"
  p
}
M$phase_now <- phase_at(PULL)

## ---- WHY they left ------------------------------------------------------
## reason_for_sale (Sold) and cause_of_death (Dead) are free text; the raw
## value is kept verbatim and a grouped category added alongside it.
source(file.path(cfg$root,"R","exit_reason_map.R"))
M$exit_reason <- ifelse(M$status %in% "Sold", a$reason_for_sale,
                 ifelse(M$status %in% "Dead", a$cause_of_death, NA))
M$exit_reason_source <- ifelse(M$status %in% "Sold" & !is.na(a$reason_for_sale), "reason_for_sale",
                        ifelse(M$status %in% "Dead" & !is.na(a$cause_of_death), "cause_of_death", NA))
M$exit_reason_group <- classify_exit_reason(M$exit_reason)
M$flag_left_no_reason <- M$status %in% c("Sold","Dead") & is.na(M$exit_reason)

## ---- static group membership (undated in CattleMax; snapshot only) ----
gg <- rd("groupings.csv"); gr <- rd("groups.csv")
gg$gname <- gr$name[match(gg$group_id, gr$id)]
gl <- tapply(gg$gname[!is.na(gg$gname)], gg$animal_id[!is.na(gg$gname)],
             function(v) paste(sort(unique(v)), collapse="; "))
M$group_names <- unname(gl[id])
M$category_name <- setNames(rd("categories.csv")$name, rd("categories.csv")$id)[a$category_id]

## ---- FLAGS ----
M$flag_placeholder_birth <- !is.na(M$birth_date) & format(M$birth_date,"%m-%d")=="01-01"
M$flag_exit_estimated    <- M$exit_rule %in% c("last_activity(EST)","none(entry-only)")
M$flag_entry_estimated   <- M$entry_rule %in% c("first_movement(EST)","created_at(EST)")
M$flag_weaning_assumed   <- M$weaning_source %in% c("weaning_weight(EST 205d)","age>8mo(ASSUMED 205d)")
M$flag_no_birth_date     <- is.na(M$birth_date)
M$flag_exit_before_entry <- !is.na(M$exit_date) & !is.na(M$entry_date) & M$exit_date < M$entry_date

## ---- flags added after the 2026-08-14 review -----------------------------
## The animal kept being recorded after we say it left. Either the exit date
## is wrong or the child record is. We pick a side (exit precedence) and say so.
M$days_active_after_exit <- ifelse(!is.na(M$exit_date) & !is.na(M$last_activity_date),
                                   as.numeric(M$last_activity_date - M$exit_date), NA_real_)
M$flag_activity_after_exit <- !is.na(M$days_active_after_exit) & M$days_active_after_exit > 0
## Any date later than the pull is impossible: the export cannot know the future.
M$flag_date_after_pull <- Reduce(`|`, lapply(
  c("birth_date","purchase_date","sale_date","death_date","sale_ticket_date",
    "last_activity_date","weaning_date","first_calving_date","exit_date"),
  function(cn) !is.na(M[[cn]]) & M[[cn]] > PULL))
## A recorded (not assumed) weaning date that falls after she left. Left as a
## data flag rather than corrected, since the recorded date may be the right one.
M$flag_weaning_after_exit <- !is.na(M$weaning_date) & !is.na(M$exit_date) &
                             M$weaning_date > M$exit_date
## A departure with no dated evidence at all - the entire gap between our
## independent presence count and CattleMax's Active count (see validate_presence.R)
M$flag_left_undated <- M$status %in% c("Sold","Dead") &
                       is.na(M$sale_date) & is.na(M$death_date) & is.na(M$sale_ticket_date)

source(file.path(cfg$root,"R","exclusions.R")); excl_reset()
excl_add("animals.parquet", "status == Reference",
         sum(aAll$status %in% "Reference"), n_animals = sum(aAll$status %in% "Reference"),
         detail="pedigree back-fill, never present on the operation; still used as calving events and sires",
         recoverable=FALSE)
excl_write(cfg$silver)
cm_write_silver(M, cfg, "animals")
cat("\n")

cat("=== columns ===\n"); print(names(M))
cat("\n=== phase now (pull date", format(PULL), ") ===\n"); print(table(M$phase_now, useNA="ifany"))
cat("\n=== phase now x sex ===\n"); print(table(M$phase_now, M$sex, useNA="ifany"))
cat("\n=== weaning source ===\n"); print(sort(table(M$weaning_source), decreasing=TRUE))
cat("\n=== exit rule ===\n"); print(sort(table(M$exit_rule), decreasing=TRUE))
cat("\n=== entry rule ===\n"); print(sort(table(M$entry_rule), decreasing=TRUE))
cat("\n=== data-quality flags ===\n")
print(sapply(M[,grep("^flag_",names(M))], sum))
cat("\n=== why they left (grouped) ===\n")
print(sort(table(M$exit_reason_group, useNA="ifany"), decreasing=TRUE))
cat("left with NO reason recorded:", sum(M$flag_left_no_reason), "of",
    sum(M$status %in% c("Sold","Dead")), "\n")
if (any(M$exit_reason_group %in% "Unclassified", na.rm=TRUE)) {
  cat("\nUNCLASSIFIED raw reasons - add these to R/exit_reason_map.R:\n")
  print(sort(table(M$exit_reason[M$exit_reason_group %in% "Unclassified"]), decreasing=TRUE))
}
cat("\ninactivated (gone, no sale or death date):", sum(!is.na(M$inactivated_date)), "\n")
cat("\n=== ACTIVE only: phase counts ===\n")
print(table(M$phase_now[M$status=="Active"], useNA="ifany"))
