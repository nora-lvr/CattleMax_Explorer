## ---------------------------------------------------------------
## treatments.parquet : one row per TREATMENT EVENT.
## Stand-alone silver table - carries the animal context it needs (phase, sex,
## age at treatment) so a health report never has to re-join animals.parquet
## just to answer a basic question.
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
rd <- function(f) cm_read(cfg, f)
source(file.path(cfg$root,"R","treatment_map.R"))

tx <- rd("treatments.csv")
A  <- cm_read_silver(cfg, "animals")

T <- data.frame(
  treatment_id   = tx$id,
  animal_id      = tx$animal_id,
  treatment_date = d10(tx$treatment_date),
  stringsAsFactors = FALSE)

## ---- animal context, carried so this table stands alone ----
m <- match(T$animal_id, A$animal_id)
T$in_animals_parquet <- !is.na(m)          # FALSE = a Reference animal
T$ear_tag    <- A$ear_tag[m]
T$sex        <- A$sex[m]
T$birth_date <- A$birth_date[m]
T$dam_status <- A$status[m]
T$age_days_at_treatment <- as.numeric(T$treatment_date - T$birth_date)
T$age_months_at_treatment <- round(T$age_days_at_treatment/30.44, 1)

## phase ON THE DAY OF TREATMENT, recomputed from the stored phase boundaries
ph <- function(i){
  d <- T$treatment_date[i]; k <- m[i]
  if (is.na(k) || is.na(d)) return(NA_character_)
  p <- NA_character_
  if (!is.na(A$entry_date[k]) && A$entry_date[k] <= d &&
      (is.na(A$exit_date[k]) || A$exit_date[k] >= d)) p <- "Calf"
  if (!is.na(A$growing_start[k]) && A$growing_start[k] <= d) p <- "Growing"
  if (!is.na(A$sire_start[k])    && A$sire_start[k]    <= d) p <- "Breeding"
  if (!is.na(A$cow_start[k])     && A$cow_start[k]     <= d) p <- "Cow"
  p
}
T$phase_at_treatment <- vapply(seq_len(nrow(T)), ph, character(1))

## ---- what was given, and why ----
T$medication  <- tx$medication                       # raw, verbatim
T$active_substance <- active_substance(tx$medication) # standardised
T$drug_class  <- classify_drug(tx$medication)
T$diagnosis   <- tx$diagnosis
T$disease_category <- classify_disease(tx$diagnosis)
T$treatment_intent <- TREATMENT_INTENT(T$drug_class, T$diagnosis, T$medication)
T$is_therapeutic <- T$treatment_intent %in% "Therapeutic"
T$is_preventative<- T$treatment_intent %in% "Routine / preventative"

## ---- clinical / administrative detail worth keeping ----
T$raw_category    <- tx$category          # kept verbatim; unreliable, see map
T$dosage          <- tx$dosage
T$route           <- tx$route
T$body_location   <- tx$location
T$administered_by <- tx$administered_by
T$temperature     <- suppressWarnings(as.numeric(tx$temperature))
T$withdrawal_date <- d10(tx$withdrawal_date)
T$withdrawal_days <- as.numeric(T$withdrawal_date - T$treatment_date)
T$booster_date    <- d10(tx$booster_date)
T$lot_number      <- tx$lot_number
T$manufacturer    <- tx$manufacturer
T$comments        <- tx$comments

## ---- record horizon: treatments start later than the animal record ----
HORIZON <- min(T$treatment_date, na.rm=TRUE)
T$record_horizon <- HORIZON

## ---- flags: surface, do not chase ----
T$flag_reference_animal   <- !T$in_animals_parquet
T$flag_no_diagnosis       <- is.na(T$diagnosis)
T$flag_no_withdrawal_date <- is.na(T$withdrawal_date)
T$flag_unclassified_drug    <- T$drug_class %in% "Unclassified"
T$flag_unclassified_disease <- T$disease_category %in% "Unclassified"
T$flag_no_birth_date      <- is.na(T$birth_date)
T$flag_negative_age       <- !is.na(T$age_days_at_treatment) & T$age_days_at_treatment < 0
key <- paste(T$animal_id, T$treatment_date, T$medication)
T$flag_duplicate_event    <- duplicated(key) | duplicated(key, fromLast=TRUE)

T <- T[order(T$treatment_date, T$animal_id), ]
fp <- file.path(SILVER,"treatments.parquet"); fc <- file.path(SILVER,"treatments.csv")
arrow::write_parquet(T, fp, compression="snappy")
write.csv(T, fc, row.names=FALSE, na="")
cat("WROTE", fp, sprintf("(%.0f KB)", file.size(fp)/1024), "\n")
cat(" treatment events:", nrow(T), " animals:", length(unique(T$animal_id)),
    " cols:", ncol(T), "\n")
cat(" record horizon:", format(HORIZON), " .. ", format(max(T$treatment_date,na.rm=TRUE)), "\n\n")

cat("=== TREATMENT INTENT (the routine vs therapeutic split) ===\n")
print(sort(table(T$treatment_intent), decreasing=TRUE))
cat("\n=== DRUG CLASS ===\n");        print(sort(table(T$drug_class, useNA="ifany"), decreasing=TRUE))
cat("\n=== DISEASE CATEGORY (therapeutic events) ===\n")
print(sort(table(T$disease_category[T$is_therapeutic], useNA="ifany"), decreasing=TRUE))
cat("\n=== intent x phase at treatment ===\n")
print(table(T$treatment_intent, T$phase_at_treatment, useNA="ifany"))
cat("\n=== FLAGS ===\n"); print(sapply(T[,grep("^flag_",names(T))], sum, na.rm=TRUE))

um <- unique(T$medication[T$flag_unclassified_drug])
if (length(um)) { cat("\nUNCLASSIFIED medications - add to R/treatment_map.R:\n"); print(sort(table(T$medication[T$flag_unclassified_drug]), decreasing=TRUE)) }
ud <- unique(T$diagnosis[T$flag_unclassified_disease])
if (length(ud)) { cat("\nUNCLASSIFIED diagnoses - add to R/treatment_map.R:\n"); print(sort(table(T$diagnosis[T$flag_unclassified_disease]), decreasing=TRUE)) }
