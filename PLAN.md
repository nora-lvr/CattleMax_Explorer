# CattleMax Explorer — Planning & Design Spec

_Last updated: 2026-08-13. Owner: Nora (livestockvets@gmail.com). Status: **planning complete, engine not yet built.**_

This is the durable specification for the project. It captures what we're building, why, the
decisions we've locked, and the questions still open. Read this before writing any code.

---

## 1. Purpose

A tool for a **beef cow-calf veterinary practice** to turn CattleMax herd exports into answers and
reports — for Nora and for her clients.

Two things it must do, treated as **equal priorities** ("parallel front doors"):

1. **Answer plain-English questions** about a cow herd ("how many cows were in the spring group last
   May?", "is our death loss trending up?").
2. **Produce customized reports** as `.qmd` rendered to HTML or PDF, that **trend over time** and
   **alert when a value is trending in an undesirable direction**.

It must be a **very efficient** way for Nora to make reports for herself and clients, and it must let
**clients make their own reports** from their own data.

Word/PPT output is a nice-to-have, explicitly **not** a priority.

---

## 2. Users & distribution constraints

- Runs on **other people's machines**, not just Nora's.
- **Everything except the data lives in the repo.** A client clones/receives the repo, drops their
  CattleMax export into the documented location, and has full function.
- Reproducible environment via **renv** (R lockfile) so a client needs only R + the lockfile to
  render reports.
- The plain-English/LLM path has a **heavier, opt-in install** (see §4); the report path stays light.
- Herd sizes: ~200 to ~5,000 **active** head. Not large data, but many animals go **inactive** each
  year, and reference animals inflate the files further (see §7). History spans years.
- Refresh cadence: **manual quarterly** CSV pull for now. That's acceptable.

---

## 3. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Core language | **R** (tidyverse) | Nora & clients live in R; she owns the fuzzy definitions and must audit/iterate them; reports are Quarto+R; existing domain code is R. |
| Single source of truth | **One metric definition each, in R** | Reports and the LLM both call the same R functions. No metric defined twice. This is non-negotiable. |
| LLM front door | **Thin Python MCP shim calling the R engine** via a clean CLI/JSON boundary | The mature MCP path is Python; the seam's complexity lands on the developer, not on Nora or clients. R computes, Python relays. |
| Denominator substrate | **Validated herd-state store (DuckDB/parquet), language-neutral data** | Materialize the "who was present, in which group, on which date" layer once; both front doors read metric functions built on it. |
| Data in git | **Never.** `data/` is gitignored. | Real client herd data. Confirmed nothing tracked; `data/` added to `.gitignore` 2026-08-13. |

---

## 4. Architecture

Layered, single source of truth for every metric:

1. **Data contract + loader** — a documented, gitignored `data/` location holding native CattleMax
   exports (one folder per pull). R loader reads the ~55 CSVs into a clean model **using a real
   quoted-CSV parser** (readr / DuckDB), never naive splitting (see §7).
2. **Herd-state / denominator engine** — the crown jewel (§6). As-of-any-date inventory + group
   membership, materialized to the DuckDB/parquet substrate. Validated hard.
3. **Metrics library** — R functions for repro, health/treatment, mortality, growth/inventory. Each
   has an explicit numerator/denominator definition and carries a provenance stamp.
4. **Trend + alert layer** — run metrics across event-dates (within a pull) and across pulls
   (snapshot-over-snapshot); flag against the herd's **own** history and against a target direction /
   threshold.
5. **Two front doors on the same engine:**
   - (a) Parameterized **Quarto** reports (HTML/PDF) a client renders themselves.
   - (b) **Plain-English querying** via a Python MCP tool server that calls the same R metric
     functions.

### Two independent sources of "trend over time"
- **Within one pull** — most events carry dates (breedings, treatments, movements), so trends come
  from a single export.
- **Across pulls** — the `data/` folder keeps **every** pull, enabling snapshot-over-snapshot trends
  for things that aren't event-dated (e.g. inventory composition). Keep all pulls.

---

## 5. Design principles (adopted from the mySYNCH Explorer system)

These are the discipline that makes the answers trustworthy:

1. **The engine does the arithmetic; the LLM only picks the question and writes the sentence.** The
   model never counts or divides.
2. **Gates that refuse and list valid options** rather than returning a plausible-wrong answer. (The
   canonical failure to avoid: silently returning the whole herd's number labelled as a subgroup.)
3. **Every answer carries a provenance stamp** — which pull, its date, which metric definition, which
   code version.
4. **Chartability rules** — refuse to plot a rate that's too thin or too full of unknowns, and
   **name** what was excluded rather than silently dropping it.
5. **Explicit, owned definitions** — every numerator/denominator is a settled, documented decision
   Nora makes, not something inferred per query.
6. **Validation is first-class** — independent reconciliation, invariant tests, and mutation tests
   (break the code on purpose, confirm the tests notice).

---

## 6. The denominator engine (Phase 1 — the foundation)

Nora's framing: *"I need to count the number of cattle present in any group at any point in time.
This is fundamental to all other measures."* Everything else stands on this.

It is primarily a **temporal-interval reconstruction**:

- **Presence interval per animal** — entry (birth / acquisition / first-seen) → exit (death / sale /
  disposal, or open = still present), reconciled across `animals`, `movements`, `sale_tickets`, and
  death records.
  - **Presence = in the data AND present in any location for any amount of time.**
  - **Reference animals do NOT count** — exclude `status == "Reference"` (see §7; this is the
    single biggest filter in the engine).
- **Group-membership intervals** — `movements` gives dated moves; each animal becomes a sequence of
  `[from, to)` intervals in a group / pasture.
- **Class-as-of-date** — an animal's class (calf → heifer → cow; bull; steer) changes with age and
  status, so class is part of the state, not a fixed attribute.
- **As-of query** — "on date D, who is present and in group G?" → a point-in-time interval join
  (efficient in DuckDB). Trend = run it across a sequence of dates.

### The seven functional groups (cow-calf enterprise view)
A "group" can be any combination of grouping variables, but the main functional groups are:
**cows, replacement heifers, sale heifers, feeders, sale bulls, calves, herd bulls.**
These are **derived** from `animal_type` + `sex` + age + `category` + group-membership + intent — not
a single column.

### Validation (must pass before building on it)
- Reconcile the engine's as-of **active** count against CattleMax's own active count per pull (e.g.
  1,857 Active in the Mertz export).
- Invariant tests: splitting a group can't create or lose cattle; presence intervals never overlap
  for one animal; counts across groups sum to the whole.
- Provenance stamp on every number.

---

## 7. Findings from real data (Mertz / River Creek export, pulled 2026-07-29)

`data/81258_joe_mertz_202607291020/` — 17,055 animal rows. Concrete facts that shape the build:

- **`status` distribution:** `Reference` 12,182 · `Sold` 2,506 · `Active` 1,857 · `Dead` 507.
  Reference animals are **71% of the file** — excluding them is the biggest single filter.
- **CSV needs a real parser.** Free-text fields (comments, addresses) contain commas and newlines;
  naive splitting corrupts rows (some `sex`/`animal_type` values parsed as timestamps in a quick
  scan). Use readr / DuckDB quoted-CSV reading only.
- **`categories` are current-snapshot enrollment tags, not history** — e.g. "Fall – Replacement
  Heifer (6 to 20 MOA)", "Bull – Next Spring Sale", "Donor – Open". They give today's classification,
  not the historical one. History comes from `movements` + `groups`.
- **`animal_type`** ∈ {Bull, Calf, Cow}; **`sex`** ∈ {Bull, Heifer, Steer}. Coarse; the seven
  functional groups are derived, confirming class is fuzzy.

---

## 8. Open definitional questions (to settle against real examples, Nora owns)

These are deliberately unresolved; we work them out by looking at real animals, then encode rules:

1. **Class boundaries.** When does a heifer become a replacement heifer (e.g. not sold with her
   feeder cohort) and when does she become a cow (first calving)? Age cutoffs for calf/heifer/cow.
2. **Date precedence.** When a disposal date and the last movement date disagree, which wins?
   Resolve by inspecting real conflicting records.
3. **Grouping dimensions.** Which grouping variable(s) back each functional group — CattleMax
   groups, pastures/locations, categories, or combinations.
4. **Mapping the seven functional groups** to concrete rules over the derived inputs.

Settled: presence = in data + present at any location for any time; **reference animals excluded**.

---

## 9. Phased plan

- **Phase 1 — Denominator engine + substrate + validation.** The foundation. Deliverable: "count
  present cattle in any group on any date," reconciled to CattleMax's own active count.
- **Phase 2 (parallel front doors) — first metrics on the engine:**
  - (a) a herd **inventory / composition** report trended across pulls, in Quarto;
  - (b) the same 2–3 questions answerable in **plain English** via the MCP shim.
  - Goal: prove both front doors return **identical numbers**.
- **Phase 3+ — expand:** metrics library (repro → health → mortality → growth), trend + alert layer
  (flag against the herd's own history and target direction), self-service report parameters.
- **Throughout:** renv lockfile, documented `data/` drop layout, quickstart, so the repo runs on a
  client machine with only their data added.

**Metric priority order:** denominator engine first (fundamental), then Reproduction, Health &
treatments, Mortality / death loss, Inventory & growth.

---

## 10. Sibling repos (context, not dependencies)

- **`C:\GIT\CattleMaxReports`** — prior, non-Claude R reports (BaseData.qmd, CowCalfReport.qmd,
  DiseaseEvaluation.qmd, clean_* functions, calf-crop logic) plus a `Data Pulls/` archive of many
  historical exports. **Dirty sandbox** — treat as a **domain-knowledge quarry** (how Nora defines
  calf crop, disease overviews, denominators), not as gold-standard code. Rebuild clean.
- **`C:\GIT\mySYNCH_Explorer`** (`llm-query-poc/`) — an exemplar of the architecture and discipline
  in §5 (Python MCP server, validated tools, gates, provenance, mutation tests). Different domain
  (dairy breeding), but the **system design** is the model to follow.

---

## 11. The CattleMax export (data contract)

Native CattleMax bulk export = one folder per pull, named `{accountid}_{name}_{timestamp}`,
containing ~55 CSVs. Key tables for this project:

| Table | Role |
|---|---|
| `animals.csv` | Animal master: birth/purchase/sale/death dates, sex, `animal_type`, `category_id`, `status`, sire/dam. |
| `movements.csv` | Dated moves between groups/pastures — the backbone of group-membership intervals. |
| `groups.csv`, `groupings.csv` | Group definitions & membership. |
| `pastures.csv` | Location definitions. |
| `ownerships.csv` | Ownership over time. |
| `categories.csv` | Current-snapshot enrollment/marketing categories. |
| `breedings.csv`, `pregnancy_checks.csv`, `breeding_soundness_exams.csv`, `heats.csv` | Reproduction. |
| `measurements.csv` | Weights / BCS / heights over time. |
| `treatments.csv` | Health events. |
| `sale_tickets.csv`, `income.csv`, `carcass.csv` | Disposal / sales / carcass. |

Keep **every** pull for cross-snapshot trends.
