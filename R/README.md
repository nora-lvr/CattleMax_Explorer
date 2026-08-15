# R/ — working pipeline (sandbox implementation)

**Status:** this is the *working* implementation, written in R because R is already installed on
Nora's machine and she can read and audit it. [PLAN.md](../PLAN.md) still locks **Python** as the
eventual engine language; these scripts are the sandbox that pins down the rules, and the Python
engine will re-implement them against the same validated outputs. The parquet files they emit are
language-neutral, so nothing here has to be thrown away.

## Pipeline order

```
data/<pull-folder>/*.csv          native CattleMax export (gitignored)
        |
        |  R/build_animals.R      one row per animal + every event date + phase boundaries
        v
data/silver-data/animals.parquet
        |
        |  R/build_cows.R         one row per COW-SEASON (season ends at each calving)
        v
data/silver-data/cow_lactations.parquet
        |
        |  R/export_calving_json.R    -> calving JSON  (reads animals.parquet)
        |  R/export_exposure_json.R   -> exposure JSON (reads cow_lactations.parquet)
        v
reports/templates/herd_report.html + the two JSON payloads
        v
data/derived/<herd>_herd_report.html      self-contained, emailable (gitignored)
```

Each script currently has the pull folder path at the top; change it there to run a different herd.
Parameterising that is the first thing to do when this moves to Python.

## The two rules that are easy to get wrong

1. **`dam_animal_id` is the female who CARRIED the calf.** `real_dam_animal_id` is the registry /
   genetic dam and, for ET calves, equals `genetic_dam_animal_id` (453 of 458). Using `real_dam` as
   the calving dam credits donors with their recipients' calvings and makes a recipient herd look
   barren — it understated one season from 76.5% calved to 44.7%.
2. **Never use `updated_at` as a departure date.** It is a bulk record-edit stamp.

## Data-quality policy

Flag, don't chase. Every derived date carries a `_rule`/`_source` column saying how it was obtained,
and every questionable row carries a `flag_*` column. Nothing is dropped without an entry in
`data/silver-data/exclusions.parquet`.

## Which readiness gate to filter on

There were once a single `analysis_ready` column. **It was wrong and has been removed**: it required
`calved == TRUE`, so filtering a rate on it deleted every failure before the rate was computed and
returned 100% by construction, while the honest rate was 77.5%. A filter that removes failures
cannot be used to measure failure.

| gate | means | use for |
|---|---|---|
| **`interval_ready`** | she calved, season fully inside the record, interval biologically plausible | calving interval, age at first calving, gestation |
| **`rate_ready`** | she was exposed and the season is fully inside the record — **says nothing about whether she calved** | % calved, calves per exposed, conception rate |

**A readiness gate is not a denominator.** It decides whether a season is trustworthy enough to use
at all. Having passed the gate you still choose the denominator — **exposed** (every female served,
carrying attrition as a cost) or **retained** (still present at her due date). The two axes compose.
