## ---------------------------------------------------------------
## Exit-reason grouping. CattleMax reason_for_sale / cause_of_death are FREE
## TEXT, so they arrive misspelt and in mixed case ("POOR PERFORMACE HEIFERS",
## "Poor Preformance"). This maps them to a small set of categories a report
## can actually count.
##
## EDIT THIS FILE, not the build scripts, when a new reason shows up.
## Anything unmatched lands in "Unclassified" and is COUNTED, never dropped -
## so a growing Unclassified bucket is the signal to extend the list here.
## Patterns are case-insensitive regex, applied in order; first match wins.
## ---------------------------------------------------------------
EXIT_REASON_RULES <- list(
  ## sold as product - this is the business working, not a failure
  list(cat="Marketed",            pat="production sale|commercial calf|commercial calves|bred cow|bred heifer|breeding bull|replacement (female|bull)|private treaty|cow/calf pair|steer|bucket calf|leased|butcher"),
  ## reproductive failure
  list(cat="Reproductive",        pat="\\bopen\\b|lost calf|no calf|did not pass bred|bred soundness|poor semen|one nut|ovarian|oviduct|uterine|free martin|prolapse|late calving|broken penis|breeding injury|wart on penis|testicle|pelvis|aborted|sluffed|did not accept calf|did not nurse|was not nursing|calf did not nurse"),
  ## she raised the calf badly / udder & mothering
  list(cat="Udder or mothering",  pat="udder|cow laid on|did not accept"),
  ## structure, feet, legs, general soundness
  list(cat="Structure or lameness", pat="cripple|lamin|blown hock|structural|unsound|broken leg|stepped on|could not get up|v shaped"),
  ## disease and health events
  list(cat="Health or disease",   pat="brd|pneumonia|scour|bloat|infection|lump jaw|brainer|cancer|abcess|abscess|hardware|navel|johne|leukosis|anaplasm|coccidio|mastitis|septic|chronic|lungger|waterbelly|blood clot|heart valve|heat stress|ammonia|bad eye|sick"),
  ## environment / accident / predation
  list(cat="Environment or accident", pat="frozen|cold stress|coyote|lightning|mud|tangled|fence|tire|difficulty calving|calving difficulty|premature|born dead|stuck"),
  ## temperament
  list(cat="Temperament",         pat="wild|aggressive|jumper"),
  ## age
  list(cat="Age",                 pat="old cow|old age"),
  ## performance / type culls
  list(cat="Performance",         pat="perform|preform"),
  ## explicitly recorded as not known
  list(cat="Recorded as unknown", pat="^unsure$|^unknown|put down|culled by cooperator")
)

classify_exit_reason <- function(x){
  out <- rep(NA_character_, length(x))
  has <- !is.na(x) & trimws(x) != ""
  out[has] <- "Unclassified"
  for (r in EXIT_REASON_RULES) {
    hit <- has & is.na(match(out, NA)) & out == "Unclassified" &
           grepl(r$pat, x, ignore.case = TRUE, perl = TRUE)
    out[hit] <- r$cat
  }
  out
}
