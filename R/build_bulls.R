## ---------------------------------------------------------------
## bulls.parquet : one row per BULL.
##
## In a seedstock herd the bulls ARE the product, so they need their own
## table. A bull's life is simpler than a cow's - there is no repeating
## season - so the grain is one row per animal, carrying his breeding
## soundness history, his use as a sire, his progeny, and his sale outcome.
##
## This closes the largest recoverable exclusion on the ledger (1,896 records
## excluded from cow_lactations.parquet purely for not being female).
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
source(file.path(cfg$root,"R","exclusions.R")); excl_reset()

M   <- cm_read_silver(cfg, "animals")
aAll<- rd("animals.csv"); br <- rd("breedings.csv"); bse <- rd("breeding_soundness_exams.csv")
ms  <- rd("measurements.csv")
br$bdate <- d10(br$breeding_date); bse$edate <- d10(bse$exam_date)

B <- M[M$sex %in% "Bull", ]
cat("bulls (sex == Bull, non-Reference):", nrow(B), "\n")
id <- B$animal_id

## ---- BREEDING SOUNDNESS ----------------------------------------------
bx <- bse[bse$animal_id %in% id, ]
agg1 <- function(df, key, val, fn) { v <- tapply(val, df[[key]], fn); v[id] }
B$n_bse            <- as.integer(table(factor(bx$animal_id, levels=id)))
B$first_bse_date   <- as.Date(unname(agg1(bx,"animal_id",as.integer(bx$edate),function(v) min(v,na.rm=TRUE))), origin="1970-01-01")
B$last_bse_date    <- as.Date(unname(agg1(bx,"animal_id",as.integer(bx$edate),function(v) max(v,na.rm=TRUE))), origin="1970-01-01")
B$first_bse_date[!is.finite(as.numeric(B$first_bse_date))] <- NA
B$last_bse_date[!is.finite(as.numeric(B$last_bse_date))]   <- NA
## classification at his LATEST exam
bx <- bx[order(bx$animal_id, bx$edate), ]
lastrow <- bx[!duplicated(bx$animal_id, fromLast=TRUE), ]
mm <- match(id, lastrow$animal_id)
B$last_bse_class   <- lastrow$classification[mm]
B$last_bse_scrotal <- num(lastrow$scrotal[mm])
B$last_bse_motility<- lastrow$motility[mm]
B$last_bse_normal  <- num(lastrow$normal[mm])
## ever failed, at any exam
fail_pat <- "fail|unsatisf|defer"
B$ever_failed_bse <- id %in% unique(bx$animal_id[grepl(fail_pat, bx$classification, ignore.case=TRUE)])
B$bse_outcome <- ifelse(is.na(B$last_bse_class), NA,
                 ifelse(grepl("fail|unsatisf", B$last_bse_class, ignore.case=TRUE), "Fail",
                 ifelse(grepl("defer", B$last_bse_class, ignore.case=TRUE), "Deferred", "Pass")))

## ---- USE AS A SIRE ----------------------------------------------------
use <- br[br$bull_animal_id %in% id, ]
B$n_services_as_sire <- as.integer(table(factor(use$bull_animal_id, levels=id)))
B$first_sire_use <- as.Date(unname(tapply(as.integer(use$bdate), use$bull_animal_id, function(v) min(v,na.rm=TRUE))[id]), origin="1970-01-01")
B$last_sire_use  <- as.Date(unname(tapply(as.integer(use$bdate), use$bull_animal_id, function(v) max(v,na.rm=TRUE))[id]), origin="1970-01-01")
B$first_sire_use[!is.finite(as.numeric(B$first_sire_use))] <- NA
B$last_sire_use[!is.finite(as.numeric(B$last_sire_use))]   <- NA
B$ever_used_as_sire <- B$n_services_as_sire > 0
B$breeding_methods  <- unname(tapply(use$breeding_method, use$bull_animal_id,
                        function(v) paste(sort(unique(v)), collapse="/"))[id])
B$age_at_first_use_mo <- round(as.numeric(B$first_sire_use - B$birth_date)/30.44, 1)
## progeny actually recorded against him
B$n_progeny <- as.integer(table(factor(aAll$sire_animal_id, levels=id)))

## ---- GROWTH ------------------------------------------------------------
B$birth_weight   <- num(aAll$birth_weight[match(id, aAll$id)])
B$weaning_weight <- num(aAll$weaning_weight[match(id, aAll$id)])
B$yearling_weight<- num(aAll$yearling_weight[match(id, aAll$id)])
B$adj_ww         <- num(aAll$adj_weaning_weight[match(id, aAll$id)])
B$adj_yw         <- num(aAll$adj_yearling_weight[match(id, aAll$id)])
B$last_weight    <- num(aAll$last_weight[match(id, aAll$id)])
B$last_weight_date <- d10(aAll$last_weight_date[match(id, aAll$id)])
mw <- ms[ms$animal_id %in% id, ]
B$n_weights <- as.integer(table(factor(mw$animal_id, levels=id)))

## ---- DISPOSAL ----------------------------------------------------------
## SCOPE (Nora, 2026-08-14): this is a VETERINARY tool. Animals and health
## only - no prices, no economics. Sale WEIGHT is kept because it is a growth
## measurement; sale price, marketing method and $/cwt are deliberately absent.
B$sale_weight     <- num(aAll$sale_weight[match(id, aAll$id)])
B$reason_for_sale <- aAll$reason_for_sale[match(id, aAll$id)]

## ---- ROLE: is he a herd sire or product? ------------------------------
## Destiny, not age (PLAN.md 6): a bull who was never exposed is inventory.
B$bull_role <- ifelse(B$ever_used_as_sire, "Herd sire",
               ifelse(B$status %in% "Sold", "Sold",
               ifelse(!is.na(B$exit_date), "Died or left", "Growing inventory")))
B$age_now_mo  <- round(as.numeric(pmin(PULL, ifelse(is.na(B$exit_date), PULL, B$exit_date),
                                        na.rm=TRUE) - B$birth_date)/30.44, 1)

## ---- FLAGS -------------------------------------------------------------
B$flag_no_bse          <- B$n_bse == 0
B$flag_failed_bse      <- B$ever_failed_bse
B$flag_used_despite_fail <- B$ever_failed_bse & B$ever_used_as_sire
B$flag_no_birth_date   <- is.na(B$birth_date)
B$flag_no_weights      <- B$n_weights == 0

B <- B[order(B$birth_date, B$animal_id), ]
cm_write_silver(B, cfg, "bulls")
cat("\n")

cat("=== ROLE ===\n");            print(sort(table(B$bull_role), decreasing=TRUE))
cat("\n=== BREEDING SOUNDNESS (latest exam) ===\n")
print(table(B$bse_outcome, useNA="ifany"))
cat("bulls with at least one BSE:", sum(B$n_bse>0), " exams total:", sum(B$n_bse), "\n")
cat("ever failed/deferred:", sum(B$ever_failed_bse), "  of those, still used as a sire:",
    sum(B$flag_used_despite_fail), "\n")
cat("\n=== USE AS A SIRE ===\n")
cat("ever used:", sum(B$ever_used_as_sire), " of", nrow(B), "\n")
cat("age at first use (months):\n"); print(round(summary(B$age_at_first_use_mo[B$ever_used_as_sire]),1))
cat("services by the top sires:\n")
print(head(sort(B$n_services_as_sire[B$ever_used_as_sire], decreasing=TRUE), 8))
cat("progeny recorded:\n"); print(summary(B$n_progeny[B$n_progeny>0]))
cat("\n=== DISPOSAL (veterinary scope: no prices, no economics) ===\n")
print(head(sort(table(B$reason_for_sale, useNA="no"), decreasing=TRUE), 8))
cat("\n=== FLAGS ===\n"); print(sapply(B[,grep("^flag_",names(B))], sum, na.rm=TRUE))

excl_add("bulls.parquet", "animal is not sex == Bull",
         sum(!(M$sex %in% "Bull")), n_animals=sum(!(M$sex %in% "Bull")),
         detail="females are in cow_lactations.parquet; 91 steers and 24 with no sex have no table",
         recoverable=TRUE)
excl_write(cfg$silver)
