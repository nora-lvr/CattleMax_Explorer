# Worklog

Newest first. Absolute dates. The *why* matters more than the *what* — the reasoning
is the expensive part to reconstruct.

---

## 2026-08-15 — Stop the pipeline inventing data; collapse the guards into one check

**Done**

- **Golden rule 13, never invent a value** (CLAUDE.md). Enforced by `R/check_data.R`, which
  classifies every silver column as *sourced / derived / invented* against
  `reference/columns.csv` and fails the build on anything unclassified or unapproved.
  389 columns classified: 73 sourced, 314 derived, 2 invented, 0 unresolved.
- **`R/check_data.R` replaced three scripts and two config files** — `check_schema.R`,
  `test_no_invention.R`, `audit_columns.R`, `approved_inventions.csv`,
  `column_classification.csv`. They were three reports asking one question.
  It runs twice: step 1 (schema only, before anything is built) and last (full check).
- **Counts stripped from the reference configs.** They are configuration and must be true
  for any herd; River Creek's row counts would be wrong for the next client and stale for
  this one. Counts are computed and printed live by the check instead.
- **Every CSV read as character, via readr.** `cm_read` now uses
  `cols(.default = col_character())` and treats **only `""`** as missing.
- **Schema baseline** (`reference/cattlemax_schema.json`) — file and column names only,
  59 files / 1,252 columns. A lost column only fails the build if the code reads it,
  detected by scraping `$column` references out of `R/*.R`.
- **`cows.parquet` → `cow_lactations.parquet`** — the name now says what a row is.
- **Source map** (`R/export_source_map.R` + `reports/templates/source_map.html`) — all 59
  export files, 47 joins confirmed by matching values, every column's fill rate.
- **Data-flow doc rebuilt** — 12 stages, 22 decisions, generated layout.
- **Cow scorecard** — calf survival to transition (sold / calved / used as a sire).

**Why**

Nora caught the pipeline inventing weaning dates for 665 animals, including calves that
died on their birth date recorded as weaned seven months later:
*"you are not allowed to make things up like this. We don't ever make up data unless we
have discussed it and I specifically approved it."*

A fabricated value is worse than a missing one — missing is visible, invented is
indistinguishable from real once downstream and silently becomes a denominator. This is a
veterinary decision tool; a made-up date can become a cull call.

Two hand-audits missed things, which is why the check is code and not a convention:
- a keyword scan (EST/ASSUMED) missed `first_calving-283d`, which manufactures a
  cow-season start by subtracting gestation and carries no marker word;
- a provenance-column scan missed **`inactivated_date`** — a column with no CattleMax
  equivalent at all, built from `last_activity` and named like a fact. Nora caught that too.

On the reader: Nora asked for all-character reads and was right that values were being
lost. `na.strings` included the text `"NA"`, so a sale ticket whose invoice is literally
`NA` was read as missing. Type inference would have destroyed 38 identifier values in
`animals.csv` alone.

**Gotchas**

- **`R/check_data.R` currently FAILS the build**, by design: `inactivated_date` (animals
  308, bulls 88) is invented and unapproved. That is the correct state — it must be
  removed or approved, not silenced.
- **2,220 manufactured values** remain inside otherwise-real columns, all declared by a
  provenance column: weaning_date (783), entry_date (373), exit_date (372),
  season_start (434). Nora approved the *fix* for the two weaning rules (no date; end the
  phase honestly with NA) — **not yet implemented**.
- **R parses a bare `else` on a new line at top level as an error.** This has bitten the
  repo three times. Always brace multi-line `if/else`.
- `run_pipeline.R` *sources* each step, so it cannot pass command-line arguments — the
  first `check_data.R` pass gets its mode from a `CHECK_MODE` global, and the file guards
  its post-build half rather than calling `quit()`, which would end the whole pipeline.
- Reading a parquet with arrow memory-maps it, and Windows then refuses to overwrite the
  file — the exclusions ledger accumulates via its CSV twin for this reason.

**Verified, not assumed**

- readr vs the old reader: identical rows and columns on all 59 files, one cell rescued.
- `arrow::read_csv_arrow` independently agrees on the row count for every file, so the
  embedded newlines in `pregnancy_checks` (861 lines more than records), `events` (255)
  and `animal_notes` (186) are genuinely handled.
- Both `check_data.R` modes run; the full pipeline reached step 12 before the rewrite.

**Decided with Nora, not yet built**

- **Four phase tables from animals**: `calves` (birth→weaning), `growing` (weaning→sold/
  calved/sire), `cow_lactations` (one row per lactation), `herd_bulls` (one row per
  breeding season). `phase_risk` becomes a derived union; `calf_fates` is folded into
  `calves`. AI and outside sires stay a pedigree reference, not Herd Bulls (only 37 of 102
  sires are owned animals).
- **Season start** = previous calving, else exposure to a sire. Checked: of the 434 seasons
  currently on `first_calving-283d`, 427 cows have a breeding record but **none before that
  calving**, so all 434 become NA.
- **Exit**: CattleMax gives `status = Sold/Dead` and no date for those 308 — `sale_date` 0,
  `death_date` 0, none in `sale_tickets`. The honest answer is exit_date NA.
- **Weaning weight ranking** (not started): BIF 205-day, contemporary group =
  year × season × sex, missing birth weight → group mean (flagged), "light calf" = >3 SD
  below the group mean, "under-performing" = bottom 25%, both tunable at the top of the
  document, rolled to the dam as a milk signal. CattleMax's own `adjusted_weight` was
  reverse-engineered and **is** BIF with age-of-dam adjustment (+60/+54 at dam age 2,
  +40/+36 at 3, +20/+18 at 4, 0 at 5–10); our independent calculation agrees within 1 lb
  on 96% of 517 mature-dam rows.

**Next:** see `## Next session` at the top of this file.

---

## Next session

Rebuild `animals.parquet` from a clean all-character read, standardising types by a
declared spec. Agreed with Nora:

- Type spec lives in **`reference/animals_column_types.csv`** — one row per column
  (name, type, note), editable without touching code; the build fails if an export column
  is missing from the spec.
- A value that fails to convert **keeps its raw text in a companion column and is flagged**
  (`birth_date`, `birth_date_raw`, `flag_birth_date_unparsed`). Nothing is lost.
- Sentinels are **flagged, never fixed**: 955 birth dates on Jan 1, 6,464 zero yearling
  weights, 1,371 zero weaning weights, 904 zero birth weights, 39 birth dates before 1950,
  1 death date after the pull. Keep the value, add the flag, let each metric decide.
- Stop there. No presence logic, no phases, no weaning rules — those are a separate layer.

Profiled from the raw character read of `animals.csv` (17,052 × 103): all 19 date and
timestamp columns parse 100% clean via `substr(1,10)` — never timezone-shift, it could move
a calving across midnight. The only numeric parse failures are `reg_num`, `electronic_id`
and `other_id`, which are **identifiers** and must stay character.
