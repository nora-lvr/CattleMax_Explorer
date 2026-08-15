## ---------------------------------------------------------------
## Build every silver table for one herd, in dependency order.
##
##   Rscript R/run_pipeline.R                     # newest pull in data/
##   Rscript R/run_pipeline.R <pull-folder-name>  # a specific pull
##
## Nothing in the pipeline knows a path, a herd name or a pull date: they all
## come from R/config.R, so a second herd is an argument rather than an edit.
## ---------------------------------------------------------------
options(width = 220)
source(file.path("R", "config.R"))
source(file.path("R", "common.R"))

args <- commandArgs(trailingOnly = TRUE)
cfg  <- cm_config(pull = if (length(args)) args[1] else NULL)

cat(strrep("=", 78), "\n")
cat("CattleMax Explorer pipeline\n")
cat(strrep("=", 78), "\n")
cm_announce(cfg)

steps <- c(
  "check_data.R",        # has the export changed shape? (schema only - see below)
  "build_animals.R",     # one row per animal; everything else reads it
  "build_cows.R",        # one row per cow-season
  "build_bulls.R",       # one row per bull
  "build_treatments.R",  # one row per treatment event
  "build_locations.R",   # one row per animal-location interval (the group half)
  "build_phase_risk.R",  # one row per animal-phase: the producer-facing denominator
  "build_disease.R",     # one row per disease case, with its outcome
  "build_cow_scorecard.R",   # one row per calving on the outcome ladder, one per cow
  "export_disease_review.R", # the editable disease grouping sheet
  "export_lineage.R",    # the data-flow document's live counts
  "check_data.R"         # FINAL GATE: every column traces, nothing unapproved ships
)

## The step scripts run in the global environment and freely use short names
## like `s`, `i`, `d`. Keep the runner's own state in dotted names it will
## never collide with, and stash the timing where a step cannot overwrite it.
.cm_t0 <- Sys.time()
.cm_announced <- TRUE          # steps skip their own banner once this is set
for (.cm_i in seq_along(steps)) {
  .cm_step <- steps[.cm_i]
  ## check_data.R runs twice. The first pass is BEFORE anything is built, so it
  ## can only ask whether the export changed shape; the last pass checks the
  ## output. Sourcing cannot pass arguments, so the mode goes in a variable.
  if (.cm_step == "check_data.R" && .cm_i == 1) CHECK_MODE <- "schema"
  cat("\n", strrep("-", 78), "\n", sep = "")
  cat("STEP ", .cm_i, "/", length(steps), ": ", .cm_step, "\n", sep = "")
  cat(strrep("-", 78), "\n", sep = "")
  assign(".cm_t1", Sys.time(), envir = globalenv())
  source(file.path("R", .cm_step), local = FALSE)
  .cm_step <- steps[.cm_i]     # re-read: a step may have clobbered it
  cat(sprintf("\n[%s finished in %.1f s]\n", .cm_step,
              as.numeric(difftime(Sys.time(), get(".cm_t1", envir = globalenv()), units = "secs"))))
}

cat("\n", strrep("=", 78), "\n", sep = "")
cat(sprintf("pipeline complete in %.1f s\n",
            as.numeric(difftime(Sys.time(), get(".cm_t0", envir = globalenv()), units = "secs"))))
cat("silver tables in ", cfg$silver, ":\n", sep = "")
for (f in list.files(cfg$silver, "\\.parquet$", full.names = TRUE))
  cat(sprintf("  %-24s %6.0f KB\n", basename(f), file.size(f) / 1024))
cat("\nExclusions ledger: ", file.path(cfg$silver, "exclusions.parquet"), "\n", sep = "")
cat("Nothing is dropped without a row in it.\n")
