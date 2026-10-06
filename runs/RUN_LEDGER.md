# STUDIO.RUN_LEDGER — snapshot

Every gate decision of every use-case studio run, as stored in `CUSTOMER_360_DB.STUDIO.RUN_LEDGER`.
Each approval is bound to the draft's hash: change the draft after approving and the approval no longer counts.

Live query:
```sql
SELECT * FROM CUSTOMER_360_DB.STUDIO.RUN_LEDGER ORDER BY ts;
```

| Run | Gate | Decision | Approver | Draft hash | Comment | Time (US Pacific) |
|---|---|---|---|---|---|---|
| UC-20261005-2055 | G0 | OPENED | SAIRAJSAWANT30 | `a776581b` | Find health policyholders whose cover no longer fits their life and offer the right upgrade. | 2026-10-05 08:25:29 |
| UC-20261005-2055 | G1 | APPROVE | auto: recommended option | `2459a88e` | Card and plan accepted with defaults: GROW tier, 6 signals reused, build cover_gap (SQL) and life_event (AI_LABEL) | 2026-10-05 08:26:38 |
| UC-20261005-2055 | G2 | APPROVE | auto: recommended option | `ae8b8bbb` | cover_gap 220 customers; life_event precision 0.909 (CI 0.722-0.975) after 3 rounds, parent_dependent dropped | 2026-10-05 08:30:23 |
| UC-20261005-2055 | G3 | APPROVE | auto: recommended option | `2ea6dcef` | 157 reached, 0 violations, 0 conflicts after service guardrails | 2026-10-05 08:32:47 |
| UC-20261005-2055 | G4 | APPROVE | auto: recommended option | `2ea6dcef` | Release v1 | 2026-10-05 08:33:04 |
| UC-20261005-2055 | G4 | RELEASED | SAIRAJSAWANT30 | `2ea6dcef` | {"version": 1, "candidates": 3, "rules": 9, "guardrails": 8, "signals": 2, "config_rows": 23} | 2026-10-05 08:33:15 |

`UC-20261005-2055` built and released **Life-Event Cover Upgrade v1** (artifacts in [`UC-20261005-2055/`](UC-20261005-2055/)).
