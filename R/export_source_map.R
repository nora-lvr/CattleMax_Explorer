## ---------------------------------------------------------------
## source_map.json : what CattleMax actually gives us, and how it joins.
##
## Scans EVERY csv in the pull, records row counts, column fill rates, and
## infers the foreign keys by matching *_id columns against other tables'
## primary keys. Nothing here is hand-written, so a pull with different files
## produces a different map rather than a stale one.
## ---------------------------------------------------------------
options(width=200)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
q  <- function(x) paste0('"', gsub('"','\\\\"', ifelse(is.na(x),"",as.character(x))), '"')
j  <- function(x) paste0("[", paste(x, collapse=","), "]")
p  <- function(k,v) paste0(q(k), ":", v)
kv <- function(...) paste0("{", paste(c(...), collapse=","), "}")

files <- sort(list.files(cfg$pull_dir, pattern="\\.csv$"))
cat("csv files in the pull:", length(files), "\n")

## ---- read every file once ----------------------------------------------
TB <- list()
for (f in files) {
  d <- tryCatch(cm_read(cfg, f), error=function(e) NULL)
  if (is.null(d)) { cat("  unreadable:", f, "\n"); next }
  TB[[sub("\\.csv$","",f)]] <- d
}
cat("read:", length(TB), "tables\n")

## ---- which tables are worth drawing? -----------------------------------
## An empty table is still reported - it is a fact about the pull, not noise.
nm <- names(TB)

## ---- infer joins --------------------------------------------------------
## A column named <x>_id joins the table whose singular name is <x>. animal_id
## is the spine. We only claim a join when the values actually match, so a
## coincidence of naming cannot invent a relationship.
singular <- function(s) sub("s$","", s)
tbl_for <- function(col) {
  base <- sub("_id$","", col)
  hit <- nm[vapply(nm, function(t) singular(t) == base || t == base, logical(1))]
  if (length(hit)) return(hit[1])
  ## common aliases where the column names a ROLE, not the table
  al <- c(animal="animals", bull_animal="animals", dam_animal="animals",
          sire_animal="animals", real_dam_animal="animals",
          genetic_dam_animal="animals", recipient_animal="animals",
          donor_animal="animals", calf_animal="animals",
          category="categories", location="locations", pasture="locations",
          group="groups", grouping="groupings", breeding="breedings",
          treatment="treatments", embryo="embryos", flush="flushes",
          pregnancy_check="pregnancy_checks", sale_ticket="sale_tickets",
          measurement="measurements", movement="movements")
  if (base %in% names(al) && al[[base]] %in% nm) return(al[[base]])
  NA_character_
}
edges <- list(); cols <- list()
for (t in nm) {
  d <- TB[[t]]
  for (c in names(d)) {
    fill <- if (!nrow(d)) 0 else round(100*mean(!is.na(d[[c]]) & nzchar(d[[c]])))
    cols[[length(cols)+1]] <- kv(p("table",q(t)), p("col",q(c)), p("fill",fill),
      p("uniq", if (!nrow(d)) 0 else length(unique(d[[c]]))))
    if (!grepl("_id$", c) || c == "id") next
    tgt <- tbl_for(c)
    if (is.na(tgt) || tgt == t) next
    if (!"id" %in% names(TB[[tgt]])) next
    v <- d[[c]]; v <- v[!is.na(v) & nzchar(v)]
    if (!length(v)) next
    hit <- mean(v %in% TB[[tgt]]$id)
    ## demand that the values really land in the target's keys
    if (hit < 0.5) next
    edges[[length(edges)+1]] <- kv(p("from",q(t)), p("to",q(tgt)), p("via",q(c)),
      p("n",length(v)), p("match",round(100*hit)))
  }
}

## ---- table summaries ----------------------------------------------------
## `used` marks the files the pipeline actually reads today, so the map shows
## what is exploited and what is sitting untouched.
USED <- c("animals","movements","treatments","breedings","measurements",
          "sale_tickets","groupings","groups","categories","pregnancy_checks",
          "embryos","flushes")
tables <- lapply(nm, function(t) {
  d <- TB[[t]]
  anim <- intersect(c("animal_id","bull_animal_id","dam_animal_id"), names(d))
  kv(p("name",q(t)), p("rows",nrow(d)), p("cols",ncol(d)),
     p("used", if (t %in% USED) "true" else "false"),
     p("animals", if (length(anim)) length(unique(d[[anim[1]]][!is.na(d[[anim[1]]])])) else 0),
     p("keyCols", j(vapply(grep("_id$|^id$", names(d), value=TRUE), q, character(1)))))
})

json <- kv(p("tables", j(unlist(tables))),
           p("edges",  j(unlist(edges))),
           p("columns",j(unlist(cols))),
           p("herd",   q(cfg$herd)), p("pull", q(cfg$pull)),
           p("pulled", q(format(cfg$pull_date))),
           p("nFiles", length(files)),
           p("generated", q(format(Sys.Date()))))
cm_write_json(json, file.path(cfg$derived,"source_map.json"),
              expect=list(tables=length(tables), edges=length(edges)))
cat("tables:", length(tables), " joins found:", length(edges),
    " columns:", length(cols), "\n")
cat("\nlargest tables:\n")
sz <- sort(vapply(TB, nrow, numeric(1)), decreasing=TRUE)
print(utils::head(sz, 15))
cat("\nempty tables:", paste(names(sz)[sz==0], collapse=", "), "\n")
