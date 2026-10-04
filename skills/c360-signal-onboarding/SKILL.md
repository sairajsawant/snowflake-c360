---
name: c360-signal-onboarding
description: "Add a new signal to the Customer 360 platform in CUSTOMER_360_DB — run schema-driven discovery over RAW tables nothing has mined yet, review the proposed candidates, and promote one into CONFIG.SIGNAL_DEFINITION so every decision engine can use it. Covers the three signal categories (RISK / SERVICE / OPPORTUNITY), the difference between deterministic SQL signals and AI-extracted ones, and the two-place vocabulary guardrail that constrains any AI classification. Use when: adding something new for the platform to watch, mining an unused source table, reviewing discovered signal candidates, or asked how the platform learns what to look for. Triggers: new signal, add a signal, signal discovery, discover signals, promote candidate, signal definition, what should we watch for, mine a table, extraction prompt, signal category."
---

# Onboard a signal

Signals are the platform's shared vocabulary — every decision engine reads the
same signal layer, so a signal added once is available to all of them. There are
25 definitions producing 184 live rows across 30 customers.

## Always run discovery before hand-writing anything

```sql
CALL CUSTOMER_360_DB.APP.DISCOVER_SIGNALS();
```

It scans RAW tables nothing has mined yet and proposes candidates for free —
deterministic ones for structured columns (dates → proximity, low-cardinality
columns → flags) and AI-classified ones for free text. Review them:

```sql
SELECT candidate_id, signal_name, category, priority,
       source_table, source_column, rationale
FROM CUSTOMER_360_DB.APP.SIGNAL_CANDIDATE
WHERE status = 'NEW'
ORDER BY CASE priority WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END;

SELECT run_at, tables_scanned, candidates_found, ai_summary
FROM CUSTOMER_360_DB.APP.DISCOVERY_RUN ORDER BY run_at DESC LIMIT 1;
```

Promote or dismiss — nothing activates on its own:

```sql
CALL CUSTOMER_360_DB.APP.PROMOTE_SIGNAL_CANDIDATE('<candidate_id>');
CALL CUSTOMER_360_DB.APP.DISMISS_SIGNAL_CANDIDATE('<candidate_id>');
```

Only hand-write a signal when discovery genuinely cannot reach it — e.g. one
that needs synthesis across *multiple* calls, which discovery has no concept of.

## Categories — there are exactly three

| Category | Means | Example |
|---|---|---|
| `RISK` | predicts churn, default or attrition | `churn_intent`, `portability_intent` |
| `SERVICE` | operational friction **we** caused | `unresolved_claim`, `ticket_reopen` |
| `OPPORTUNITY` | relationship value or growth timing | `renewal_proximity`, `tenure_segment` |

Do not invent a fourth without revisiting the whole taxonomy — the UI groups by
exactly these three, and the decision domains are organised around them.

## Hand-writing one

```sql
INSERT INTO CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION
  (signal_id, domain_id, signal_name, signal_type, extraction_method,
   extraction_prompt, source_table, weight, active, category)
SELECT '<id>', '<insurance|lending>', '<signal_name>', '<type>',
       '<SQL|INTENT|SENTIMENT>', '<prompt or NULL>', '<RAW.TABLE>',
       <weight>, TRUE, '<RISK|SERVICE|OPPORTUNITY>';
```

`signal_id` is `VARCHAR(50)` — keep it short, longer values fail on insert.

## The guardrail for AI-extracted signals

An `INTENT`-method signal must be constrained to a **fixed, pre-approved
vocabulary**, enforced in *two* places independently:

1. the extraction prompt text, and
2. a hardcoded guard list in the procedure that rejects anything outside it.

Keep them adjacent in the file and re-verify **both** after touching either.
They have drifted apart before on this platform; the symptom is a value that
looks plausible, passes review, and silently makes a customer eligible for the
wrong thing. See `APP.EXTRACT_PRODUCT_INTEREST` for the working pattern.

## After promoting

The signal layer is materialised for speed, so republish before anything reads it:

```sql
CALL CUSTOMER_360_DB.APP.REFRESH_SIGNAL_SNAPSHOT();
SELECT signal_name, signal_value, COUNT(*) AS customers
FROM CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT
WHERE signal_name = '<signal_name>' GROUP BY 1,2;
```

Zero rows means the signal is defined but inert — check the source table has
data and the extraction actually ran, before wiring any rule to it.

## Then what

A signal on its own changes nothing. To make a decision engine act on it, add a
matching rule via the `c360-decision-domain` skill.
