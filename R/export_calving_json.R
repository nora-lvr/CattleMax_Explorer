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
## Every animal with no value for a dimension used to vanish from `counts`,
## so the counts array did not sum to n and any legend built from it
## understated its buckets - silently. phase_now alone dropped 2,667 rows
## (it is NA for every Sold/Dead animal by construction). Blanks are now
## counted as their own level and named, per the "never drop silently" rule.
dim1 <- function(vals, blank="(not recorded)"){
  v  <- ifelse(is.na(vals) | vals=="", NA, vals)
  lv <- sort(unique(v[!is.na(v)]))
  idx <- match(v, lv); idx[is.na(idx)] <- length(lv) + 1L   # blanks -> last level
  lv <- c(lv, blank)
  list(lv=lv, idx=idx,
       counts=as.integer(table(factor(idx, levels=seq_along(lv)))),
       nblank=sum(is.na(v)))
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
## every dimension's counts must now account for all n rows
for (nm in c("phase","sex","status","cat","weaning")) {
  d <- get(c(phase="PH",sex="SEX",status="STA",cat="CAT",weaning="WS")[[nm]])
  stopifnot(sum(d$counts) == n)
  cat(sprintf("  %-8s levels=%-2d counts sum=%d of %d  (blank: %d)\n",
              nm, length(d$lv), sum(d$counts), n, d$nblank))
}
cat("phases:", paste(PH$lv, PH$counts, sep="=", collapse=" "), "\n")
cat("groups:", length(GN), "  categories:", length(CAT$lv), "\n")
