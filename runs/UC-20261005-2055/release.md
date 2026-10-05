# Release · life_event_upgrade v1 · run UC-20261005-2055

Released through `STUDIO.RELEASE_RUN` after G3 and G4 were approved for draft hash `2ea6dcefecf6615ad1c368d926f93208`
(simulation: 0 violations, 0 failed bounds, 0 conflicts).

| Change | Rows |
|---|---|
| Decision domain `life_event_upgrade` (GENERIC, SIGNAL_MATCHED) + pack meta (v1, GROW, owner) | 1 |
| Offers: Maternity Cover Add-on, Super Top-up Health Cover, Senior Citizen Wellness Plan | 3 |
| Rules | 9 |
| Guardrails (cited) | 8 |
| Signals: `cover_gap` (SQL, 220 customers), `life_event` (AI_LABEL, 22 customers) — also registered in `CONFIG.SIGNAL_DEFINITION` | 2 |
| **Total configuration rows** | **23** |
| Engine code | 0 lines |

Verification:
```sql
SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_PACK('life_event_upgrade', 'INS-1009'));
-- 1  Super Top-up Health Cover   1.4  cover_gap=HIGH, life_event=pregnancy_or_newborn
-- 2  Maternity Cover Add-on      1.0  life_event=pregnancy_or_newborn
```
Evidence for INS-1009 (Rohit Joshi, rm1): *"Meri wife ka delivery hua Manipal Hospital mein."* ·
*"Family Floater policy, sum insured INR 500,000, claims in last 12 months INR 0"*. Matches the simulation.

Rollback (restores exactly what was there before — here, no pack):
```sql
CALL CUSTOMER_360_DB.STUDIO.ROLLBACK_RUN('UC-20261005-2055');
```
