# Backlog

Everything outstanding, so nothing is carried in anyone's head. Worked in **sets** — one at a
time. Tick items off in place; move a whole set to Done when it closes.

Source: three independent pipeline reviews, 2026-08-14 (accuracy · completeness · assumptions).

---

## SET 1 — IN PROGRESS

### 1A. Nora decides (blocking — these change numbers already on screen)

- [ ] **March breedings.** 166 seasons have a first service in March, which maps to neither the
      Nov–Jan (Fall) nor Apr–Jul (Spring) window, so they get no calf crop and are dropped.
      **Effect: 2,021 of 6,192 seasons and ~40% of calvings never reach the calf-crop report.**
      Spring? A third season? Off-pattern? And should unlabelled seasons be *shown as excluded*
      rather than dropped?
- [ ] **Donor dams.** 46 dams carry ~39% of counted calves with a median "calving interval" of
      9 days — they are ET donors whose flushes are recorded against them as births.
      `dam_animal_id` is the carrier for the Oct-2024 recipient block (settled, correct) but does
      **not** hold for these. Should calves with `conception_method == "ET"` be attributed to the
      recipient? Twinning currently reads 5.1% against a 1–3% norm; this is the residue.
- [ ] **`analysis_ready` semantics.** It hard-codes `calved == TRUE`, so **any rate filtered on it
      returns 100%**, yet README/CLAUDE.md both call it "the column to filter on before computing
      any rate". Interval filter (keep `calved`) or general filter (drop it)? And should
      `flag_long_interval` / `flag_short_interval` be part of it — is a 1-day or 1,431-day
      interval ever analysis-ready?

### 1B. Claude does in parallel — **DONE** (commit 29c0fa9)

- [x] Replaced the **circular 1,857 reconciliation** with `R/validate_presence.R`, which rebuilds
      presence from dated evidence only and never consults `status`. It now disagrees — 2,154 vs
      1,857 — and the whole 297 gap is departures with no recorded date (281 Sold, 16 Dead), zero
      the other way. Also prints historical as-of counts CattleMax cannot answer at all.
- [x] Corrected **three wrong figures in PLAN.md**, all mine: 17,055 → 17,052 rows; "207 animals
      over two years old" → 525; "the 6–8 month bucket is empty" → 2,184 of 3,079 land there, so
      the 8-month threshold is **not** safe by construction and stays unvalidated.
- [x] **`export_calving_json.R`** — blanks are now their own named level, with an assertion that
      each dimension's counts sum to `n`. `phase_now` alone had been dropping 2,667 rows.
- [x] **Four new flags**: `activity_after_exit` (791, median 20 d), `date_after_pull` (1),
      `weaning_after_exit` (42), `left_undated` (308).
- [x] The 34 remaining assumed-weaning-after-exit turned out to be **recorded** weaning dates, not
      assumed ones, so they are flagged rather than overwritten — the recorded date may be right.

---

## SET 2 — Portability (blocks running a second herd at all)

- [ ] Hard-coded absolute paths in **8 files**; two export scripts point at a **session-specific temp
      GUID directory** and are already broken anywhere else.
- [ ] Hard-coded pull date (3 files), gestation constant (3 literals), herd name baked into the JSON.
- [ ] `rd()` / `d10()` / `PULL` / `SILVER` duplicated across 4–5 scripts.
- [ ] Every silver table written as both `.csv` and `.parquet` with no stated consumer of the CSV.

## SET 3 — Missing substrate (each blocks a whole report domain)

- [ ] **Group / location intervals.** 69,973 movement rows across 122 pastures reduced to two dates;
      `group_names` covers 12% of animals. **This is the stated Phase-1 goal** — "who was present,
      *in which group*, on which date" — and it is not met. Also blocks death-loss *rates*.
- [ ] **Calf outcome.** 412 calves died, weights and sale prices exist, none carried.
      **Blocks calves-weaned-per-cow-exposed, the core cow-calf KPI.** We can only do calves *born*.
- [ ] **Pregnancy-check results.** 4,442 results (3,700 pregnant / 715 open); only the *count* is
      stored. Blocks conception rate and open-cow lists.
- [ ] **Weights / growth.** 36,533 measurements, 3,207 animals with ≥2 weights. Blocks ADG, weaning
      weight, sale weight, bull performance.
- [ ] **Sire linkage.** `sire_animal_id` (4,018 populated) dropped entirely; 277 of 306 sires are
      Reference-status. Blocks all progeny/sire evaluation — for a seedstock herd.
- [ ] Calving ease (2,949 codes unread) · money ($10.35M in sale prices unused).

## SET 4 — Remaining decisions (lower urgency than 1A)

- [ ] **Gestation** — 283 (industry) or 266 (this herd's median)? `due_date` off first or last service?
- [ ] **Purchased animals** — entry = purchase, or keep the birth→purchase Calf/Growing phases?
      674 animals lose a median 1,164 days.
- [ ] **Record horizon** — first breeding (2018-11-07), first movement (2019-05), first treatment
      (2020-02)?
- [ ] **Reference animals as calving events** — 10,228 of 14,171 calf records. In or out?
- [ ] **Twin window** — 7 days or same-day only? 734 merged pairs are 1–7 days apart.
- [ ] `retained_to_due` defaults TRUE when `due_date` is NA (1,852 seasons) — inflates any other
      reader's retained denominator.

## SET 5 — Engineering discipline

- [ ] No functions, no tests. PLAN.md §5.6 promises invariant and mutation tests; there are none.
      Extract `resolve_weaning` / `resolve_entry` / `resolve_exit` / `build_seasons` / `label_cohort`
      as pure functions with the constants as parameters.
- [ ] `build_cows.R` row-by-row loop is 58% of its 19.7 s runtime (vectorised: ~0.17 s). Readability,
      not wall clock, is the real cost.
- [ ] Python port (PLAN.md locks Python as the engine language; R is the sandbox).

---

## Done

- [x] Twins/multiples collapse — calf counts were 46% high, 1-day intervals manufactured
- [x] `Inf` dates written to parquet as year −5877641 (181 rows, unflagged)
- [x] `real_dam` donor fallback removed (28 rows, all crediting donors)
- [x] Weaning age backstop measured at exit, not at the pull (234 → 34)
- [x] Season windows half-open; zero-length seasons dropped; NULL-preallocation landmine
- [x] Banamine misclassified as antiparasitic (176 events)
- [x] `treatments.parquet` built; Nora's 14 class + 11 intent overrides applied
- [x] `active_substance` — 55 raw spellings collapsed to 31
- [x] Data-lineage document, generated from the pipeline so it cannot drift
- [x] Malformed lineage JSON that rendered that document blank
