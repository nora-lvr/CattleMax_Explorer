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
## ORDER MATTERS - first match wins, so brand names must be listed BEFORE any
## generic route word. "Banamine Transdermal Pour-On" is flunixin, an
## anti-inflammatory; if a bare "pour-on" pattern is tested first it steals
## 176 events into Antiparasitic and inverts their intent.
DRUG_CLASS_RULES <- list(
  list(cls="Anti-inflammatory",  pat="banamine|flunixin|dexameth|predef|isoflupredone|meloxicam|prevail|aspirin|bute"),
  list(cls="Antibiotic",         pat="excede|baytr|biomycin|terramycin|liquamycin|advocin|combi-?pen|penicillin|draxxin|tulathro|florfenicol|nuflor|resflor|zactran|zuprevo|micotil|oxytetracycl|tetracycline|sulfamethazine|albon|naxcel|polyflex|noromycin"),
  list(cls="Vaccine",            pat="bovi-shield|alpha 7|covexin|nasalgen|bar-vac|vaccine|bacterin|baterine|bovoculi|moraxl|vista|pyramid|triangle|express|virashield|somnu"),
  list(cls="Antiparasitic",      pat="permectrin|synanthic|oxfendazole|safe-?guard|fenbendazole|ivermectin|dectomax|cydectin|convert|eprinex|clean[ -]?up|pour-?on insectic"),
  list(cls="Insecticide",        pat="insect control|\\bfly\\b|pour-?on"),
  list(cls="Repro hormone",      pat="lutalyse|cystorelin|estrumate|factrel|gonabreed|cidr|prostagland|oxytocin"),
  list(cls="Supportive care",    pat="electrolyte|re-?sorb|bluelite|probios|fluids|milk replacer|bolus|vit |vitamin|multimin|b complex|b 12|k1|a d e|corid|amprol|microbial"),
  list(cls="Not a product",      pat="^dead$|took the vet|^n/?a$"),
  ## catch-all for real products that fit none of the classes above.
  ## Reached only when nothing else matches, so it replaces "Unclassified"
  ## for anything that IS a treatment but has no obvious class.
  list(cls="Other treatment",    pat=".")
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
  ## "Other treatment": a real product with no clear class. Follow the
  ## diagnosis - with one it is therapeutic, without one it stays Other.
  intent[drug_class %in% "Other treatment"] <- ifelse(
    has_dx[drug_class %in% "Other treatment"], "Therapeutic", "Other treatment")

  ## a recorded diagnosis promotes preventative products to therapeutic:
  ## e.g. a pinkeye bacterin given to an animal already diagnosed with pinkeye
  promote <- has_dx & intent %in% "Routine / preventative"
  intent[promote] <- "Therapeutic"

  intent[is.na(intent)] <- "Unclassified"
  ## Nora's explicit intent overrides win over everything above, including
  ## the diagnosis promotion.
  if (length(MEDICATION_INTENT_OVERRIDES) && !missing(medication)) {
    hit <- match(medication, names(MEDICATION_INTENT_OVERRIDES))
    intent[!is.na(hit)] <- unname(MEDICATION_INTENT_OVERRIDES[hit[!is.na(hit)]])
  }
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

## =================================================================
## APPROVED BY NORA 2026-08-14 via the treatment review sheet.
## Exact per-value matches; these take precedence over the regex rules above.
## An INTENT override is absolute - it applies to every event of that
## medication, including the diagnosis-promotion rule.
## Trailing spaces in some keys are REAL: they exist in the raw CattleMax
## values and the match is exact, so do not tidy them away.
## =================================================================
MEDICATION_CLASS_OVERRIDES <- c(
  "Sustain III Calf Bolus"            = "Antibiotic",
  "Sustain III Cattle Bolus"          = "Antibiotic",
  "Sustain 3 calf bolus "             = "Antibiotic",
  "Corid"                             = "Other treatment",
  "Bluelite Replenish Electrolytes "  = "Other treatment",
  "Sx calf oral electrolyte "         = "Other treatment",
  "Vit B Complex"                     = "Other treatment",
  "Vit A D E"                         = "Other treatment",
  "Vit B 12"                          = "Other treatment",
  "Vit K1"                            = "Other treatment",
  "Vit-E&AD, Vit K1, & Vit B complex" = "Other treatment",
  "Uterine bolus "                    = "Other treatment",
  "Scour Bolus"                       = "Other treatment",
  "Fluids"                            = "Other treatment"
)

MEDICATION_INTENT_OVERRIDES <- c(
  "Corid"                             = "Therapeutic",
  "Vit B Complex"                     = "Therapeutic",
  "Powdered Tetracycline "            = "Therapeutic",
  "Vit A D E"                         = "Therapeutic",
  "Vit B 12"                          = "Therapeutic",
  "Vit K1"                            = "Therapeutic",
  "Vit-E&AD, Vit K1, & Vit B complex" = "Therapeutic",
  "Uterine bolus "                    = "Therapeutic",
  "Sustain 3 calf bolus "             = "Therapeutic",
  "Scour Bolus"                       = "Therapeutic",
  "Fluids"                            = "Therapeutic"
)

DIAGNOSIS_OVERRIDES <- character(0)

## ---- ACTIVE SUBSTANCE ----------------------------------------------------
## The raw `medication` is kept verbatim, but the same drug arrives under
## brand names, alternate spellings and case variants ("Dexamethasone" /
## "dexamethasone", "Draxxin" / "Tulathromyicn", "RE-SORB" / "Re-sorb & Milk
## Replacer"). This collapses them to the ACTIVE SUBSTANCE so a report can
## count a drug once. First match wins; anything unmatched keeps a tidied
## version of its own raw value and is reported by the build.
ACTIVE_SUBSTANCE_RULES <- list(
  list(sub="tulathromycin",      pat="draxxin|tulathro"),
  list(sub="florfenicol",        pat="nuflor|florfenicol|resflor"),
  list(sub="oxytetracycline",    pat="noromycin|biomycin|liquamycin|oxytetracycl|terramycin|powdered tetracycline|tetracycline"),
  list(sub="ceftiofur",          pat="excede|naxcel|spectramast"),
  list(sub="enrofloxacin",       pat="baytr"),
  list(sub="danofloxacin",       pat="advocin|a180"),
  list(sub="penicillin",         pat="combi-?pen|penicillin|pen ?g"),
  list(sub="sulfamethazine",     pat="sustain|sulfamethazine|albon|sulfadime"),
  list(sub="flunixin",           pat="banamine|flunixin|prevail"),
  list(sub="dexamethasone",      pat="dexameth"),
  list(sub="isoflupredone",      pat="predef|isoflupredone"),
  list(sub="meloxicam",          pat="meloxicam"),
  list(sub="amprolium",          pat="corid|amprol"),
  list(sub="eprinomectin",       pat="eprinex|long ?range"),
  list(sub="doramectin",         pat="dectomax"),
  list(sub="ivermectin",         pat="ivermectin|ivomec"),
  list(sub="moxidectin",         pat="cydectin"),
  list(sub="fenbendazole",       pat="safe-?guard|fenbendazole|panacur"),
  list(sub="oxfendazole",        pat="synanthic|oxfendazole"),
  list(sub="permethrin",         pat="permectrin|clean[ -]?up|pour-?on insectic|permethrin"),
  list(sub="dinoprost",          pat="lutalyse|prostagland|dinoprost"),
  list(sub="gonadorelin",        pat="cystorelin|factrel|gonabreed|gonadorelin"),
  list(sub="oral electrolytes",  pat="electrolyte|re-?sorb|bluelite|resorb"),
  list(sub="oral probiotic",     pat="probios|microbial"),
  list(sub="trace minerals",     pat="multimin|trace min"),
  list(sub="vitamins",           pat="^vit|vitamin|b complex"),
  ## vaccines: keep them separated by what they protect against
  list(sub="vaccine: BRD viral (IBR/BVD/PI3/BRSV)", pat="bovi-shield|triangle|nasalgen|pyramid|vista|express|virashield|bovine rhinotracheitis"),
  list(sub="vaccine: clostridial", pat="alpha 7|covexin|bar-vac|clostridium|blackleg"),
  list(sub="vaccine: pinkeye",   pat="bovoculi|moraxl|pink ?eye"),
  list(sub="vaccine: wart",      pat="wart"),
  list(sub="not a product",      pat="^dead$|took the vet|^n/?a$")
)
active_substance <- function(x){
  out <- rep(NA_character_, length(x))
  has <- !is.na(x) & trimws(x) != ""
  for (r in ACTIVE_SUBSTANCE_RULES) {
    hit <- has & is.na(out) & grepl(r$pat, x, ignore.case=TRUE, perl=TRUE)
    out[hit] <- r$sub
  }
  ## unmatched: keep a tidied form of the raw value so nothing is lost
  out[has & is.na(out)] <- tolower(trimws(x[has & is.na(out)]))
  out
}

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
.apply_override <- function(v, x, ov){
  if (!length(ov)) return(v)
  hit <- match(x, names(ov))
  v[!is.na(hit)] <- unname(ov[hit[!is.na(hit)]])
  v
}
classify_drug    <- function(x) .apply_override(.match_first(x, DRUG_CLASS_RULES, "cls"),
                                                x, MEDICATION_CLASS_OVERRIDES)
classify_disease <- function(x) .apply_override(.match_first(x, DISEASE_RULES, "cat"),
                                                x, DIAGNOSIS_OVERRIDES)
