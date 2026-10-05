# Use-case card · life_event_upgrade · run UC-20261005-2055

| Field | Value |
|---|---|
| Brief | "Find health policyholders whose cover no longer fits their life and offer the right upgrade." |
| Mode | NEW (no live pack has this objective; overlaps checked below) |
| Label | Life-Event Cover Upgrade |
| Objective | Offer the right cover upgrade when a policyholder's household or cover needs change |
| Population | Insurance customers with an active health policy: 500 (Individual 192, Family Floater 171, Senior Citizen 102, Corporate Group 35) |
| Decision grain | customer (platform grain; offers are per policyholder) |
| Tier | GROW *(inferred)* — below PROTECT/RETAIN/SERVICE: never upsell someone at churn risk or owed a fix |
| Owner | Head of Health Products *(inferred)* |
| Success metric | Offer accepted within 45 days — recorded per offer via `APP.RECORD_DECISION_OUTCOME` *(inferred)*. Computable from day 1 as acceptance; "upgrade actually bought" needs policy endorsement data the platform doesn't have yet |
| Offers in scope (catalog) | `ins_prod_maternity` (21–45), `ins_prod_supertopup` (18–65), `ins_prod_senior` (Senior Citizen, 60–80) |
| Catalog request | "Add a dependent parent / new spouse to the floater" — no catalog product; raised, not invented |
| Overlaps | `personalization` (LEGACY) also offers maternity / senior / super top-up on `product_interest` alone; this pack differs by acting on life events and cover adequacy. `service_recovery` may act on the same customers — guardrails resolve it (protect > grow) |

Open questions: none — every field above has a default the expert can override at G1.
