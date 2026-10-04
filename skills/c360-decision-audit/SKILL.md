---
name: c360-decision-audit
description: "Verify that a decision engine on the Customer 360 platform in CUSTOMER_360_DB is trustworthy before it is relied on — prove the scoring is deterministic by diffing repeated calls, confirm no AI call sits inside a scoring path, check that an AI classifier's vocabulary guard matches its prompt, confirm cross-domain suppression fires, and confirm the effectiveness loop actually closes. Use when: a new decision domain was just onboarded, a scoring function or rule set changed, a recommendation looks wrong or unstable, or asked whether the engine's output can be trusted or audited. Triggers: verify the engine, audit decisions, is it deterministic, determinism check, same question different answer, governance, guardrail, trustworthy answers, prove it is not hallucinating, effectiveness loop, cross-domain suppression, sanity check the recommendations."
---

# Audit a decision engine

Run this after onboarding a domain or changing any rule. Every check below has
caught a real defect on this platform — none of them are ceremony.

## 1. Determinism — call it repeatedly, diff byte for byte

The same question must return the same answer. Do not reason about whether it
is deterministic; run it.

```sql
SELECT 1 AS run, candidate_id, ranking, score
  FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('<domain_id>','<customer_id>'))
UNION ALL
SELECT 2, candidate_id, ranking, score
  FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('<domain_id>','<customer_id>'))
UNION ALL
SELECT 3, candidate_id, ranking, score
  FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('<domain_id>','<customer_id>'))
ORDER BY run, ranking;
```

Any difference across runs is a bug. **Look first at any `LISTAGG` or aggregate
without an explicit `ORDER BY`** — that is exactly what it caught in
`RECOMMEND_PRODUCT`, where `LISTAGG(DISTINCT …)` reordered its output between
calls. The fix is `WITHIN GROUP (ORDER BY <the same expression being
concatenated>)` — ordering by a different source column is rejected.

Second place to look: a `ROW_NUMBER()` whose `ORDER BY` has no tie-break. Two
candidates on an identical score will swap arbitrarily.

## 2. No AI inside the decision

Scoring must be pure SQL. The model may classify and extract *upstream*; it must
never pick the outcome.

```sql
SELECT GET_DDL('FUNCTION','CUSTOMER_360_DB.APP.RECOMMEND_GENERIC(VARCHAR,VARCHAR)');
```

Grep the body for `AI_COMPLETE`, `AI_CLASSIFY`, `AI_SENTIMENT`, `SNOWFLAKE.CORTEX`.
Any hit is a finding: the engine is no longer reproducible or auditable.

## 3. Vocabulary guard matches the prompt

For any `INTENT`-method signal, the allowed values are enforced in two places —
the prompt text and a hardcoded guard list. They must agree.

```sql
SELECT signal_name, extraction_prompt
FROM CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION
WHERE extraction_method = 'INTENT' AND active;

-- what the data actually contains
SELECT DISTINCT signal_name, signal_value
FROM CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT
WHERE signal_name IN (SELECT signal_name FROM CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION
                      WHERE extraction_method='INTENT' AND active);
```

A value present in the data but absent from the prompt's list means the two have
drifted. **Test with a value that is *not* in the vocabulary**, not just the
happy path — a guard that has never rejected anything has never been tested.

## 4. Cross-domain suppression fires

A customer in a bad state in another domain must not be sold to. Find one and
check:

```sql
SELECT customer_id, state_name, severity
FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
WHERE is_current AND severity >= 3 LIMIT 3;

SELECT candidate_id, suppressed, suppression_reason
FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('<domain_id>','<that_customer>'));
```

`SUPPRESSED = TRUE` with a populated reason is correct. Silently returning no
rows is **not** — suppressed candidates stay visible with their reason so the
reasoning is auditable.

## 5. Nothing is a valid answer

A customer who matches no rule must get an empty result, not a weak suggestion.
Pick someone with few signals and confirm zero rows. An engine that always
recommends something is not making a decision.

## 6. The effectiveness loop closes

Record two outcomes and confirm the rate moves **and** is read back by the next
scoring call — not merely written to the table.

```sql
CALL CUSTOMER_360_DB.APP.RECORD_DECISION_OUTCOME('<domain_id>','<cand_id>','<cust>',TRUE);
CALL CUSTOMER_360_DB.APP.RECORD_DECISION_OUTCOME('<domain_id>','<cand_id>','<cust>',FALSE);

SELECT candidate_id, offered_count, accepted_count, acceptance_rate, confidence
FROM CUSTOMER_360_DB.ENGINE.DECISION_EFFECTIVENESS
WHERE decision_domain_id = '<domain_id>';

-- must now reflect the new rate
SELECT candidate_id, effectiveness_rate, sample_size
FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('<domain_id>','<cust>'));
```

Confidence follows `LEAST(0.99, 1 - 1/SQRT(offered_count + 2))`, so thin samples
stay visibly uncertain rather than being treated like well-evidenced ones.

## Reporting

State what passed, what failed, and what you did not check. A finding with a
reproduction query beats a paragraph of reassurance. If every check passes, say
so plainly and name the customer ids used, so someone else can repeat it.
