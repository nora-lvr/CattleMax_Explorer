# data/ — CattleMax exports go here (never committed)

This folder is **gitignored**. Real client herd data must never enter git. Only this `README.md` and
`.gitkeep` are tracked.

## What to put here
Drop a **native CattleMax bulk export** — one folder per pull, exactly as CattleMax produces it:

```
data/
  {accountid}_{name}_{timestamp}/     e.g. 81258_joe_mertz_202607291020/
    animals.csv
    movements.csv
    groups.csv
    ... (~55 CSVs)
```

- **Keep the folder-per-pull structure** — do not flatten or rename. The timestamp is how we order
  pulls for cross-snapshot trends.
- **Keep every pull** you have for a herd. Snapshot-over-snapshot is one of our two ways of trending
  over time.
- Don't hand-edit the CSVs. Free-text fields contain commas and newlines; they parse correctly only
  with a real quoted-CSV reader, which the loader uses.

## What counts as "present"
The engine treats an animal as present if it is in the data and was at any location for any amount of
time. **Reference animals (`status == "Reference"`) are excluded** — in real exports they can be the
large majority of rows.
