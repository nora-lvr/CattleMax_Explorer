# CattleMax Explorer — Planning & Design Spec

_Last updated: 2026-08-13. Owner: Nora (livestockvets@gmail.com). Status: **planning complete, engine not yet built.**_

This is the durable specification for the project. It captures what we're building, why, the
decisions we've locked, and the questions still open. Read this before writing any code.

> **Decision history:** The core language was briefly locked to R (commit 764a7ad), then flipped to
> **Python** the same day (2026-08-13). Reason: Python gives a **single runtime for both front
> doors** (reports + plain-English querying), removing the R-engine/Python-shim seam; its data stack
> (polars/DuckDB) is strong for the interval-join denominator work; and the client-install advantage
> that favored R mostly evaporates once you notice **most clients receive a rendered HTML and install
> nothing**. Nora owns the definitions and reads them in Python (polars ≈ dplyr); Claude authors the
> code.

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
- Reproducible environment via **`uv`** (Python) so a client self-rendering needs only Python (+ the
  Quarto installer) and one command to restore exact package versions.
- The plain-English/LLM path has a **heavier, opt-in install** (see §4); the report path stays light.
- Herd sizes: ~200 to ~5,000 **active** head. Not large data, but many animals go **inactive** each
  year, and reference animals inflate the files further (see §7). History spans years.
- Refresh cadence: **manual quarterly** CSV pull for now. That's acceptable.

---

## 3. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Core language | **Python** (polars/pandas + DuckDB) | One runtime serves both front doors; strong data stack for the interval-join denominator work; native MCP querying path. Nora owns the definitions (reads them via polars ≈ dplyr); Claude authors the code. |
| Single source of truth | **One metric definition each, in Python** | Reports and the LLM both call the same Python functions. No metric defined twice. Non-negotiable. |
| LLM front door | **Native Python MCP server** | Same runtime as the engine — no cross-language seam. |
| Report front door | **Quarto with the Python (Jupyter) engine** | Renders HTML/PDF from the same engine functions. |
| Environment / install | **`uv`** for one-command reproducible installs | Self-render needs Python + Quarto; querying needs Claude Desktop. Most clients receive rendered HTML and install nothing. |
| Denominator substrate | **Validated herd-state store (DuckDB/parquet)** | Materialize "who was present, in which group, on which date" once; the metric functions read it. |
| Data in git | **Never.** `data/` is gitignored. | Real client herd data. Confirmed nothing tracked; `data/` added to `.gitignore` 2026-08-13. |

---

## 4. Architecture

Layered, single source of truth for every metric:

1. **Data contract + loader** — a documented, gitignored `data/` location holding native CattleMax
   exports (one folder per pull). Python loader (polars / DuckDB) reads the ~55 CSVs into a clean
   model **using a real quoted-CSV parser**, never naive splitting (see §7).
2. **Herd-state / denominator engine** — the crown jewel (§6). As-of-any-date inventory + group
   membership, materialized to the DuckDB/parquet substrate. Validated hard.
3. **Metrics library** — Python functions for repro, health/treatment, mortality, growth/inventory.
   Each has an explicit numerator/denominator definition and carries a provenance stamp.
4. **Trend + alert layer** — run metrics across event-dates (within a pull) and across pulls
   (snapshot-over-snapshot); flag against the herd's **own** history and against a target direction /
   threshold.
5. **Two front doors on the same engine:**
   - (a) Parameterized **Quarto** reports (Python engine, HTML/PDF) a client renders themselves.
   - (b) **Plain-English querying** via a native Python MCP tool server that calls the same Python
     metric functions.

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

### Exit-date rule (derived from real data, 2026-08-13)
Resolve an animal's departure date in this precedence order:
1. `sale_date` / `death_date` on the animal record
2. **join `sale_ticket_id` → `sale_tickets.sale_date`** (recovered 129 of 437 missing in River Creek)
3. **last real activity** — max of last movement / measurement / treatment / breeding / note
4. **Never `updated_at`** — it is a bulk record-edit stamp, not a departure. In River Creek, animals
   whose real activity stopped 2016–2019 carry an `updated_at` of 2025-12-14; using it would keep
   them "present" 6+ years too long.

Every exit date must carry **which rule produced it**, so reports can distinguish known from
estimated departures.

### Class & role taxonomy (worked out against River Creek, 2026-08-13)

**Two orthogonal dimensions**, not one. Both derived time-accurately — never read from
`category_id`, which is a *current snapshot* and is wrong for historical dates.

**Dimension 1 — class** (from sex + life events):
| class | rule |
|---|---|
| Nursing calf | entry → `weaning_date` (fallback: birth + 205 d) |
| Replacement heifer | weaning → first calving |
| Cow | from first calving onward; **first calving = earliest `birth_date` among her calves** via `dam_animal_id` |
| Sale bull | weaning → first breeding use (or exit) |
| Herd sire | from **first use as a sire** onward (`breedings.bull_animal_id`) |
| Steer | weaning onward, where `sex == "Steer"` |

**Bulls are split by destiny, not age.** An 18-month cut was tested and rejected: only 35 of 1,657
bulls were ever used as sires; sold bulls' age at sale (median 16.3 mo) and sires' age at first use
(median 17.9 mo, range 12.8–47.3) overlap almost completely. In a seedstock herd a bull is a
*product*, so use — not months — separates the groups.

**Dimension 2 — reproductive role** (orthogonal; a cow may be Donor, Recipient, or neither):
| role | rule |
|---|---|
| Donor | from first flush (`flushes.flush_date`) or embryo collection (`embryos.animal_id`) onward |
| Recipient | from first ET breeding onward (`breedings.embryo_id` present) |
| None | otherwise |

Derived roles beat the snapshot category: in River Creek the category field catches 163 recipients
but misses ~39 more (and ~50 donors) filed under generic "Total Herd Enrollment" categories.

### Data-quality flags (required, surfaced in reports)
The engine must **count and expose missing/estimated inputs**, and reports must show a notice when
they exceed a threshold. Minimum flag set:
- animals with no exit date after all fallbacks (River Creek: 308 of 4,870 non-reference)
- exit dates that are **estimated** (rule 3) vs recorded (rules 1–2)
- animals missing `birth_date` (River Creek: 177 of 1,857 active)
- animals with no movement history at all
- any denominator whose members are >X% estimated → warn rather than silently report a rate
- **impossible class × role combinations** — e.g. "Nursing calf + Recipient" (2 in River Creek),
  which implies a bad ET breeding date or a missing `weaning_date` firing the 205-day fallback
- sale/death date earlier than birth date (seen in River Creek bulls)

**Policy: flag, don't chase.** The engine surfaces these counts so a report can raise a notice when
the share is material; we do not hand-investigate individual animals.

### The exclusions ledger (standing rule, Nora 2026-08-14)
**Nothing is ever silently discarded.** Every record that falls out of a table or a report is
written to `data/silver-data/exclusions.parquet` via `R/exclusions.R`, carrying the table, the
reason, the count, a plain-English detail, and a `recoverable` flag saying whether a rule change
could bring it back. **A report that excludes records without naming them is not finished.**

Current ledger for River Creek — 15,658 records excluded in total:

| table | reason | records | recoverable |
|---|---|---|---|
| animals.parquet | `status == Reference` | 12,182 | no |
| cows.parquet | animal is not `sex == Heifer` (no bull-side table yet) | 1,896 | **yes** |
| cows.parquet | female never calved and never exposed | 979 | **yes** |
| cows.parquet | calf has no dam link of any kind | 485 | no |
| cows.parquet | season of zero length | 85 | no |
| cows.parquet | calf's dam field names the ET donor, no recipient recoverable | 31 | **yes** |

The `recoverable = yes` rows are the ones worth revisiting: 2,906 records are out purely because of
a rule we chose, not because the data is missing.

This follows the mySYNCH chartability discipline (§5.4): **name what's uncertain, never drop it
silently.**

### Production phases (locked 2026-08-14)
Phases are defined by **events**, not by guesses about class, and both boundaries are stored as
dates so "phase on date D" is a comparison rather than a stored label.

| phase | starts at | ends |
|---|---|---|
| **Calf** | entry (birth, or purchase if bought as a calf) | weaning |
| **Growing** | weaning | sale, first calving, or first breeding exposure |
| **Cow** | first calving | exit |
| **Breeding** | first exposure as a sire (`breedings.bull_animal_id`) | exit |

Breeding is the male parallel to Cow. A bull never exposed stays in **Growing** until sold, which is
correct for a seedstock herd where most bulls are product rather than breeding stock.
Donor / Recipient remains an **orthogonal role**, not a phase.

**Weaning precedence:** `weaning_date` → a `measurements` row of category *Weaning* → `weaning_weight`
present (estimate birth + 205 d) → **age > 8 months** (assume weaned, flag it) → still nursing.
The age backstop matters: without it, **525** animals over two years old with no weaning record are
counted as nursing calves. River Creek's own recorded weaning age is tight — median **6.8 months**.

**Correction (2026-08-14).** Earlier versions of this section said "207 animals" and claimed the
6–8 month bucket was empty. Both were wrong: it is 525 animals, and **2,184 of 3,079 recorded
weaning ages fall between 6 and 8 months**. What is actually empty is the 6–9 month band *among
animals with no weaning record at this pull date* — an artifact of this herd's calving seasons and
of this particular pull, not a property of the data. **The 8-month threshold is therefore not safe
by construction and remains unvalidated** (see §8). Age is measured at **exit**, not at the pull, or
animals that died young are recorded as weaned because they would have been old enough had they
lived — that affected 234 animals with a median age at death of 34 days.

### THE dam-field trap (verified 2026-08-14 — do not re-introduce)
- **`dam_animal_id` = the female who CARRIED the calf.** Use this as the calving dam.
- `real_dam_animal_id` = the registry / genetic dam. For ET calves it equals
  `genetic_dam_animal_id` in **453 of 458** cases, i.e. it names the **donor**.
- Using `real_dam` credits donors with their recipients' calvings. It made River Creek's Oct-2024
  purchase of 314 commercial recipients look barren and understated that breeding season from
  **76.5% calved to 44.7%**.

### `cows.parquet` — the cow-season table
One row per **cow-season**. A season **ends each time a calf is born**; the next season starts there.
Season 1 opens at **first bull exposure** (falls back to entry when there is no breeding record).
The final season is left open, or closed by her exit. Calvings within 7 days collapse into one
event (twins/multiples) with `n_calves_born`.

### Record horizon and censoring (Nora's ragged-start rule)
CattleMax recording began only a few years ago; earlier births were back-filled as pedigree, so the
start of the record is ragged and must never be silently averaged in. The horizon is **derived from
the data** (earliest operational record — 2018-11-07 for River Creek; note `measurements` contains a
junk 1900-01-01). Every cow-season carries `flag_left_censored`, `flag_right_censored` and
`flag_parity_unknown`.

### Two readiness gates — and a gate is not a denominator
A single `analysis_ready` column used to serve both jobs. **It was wrong and has been removed.** It
required `calved == TRUE`, so filtering a rate on it deleted every failure before the rate was
computed: `calved / analysis_ready` was **100% by construction** on every calf crop, while the
honest rate was **77.5%**. A filter that removes failures cannot be used to measure failure. It also
still admitted intervals of 8 to 1,043 days despite `flag_short_interval` / `flag_long_interval`
being computed and never used.

| gate | means | use for | n (River Creek) |
|---|---|---|---|
| **`interval_ready`** | she calved, season fully inside the record, interval plausible | calving interval, age at first calving, gestation | 2,591 |
| **`rate_ready`** | she was exposed and the season is fully inside the record — **says nothing about whether she calved** | % calved, calves per exposed, conception rate | 3,380 (77.4% calved) |

**These are orthogonal to the denominator choice.** A gate decides whether a season is trustworthy
enough to use; the denominator decides what you divide by. Having passed `rate_ready` you still
choose **exposed** (every female served, carrying attrition as a cost) or **retained** (still
present at her due date). The exposure report prints, per cohort, how many seasons the censoring
gate would exclude and what the rate is with and without them, so the effect is named rather than
hidden.

**Right-censoring is equally load-bearing:** a breeding season whose calves are not all due until
after the pull date must be shown as incomplete, never plotted as a collapse. River Creek's 2025
Fall season reads 0.004 calves/exposed purely because those calves are not born yet.

### Validation (must pass before building on it)
- **Reconcile presence independently — `R/validate_presence.R`.**
  **A previous version of this section claimed a PASS at exactly 1,857. That check was circular and
  has been replaced.** `exit_date` is written only for Sold/Dead animals, so "present at the pull"
  was *identical to* `status == "Active"` by construction — it re-read CattleMax's own answer and
  could never fail.

  The real check rebuilds presence from **dated evidence only** (birth, purchase, movements, sale
  tickets, sale and death dates) and never consults `status`. On River Creek it **disagrees, and the
  disagreement is fully explained**:

  | source | count at 2026-07-29 |
  |---|---|
  | CattleMax `status == "Active"` | 1,857 |
  | `animals.parquet` presence interval | 1,858 |
  | **independent, dates only** | **2,154** |

  All 297 of the gap run one way: animals CattleMax calls Sold/Dead that have **no sale, death or
  ticket date at all** (281 Sold, 16 Dead), carried as `flag_left_undated`. **Zero** animals go the
  other way, so the interval reconstruction itself is sound — the gap measures undated departures,
  a data-quality fact about the herd record rather than a logic error.

  The script also prints historical as-of counts (825 at 2020-07-29, 1,045 at 2022, 1,224 at 2024).
  Those cannot be reconciled against CattleMax at all — it publishes only a *current* status — so
  they are the real test of the interval reconstruction.
- Invariant tests: splitting a group can't create or lose cattle; presence intervals never overlap
  for one animal; counts across groups sum to the whole.
- Provenance stamp on every number.

---

## 7. Findings from real data (Mertz / River Creek export, pulled 2026-07-29)

`data/81258_joe_mertz_202607291020/` — **17,052 animal rows** (17,055 raw lines; two records contain
embedded newlines, which is exactly why a quoted parser is mandatory). Concrete facts that shape the
build:

- **`status` distribution:** `Reference` 12,182 · `Sold` 2,506 · `Active` 1,857 · `Dead` 507.
  Reference animals are **71% of the file** — excluding them is the biggest single filter.
- **CSV needs a real parser.** Free-text fields (comments, addresses) contain commas and newlines;
  naive splitting corrupts rows (some `sex`/`animal_type` values parsed as timestamps in a quick
  scan). Use polars / DuckDB quoted-CSV reading only.
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

## 8b. Report styling (locked 2026-08-14)

Reports are styled to the **client's own marketing identity**, so a herd recognises its own report.
Per-herd branding lives as a small token set (colours + type) applied to a shared template.

**River Creek Farms** — taken from their live site: brick red `#944947`, deep `#852d2b`,
near-black `#1d1d1d`, greys `#7a7a7a` / `#a7a7a7`; display faces *Rift* and *URWDINSemiCond*
(condensed, industrial — echoed with a condensed system stack since webfonts cannot be embedded).
Tagline "SimAngus Bulls Built to Work", "A Family Tradition Since 1890".

**Charts stay greyscale.** The brand colour is reserved for a very small number of genuinely
interesting things — currently only: incomplete-season markers, the "incomplete" pill, the warning
panel, and one thin rule under the masthead. Everything else is neutral grey.

**Delivery:** a single self-contained HTML file — all data embedded, no external requests — so a
client can be emailed the report and open it with nothing installed. This is the default path for
most clients (see §2).

## 9. Phased plan

- **Phase 1 — Denominator engine + substrate + validation.** The foundation. Deliverable: "count
  present cattle in any group on any date," reconciled to CattleMax's own active count.
- **Phase 2 (parallel front doors) — first metrics on the engine:**
  - (a) a herd **inventory / composition** report trended across pulls, in Quarto;
  - (b) the same 2–3 questions answerable in **plain English** via the MCP shim.
  - Goal: prove both front doors return **identical numbers**.
- **Phase 3+ — expand:** metrics library (repro → health → mortality → growth), trend + alert layer
  (flag against the herd's own history and target direction), self-service report parameters.
- **Throughout:** `uv` lockfile, documented `data/` drop layout, quickstart, so the repo runs on a
  client machine with only their data added.

**Metric priority order:** denominator engine first (fundamental), then Reproduction, Health &
treatments, Mortality / death loss, Inventory & growth.

---

## 10. Sibling repos (context, not dependencies)

- **`C:\GIT\CattleMaxReports`** — prior, non-Claude **R** reports (BaseData.qmd, CowCalfReport.qmd,
  DiseaseEvaluation.qmd, clean_* functions, calf-crop logic) plus a `Data Pulls/` archive of many
  historical exports. **Dirty sandbox** — treat as a **domain-knowledge quarry** (how Nora defines
  calf crop, disease overviews, denominators). Since we're now Python, **re-derive the definitions,
  don't port the R code.**
- **`C:\GIT\mySYNCH_Explorer`** (`llm-query-poc/`) — an exemplar of the architecture and discipline
  in §5 (Python MCP server, validated tools, gates, provenance, mutation tests). Different domain
  (dairy breeding), but **same language and same system design** — the closest template to follow.

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
