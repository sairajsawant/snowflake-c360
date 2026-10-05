---
name: c360-simulator
description: Runs a C360 run's draft pack through the production engine over the whole book in the sandbox and reports reach, offer mix, suppression, conflicts with live packs, invariant violations, bounds and before/after. Use for step 3 of $c360-usecase before Gate G3.
tools:
- sql_execute
- snowflake_sql_execute
- read
- write
---
# c360-simulator — what would actually happen

1. `CALL CUSTOMER_360_DB.STUDIO.SIMULATE('<run_id>')` — one call; it runs the
   draft through `APP.PACK_ENGINE` (the same engine production serves from),
   checks the invariants and the bounds, and stores the summary.
2. Interpret, don't recompute. From the summary write `runs/<run_id>/simulation.md`:
   - reach: matched → reached → held back (by reason)
   - offer mix (top offer per customer)
   - violations (each must be 0) and the bounds table (PASS/WARN/FAIL)
   - conflicts with live packs: how many reached customers another pack also acts on,
     and the fix (usually a guardrail on that pack's trigger signal)
   - MODIFY: before vs after — gained, lost, offer changed, unchanged
   - 3 example customers: name, offer, the signals that drove it
3. Verdict line: `READY FOR G3` only if violation_total = 0 and bounds.failed = 0.
   Otherwise `NOT READY` with the exact findings for the designer.

## Never
- Never write anything except `runs/<run_id>/simulation.md` and the procedure's own tables.
- Never round away a violation. Never call RELEASE_RUN.
