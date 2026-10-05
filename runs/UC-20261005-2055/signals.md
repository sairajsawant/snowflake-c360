# Signals · life_event_upgrade · run UC-20261005-2055

## cover_gap — SQL (records)
Highest active health policy per customer, sum insured vs segment, plus non-rejected claims filed in the last 12 months.

| Value | Rule | Customers |
|---|---|---|
| HIGH | claims in 12 months ≥ 40% of sum insured; or Family Floater ≤ ₹10 L; or Senior Citizen ≤ ₹5 L | 138 |
| MEDIUM | any other policy ≤ ₹5 L | 82 |

Coverage 44% of the book (220). Evidence per customer, e.g. *"Family Floater policy, sum insured INR 500,000, claims in last 12 months INR 0"*.

## life_event — AI_LABEL (what the customer said, last 3 calls, customer lines only)
Model `llama3.1-70b`, keyword prefilter, independent verification of every positive (`STUDIO.EVALUATE_SIGNAL`), gate = Wilson 95% lower bound ≥ 0.70.

| Round | Labels | Positives | Precision | 95% CI | Gate | What the evaluator rejected |
|---|---|---|---|---|---|---|
| 1 | marriage, pregnancy_or_newborn, parent_dependent | 59 | 0.81 | 0.696–0.893 | ✗ (by 0.004) | mother-in-law; parent in ICU without a cover request; pensioner who asked for nothing |
| 2 | parent_dependent tightened | 50 | 0.68 | 0.542–0.792 | ✗ | in-laws; parent in ICU; an HR manager asking about employees' parents |
| 3 | parent_dependent with explicit counter-examples | 40 | 0.875 | 0.739–0.945 | ✓ overall — but parent_dependent alone 13/18, CI 0.49–0.88 | pension-only mentions; parent in ICU |
| **final** | **parent_dependent dropped** | **22** | **0.909** | **0.722–0.975** | **✓** | two mis-selling complaints mentioning a delivery claim |

`parent_dependent` was dropped rather than shipped: after three rounds its own lower bound was 0.49. Senior offers rely on the reused `product_interest = senior_wellness` instead. `marriage` stays defined but no customer in this book mentions a recent marriage, so it has no hits today.

Quotes (verified):
- INS-1009 — *"Meri wife ka delivery hua Manipal Hospital mein."* → pregnancy_or_newborn
- INS-1004 — *"Now when I filed a claim for my delivery at Max Hospital, you rejected it…"* → pregnancy_or_newborn
