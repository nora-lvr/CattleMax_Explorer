# CLAUDE.md — CattleMax Explorer

Orientation for any Claude session opening this repo. **Full spec: [PLAN.md](PLAN.md). Read it.**

## What this is
A tool for a beef **cow-calf veterinary practice** to turn CattleMax herd exports into (1) answers to
**plain-English questions** and (2) customized **Quarto reports (HTML/PDF)** that trend over time and
**alert on undesirable trends**. Must run on **clients' machines** (everything but the data ships in
the repo) and let clients build their own reports. Owner: Nora (livestockvets@gmail.com).

## Status
**Phase 1 built and reconciled.** A working R pipeline (`R/`) produces the silver layer and a
branded, self-contained HTML report. The denominator engine **reconciles exactly** to CattleMax's
own active count (1,857 on River Creek). PLAN.md still locks Python as the eventual engine language;
the R scripts are the sandbox that pinned down the rules — see [R/README.md](R/README.md).

## What exists
- `R/build_animals.R` → `data/silver-data/animals.parquet` — one row per animal, every event date,
  phase boundaries as dates, entry/exit each with a `_rule` column, six `flag_*` columns.
- `R/build_cows.R` → `data/silver-data/cows.parquet` — one row per **cow-season** (a season ends at
  each calving), with censoring flags and a single `analysis_ready` column.
- `R/export_*_json.R` + `reports/templates/herd_report.html` → a self-contained, emailable report.

## Production phases (locked)
**Calf** (entry→weaning) · **Growing** (weaning→sale/first calving/first exposure) ·
**Cow** (first calving→exit) · **Breeding** (first use as a sire→exit).
Donor/Recipient is an orthogonal **role**, not a phase.

## Locked decisions
- **Python core** (polars/pandas + DuckDB). One metric defined once, in Python — **single source of
  truth**, non-negotiable. (Briefly R, flipped to Python 2026-08-13 for a single runtime across both
  front doors; see PLAN.md decision-history note.)
- **Reports**: Quarto with the Python engine, calling the engine directly. **Plain-English querying**:
  a **native Python MCP server** calling the same Python functions — no cross-language seam.
- **Denominator substrate**: a validated herd-state store (DuckDB/parquet) — the "who was present, in
  which group, on which date" layer, built once, read by the metric functions.
- Distribution via **`uv`**; client drops their CattleMax pull into `data/`. Most clients receive a
  rendered HTML and install nothing; self-render adds Python + Quarto; querying adds Claude Desktop.

## Golden rules
1. **Never commit client data.** `data/` is gitignored. Confirm before any `git add -A`.
2. **The engine does the arithmetic; the LLM never counts or divides.** It picks the question and
   writes the sentence around a validated number.
3. **Gates refuse and list valid options** rather than returning a plausible-wrong answer.
4. **Stamp every answer** with pull + its date + metric definition + code version.
5. **Read CSVs with a real quoted parser** (polars/DuckDB) — free-text fields contain commas/newlines.
6. **Exclude `status == "Reference"`** from presence — it's ~71% of rows and the biggest filter.
7. **`dam_animal_id` is the female who CARRIED the calf.** `real_dam_animal_id` is the genetic/registry
   dam and for ET calves names the **donor** — using it credits donors with their recipients'
   calvings and makes a recipient herd look barren. See PLAN.md §6.
8. **Never use `updated_at` as a departure date** — it's a bulk record-edit stamp.
9. **Respect the record horizon.** CattleMax recording starts only a few years back; filter on
   `analysis_ready` before computing any rate, and show right-censored seasons as incomplete rather
   than plotting them as a collapse.
10. **Charts greyscale; brand colour only for the few genuinely interesting things.**
11. **NEVER silently discard anything.** If a record falls out of a table or a report, it is
    recorded in the **exclusions ledger** (`R/exclusions.R` → `data/silver-data/exclusions.parquet`)
    with what it was, why it went, how many, and whether a rule change could recover it. A report
    that excludes records without naming them is not finished. This is Nora's standing rule
    (2026-08-14) and it outranks tidiness.

## The core problem (Phase 1)
Reconstruct **"count present cattle in any group on any date"** from `animals` (presence intervals) +
`movements` (group-membership intervals) + class-as-of-date. Validate against CattleMax's own active
count. Everything else stands on this. Details + open definitional questions in [PLAN.md](PLAN.md) §6/§8.

## Data
Native CattleMax export = one folder per pull (`{accountid}_{name}_{timestamp}`) of ~55 CSVs, dropped
in `data/` (gitignored). Keep every pull for cross-snapshot trends. See [data/README.md](data/README.md).

## Sibling repos (context, not dependencies)
- `C:\GIT\CattleMaxReports` — prior dirty R reports + a `Data Pulls/` archive. Mine for domain
  definitions; don't treat as gold.
- `C:\GIT\mySYNCH_Explorer\llm-query-poc` — architecture/discipline exemplar (Python MCP, gates,
  provenance, mutation tests). Different domain, **same language** — the closest template.
