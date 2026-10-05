# Build plan · life_event_upgrade

## Signals

| Signal | Reuse / build | Method | Source | Coverage today |
|---|---|---|---|---|
| product_interest | reuse | (AI, live) | calls | 167 customers |
| renewal_proximity | reuse | (rule, live) | policies | 131 |
| grievance_filed | reuse — guardrail | (rule, live) | IRDAI grievances | 38 |
| claim_friction | reuse — guardrail | (rule, live) | claims | 110 |
| portability_intent | reuse — guardrail | (rule, live) | portability requests | 54 |
| csat_low | reuse — guardrail | (rule, live) | tickets | 61 |
| **cover_gap** | **build** | SQL | `RAW.INSURANCE_POLICIES` (sum insured, segment) + `RAW.INSURANCE_CLAIMS` (claims in 12 months) | 97 customers claimed in 12 months, 22 of them ≥40% of sum insured; Family Floater ≤ ₹10 L: 61; Senior ≤ ₹5 L: 59 |
| **life_event** | **build** | AI_LABEL | what the customer said on their last 3 calls (257 customers have calls) | — |

Not built: age or segment signals (they are eligibility limits on each offer); churn risk (the engine already holds those customers back).

## Tool choice (from STUDIO.CAPABILITY)
- Targeting by fit → **rules over signals, `APP.PACK_ENGINE`**. Simplest tool that meets the metric.
- `SNOWFLAKE.ML.CLASSIFICATION` not now: 0 labelled outcomes for this pack. The pack records acceptance from day 1, so ML becomes possible once ~200 outcomes exist.

## Out of scope
Pricing of the upgrade, underwriting of the higher sum insured (both stay with underwriting).
