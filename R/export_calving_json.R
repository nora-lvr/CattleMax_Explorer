## Export the explorer's JSON from the SILVER parquet - the single substrate.
SILVER <- "C:/GIT/CattleMax_Explorer/data/silver-data/animals.parquet"
OUT    <- "C:/Users/lives/AppData/Local/Temp/claude/C--GIT-CattleMax-Explorer/2076ae99-6a88-45b1-927a-6cdd341f08b4/scratchpad"
M <- as.data.frame(arrow::read_parquet(SILVER))
cat("read", nrow(M), "animals from silver parquet\n")

BASE <- as.Date("2013-01-01")
C <- M[!is.na(M$birth_date) & M$birth_date >= BASE, ]
C <- C[order(C$birth_date), ]
n <- nrow(C); cat("calves born", format(BASE), "or later:", n, "\n")

j  <- function(x) paste0("[", paste(x, collapse=","), "]")
qs <- function(x) paste0('"', gsub('"','\\\\"', x), '"')
dim1 <- function(vals){
  lv <- sort(unique(vals[!is.na(vals) & vals!=""]))
  idx <- match(vals, lv); idx[is.na(idx)] <- 0
  list(lv=lv, idx=idx, counts=as.integer(table(factor(idx, levels=seq_along(lv)))))
}
emit <- function(d) paste0('{"idx":', j(d$idx), ',"names":[', paste(qs(d$lv),collapse=","),
                           '],"counts":', j(d$counts), '}')

PH  <- dim1(C$phase_now)
SEX <- dim1(C$sex)
STA <- dim1(C$status)
CAT <- dim1(C$category_name)
WS  <- dim1(C$weaning_source)

## groups: multi-valued, so emit member index lists
gsplit <- strsplit(ifelse(is.na(C$group_names),"",C$group_names), "; ", fixed=TRUE)
GN <- sort(unique(unlist(gsplit))); GN <- GN[GN!=""]
gmem <- lapply(GN, function(nm) which(vapply(gsplit, function(v) nm %in% v, logical(1))) - 1L)

flagcols <- grep("^flag_", names(C), value=TRUE)
flags <- paste0('{', paste(sprintf('%s:%d', qs(sub("^flag_","",flagcols)),
                 sapply(flagcols, function(f) sum(C[[f]], na.rm=TRUE))), collapse=","), '}')

json <- paste0('{',
  '"base":"2013-01-01","n":', n,
  ',"t":',   j(as.integer(C$birth_date - BASE)),
  ',"doy":', j(as.integer(format(C$birth_date,"%j"))),
  ',"yr":',  j(as.integer(format(C$birth_date,"%Y"))),
  ',"years":', j(sort(unique(as.integer(format(C$birth_date,"%Y"))))),
  ',"phase":',  emit(PH),
  ',"sex":',    emit(SEX),
  ',"status":', emit(STA),
  ',"cat":',    emit(CAT),
  ',"weaning":',emit(WS),
  ',"groups":{"names":[', paste(qs(GN),collapse=","), ']',
      ',"counts":', j(sapply(gmem,length)),
      ',"members":[', paste(sapply(gmem, j), collapse=","), ']}',
  ',"flags":', flags,
  ',"herd":"River Creek Farms"',
  ',"pull":"81258_joe_mertz_202607291020","pulled":"2026-07-29"',
  ',"source":"data/silver-data/animals.parquet"}')

writeLines(json, file.path(OUT,"calving3.json"))
cat("wrote calving3.json  bytes:", nchar(json), "\n")
cat("phases:", paste(PH$lv, PH$counts, sep="=", collapse=" "), "\n")
cat("groups:", length(GN), "  categories:", length(CAT$lv), "\n")
