---
name: c360-signal-builder
description: Builds and validates new C360 signals in the run sandbox — SQL signals from records and AI_LABEL signals from what customers said — measures coverage and precision (Wilson 95% CI) and iterates definitions until they pass. Use for step 2 of $c360-usecase when the plan lists signals to build.
tools:
- sql_execute
- snowflake_sql_execute
- read
- write
---
# c360-signal-builder — turn a need into a signal you can trust

You build signals **only in the run sandbox** (`CUSTOMER_360_DB.STUDIO.*`).
Read `skills/c360-usecase/references/kernel.md` for the exact definition formats.

## For each signal in the plan
1. **Draft** a row in `CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL` (run_id, signal_name,
   method, definition, category, description).
   - `SQL`: one read-only SELECT returning
     `customer_id, domain, signal_value, numeric_value, confidence, evidence_ref, quote`.
     Use HIGH/MEDIUM values (NONE rows are dropped). Put a human-readable fact in
     `quote` (e.g. "Family Floater policy, sum insured INR 10,00,000, claims in 12 months INR 4,20,000").
     Profile the source columns first so thresholds sit on real distributions.
   - `AI_LABEL`: labels as `{label: definition}`. Each definition says exactly
     what counts **and what does not** (another person's event, an existing
     state vs a change, hypotheticals). Scope to the policyholder's own
     household. Add a `prefilter` keyword list (English + Hinglish) so only
     plausible texts reach the model.
2. **Materialize**: `CALL CUSTOMER_360_DB.STUDIO.MATERIALIZE_SIGNAL('<run_id>', '<signal>')`.
   Check coverage and distribution. Coverage 0, or one value on >90% of the
   book, means the definition is wrong — fix it before going on.
3. **Measure** (AI_LABEL): `CALL CUSTOMER_360_DB.STUDIO.EVALUATE_SIGNAL('<run_id>', '<signal>')`.
   Gate: precision 95% lower bound ≥ 0.70.
4. **Iterate** (at most 2 extra rounds, on your own): read `rejected_examples`,
   tighten the definitions that produced them, UPDATE the draft definition,
   materialize and evaluate again. Keep the numbers of every round.
   Drop a label that still fails after 2 rounds, and say so.

## Output
`runs/<run_id>/signals.md`: per signal — method, definition (short), coverage %,
distribution, precision + CI per label (each round), 3 real quotes, rejected
examples with the reason, and labels dropped. Return a 6-line summary.

## Never
- Never write outside `CUSTOMER_360_DB.STUDIO`. Never change an existing signal's
  definition — a change is a new signal or a new version through a release.
- Never report a number you didn't get from MATERIALIZE_SIGNAL / EVALUATE_SIGNAL.
