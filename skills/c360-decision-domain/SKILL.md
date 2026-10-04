---
name: c360-decision-domain
description: "Onboard a new decision use case onto the Customer 360 platform in CUSTOMER_360_DB as configuration rows rather than new code — register a decision domain, its candidates and its signal-matching rules, then serve it through the existing generic engine APP.RECOMMEND_GENERIC. Covers choosing between the two proven eligibility paradigms (signal-matched vs state-gated), writing the config, and the verification that must pass before it is considered done. Use when: adding a new kind of customer decision (collections prioritisation, fraud triage, onboarding nudges, win-back, service recovery), extending the platform to a new use case, or asked how a third/fourth decision engine would be built. Triggers: new use case, new decision domain, onboard a use case, add a decision engine, extend the platform, decision domain registry, RECOMMEND_GENERIC, bootstrap a use case, config-driven decisioning."
---

# Onboard a decision use case

A transcription of what was done three times on this platform — churn/retention,
product personalization, service recovery — not a proposal. The third one took
**19 config rows and no engine code**, which is the bar to hold to.

Do not use this for a one-off report or a UI tweak. This is for a genuine new
"detect signals → decide → act → learn" loop.

## The fork you must choose deliberately

| Paradigm | Shape | Right when | Built as |
|---|---|---|---|
| **SIGNAL_MATCHED** | candidates matched directly against the customer's current signals | the question is *fit* — "what applies to this person" | **config only** — this skill ends at step 4 |
| **STATE_GATED** | candidates gated by a severity-tiered state machine | the question is *escalating severity* — "how bad is this" | needs engine work, see limits below |

Pick on purpose. If the use case is about fit, SIGNAL_MATCHED is config-only and
you are done in minutes. If it is genuinely about escalating severity, read
"Limits" at the bottom before promising anything.

## Step 1 — find the gap, don't invent one

The strongest use case is one the data already supports and nothing acts on.
Ask which signals exist that no engine consumes:

```sql
SELECT sd.signal_name, sd.category,
       COUNT(DISTINCT s.customer_id) AS customers
FROM CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION sd
LEFT JOIN CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT s ON s.signal_name = sd.signal_name
WHERE sd.active
GROUP BY 1,2 ORDER BY customers DESC;

-- what the existing engines already consume
SELECT DISTINCT signal_name FROM CUSTOMER_360_DB.CONFIG.PRODUCT_RULE WHERE active;
SELECT DISTINCT match_key  FROM CUSTOMER_360_DB.CONFIG.DECISION_RULE WHERE active;
SELECT rule_expression     FROM CUSTOMER_360_DB.CONFIG.STATE_RULE   WHERE active;
```

Signals with real coverage that appear in none of those are your candidate use
case. **This is how service recovery was found** — the `SERVICE` category had
four populated signals and no engine, which was letting customers with
unresolved claims fall off every feed while customers we had given a poor
rating were being recommended an upsell.

## Step 2 — register the domain

```sql
INSERT INTO CUSTOMER_360_DB.CONFIG.DECISION_DOMAIN
  (decision_domain_id, label, entity_type, eligibility_mode, implementation,
   legacy_function_name, description)
SELECT '<domain_id>', '<Label>', 'CUSTOMER',
       'SIGNAL_MATCHED', 'GENERIC', NULL, '<one honest sentence>';
```

## Step 3 — candidates

What is being ranked. `business_domain_id` NULL means it applies to both
insurance and lending; age/segment bounds are optional.

```sql
INSERT INTO CUSTOMER_360_DB.CONFIG.DECISION_CANDIDATE
  (candidate_id, decision_domain_id, business_domain_id, candidate_name,
   candidate_type, description, default_cost, requires_approval,
   approval_threshold, active)
SELECT '<cand_id>', '<domain_id>', NULL, '<Name>', '<type>',
       '<what it actually is>', <cost>, FALSE, 0, TRUE
UNION ALL SELECT …;
```

## Step 4 — rules

Which signal, at which value, moves which candidate, by how much.

```sql
INSERT INTO CUSTOMER_360_DB.CONFIG.DECISION_RULE
  (rule_id, decision_domain_id, candidate_id, match_type, match_key,
   match_value, weight, active)
SELECT '<rule_id>', '<domain_id>', '<cand_id>', 'SIGNAL',
       '<signal_name>', '<signal_value>', <weight>, TRUE
UNION ALL SELECT …;
```

`match_value` must match the signal's stored value **exactly** — check first,
values are strings and some are `'1'` not `1`:

```sql
SELECT DISTINCT signal_name, signal_value
FROM CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT ORDER BY 1,2;
```

Use `INSERT … SELECT`, never `VALUES` — a `VALUES` clause here rejects function
calls and complex expressions. Make the script re-runnable by deleting the
domain's three row sets first.

## Step 5 — it already works

No function to write:

```sql
SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('<domain_id>', '<customer_id>'));
```

The effectiveness loop is shared too:

```sql
CALL CUSTOMER_360_DB.APP.RECORD_DECISION_OUTCOME('<domain_id>', '<cand_id>', '<customer_id>', TRUE);
```

## Step 6 — verify before calling it done

Run the `c360-decision-audit` skill. Minimum bar: identical output across
repeated calls, suppression behaves, and at least one customer who should get
nothing actually gets nothing.

## Surfacing it (this part is not config)

Config gets you the engine and a queryable capability. Giving the new domain a
place in the product is a small code change, and it is honest to say so:

- **Feed** — `APP.UNIFIED_FEED_FAST` needs a branch and a position in the
  `RETENTION → SERVICE → OPPORTUNITY` ordering.
- **Chat** — a new intent in `streamlit/utils/sf.py`: the prompt's intent list
  **and** the `valid` guard set, which must be edited together. They have
  drifted before and the symptom is a silently wrong classification.

## Limits — say these out loud rather than discovering them later

- `APP.RECOMMEND_GENERIC` hardcodes `CANONICAL.CUSTOMER`.
  `DECISION_DOMAIN.entity_type` exists but is **not** honoured, so a non-customer
  entity is not supported today.
- STATE_GATED domains can only reuse the churn state machine that already
  exists. A new, independent one needs a decision-domain key added to
  `ENGINE.CUSTOMER_STATE` — additive, but a schema change, not config.
- `ENGINE.COMPUTE_STATE_FOR` still has hardcoded predicates, so editing a state
  rule's *threshold* has no effect. Priority and the active flag do work.
