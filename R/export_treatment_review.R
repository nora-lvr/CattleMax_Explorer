## Export every raw treatment value + its current classification, for review.
options(width=200)
SILVER <- "C:/GIT/CattleMax_Explorer/data/silver-data"
OUT    <- "C:/GIT/CattleMax_Explorer/data/derived"
dir.create(OUT, showWarnings=FALSE, recursive=TRUE)
T <- as.data.frame(arrow::read_parquet(file.path(SILVER,"treatments.parquet")))

j  <- function(x) paste0("[", paste(x, collapse=","), "]")
qs <- function(x) paste0('"', gsub('\\\\','\\\\\\\\', gsub('"','\\\\"', ifelse(is.na(x),"",x))), '"')

## ---- medications ----
meds <- unique(T$medication)
mrow <- lapply(meds, function(m){
  s <- T[T$medication==m, ]
  dx <- sort(table(s$diagnosis), decreasing=TRUE)
  list(raw=m, n=nrow(s), animals=length(unique(s$animal_id)),
       cls=s$drug_class[1],
       intents=paste(sort(unique(s$treatment_intent)), collapse=" / "),
       withDx=sum(!is.na(s$diagnosis)),
       first=format(min(s$treatment_date)), last=format(max(s$treatment_date)),
       topdx=if(length(dx)) paste(utils::head(names(dx),3), collapse="; ") else "",
       route=paste(sort(unique(s$route[!is.na(s$route)])), collapse="/"))
})
mrow <- mrow[order(-sapply(mrow, function(z) z$n))]
mjson <- paste0("{",
  '"raw":',qs(sapply(mrow,`[[`,"raw")),',"n":',sapply(mrow,`[[`,"n"),
  ',"animals":',sapply(mrow,`[[`,"animals"),',"cls":',qs(sapply(mrow,`[[`,"cls")),
  ',"intents":',qs(sapply(mrow,`[[`,"intents")),',"withDx":',sapply(mrow,`[[`,"withDx"),
  ',"first":',qs(sapply(mrow,`[[`,"first")),',"last":',qs(sapply(mrow,`[[`,"last")),
  ',"topdx":',qs(sapply(mrow,`[[`,"topdx")),',"route":',qs(sapply(mrow,`[[`,"route")),"}")

## ---- diagnoses ----
D <- T[!is.na(T$diagnosis), ]
dxs <- unique(D$diagnosis)
drow <- lapply(dxs, function(d){
  s <- D[D$diagnosis==d, ]
  list(raw=d, n=nrow(s), animals=length(unique(s$animal_id)), cat=s$disease_category[1],
       topmed=paste(utils::head(names(sort(table(s$medication),decreasing=TRUE)),2), collapse="; "),
       phase=paste(names(sort(table(s$phase_at_treatment),decreasing=TRUE))[1]),
       first=format(min(s$treatment_date)), last=format(max(s$treatment_date)))
})
drow <- drow[order(-sapply(drow, function(z) z$n))]
djson <- paste0("{",
  '"raw":',qs(sapply(drow,`[[`,"raw")),',"n":',sapply(drow,`[[`,"n"),
  ',"animals":',sapply(drow,`[[`,"animals"),',"cat":',qs(sapply(drow,`[[`,"cat")),
  ',"topmed":',qs(sapply(drow,`[[`,"topmed")),',"phase":',qs(sapply(drow,`[[`,"phase")),
  ',"first":',qs(sapply(drow,`[[`,"first")),',"last":',qs(sapply(drow,`[[`,"last")),"}")

CLASSES  <- c("Antibiotic","Anti-inflammatory","Vaccine","Antiparasitic","Insecticide",
              "Supportive care","Repro hormone","Other treatment","Not a product","Unclassified")
INTENTS  <- c("Therapeutic","Routine / preventative","Supportive",
              "Reproductive management","Other treatment","Not a treatment","Unclassified")
DISEASES <- sort(unique(c(T$disease_category[!is.na(T$disease_category)],
              "Respiratory (BRD)","Ocular (pinkeye)","Lameness / foot","Enteric","Ear",
              "Navel / umbilical","Reproductive","Udder / mastitis","Bull breeding soundness",
              "Neurologic","Systemic / infectious","Injury / trauma","Nonspecific","Unclassified")))

json <- paste0('{"meds":[',paste(mjson,collapse=","),']',
  ',"dx":[',paste(djson,collapse=","),']',
  ',"classes":[',paste(qs(CLASSES),collapse=","),']',
  ',"intents":[',paste(qs(INTENTS),collapse=","),']',
  ',"diseases":[',paste(qs(DISEASES),collapse=","),']',
  ',"totalEvents":',nrow(T),',"noDx":',sum(is.na(T$diagnosis)),
  ',"herd":"River Creek Farms","pulled":"2026-07-29"}')
writeLines(json, file.path(OUT,"treatment_review.json"))
cat("wrote treatment_review.json  meds:",length(meds)," diagnoses:",length(dxs),
    " bytes:",nchar(json),"\n")
