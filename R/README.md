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
data/silver-data/cows.parquet
        |
        |  R/export_calving_json.R    -> calving JSON  (reads animals.parquet)
        |  R/export_exposure_json.R   -> exposure JSON (reads cows.parquet)
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
and every questionable row carries a `flag_*` column. `analysis_ready` on `cows.parquet` is the
column to filter on before computing any rate or average.
