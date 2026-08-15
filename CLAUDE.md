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
`R/run_pipeline.R` runs everything in order. `R/check_data.R` is both the first and the last step.

**Silver tables** (`data/silver-data/`, gitignored): `animals`, `cow_lactations` (one row per
lactation), `bulls`, `treatments`, `locations`, `phase_risk`, `disease_cases`, `calf_fates`,
`cow_scorecard`, `exclusions`.

**Guards** — `R/check_data.R` + `reference/columns.csv` + `reference/cattlemax_schema.json`.
Before the builds it asks whether the export changed shape; after them, whether every column
traces to the export or to an approved rule. Both configs are **schema and classification only —
no counts** — so they are portable to any herd.

**Reports** — `R/export_*.R` → JSON, inlined into `reports/templates/*.html` by
`R/render_disease_report.R` (generic: template, output, json). Self-contained, emailable.
`data_flow.html` (how the export becomes the silver tables) and `source_map.html` (all 59 export
files, 47 confirmed joins, what we do and don't read) are both **generated from the data** — the
layout code names no table, so a new table appears automatically.

## Diagrams
Generate the layout from the data; never hand-position boxes. Radial for hub-and-spoke, columns for
build order. Optimise edges (barycentre ordering, then a hill climb on total length; place outer-ring
nodes at their parent's angle). Render at natural size in a scrolling frame with zoom — a shared
stylesheet's `svg{width:100%}` beats a width *attribute* and silently kills zoom. Arrows in the
accent colour, never the box palette. Offer a 3× PNG export.

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
5. **Read CSVs with a real quoted parser, every column as character.** Free-text fields contain
   commas and newlines. `cm_read` uses **readr** (Nora: "use tidyverse when possible, it is
   safest") with `cols(.default = col_character())` — nothing type-guessed — and treats **only `""`
   as missing, never the text `"NA"`** (a sale ticket's invoice is literally `NA`; reading it as
   missing deleted a real value). Convert dates and numbers deliberately, downstream, where the
   conversion can be checked. Type inference would have destroyed 38 identifier values in
   `animals.csv` alone (`reg_num` = "COMM"/"pending", `electronic_id` with spaces).
6. **Exclude `status == "Reference"`** from presence — it's ~71% of rows and the biggest filter.
7. **`dam_animal_id` is the female who CARRIED the calf.** `real_dam_animal_id` is the genetic/registry
   dam and for ET calves names the **donor** — using it credits donors with their recipients'
   calvings and makes a recipient herd look barren. See PLAN.md §6.
8. **Never use `updated_at` as a departure date** — it's a bulk record-edit stamp.
9. **Respect the record horizon.** CattleMax recording starts only a few years back. Filter on
   **`rate_ready`** for any rate and **`interval_ready`** for any interval/age average, and show
   right-censored seasons as incomplete rather than plotting them as a collapse. The old
   `analysis_ready` column is **gone** — it required `calved == TRUE`, so any rate filtered on it
   returned 100% by construction. A gate is not a denominator: after passing it you still choose
   **exposed** or **retained** (PLAN.md §6).
10. **Charts greyscale; brand colour only for the few genuinely interesting things.**
11. **Veterinary scope only — animals and health.** No sale prices, no revenue, no cost, no
    margin, no marketing analysis. Economics is not this practice's arena and is out of scope
    (Nora, 2026-08-14). Sale *weight* and *reason for sale* are in scope — they are a growth
    measurement and a health/culling reason. Sale *price* is not.
12. **NEVER silently discard anything.** If a record falls out of a table or a report, it is
    recorded in the **exclusions ledger** (`R/exclusions.R` → `data/silver-data/exclusions.parquet`)
    with what it was, why it went, how many, and whether a rule change could recover it. A report
    that excludes records without naming them is not finished. This is Nora's standing rule
    (2026-08-14) and it outranks tidiness.
13. **NEVER invent a value.** Do not estimate, assume or impute anything unless Nora has been shown
    that specific scenario and has approved it **by name**. Missing stays missing: NA plus a reason
    column, never a plugged number. A fabricated value is worse than a gap — it is indistinguishable
    from a real one downstream and silently becomes a denominator, and this is a veterinary decision
    tool where a made-up date can become a cull call. Nora's standing rule (2026-08-15): *"you are
    not allowed to make things up like this. We don't ever make up data unless we have discussed it
    and I specifically approved it."*
    - Prefer **restructuring over imputing**. If a missing weaning date means the Calf phase never
      ends, the fix is a better phase-end rule, not a manufactured weaning date.
    - Enforced by `R/check_data.R`, which classifies every silver column as **sourced / derived /
      invented** against `reference/columns.csv` and **fails the build** on anything unclassified or
      unapproved. It was written because a hand-audit missed things twice: a keyword scan missed
      `first_calving-283d`, and a provenance-column scan missed `inactivated_date` — a column with
      no CattleMax equivalent at all, which Claude fabricated and named like a fact.

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
