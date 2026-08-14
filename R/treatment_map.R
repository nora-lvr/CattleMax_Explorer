## ---------------------------------------------------------------
## Treatment classification. CattleMax `category` is only ~24% filled and mixes
## product classes with drug names, so it is NOT the routine/therapeutic axis.
## `medication` is 100% filled with ~55 distinct values, so intent is derived
## from the DRUG, and disease from `diagnosis`.
##
## EDIT THIS FILE when a new drug or diagnosis appears. Unmatched values land
## in "Unclassified" and are COUNTED, never dropped - the build prints them.
## Patterns are case-insensitive regex, applied in order; first match wins.
##
## NOTE FOR NORA: the intent and drug-class assignments below are a
## veterinarian-facing judgement call. Please review them - especially the
## drugs that can be either preventative or therapeutic depending on context.
## ---------------------------------------------------------------

## ---- what the product IS ----
DRUG_CLASS_RULES <- list(
  list(cls="Vaccine",            pat="bovi-shield|alpha 7|covexin|nasalgen|bar-vac|vaccine|bacterin|baterine|bovoculi|moraxl|vista|pyramid|triangle|express|virashield|somnu"),
  list(cls="Antiparasitic",      pat="permectrin|pour-?on|synanthic|oxfendazole|safe-?guard|fenbendazole|ivermectin|dectomax|cydectin|convert|eprinex|clean[ -]?up"),
  list(cls="Insecticide",        pat="insect control|fly|tag"),
  list(cls="Antibiotic",         pat="excede|baytr|biomycin|terramycin|liquamycin|advocin|combi-?pen|penicillin|draxxin|tulathro|florfenicol|nuflor|resflor|zactran|zuprevo|micotil|oxytetracycl|tetracycline|sulfamethazine|albon|naxcel|polyflex|noromycin"),
  list(cls="Anti-inflammatory",  pat="banamine|flunixin|dexameth|predef|isoflupredone|meloxicam|prevail|aspirin|bute"),
  list(cls="Repro hormone",      pat="lutalyse|cystorelin|estrumate|factrel|gonabreed|cidr|prostagland|oxytocin"),
  list(cls="Supportive care",    pat="electrolyte|re-?sorb|bluelite|probios|fluids|milk replacer|bolus|vit |vitamin|multimin|b complex|b 12|k1|a d e|corid|amprol|microbial"),
  list(cls="Not a product",      pat="^dead$|took the vet|^n/?a$")
)

## ---- WHY it was given: the routine vs therapeutic axis ----
## Rules are applied in order. A recorded diagnosis outranks the drug class,
## because a vaccine given to a sick animal is still a therapeutic event.
TREATMENT_INTENT <- function(drug_class, diagnosis, medication){
  intent <- rep(NA_character_, length(drug_class))
  has_dx <- !is.na(diagnosis) & trimws(diagnosis) != ""

  ## whole-herd preventative work, given on healthy animals
  intent[drug_class %in% c("Vaccine","Antiparasitic","Insecticide")] <- "Routine / preventative"
  ## breeding management, not disease
  intent[drug_class %in% "Repro hormone"] <- "Reproductive management"
  ## drugs only reached for when something is wrong
  intent[drug_class %in% c("Antibiotic","Anti-inflammatory")] <- "Therapeutic"
  ## supportive care follows the diagnosis
  intent[drug_class %in% "Supportive care"] <- ifelse(
    has_dx[drug_class %in% "Supportive care"], "Therapeutic", "Supportive")
  intent[drug_class %in% "Not a product"] <- "Not a treatment"

  ## a recorded diagnosis promotes preventative products to therapeutic:
  ## e.g. a pinkeye bacterin given to an animal already diagnosed with pinkeye
  promote <- has_dx & intent %in% "Routine / preventative"
  intent[promote] <- "Therapeutic"

  intent[is.na(intent)] <- "Unclassified"
  intent
}

## ---- disease grouping, for therapeutic events ----
DISEASE_RULES <- list(
  list(cat="Respiratory (BRD)",   pat="\\bbrd\\b|respirator|pneumon|cough|breathing|snotty|congestion|lungger|nasal"),
  list(cat="Ocular (pinkeye)",    pat="pink ?eye|eye poke|blindness|cancer eye|\\beye\\b"),
  list(cat="Lameness / foot",     pat="limp|foot ?ro+t|hoof|heel wart|cracked|swollen (leg|hock)|cut on foot|cut leg|lame|stifle|broken (leg|tail)"),
  list(cat="Enteric",             pat="scour|coccidio|diarrh|bloat|hardware|peritenitis|peritonitis"),
  list(cat="Ear",                 pat="dropp?y ears|down ear|ear infection|infected ear|head tilt"),
  list(cat="Navel / umbilical",   pat="naval|navel"),
  list(cat="Reproductive",        pat="uterine|retained placenta|abort|prolapse|breeding|ovarian"),
  list(cat="Udder / mastitis",    pat="mastitis|udder"),
  list(cat="Bull breeding soundness", pat="semen|white cell|puss in|penile"),
  list(cat="Neurologic",          pat="polio|brainer|listeri"),
  list(cat="Systemic / infectious",pat="anaplasm|lump jaw|abscess|abcess|infection|hives|lethargic|ammonia|fever|woody tongue|water ?logged"),
  list(cat="Injury / trauma",     pat="cut |lump on|wound|stepped|snake"),
  list(cat="Nonspecific",         pat="^unsure$|not coming up to feed|^fever$")
)

.match_first <- function(x, rules, field){
  out <- rep(NA_character_, length(x))
  has <- !is.na(x) & trimws(x) != ""
  out[has] <- "Unclassified"
  for (r in rules) {
    hit <- has & out == "Unclassified" & grepl(r$pat, x, ignore.case=TRUE, perl=TRUE)
    out[hit] <- r[[field]]
  }
  out
}
classify_drug    <- function(x) .match_first(x, DRUG_CLASS_RULES, "cls")
classify_disease <- function(x) .match_first(x, DISEASE_RULES,    "cat")
