## ---------------------------------------------------------------
## Configuration and path resolution.
##
## Nothing downstream may hard-code a path, a pull date, a herd name or a
## biological constant. Everything comes from here, so a second herd is a
## different argument rather than an edit across eight files.
##
##   source("R/config.R")
##   cfg <- cm_config()              # newest pull in data/
##   cfg <- cm_config(pull = "81258_joe_mertz_202607291020")
##   cfg <- cm_config(root = "D:/somewhere/else")
##
## Override the root from outside R with the CATTLEMAX_ROOT environment
## variable, e.g. for a scheduled run on a client machine.
## ---------------------------------------------------------------

## ---- repo root: walk up looking for the markers, never a literal ----
cm_root <- function(start = getwd()) {
  env <- Sys.getenv("CATTLEMAX_ROOT", "")
  if (nzchar(env)) {
    if (!dir.exists(env)) stop("CATTLEMAX_ROOT is set but does not exist: ", env)
    return(normalizePath(env, winslash = "/", mustWork = TRUE))
  }
  p <- normalizePath(start, winslash = "/", mustWork = FALSE)
  repeat {
    if (file.exists(file.path(p, "PLAN.md")) && dir.exists(file.path(p, "R"))) return(p)
    up <- dirname(p)
    if (identical(up, p)) break
    p <- up
  }
  stop("Could not find the repo root from '", start,
       "'. Run from inside the repo, or set CATTLEMAX_ROOT.")
}

## ---- which pull are we building? ----
## A CattleMax export folder is {accountid}_{name}_{YYYYMMDDHHMM}.
cm_pulls <- function(root = cm_root()) {
  d <- file.path(root, "data")
  if (!dir.exists(d)) stop("no data/ directory under ", root)
  f <- list.dirs(d, recursive = FALSE, full.names = FALSE)
  f <- f[grepl("^[0-9]+_.+_[0-9]{12}$", f)]
  f[order(sub("^.*_([0-9]{12})$", "\\1", f))]      # oldest -> newest
}

cm_pull_date <- function(pull) {
  ts <- sub("^.*_([0-9]{12})$", "\\1", pull)
  as.Date(as.POSIXct(ts, format = "%Y%m%d%H%M", tz = "UTC"))
}
cm_pull_account <- function(pull) sub("^([0-9]+)_.*$", "\\1", pull)

## ---- herd registry: account id -> display name and brand ----
## Lives in the repo (config/herds.csv), never in data/, so it ships with the
## code. Unknown accounts fall back to the folder name rather than failing.
cm_herd <- function(pull, root = cm_root()) {
  acct <- cm_pull_account(pull)
  f <- file.path(root, "config", "herds.csv")
  fallback <- list(account_id = acct,
                   display_name = gsub("_", " ", sub("^[0-9]+_(.+)_[0-9]{12}$", "\\1", pull)),
                   brand_hex = "#3a3634", brand_deep_hex = "#1d1d1d")
  if (!file.exists(f)) return(fallback)
  h <- utils::read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
  row <- h[h$account_id == acct, , drop = FALSE]
  if (!nrow(row)) return(fallback)
  as.list(row[1, ])
}

## ---- the one object every script uses ----
cm_config <- function(pull = NULL, root = NULL, pull_date = NULL) {
  root <- if (is.null(root)) cm_root() else normalizePath(root, winslash = "/", mustWork = TRUE)
  all  <- cm_pulls(root)
  if (!length(all)) stop("No CattleMax export folders found in ", file.path(root, "data"),
                         ". Expected {accountid}_{name}_{YYYYMMDDHHMM}.")
  if (is.null(pull)) pull <- tail(all, 1)                    # newest by default
  if (!pull %in% all) stop("Pull '", pull, "' not found. Available: ", paste(all, collapse = ", "))

  herd <- cm_herd(pull, root)
  pd   <- if (is.null(pull_date)) cm_pull_date(pull) else as.Date(pull_date)

  cfg <- list(
    root      = root,
    pull      = pull,
    pull_dir  = file.path(root, "data", pull),
    silver    = file.path(root, "data", "silver-data"),
    derived   = file.path(root, "data", "derived"),
    reports   = file.path(root, "reports", "templates"),
    pull_date = pd,
    account   = cm_pull_account(pull),
    herd      = herd$display_name,
    brand     = herd$brand_hex,
    brand_deep= herd$brand_deep_hex,
    all_pulls = all,
    ## ---- biological / rule constants, one definition each ----
    ## NOT YET VALIDATED BY NORA - see PLAN.md 8 and BACKLOG Set 4.
    gestation_days     = 283,   # industry figure; this herd's observed median is 266
    twin_window_days   = 7,     # calves within this of the cluster start are one calving
    wean_fallback_days = 205,   # conventional weaning age
    wean_assume_age_mo = 8,     # older than this with no record => assume weaned
    explorer_from      = as.Date("2013-01-01")  # earliest year shown in the explorer
  )
  dir.create(cfg$silver,  showWarnings = FALSE, recursive = TRUE)
  dir.create(cfg$derived, showWarnings = FALSE, recursive = TRUE)
  cfg
}

cm_announce <- function(cfg) {
  if (isTRUE(get0(".cm_announced", envir = globalenv()))) return(invisible(NULL))
  cat("herd      :", cfg$herd, "(account", cfg$account, ")\n")
  cat("pull      :", cfg$pull, "\n")
  cat("pull date :", format(cfg$pull_date), "\n")
  cat("root      :", cfg$root, "\n")
  if (length(cfg$all_pulls) > 1)
    cat("note      :", length(cfg$all_pulls), "pulls available; building the newest\n")
  cat("\n")
}
