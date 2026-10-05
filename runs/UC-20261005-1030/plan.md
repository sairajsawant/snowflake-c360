# Build Plan — Life Event Upgrade

**Run ID:** `UC-20261005-1030`  
**Domain:** `life_event_upgrade`  
**Tool:** Rules over signals → `APP.PACK_ENGINE` (SIGNAL_MATCHED)

---

## Signal Plan

| # | Signal Name | Reuse / Build | Method | Source | Customers Covered | Notes |
|---|---|---|---|---|---|---|
| 1 | `product_interest` | **REUSE** | AI_LABEL (EXTRACTED) | Call transcripts, interactions | 165 (insurance) | Values: maternity_cover (27), critical_illness (12), senior_wellness (24), super_topup_cover (21), opd_cover (18), claim_protection (56), corporate_topup (6). Already used by `personalization` pack. |
| 2 | `coverage_downgrade` | **REUSE** | DERIVED | Policy records | 15 | Only HIGH value. Small but high-signal: these customers explicitly had cover reduced. |
| 3 | `renewal_proximity` | **REUSE** | DERIVED | Policy dates | 131 | Values: HIGH, MEDIUM. Useful for timing the offer near renewal. |
| 4 | `tenure_segment` | **REUSE** | DERIVED | Customer since date | 510 | Values: EARLY, MATURE. Filter out EARLY customers who haven't experienced a life change yet. |
| 5 | `age_band` | **BUILD** | SQL | `CANONICAL.CUSTOMER.DATE_OF_BIRTH` | ~500 (all insurance) | Derive: 18-30, 31-45, 46-59, 60+. Maps to product eligibility windows (maternity ≤45, senior ≥60, etc.). |
| 6 | `coverage_gap` | **BUILD** | SQL | `RAW.POLICY_VERSION.SUM_INSURED`, `CANONICAL.CUSTOMER.ANNUAL_INCOME` (if populated), family size from segment | ~500 | Ratio of current sum_insured to expected need. Threshold TBD (open question). Fallback: flag customers whose sum_insured hasn't increased in 3+ renewal cycles. |
| 7 | `life_stage_change` | **BUILD** | AI_LABEL | `RAW.INSURANCE_CALL_TRANSCRIPTS`, `RAW.EMAIL_MESSAGE` | Est. 50–100 | Labels: `new_baby`, `marriage`, `retirement_planning`, `child_leaving_home`, `job_change`. Captures life events mentioned in conversations that aren't product requests. |
| 8 | `negative_sentiment` | **REUSE** | EXTRACTED | Transcripts, interactions | 311 | Used as a **suppression** signal: HIGH sentiment → do not offer upgrade (tier rule). |
| 9 | `churn_intent` | **REUSE** | EXTRACTED | Transcripts | 257 | **Suppression**: HIGH → suppress from upgrade (PROTECT/RETAIN takes precedence). |
| 10 | `unresolved_claim` | **REUSE** | EXTRACTED | Claims system | 79 | **Suppression**: active unresolved claim → suppress upgrade offer. |

**Summary: 7 reused, 3 to build** (1 SQL fact, 1 SQL derived, 1 AI_LABEL).

---

## Tool Choice

| Considered | Decision | Reason |
|---|---|---|
| **Rules over signals (PACK_ENGINE)** | **Selected** | Signals with coverage exist (165 customers already have `product_interest`). Action catalog has all required offers. SIGNAL_MATCHED eligibility mode fits the "find and match" pattern. Available in Mini Studio. |
| SNOWFLAKE.ML.CLASSIFICATION (propensity) | Rejected | No labelled upgrade outcomes yet. Fewer than 200 historical conversions tagged. Can revisit after collecting outcomes via `RECORD_DECISION_OUTCOME` for one cycle. |
| SNOWFLAKE.ML.FORECAST | Not applicable | This is a targeting problem, not a volume forecast. |

---

## Rule Sketch (candidates × signals → offer)

```
IF product_interest = 'maternity_cover'
   AND age_band IN ('18-30','31-45')
   AND (renewal_proximity IN ('HIGH','MEDIUM') OR coverage_gap = 'HIGH')
   → ins_prod_maternity

IF product_interest = 'critical_illness'
   AND age_band IN ('31-45','46-59')
   → ins_prod_critical

IF product_interest = 'senior_wellness'
   AND age_band = '60+'
   → ins_prod_senior

IF product_interest = 'super_topup_cover'
   AND age_band IN ('31-45','46-59')
   → ins_prod_supertopup

IF product_interest = 'opd_cover'
   → ins_prod_opd

IF product_interest = 'corporate_topup'
   AND segment = 'Corporate Group'
   → ins_prod_corp_topup

IF life_stage_change IS NOT NULL
   AND coverage_gap = 'HIGH'
   → ins_policy_review   (catch-all: trigger a review before specific offer)
```

### Suppression guardrails
```
SUPPRESS IF churn_intent = 'HIGH'
SUPPRESS IF unresolved_claim = '1'
SUPPRESS IF negative_sentiment = 'HIGH'
SUPPRESS IF personalization pack acted on same customer < 30 days ago
```

---

## Success Metric Computability

| Metric | Source | Computable? |
|---|---|---|
| Upgrade bought within 45 days | `RAW.POLICY_VERSION` where `CHANGE_TYPE = 'UPGRADE'` within 45 days of offer | **Partially.** Policy version data exists. Need a scheduled join: `APP.RECORD_DECISION_OUTCOME` → `POLICY_VERSION` upgrades within window. |
| Proxy (immediate) | `APP.RECORD_DECISION_OUTCOME` acceptance flag | **Yes.** Available from day 1. |

---

## What Is Out of Scope

| Item | Reason |
|---|---|
| **Propensity model** | < 200 labelled outcomes. Collect via RECORD_DECISION_OUTCOME for one cycle, then revisit. |
| **Cross-sell to lending customers** | Brief is health-only. Lending domain has 10 customers, different product set. |
| **Automated fulfilment** | Upgrade offers require APPROVAL_REQUIRED workflow for premium-changing riders. `ins_policy_review` is AUTONOMOUS for the review step only. |
| **Family-member-level targeting** | Decision grain is customer, not member. Family Floater segment is treated as one customer unit. |
| **Offers not in catalog** | No "wellness add-on" or "dental rider" exists in `V_ACTION_CATALOG`. If needed, file a catalog request. |

---

## Overlap Summary

| Live Pack | Shared Customers | Risk | Action |
|---|---|---|---|
| `personalization` / `personalization_generic_ref` | ~165 | Duplicate upgrade offers | Cooldown rule: suppress if personalization acted < 30 days. Longer term: migrate upgrade logic into this dedicated pack. |
| `churn_retention` | ~42 (product_interest + churn_intent HIGH) | Upselling a customer we owe a fix | Hard suppress via tier rule (PROTECT/RETAIN > GROW). |
| `service_recovery` | ~15 (product_interest + unresolved_claim/service_failure) | Tone-deaf upsell during open issue | Hard suppress while recovery action is open. |
