## Emit live counts for the data-flow document, so the diagram can never
## drift from what the pipeline actually did. Run after the three builds.
options(width=200)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
OUT <- cfg$derived
dir.create(OUT, showWarnings=FALSE, recursive=TRUE)
rd  <- function(f) cm_read(cfg, f)
d10 <- function(x) as.Date(substr(x,1,10))
q   <- function(x) paste0('"', gsub('"','\\\\"', ifelse(is.na(x),"",as.character(x))), '"')
j   <- function(x) paste0("[", paste(x, collapse=","), "]")
## p() builds ONE "key":value pair. kv() joins pairs with commas.
## Passing the key, a ":" and the value as three separate args to kv() emits
## "key", : ,value - malformed JSON that renders a blank page. Use p().
p   <- function(k, v) paste0(q(k), ":", v)
kv  <- function(...) paste0("{", paste(c(...), collapse=","), "}")
num <- function(x) { x <- suppressWarnings(as.numeric(x)); ifelse(is.na(x), 0, x) }

A  <- cm_read_silver(cfg, "animals")
CS <- cm_read_silver(cfg, "cows")
TX <- cm_read_silver(cfg, "treatments")
a  <- rd("animals.csv"); br <- rd("breedings.csv"); tx <- rd("treatments.csv")

## ---- stage counts ----
raw_animals <- nrow(a)
ref         <- sum(a$status %in% "Reference")
stages <- list(
  kv(p("id",q("raw")),        p("label",q("animals.csv")),        p("n",raw_animals),     p("note",q("every row CattleMax exported"))),
  kv(p("id",q("nonref")),     p("label",q("non-Reference")),      p("n",raw_animals-ref), p("note",q(paste0(format(ref,big.mark=",")," Reference rows removed")))),
  kv(p("id",q("animals")),    p("label",q("animals.parquet")),    p("n",nrow(A)),         p("note",q(paste0(ncol(A)," columns, one row per animal")))),
  kv(p("id",q("cows")),       p("label",q("cows.parquet")),       p("n",nrow(CS)),        p("note",q(paste0(length(unique(CS$animal_id))," females, one row per season")))),
  kv(p("id",q("treatments")), p("label",q("treatments.parquet")), p("n",nrow(TX)),        p("note",q(paste0(length(unique(TX$animal_id))," animals, one row per event"))))
)

## ---- every decision, with live counts ----
dec <- function(id, stage, rule, detail, counts, validated)
  kv(p("id",q(id)), p("stage",q(stage)), p("rule",q(rule)),
     p("detail",q(detail)), p("counts",counts), p("validated",q(validated)))
ct <- function(...) paste0("[", paste(sapply(list(...), function(z)
        kv(p("k",q(z[[1]])), p("v",q(z[[2]])))), collapse=","), "]")

D1 <- dec("reference","Filter",
  "Exclude status == Reference",
  "Reference animals are pedigree back-fill, not animals that were present. They are excluded from presence but STILL used as calving events and as sires.",
  ct(list("Reference rows removed", format(ref,big.mark=",")),
     list("share of the export", sprintf("%.0f%%", 100*ref/raw_animals)),
     list("still used as calf records", format(sum(a$status %in% "Reference" & !is.na(a$birth_date) & !is.na(a$dam_animal_id)),big.mark=","))),
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

D6 <- dec("dam","cows.parquet",
  "dam_animal_id is the CARRIER. real_dam / genetic_dam is the DONOR and must never be used",
  "For ET calves real_dam equals genetic_dam in 453 of 458 cases. Using it credits donors with their recipients' calvings and made a 314-head recipient herd look barren, understating one season from 76.5% to 44.7% calved.",
  ct(list("calves linked via carrier", format(sum(CS$dam_link_source %in% "dam_animal_id(carrier)"),big.mark=",")),
     list("real_dam fallback used", sum(CS$dam_link_source %in% "real_dam(fallback)")),
     list("calves with no carrier, dropped", sum(is.na(a$dam_animal_id) & !is.na(a$real_dam_animal_id) & !is.na(a$birth_date)))),
  "yes")

D7 <- dec("twins","cows.parquet",
  "Calves born within 7 days of the cluster's FIRST calf are ONE calving event",
  "The window is measured from the cluster start, not the previous calf, or runs chain into one 34-day 'birth'. The collapsed event date is written back onto every calf row, or multiples re-expand into separate seasons and inflate calf counts.",
  ct(list("calf records", format(sum(!is.na(a$dam_animal_id) & !is.na(a$birth_date)),big.mark=",")),
     list("calving events after collapse", format(sum(CS$calved),big.mark=",")),
     list("events with >1 calf", sum(CS$n_calves_born>1, na.rm=TRUE)),
     list("flagged implausible (>3)", sum(CS$flag_implausible_multiple, na.rm=TRUE))),
  "partly")

D8 <- dec("season","cows.parquet",
  "A cow-season ENDS at each calving; the next begins there. Season 1 opens at first bull exposure",
  "Windows are half-open [start, end) so a service on a calving date belongs to the next season only. Season 1 falls back to entry when there is no breeding record.",
  ct(list("cow-seasons", format(nrow(CS),big.mark=",")),
     list("ended in a calving", format(sum(CS$calved),big.mark=",")),
     list("exited without calving", sum(CS$outcome=="Exited without calving")),
     list("open at the pull", sum(CS$outcome=="Open at pull date"))),
  "yes")

D9 <- dec("denominators","cows.parquet",
  "Two denominators: EXPOSED (every female served) and RETAINED (still present at her due date)",
  "The exposed basis carries attrition as a cost; the retained basis isolates the females that could actually calve. The gap between them is the attrition itself.",
  ct(list("exposed seasons", format(sum(!is.na(CS$first_service)),big.mark=",")),
     list("lost before calving", sum(CS$lost_before_calving, na.rm=TRUE)),
     list("retained to due date", format(sum(CS$retained_to_due, na.rm=TRUE),big.mark=","))),
  "yes")

hz <- format(CS$record_horizon[1])
D10 <- dec("horizon","cows.parquet",
  paste0("Record horizon ", hz, ": anything opening earlier is left-censored"),
  "CattleMax recording began only a few years ago and earlier births are pedigree back-fill, so the start of the record is ragged and must never be silently averaged in.",
  ct(list("left-censored seasons", format(sum(CS$flag_left_censored),big.mark=",")),
     list("right-censored (open at pull)", format(sum(CS$flag_right_censored),big.mark=",")),
     list("parity unknown", sum(CS$flag_parity_unknown)),
     list("rate_ready", format(sum(CS$rate_ready),big.mark=",")),
     list("interval_ready", format(sum(CS$interval_ready),big.mark=","))),
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

## ---- flags ----
fl <- function(df,tbl) paste(sapply(grep("^flag_", names(df), value=TRUE), function(f)
        kv(p("table",q(tbl)), p("flag",q(sub("^flag_","",f))),
           p("n",num(sum(df[[f]], na.rm=TRUE))))), collapse=",")
flags <- paste(fl(A,"animals.parquet"), fl(CS,"cows.parquet"), fl(TX,"treatments.parquet"), sep=",")

json <- kv(
  p("stages",    j(unlist(stages))),
  p("decisions", j(c(D1,D2,D3,D4,D5,D6,D7,D8,D9,D10,D11,D12))),
  p("flags",     paste0("[", flags, "]")),
  p("herd",      q("River Creek Farms")),
  p("pull",      q("81258_joe_mertz_202607291020")),
  p("pulled",    q("2026-07-29")),
  p("horizon",   q(hz)),
  p("generated", q(format(Sys.Date()))))

## ---- VALIDATE before writing. A malformed payload renders a blank page,
## and balanced braces do not prove a document parses.
ok <- TRUE
tryCatch({
  chk <- jsonlite::fromJSON(json, simplifyVector=FALSE)
  stopifnot(length(chk$stages)==5, length(chk$decisions)==12, length(chk$flags)>0)
  cat("JSON parses OK - stages:", length(chk$stages),
      " decisions:", length(chk$decisions), " flags:", length(chk$flags), "\n")
}, error=function(e){ ok <<- FALSE; cat("*** JSON INVALID:", conditionMessage(e), "***\n") })
if (!ok) stop("refusing to write malformed lineage.json")

writeLines(json, file.path(OUT,"lineage.json"))
cat("wrote lineage.json  bytes:", nchar(json), "\n")
