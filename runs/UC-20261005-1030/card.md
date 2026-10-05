# Use-Case Card — Life Event Upgrade

| Field | Value |
|---|---|
| **Run ID** | `UC-20261005-1030` |
| **Decision Domain** | `life_event_upgrade` |
| **Mode** | NEW |
| **Label** | Life Event Upgrade *(inferred)* |
| **Objective** | Offer the right cover upgrade when a health policyholder's life circumstances change |
| **Decision Grain** | Customer *(inferred)* |
| **Priority Tier** | GROW (protect > retain > grow — never upsell someone we owe a fix) |
| **Owner** | Head of Health Products |
| **Eligibility Mode** | SIGNAL_MATCHED *(inferred)* |

---

## Population

| Segment | Customers | With product_interest signal |
|---|---|---|
| Individual | 192 | 62 |
| Family Floater | 171 | 52 |
| Senior Citizen | 102 | 34 |
| Corporate Group | 35 | 17 |
| **Total (insurance)** | **500** | **165** |

Age distribution (all insurance):

| Age Band | Count |
|---|---|
| 18–30 | 66 |
| 31–45 | 187 |
| 46–59 | 146 |
| 60+ | 101 |

---

## Success Metric

| Metric | Computable today? | Notes |
|---|---|---|
| **Upgrade bought within 45 days** | **Partially.** Upgrade events exist in `RAW.POLICY_VERSION` (`CHANGE_TYPE = 'UPGRADE'`). The platform can track offer → upgrade conversion by joining `APP.RECORD_DECISION_OUTCOME` with policy version changes within the 45-day window. A proxy is available immediately: outcome acceptance recorded by `RECORD_DECISION_OUTCOME`. Full metric requires a scheduled job joining accepted outcomes back to `POLICY_VERSION` upgrade rows. |

---

## Offers in Scope (from Action Catalog)

| catalog_ref | Name | Segment Fit | Age Range |
|---|---|---|---|
| `ins_prod_maternity` | Maternity Cover Add-on | Any | 21–45 |
| `ins_prod_critical` | Critical Illness Rider | Any | 25–65 |
| `ins_prod_senior` | Senior Citizen Wellness Plan | Senior Citizen | 60–80 |
| `ins_prod_corp_topup` | Corporate Group Top-up Cover | Corporate Group | 18–65 |
| `ins_prod_opd` | OPD and Daycare Cover | Any | 18–70 |
| `ins_prod_supertopup` | Super Top-up Health Cover | Any | 18–65 |
| `ins_prod_ncb_protect` | No-Claim Bonus Protector | Any | 18–70 |
| `ins_policy_review` | Policy Review (action) | Any | — |

All catalog_refs verified present in `STUDIO.V_ACTION_CATALOG`.

---

## Overlap with Live Packs

| Live Pack | Overlap | Mitigation |
|---|---|---|
| `personalization` / `personalization_generic_ref` | **High.** Already uses `product_interest` signal to match offers. 165 customers overlap. | This pack adds *life-event context* (age-band, coverage gap, family stage) to sharpen which upgrade and when. Must de-duplicate: if `personalization` already offered the same `catalog_ref` to a customer, `life_event_upgrade` should yield. Tier is GROW for both — use recency: latest pack wins, or defer to personalization if it acted < 30 days ago. |
| `churn_retention` | **Moderate.** 42 customers with `product_interest = claim_protection` also have `churn_intent = HIGH`. | Tier precedence: PROTECT/RETAIN > GROW. Any customer with active churn/retention intervention is suppressed from upgrade offers per the stated priority ("never upsell someone we owe a fix"). |
| `service_recovery` | **Low.** Customers with `unresolved_claim` or `service_failure` signals. | Same tier rule: suppress upgrade offers while a service-recovery action is open. |

---

## Inferred Fields

All fields marked *(inferred)* above were filled by the scout. Specifically:
- **Label**: derived from domain name
- **Decision Grain**: customer (standard for this platform)
- **Eligibility Mode**: SIGNAL_MATCHED (brief says "find … whose cover no longer fits" → signal-driven matching)

---

## Open Questions (max 3)

1. **De-duplication rule with personalization pack**: Should `life_event_upgrade` replace the existing personalization logic for upgrade offers, or run in parallel with a cooldown window? (Recommended: 30-day cooldown.)
2. **Coverage-gap threshold**: What sum-insured shortfall (e.g., family income × 5 minus current cover) qualifies as "cover no longer fits"? Needed to define the `coverage_gap` signal threshold.
3. **Rider stacking limit**: Can the engine offer more than one rider/add-on per customer per cycle, or is it one best-fit offer?
