## Transparency report: every raw CattleMax value and what it became.
## Run this after build_treatments.R to audit the classification.
options(width=230)
SILVER <- "C:/GIT/CattleMax_Explorer/data/silver-data"
T <- as.data.frame(arrow::read_parquet(file.path(SILVER,"treatments.parquet")))

line <- function(ch="=") cat(strrep(ch, 150), "\n")

cat("\n"); line()
cat("MEDICATION  ->  DRUG CLASS  ->  INTENT     (every raw value, sorted by volume)\n"); line()
m <- aggregate(cbind(events=treatment_id) ~ medication + drug_class + treatment_intent, T,
               FUN=length)
m <- m[order(-m$events), ]
m$pct <- sprintf("%.1f%%", 100*m$events/nrow(T))
print(data.frame(`raw medication`=m$medication, `-> drug class`=m$drug_class,
                 `-> intent`=m$treatment_intent, events=m$events, pct=m$pct,
                 check.names=FALSE), row.names=FALSE)
cat("\ntotal events:", nrow(T), " distinct raw medications:", length(unique(T$medication)), "\n")

cat("\n"); line()
cat("DIAGNOSIS  ->  DISEASE CATEGORY     (every raw value, sorted by volume)\n"); line()
d <- T[!is.na(T$diagnosis), ]
dd <- aggregate(cbind(events=treatment_id) ~ diagnosis + disease_category, d, FUN=length)
dd <- dd[order(dd$disease_category, -dd$events), ]
print(data.frame(`raw diagnosis`=dd$diagnosis, `-> disease category`=dd$disease_category,
                 events=dd$events, check.names=FALSE), row.names=FALSE)
cat("\nevents with a diagnosis:", nrow(d), " of ", nrow(T),
    sprintf(" (%.1f%%)\n", 100*nrow(d)/nrow(T)))
cat("events with NO diagnosis:", sum(is.na(T$diagnosis)), "\n")

cat("\n"); line()
cat("RAW `category` FIELD - kept verbatim but NOT used for the intent split\n"); line()
rc <- T[!is.na(T$raw_category), ]
x <- aggregate(cbind(events=treatment_id) ~ raw_category + drug_class, rc, FUN=length)
print(x[order(-x$events), ], row.names=FALSE)
cat("\nfilled on", nrow(rc), "of", nrow(T), sprintf(" rows (%.0f%%) - too sparse and too\n", 100*nrow(rc)/nrow(T)))
cat("inconsistent to drive the routine/therapeutic split; medication is used instead.\n")

cat("\n"); line()
cat("SUMMARY OF THE DERIVED SPLIT\n"); line()
print(table(intent=T$treatment_intent, drug_class=T$drug_class))
cat("\n"); line()
cat("UNCLASSIFIED (should be empty; anything here needs a rule in R/treatment_map.R)\n"); line()
cat("drugs    :", sum(T$flag_unclassified_drug), "\n")
cat("diagnoses:", sum(T$flag_unclassified_disease), "\n")
