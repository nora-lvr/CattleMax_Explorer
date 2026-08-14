## ---------------------------------------------------------------
## locations.parquet : one row per ANIMAL-LOCATION INTERVAL.
##
## This is the missing half of the Phase-1 goal. PLAN.md 6 defines the
## substrate as "who was present, IN WHICH GROUP, on which date". Presence was
## already reconstructed; this reconstructs the group half from the 69,973
## dated pasture moves that were previously collapsed to two dates.
##
## It is also the DENOMINATOR for disease incidence: a rate needs animal-time
## at risk, and animal-time is only meaningful within a location.
##
## Grain: [from_date, to_date) per animal per pasture. Intervals never overlap
## and never extend beyond the animal's presence interval.
## ---------------------------------------------------------------
options(width=220)
if (!exists("cfg")) {
  source(file.path("R","config.R")); source(file.path("R","common.R"))
  cfg <- cm_config()
}
cm_announce(cfg)
rd   <- function(f) cm_read(cfg, f)
PULL <- cfg$pull_date
source(file.path(cfg$root,"R","exclusions.R")); excl_reset()

A  <- cm_read_silver(cfg, "animals")
mv <- rd("movements.csv")
pa <- rd("pastures.csv")

mv$date <- d10(mv$movement_date)
mv <- mv[!is.na(mv$date) & !is.na(mv$animal_id), ]
cat("movement rows with a date:", nrow(mv), " animals:", length(unique(mv$animal_id)), "\n")

## keep only animals that are in the substrate (Reference already excluded)
in_sub <- mv$animal_id %in% A$animal_id
excl_add("locations.parquet", "movement of a Reference animal",
         sum(!in_sub), n_animals = length(unique(mv$animal_id[!in_sub])),
         detail = "Reference animals are pedigree back-fill and are not present",
         recoverable = FALSE)
mv <- mv[in_sub, ]

## pasture lookup
pname  <- setNames(pa$name, pa$id)
pacres <- setNames(num(pa$acres_grazeable), pa$id)
ppremises <- setNames(pa$premises_id, pa$id)

## ---- build intervals -----------------------------------------------------
## A move ENDS the current interval and STARTS a new one in moved_to_pasture.
## moved_from_pasture_id == "0" marks a first arrival, not a real origin.
mv <- mv[order(mv$animal_id, mv$date, mv$id), ]
ent <- setNames(A$entry_date, A$animal_id)
ext <- setNames(A$exit_date,  A$animal_id)

rows <- list()
n_zero <- 0L; n_clipped <- 0L
for (ix in split(seq_len(nrow(mv)), mv$animal_id)) {
  aid <- mv$animal_id[ix[1]]
  d   <- mv$date[ix]
  to  <- mv$moved_to_pasture_id[ix]
  ## an animal can be moved twice on one day (a correction, or a staged move):
  ## keep the LAST destination recorded for that day
  keep <- !duplicated(d, fromLast = TRUE)
  d <- d[keep]; to <- to[keep]
  a_exit  <- ext[[aid]]; a_entry <- ent[[aid]]
  ## interval i runs from move i until the next move, or until she leaves
  starts <- d
  ends   <- c(d[-1] - 1, if (!is.na(a_exit)) a_exit else PULL)
  for (i in seq_along(starts)) {
    s <- starts[i]; e <- ends[i]
    ## never let a location interval outlive the animal's presence
    if (!is.na(a_exit) && e > a_exit) { e <- a_exit; n_clipped <- n_clipped + 1L }
    if (is.na(s) || is.na(e) || e < s) { n_zero <- n_zero + 1L; next }
    rows[[length(rows) + 1]] <- data.frame(
      animal_id  = aid,
      pasture_id = to[i],
      from_date  = s,
      to_date    = e,
      days       = as.numeric(e - s) + 1,
      seq        = i,
      is_last    = i == length(starts),
      stringsAsFactors = FALSE)
  }
}
L <- do.call(rbind, rows)
L$pasture_name  <- unname(pname[L$pasture_id])
L$acres_grazeable <- unname(pacres[L$pasture_id])
L$premises_id   <- unname(ppremises[L$pasture_id])

## carry the animal context a disease report needs, so this table stands alone
m <- match(L$animal_id, A$animal_id)
L$sex        <- A$sex[m]
L$birth_date <- A$birth_date[m]
L$entry_date <- A$entry_date[m]
L$exit_date  <- A$exit_date[m]
L$age_days_at_start <- as.numeric(L$from_date - L$birth_date)
## phase on the day the interval STARTED, from the stored phase boundaries
ph <- rep(NA_character_, nrow(L))
liv <- !is.na(A$entry_date[m]) & A$entry_date[m] <= L$from_date
ph[liv] <- "Calf"
ph[liv & !is.na(A$growing_start[m]) & A$growing_start[m] <= L$from_date] <- "Growing"
ph[liv & !is.na(A$sire_start[m])    & A$sire_start[m]    <= L$from_date] <- "Breeding"
ph[liv & !is.na(A$cow_start[m])     & A$cow_start[m]     <= L$from_date] <- "Cow"
L$phase_at_start <- ph

## ---- flags ---------------------------------------------------------------
L$flag_no_pasture_name <- is.na(L$pasture_name)
L$flag_starts_before_entry <- !is.na(L$entry_date) & L$from_date < L$entry_date
L$flag_after_pull <- L$to_date > PULL | L$from_date > PULL
L$flag_open_interval <- L$is_last & (is.na(L$exit_date))

L <- L[order(L$animal_id, L$from_date), ]
cm_write_silver(L, cfg, "locations")

cat("\n=== COVERAGE ===\n")
cat("animals with at least one located interval:", length(unique(L$animal_id)),
    "of", nrow(A), sprintf(" (%.1f%%)\n", 100*length(unique(L$animal_id))/nrow(A)))
never <- setdiff(A$animal_id, L$animal_id)
excl_add("locations.parquet", "animal never appears in movements",
         length(never), n_animals = length(never),
         detail = "no dated move recorded, so no location interval can be built",
         recoverable = FALSE)
cat("animals with NO movement record      :", length(never), "\n")
cat("  of those, currently present        :", sum(A$animal_id %in% never & is.na(A$exit_date)), "\n")
cat("intervals dropped (end before start) :", n_zero, "\n")
cat("intervals clipped to the exit date   :", n_clipped, "\n")
excl_add("locations.parquet", "interval ends before it starts",
         n_zero,
         detail = paste("a move recorded after the animal's exit date, so the interval",
                        "inverts once clipped to her presence"),
         recoverable = TRUE)

## ---- INVARIANT: a location interval set must partition, not overlap ------
cat("\n=== INVARIANTS ===\n")
ovl <- 0L; gaps <- 0L
for (ix in split(seq_len(nrow(L)), L$animal_id)) {
  if (length(ix) < 2) next
  s <- L$from_date[ix]; e <- L$to_date[ix]
  o <- order(s); s <- s[o]; e <- e[o]
  ovl  <- ovl  + sum(s[-1] <= e[-length(e)])
  gaps <- gaps + sum(as.numeric(s[-1] - e[-length(e)]) > 1)
}
cat("overlapping intervals (must be 0):", ovl, "\n")
cat("gaps between intervals           :", gaps,
    " (a gap means she was somewhere unrecorded, not an error)\n")
if (ovl > 0) stop("location intervals overlap - the interval build is wrong")
## an as-of count must never exceed the presence count for the same date
chk <- as.Date("2026-07-29")
n_here <- length(unique(L$animal_id[L$from_date <= chk & L$to_date >= chk]))
n_live <- sum(!is.na(A$entry_date) & A$entry_date <= chk &
              (is.na(A$exit_date) | A$exit_date >= chk))
cat("located on", format(chk), ":", n_here, " vs present:", n_live,
    if (n_here <= n_live) " OK\n" else "  *** LOCATED EXCEEDS PRESENT ***\n")
if (n_here > n_live) stop("more animals located than present - clipping is wrong")

cat("\n=== INTERVALS ===\n")
cat("rows:", nrow(L), " distinct pastures:", length(unique(L$pasture_id)), "\n")
cat("interval length (days):\n"); print(round(summary(L$days)))
cat("date span:", format(min(L$from_date)), "..", format(max(L$to_date)), "\n")

cat("\n=== TOP PASTURES BY ANIMAL-DAYS ===\n")
ad <- aggregate(days ~ pasture_name, L, sum)
an <- aggregate(animal_id ~ pasture_name, L, function(v) length(unique(v)))
names(an)[2] <- "animals"
top <- merge(ad, an); top <- top[order(-top$days), ]
print(head(top, 12), row.names=FALSE)

cat("\n=== AS-OF CHECK: who was where on a given date ===\n")
for (dt in as.Date(c("2021-07-29","2024-07-29","2026-07-29"))) {
  dt <- as.Date(dt, origin="1970-01-01")
  here <- L[L$from_date <= dt & L$to_date >= dt, ]
  cat(sprintf("  %s : %4d animals across %2d pastures\n",
              format(dt), length(unique(here$animal_id)), length(unique(here$pasture_id))))
}
cat("\nThis is the group half of the Phase-1 goal: 'who was present, in which\n")
cat("group, on which date' is now a single interval filter.\n")

cat("\n=== ANIMAL-DAYS AT RISK, the disease denominator ===\n")
for (y in 2021:2026) {
  y1 <- as.Date(paste0(y,"-01-01")); y2 <- as.Date(paste0(y,"-12-31"))
  ov <- pmax(0, pmin(as.numeric(L$to_date), as.numeric(y2)) -
                pmax(as.numeric(L$from_date), as.numeric(y1)) + 1)
  cat(sprintf("  %d : %9.0f animal-days across %d pastures\n",
              y, sum(ov), length(unique(L$pasture_id[ov > 0]))))
}

excl_write(cfg$silver)
