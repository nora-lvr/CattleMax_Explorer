## Emit live counts for the data-flow document, so the diagram can never drift
## from what the pipeline actually did. Run AFTER every build.
##
## The stage list carries `tier` and `reads`, and the document lays the diagram
## out FROM THAT. Adding a silver table here makes it appear in the diagram
## automatically - the previous version hand-positioned three boxes and went
## silently blind to the five tables added after it.
options(width=200)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
OUT <- cfg$derived
dir.create(OUT, showWarnings=FALSE, recursive=TRUE)
rd  <- function(f) cm_read(cfg, f)
q   <- function(x) paste0('"', gsub('"','\\\\"', ifelse(is.na(x),"",as.character(x))), '"')
j   <- function(x) paste0("[", paste(x, collapse=","), "]")
## p() builds ONE "key":value pair. kv() joins pairs with commas.
## Passing the key, a ":" and the value as three separate args to kv() emits
## "key", : ,value - malformed JSON that renders a blank page. Use p().
p   <- function(k, v) paste0(q(k), ":", v)
kv  <- function(...) paste0("{", paste(c(...), collapse=","), "}")
num <- function(x) { x <- suppressWarnings(as.numeric(x)); ifelse(is.na(x), 0, x) }
n0  <- function(x) if (length(x) && !is.na(x)) x else 0
fm  <- function(x) format(n0(x), big.mark=",")

silver <- function(nm) tryCatch(cm_read_silver(cfg, nm), error=function(e) NULL)
A  <- silver("animals");    CS <- silver("cow_lactations");        TX <- silver("treatments")
BU <- silver("bulls");      LO <- silver("locations");   PR <- silver("phase_risk")
DZ <- silver("disease_cases"); CF <- silver("calf_fates"); SC <- silver("cow_scorecard")
EX <- silver("exclusions")
a  <- rd("animals.csv"); tx <- rd("treatments.csv")

## ---- stages: what exists, what it is built from -------------------------
raw_animals <- nrow(a)
ref         <- sum(a$status %in% "Reference")
st <- function(id,label,n,note,tier,reads=character(0))
  kv(p("id",q(id)), p("label",q(label)), p("n",n0(n)), p("note",q(note)),
     p("tier",tier), p("reads", j(vapply(reads,q,character(1)))))
stages <- c(
  st("raw","animals.csv", raw_animals, "every row CattleMax exported", 0),
  st("nonref","non-Reference", raw_animals-ref,
     paste0(fm(ref)," Reference rows removed"), 0),
  st("animals","animals.parquet", nrow(A),
     paste0(ncol(A)," columns, one row per animal"), 1, c("nonref")),
  st("cow_lactations","cow_lactations.parquet", nrow(CS),
     paste0(fm(length(unique(CS$animal_id)))," females, one row per season"), 1, c("animals")),
  st("treatments","treatments.parquet", nrow(TX),
     paste0(fm(length(unique(TX$animal_id)))," animals, one row per event"), 1, c("animals")),
  st("bulls","bulls.parquet", nrow(BU),
     if (is.null(BU)) "not built" else "one row per bull", 1, c("animals")),
  st("locations","locations.parquet", nrow(LO),
     if (is.null(LO)) "not built" else
       paste0(fm(length(unique(LO$animal_id)))," animals, one row per stay"), 1, c("animals")),
  st("phase_risk","phase_risk.parquet", nrow(PR),
     if (is.null(PR)) "not built" else "one row per animal-phase, with days at risk", 2, c("animals")),
  st("disease_cases","disease_cases.parquet", nrow(DZ),
     if (is.null(DZ)) "not built" else
       paste0(fm(length(unique(DZ$animal_id)))," animals, one row per case"), 2,
     c("treatments","phase_risk","locations")),
  st("calf_fates","calf_fates.parquet", nrow(CF),
     if (is.null(CF)) "not built" else "one row per calving, on the outcome ladder", 2,
     c("cow_lactations","animals")),
  st("cow_scorecard","cow_scorecard.parquet", nrow(SC),
     if (is.null(SC)) "not built" else "one row per cow", 3, c("calf_fates","cow_lactations")),
  st("exclusions","exclusions.parquet", nrow(EX),
     if (is.null(EX)) "not built" else
       paste0(fm(sum(num(EX$n_records)))," records accounted for"), 3,
     c("animals","cow_lactations","treatments","locations","phase_risk","disease_cases",
       "calf_fates","cow_scorecard")))

## ---- every decision, with live counts -----------------------------------
dec <- function(id, stage, rule, detail, counts, validated)
  kv(p("id",q(id)), p("stage",q(stage)), p("rule",q(rule)),
     p("detail",q(detail)), p("counts",counts), p("validated",q(validated)))
ct <- function(...) paste0("[", paste(sapply(list(...), function(z)
        kv(p("k",q(z[[1]])), p("v",q(z[[2]])))), collapse=","), "]")

D1 <- dec("reference","Filter",
  "Exclude status == Reference",
  "Reference animals are pedigree back-fill, not animals that were present. They are excluded from presence but STILL used as calving events and as sires.",
  ct(list("Reference rows removed", fm(ref)),
     list("share of the export", sprintf("%.0f%%", 100*ref/raw_animals)),
     list("still used as calf records", fm(sum(a$status %in% "Reference" & !is.na(a$birth_date) & !is.na(a$dam_animal_id))))),
  "yes")

ent <- table(A$entry_rule)
D2 <- dec("entry","animals.parquet",
  "Entry date precedence: purchase_date -> birth_date -> first movement -> created_at",
  "The first rule that yields a date wins, and entry_rule records which one fired.",
  ct(list("purchase_date", ent["purchase_date"]), list("birth_date", ent["birth_date"]),
     list("first_movement (EST)", ent["first_movement(EST)"]), list("created_at (EST)", ent["created_at(EST)"])),
  "no")

ex <- table(A$exit_rule)
D3 <- dec("exit","animals.parquet",
  "Exit date precedence: sale_date -> death_date -> sale ticket -> last activity. NEVER updated_at",
  "updated_at is a bulk record-edit stamp: animals whose real activity stopped in 2016-2019 carry an updated_at of 2025-12-14, which would keep them present six years too long.",
  ct(list("sale_date", ex["sale_date"]), list("death_date", ex["death_date"]),
     list("sale ticket join", ex["sale_ticket"]), list("last activity (EST)", ex["last_activity(EST)"]),
     list("no evidence", ex["none(entry-only)"]), list("still present", ex["open"])),
  "yes")

ws <- table(A$weaning_source)
D4 <- dec("weaning","animals.parquet",
  "Weaning precedence: weaning_date -> weaning measurement -> weaning weight (+205d) -> age at exit > 8 months (assume weaned)",
  "The age backstop stops old animals with no weaning record being counted as nursing calves. Age is measured at EXIT, not at the pull, or animals that died young are wrongly called weaned.",
  ct(list("weaning_date", ws["weaning_date"]), list("weaning measurement", ws["weaning_measurement"]),
     list("weaning weight (EST)", ws["weaning_weight(EST 205d)"]),
     list("age > 8 mo (ASSUMED)", ws["age>8mo(ASSUMED 205d)"]),
     list("still nursing", ws["none(still nursing)"])),
  "no")

D5 <- dec("phase","animals.parquet",
  "Production phase boundaries stored as DATES, not labels",
  "Calf from entry, Growing from weaning, Cow from first calving, Breeding from a bull's first exposure. Phase on any date is a comparison, so history is never lost.",
  ct(list("Calf now", sum(A$phase_now=="Calf",na.rm=TRUE)),
     list("Growing now", sum(A$phase_now=="Growing",na.rm=TRUE)),
     list("Cow now", sum(A$phase_now=="Cow",na.rm=TRUE)),
     list("Breeding now", sum(A$phase_now=="Breeding",na.rm=TRUE))),
  "yes")

D6 <- dec("dam","cow_lactations.parquet",
  "dam_animal_id is the CARRIER. real_dam / genetic_dam is the DONOR and must never be used",
  "For ET calves real_dam equals genetic_dam in 453 of 458 cases. Using it credits donors with their recipients' calvings and made a 314-head recipient herd look barren, understating one season from 76.5% to 44.7% calved.",
  ct(list("calves linked via carrier", fm(sum(CS$dam_link_source %in% "dam_animal_id(carrier)"))),
     list("real_dam fallback used", sum(CS$dam_link_source %in% "real_dam(fallback)")),
     list("calves with no carrier, dropped", sum(is.na(a$dam_animal_id) & !is.na(a$real_dam_animal_id) & !is.na(a$birth_date)))),
  "yes")

D7 <- dec("twins","cow_lactations.parquet",
  "Calves born within 7 days of the cluster's FIRST calf are ONE calving event",
  "The window is measured from the cluster start, not the previous calf, or runs chain into one 34-day 'birth'. The collapsed event date is written back onto every calf row, or multiples re-expand into separate seasons and inflate calf counts.",
  ct(list("calf records", fm(sum(!is.na(a$dam_animal_id) & !is.na(a$birth_date)))),
     list("calving events after collapse", fm(sum(CS$calved))),
     list("events with >1 calf", sum(CS$n_calves_born>1, na.rm=TRUE)),
     list("flagged implausible (>3)", sum(CS$flag_implausible_multiple, na.rm=TRUE))),
  "partly")

D8 <- dec("season","cow_lactations.parquet",
  "A cow-season ENDS at each calving; the next begins there. Season 1 opens at first bull exposure",
  "Windows are half-open [start, end) so a service on a calving date belongs to the next season only. Season 1 falls back to entry when there is no breeding record.",
  ct(list("cow-seasons", fm(nrow(CS))),
     list("ended in a calving", fm(sum(CS$calved))),
     list("exited without calving", sum(CS$outcome=="Exited without calving")),
     list("open at the pull", sum(CS$outcome=="Open at pull date"))),
  "yes")

D9 <- dec("denominators","cow_lactations.parquet",
  "Two denominators: EXPOSED (every female served) and RETAINED (still present at her due date)",
  "The exposed basis carries attrition as a cost; the retained basis isolates the females that could actually calve. The gap between them is the attrition itself.",
  ct(list("exposed seasons", fm(sum(!is.na(CS$first_service)))),
     list("lost before calving", sum(CS$lost_before_calving, na.rm=TRUE)),
     list("retained to due date", fm(sum(CS$retained_to_due, na.rm=TRUE)))),
  "yes")

hz <- format(CS$record_horizon[1])
D10 <- dec("horizon","cow_lactations.parquet",
  paste0("Record horizon ", hz, ": anything opening earlier is left-censored"),
  "CattleMax recording began only a few years ago and earlier births are pedigree back-fill, so the start of the record is ragged and must never be silently averaged in.",
  ct(list("left-censored seasons", fm(sum(CS$flag_left_censored))),
     list("right-censored (open at pull)", fm(sum(CS$flag_right_censored))),
     list("parity unknown", sum(CS$flag_parity_unknown)),
     list("rate_ready", fm(sum(CS$rate_ready))),
     list("interval_ready", fm(sum(CS$interval_ready)))),
  "no")

ti <- table(TX$treatment_intent)
D11 <- dec("intent","treatments.parquet",
  "Routine vs therapeutic comes from MEDICATION, not from CattleMax's category field",
  "category is only 24% filled and mixes product classes with drug names: 'Pink Eye' appears as both a vaccine and an antibiotic. medication is 100% filled with 55 distinct values.",
  ct(list("Therapeutic", ti["Therapeutic"]), list("Routine / preventative", ti["Routine / preventative"]),
     list("Supportive", ti["Supportive"]), list("Reproductive management", ti["Reproductive management"]),
     list("raw category filled", sprintf("%.0f%%", 100*sum(!is.na(tx$category))/nrow(tx)))),
  "yes")

D12 <- dec("substance","treatments.parquet",
  "active_substance collapses brand names and alternate spellings; raw medication is kept verbatim",
  "The same drug arrives as Draxxin and Tulathromyicn, as five oxytetracycline brands, and as both Dexamethasone and dexamethasone.",
  ct(list("raw medication values", length(unique(TX$medication))),
     list("active substances", length(unique(TX$active_substance))),
     list("Nora's class overrides", 14), list("Nora's intent overrides", 11)),
  "yes")

## ---------------- everything below was UNDOCUMENTED until 2026-08-15 -------
D13 <- dec("locations","locations.parquet",
  "Group membership becomes half-open intervals: one row per animal per stay, clipped to her presence",
  "A movement is an event; a denominator needs an interval. Each move opens a stay and the next move closes it, so 'who was in this pasture on this date' is a lookup rather than a reconstruction. Reference animals' movements are excluded, as they were never present.",
  ct(list("stays", fm(nrow(LO))),
     list("animals located", fm(length(unique(LO$animal_id)))),
     list("still in place at the pull", fm(sum(is.na(LO$to_date) | LO$to_date >= cfg$pull_date))),
     list("distinct pastures", length(unique(LO$pasture_id)))),
  "yes")

D14 <- dec("phaserisk","phase_risk.parquet",
  "One row per animal-phase, carrying days at risk, so an attack rate has a real denominator",
  "A phase is a window a producer manages as a unit, so the honest incidence is 'what share of the calves got BRD before weaning', not a per-day rate. Phase windows are clipped to presence and a phase that begins after she left never happened.",
  ct(list("animal-phases", fm(nrow(PR))),
     list("animals", fm(length(unique(PR$animal_id)))),
     list("completed the phase", fm(sum(PR$completed))),
     list("still in phase at the pull", fm(sum(PR$ended_by == "still in phase at pull")))),
  "yes")

D15 <- dec("clock","phase_risk.parquet",
  "The phase clock is only 'days since birth / weaning' when the animal was HERE for that event",
  "An animal bought after weaning has no weaning we witnessed, so her Growing phase starts at PURCHASE and her day-of-phase is days since we bought her. Mixing those into a day-of-phase curve smears it. clock_true marks the honest rows and day_of_phase_clean is NA for the rest, so they cannot be silently averaged in.",
  ct(list("phases on a true anchor", fm(sum(PR$clock_true))),
     list("clock starts at purchase", fm(sum(!PR$clock_true))),
     list("of those, Growing", fm(sum(!PR$clock_true & PR$phase=="Growing"))),
     list("phase starts before birth", sum(PR$flag_start_before_birth)),
     list("born before 2015", fm(sum(PR$flag_pre_horizon_birth)))),
  "yes")

D16 <- dec("case","disease_cases.parquet",
  paste0("A CASE is a run of therapeutic treatments on one animal for one disease, separated by more than ",
         n0(DZ$case_gap_days[1]), " treatment-free days"),
  "A treatment is not a case. An animal treated on three consecutive days for pinkeye has one case and three treatments; counting treatments as cases inflates incidence by however often the practice re-treats. The gap is a clinical judgement call, so it is a runtime parameter stamped onto every row.",
  ct(list("therapeutic events", fm(nrow(TX[TX$treatment_intent %in% "Therapeutic", ]))),
     list("cases after collapse", fm(nrow(DZ))),
     list("treatments per case", sprintf("%.2f", nrow(TX[TX$treatment_intent %in% "Therapeutic", ])/nrow(DZ))),
     list("episode gap (days)", n0(DZ$case_gap_days[1]))),
  "yes")

D17 <- dec("outcome","disease_cases.parquet",
  paste0("Outcome is resolved from what happened AFTER the case; a death within ",
         n0(DZ$death_window_days[1]), " days is attributed to it"),
  "This is the half CattleMax does not record. A treatment log says what was given, not whether the animal lived. Undiagnosed therapeutic events are reported as 'Unknown disease' rather than dropped, so they still count against every rate.",
  ct(list("died", sum(DZ$outcome=="Died")), list("relapsed", sum(DZ$outcome=="Relapsed")),
     list("sold", sum(DZ$outcome=="Sold")), list("still here", sum(DZ$outcome=="Still here")),
     list("unknown disease", fm(sum(DZ$disease=="Unknown disease"))),
     list("death window (days)", n0(DZ$death_window_days[1]))),
  "yes")

D18 <- dec("transition","calf_fates.parquet",
  "A calf has SUCCEEDED when it becomes a product or a producer: sold, first calving, or first use as a sire",
  "What happens to that animal afterwards is its own record, not its dam's. An earlier version counted 46 heifers who calved and later died as calves their dams LOST, which penalised exactly the dams whose daughters were kept as replacements. A transition dated after the animal's exit is a record error, not a success, and is refused.",
  ct(list("sold", fm(sum(CF$outcome=="transitioned: sold"))),
     list("calved", fm(sum(CF$outcome=="transitioned: calved"))),
     list("used as sire", sum(CF$outcome=="transitioned: used as sire")),
     list("died after transitioning (NOT a loss)", sum(CF$transitioned & CF$c_status %in% "Dead")),
     list("transition dated after exit, refused", sum(CF$flag_transition_after_exit))),
  "yes")

D19 <- dec("preliminary","calf_fates.parquet",
  "Every calving reports its EXACT current status; one that can still change is flagged PRELIMINARY",
  "A calf alive and not yet sold or calved has no answer yet. Forcing it past an age threshold would either credit a calf that has not earned it or count a growing calf as lost. Rates are built on final outcomes only and preliminary seasons are carried alongside.",
  ct(list("final", fm(sum(CF$outcome_final))),
     list("preliminary", fm(sum(CF$outcome_stage=="preliminary"))),
     list("unknowable (calf has no animal record)", fm(sum(!CF$calf_in_animals))),
     list("lost at birth", sum(CF$loss_type %in% "at birth")),
     list("lost before weaning", sum(CF$loss_type %in% "before weaning")),
     list("lost after weaning", sum(CF$loss_type %in% "after weaning"))),
  "yes")

D20 <- dec("openslip","cow_scorecard.parquet",
  paste0("The calving hurdle is TWO signals: LEFT OPEN (terminal, only knowable once she has gone) and SLIPPED (an interval of ",
         n0(SC$long_interval_days[1]), "+ days, knowable for every cow)"),
  "A cow-season ends AT a calving, so a cow that skips a year does not produce a missed season - she produces one long one. Verified on this pull: every non-calving season is the cow's LAST one and none are mid-career. So 'no calf' only ever means she left open. For a cow still here it reads 'not yet', never 'no' - a zero would read as 'never missed' and be false.",
  ct(list("cows scored", fm(sum(SC$rankable))),
     list("still in the herd", fm(sum(SC$rankable & SC$here))),
     list("left open (closed records only)", fm(sum(SC$left_open[SC$rankable]))),
     list("slipped intervals", fm(sum(SC$slipped[SC$rankable]))),
     list("long-interval threshold (days)", n0(SC$long_interval_days[1]))),
  "yes")

D21 <- dec("scoreall","cow_scorecard.parquet",
  "EVERY cow with enough history is scored, gone or not; filtering to the herd is the report's job",
  "A revision that scored only active cows had to be reverted: it silently removed the calving hurdle entirely, because an active cow's open season is her current one and is right-censored out. A cow that has left carries the only complete calving record we will ever have of her.",
  ct(list("cows with a rate_ready season", fm(nrow(SC))),
     list("rankable", fm(sum(SC$rankable))),
     list("too little history to rank", fm(sum(!SC$rankable))),
     list("minimum final seasons", min(SC$final[SC$rankable]))),
  "yes")

D22 <- dec("ledger","exclusions.parquet",
  "NOTHING is silently discarded. Every record that leaves a table is recorded with what it was, why, how many, and whether a rule change could recover it",
  "A report that excludes records without naming them is not finished. This is a standing rule and it outranks tidiness: the ledger is what lets a number be argued with rather than taken on trust.",
  ct(list("distinct exclusion reasons", fm(nrow(EX))),
     list("records accounted for", fm(sum(num(EX$n_records)))),
     list("recoverable by a rule change", fm(sum(num(EX$n_records)[EX$recoverable %in% TRUE]))),
     list("tables covered", length(unique(EX$table)))),
  "yes")

## ---- flags, across every table that has them ----------------------------
fl <- function(df,tbl) { if (is.null(df)) return(character(0))
  f <- grep("^flag_", names(df), value=TRUE); if (!length(f)) return(character(0))
  sapply(f, function(x) kv(p("table",q(tbl)), p("flag",q(sub("^flag_","",x))),
                           p("n",num(sum(df[[x]], na.rm=TRUE))))) }
flags <- c(fl(A,"animals.parquet"), fl(CS,"cow_lactations.parquet"), fl(TX,"treatments.parquet"),
           fl(LO,"locations.parquet"), fl(PR,"phase_risk.parquet"),
           fl(DZ,"disease_cases.parquet"), fl(CF,"calf_fates.parquet"))

DECS <- c(D1,D2,D3,D4,D5,D6,D7,D8,D9,D10,D11,D12,D13,D14,D15,D16,D17,D18,D19,D20,D21,D22)
json <- kv(
  p("stages",    j(stages)),
  p("decisions", j(DECS)),
  p("flags",     j(flags)),
  p("herd",      q(cfg$herd)),
  p("pull",      q(cfg$pull)),
  p("pulled",    q(format(cfg$pull_date))),
  p("horizon",   q(hz)),
  p("generated", q(format(Sys.Date()))))

## ---- VALIDATE before writing. A malformed payload renders a blank page,
## and balanced braces do not prove a document parses.
ok <- TRUE
tryCatch({
  chk <- jsonlite::fromJSON(json, simplifyVector=FALSE)
  stopifnot(length(chk$stages)==length(stages),
            length(chk$decisions)==length(DECS),
            length(chk$flags)==length(flags))
  ## every `reads` must name a stage that exists, or the diagram draws an arrow
  ## from nowhere and the lineage is a lie
  ids <- vapply(chk$stages, function(s) s$id, character(1))
  bad <- setdiff(unlist(lapply(chk$stages, function(s) unlist(s$reads))), ids)
  if (length(bad)) stop("stage reads an unknown source: ", paste(bad, collapse=", "))
  cat("JSON parses OK - stages:", length(chk$stages),
      " decisions:", length(chk$decisions), " flags:", length(chk$flags), "\n")
}, error=function(e){ ok <<- FALSE; cat("*** JSON INVALID:", conditionMessage(e), "***\n") })
if (!ok) stop("refusing to write malformed lineage.json")

writeLines(json, file.path(OUT,"lineage.json"))
cat("wrote lineage.json  bytes:", nchar(json), "\n")

## ---- a silver table with no decision documented is a hole in this document
tabs <- c("animals.parquet","cow_lactations.parquet","treatments.parquet","locations.parquet",
          "phase_risk.parquet","disease_cases.parquet","calf_fates.parquet",
          "cow_scorecard.parquet","exclusions.parquet")
documented <- unique(vapply(strsplit(DECS, '"stage":"'), function(z)
  sub('".*$','', z[2]), character(1)))
missing <- setdiff(tabs, documented)
if (length(missing)) {
  cat("\n*** UNDOCUMENTED TABLES:", paste(missing, collapse=", "), "***\n")
} else {
  cat("every silver table has at least one documented decision\n")
}
