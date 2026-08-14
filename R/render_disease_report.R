## ---------------------------------------------------------------
## Inline disease_report.json into a template -> one self-contained HTML.
## No external requests, safe to email.
##
##   Rscript R/render_disease_report.R
##       full herd health report
##   Rscript R/render_disease_report.R trend_report.html river_creek_trend.html
##       the trend-only sub-report, same numbers, same JSON
##   Rscript R/render_disease_report.R <template> <output> <json>
##
## A sub-report template may carry <!--__STYLE__--> instead of its own CSS; the
## <style> block is then taken from disease_report.html, so the styling has one
## source of truth and the two reports can never drift apart visually.
## ---------------------------------------------------------------
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
.a <- commandArgs(trailingOnly = TRUE)
TPL  <- if (length(.a) >= 1) .a[1] else "disease_report.html"
OUT  <- if (length(.a) >= 2) .a[2] else "river_creek_disease_report.html"
JSON <- if (length(.a) >= 3) .a[3] else "disease_report.json"

rd <- function(p) readChar(p, file.info(p)$size, useBytes = TRUE)
jf <- file.path(cfg$derived, JSON)
tf <- file.path(cfg$reports, TPL)
stopifnot(file.exists(jf), file.exists(tf))

j <- rd(jf)
invisible(jsonlite::fromJSON(j))          # never inline JSON that does not parse
tpl <- rd(tf)

## shared stylesheet, lifted from the main template
if (grepl("<!--__STYLE__-->", tpl, fixed = TRUE)) {
  main <- rd(file.path(cfg$reports, "disease_report.html"))
  sty  <- regmatches(main, regexpr("(?s)<style>.*?</style>", main, perl = TRUE))
  stopifnot(length(sty) == 1L, nchar(sty) > 500)
  tpl <- sub("<!--__STYLE__-->", sty, tpl, fixed = TRUE)
  cat("styled from disease_report.html (", nchar(sty), "chars )\n")
}

stopifnot(grepl("/*__DATA__*/", tpl, fixed = TRUE))
html <- sub("/*__DATA__*/", j, tpl, fixed = TRUE)

of <- file.path(cfg$derived, OUT)
writeLines(html, of, useBytes = TRUE)
cat("wrote", of, " KB:", round(file.info(of)$size/1024), "\n")
