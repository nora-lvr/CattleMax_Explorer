# CLAUDE.md — CattleMax Explorer

Orientation for any Claude session opening this repo. **Full spec: [PLAN.md](PLAN.md). Read it.**

## What this is
A tool for a beef **cow-calf veterinary practice** to turn CattleMax herd exports into (1) answers to
**plain-English questions** and (2) customized **Quarto reports (HTML/PDF)** that trend over time and
**alert on undesirable trends**. Must run on **clients' machines** (everything but the data ships in
the repo) and let clients build their own reports. Owner: Nora (livestockvets@gmail.com).

## Status
**Planning complete. No engine code written yet.** Do not start building until Nora says go.

## Locked decisions
- **R core** (tidyverse). One metric defined once, in R — **single source of truth**, non-negotiable.
- **Reports** call the R engine directly (Quarto). **Plain-English querying** is a thin **Python MCP
  shim** that calls the same R functions via a CLI/JSON boundary — the developer owns that seam.
- **Denominator substrate**: a validated herd-state store (DuckDB/parquet) — the "who was present, in
  which group, on which date" layer, built once, read by the metric functions.
- Distribution via **renv**; client drops their CattleMax pull into `data/`.

## Golden rules
1. **Never commit client data.** `data/` is gitignored. Confirm before any `git add -A`.
2. **The engine does the arithmetic; the LLM never counts or divides.** It picks the question and
   writes the sentence around a validated number.
3. **Gates refuse and list valid options** rather than returning a plausible-wrong answer.
4. **Stamp every answer** with pull + its date + metric definition + code version.
5. **Read CSVs with a real quoted parser** (readr/DuckDB) — free-text fields contain commas/newlines.
6. **Exclude `status == "Reference"`** from presence — it's ~71% of rows and the biggest filter.

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
  provenance, mutation tests). Different domain; follow its **system design**.
