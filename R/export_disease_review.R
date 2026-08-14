## Export the disease groupings + their clinical consequences, for review.
options(width=210)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
TX <- cm_read_silver(cfg, "treatments")
C  <- cm_read_silver(cfg, "disease_cases")
PR <- cm_read_silver(cfg, "phase_risk")

## ---- level 1: raw diagnosis -> disease category --------------------------
D <- TX[TX$treatment_intent %in% "Therapeutic", ]
D$dx  <- ifelse(is.na(D$diagnosis), "(no diagnosis recorded)", D$diagnosis)
D$cat <- ifelse(is.na(D$disease_category), "Unknown disease", D$disease_category)
raw <- lapply(sort(unique(D$dx)), function(x){
  s <- D[D$dx == x, ]
  list(raw=x, cat=s$cat[1], events=nrow(s), animals=length(unique(s$animal_id)),
       first=format(min(s$treatment_date)), last=format(max(s$treatment_date)),
       drugs=paste(head(names(sort(table(s$active_substance), decreasing=TRUE)),3), collapse="; "),
       phase=names(sort(table(s$phase_at_treatment), decreasing=TRUE))[1])
})
raw <- raw[order(-sapply(raw, `[[`, "events"))]

## ---- level 2: the disease category itself, with outcomes -----------------
cats <- sort(unique(C$disease))
cat_rows <- lapply(cats, function(k){
  s <- C[C$disease == k, ]
  ph <- sort(table(s$phase_at_onset), decreasing=TRUE)
  list(cat=k, cases=nrow(s), animals=length(unique(s$animal_id)),
       fatal=sum(s$case_fatal),
       cfr=round(100*mean(s$case_fatal),1),
       relapsed=sum(s$outcome=="Relapsed"),
       median_tx=median(s$n_treatments),
       med_day=round(median(s$day_of_phase, na.rm=TRUE)),
       top_phase=if(length(ph)) names(ph)[1] else "",
       drugs=paste(head(names(sort(table(s$substances), decreasing=TRUE)),2), collapse="; "))
})
cat_rows <- cat_rows[order(-sapply(cat_rows, `[[`, "cases"))]

CATS <- sort(unique(c(cats, "Respiratory (BRD)","Ocular (pinkeye)","Lameness / foot","Enteric",
  "Ear","Navel / umbilical","Reproductive","Udder / mastitis","Bull breeding soundness",
  "Neurologic","Systemic / infectious","Injury / trauma","Nonspecific","Unknown disease")))

emit <- function(l) jobj(paste(mapply(function(k,v)
  jp(k, if (is.numeric(v)) v else jq(v)), names(l), l), collapse=","))

json <- jobj(
  jp("raw",  jarr(vapply(raw, emit, character(1)))),
  jp("cats", jarr(vapply(cat_rows, emit, character(1)))),
  jp("categories", jarr(jq(CATS))),
  jp("totalCases", nrow(C)),
  jp("totalEvents", nrow(D)),
  jp("noDx", sum(D$dx == "(no diagnosis recorded)")),
  jp("caseGap", C$case_gap_days[1]),
  jp("deathWindow", C$death_window_days[1]),
  jp("herd", jq(cfg$herd)), jp("pulled", jq(format(cfg$pull_date))))
cm_write_json(json, file.path(cfg$derived, "disease_review.json"),
              expect = list(raw = length(raw), cats = length(cat_rows)))
cat("raw diagnoses:", length(raw), " disease categories:", length(cat_rows), "\n")
