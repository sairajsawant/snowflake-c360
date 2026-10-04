---
name: c360-customer-query
description: "Answer any question about a customer on the Customer 360 Decisioning Platform in CUSTOMER_360_DB — profile, why they are in their current state, a summary of their history, what retention action to take, what product fits them, what we owe them after a service failure, who needs attention across the portfolio, or a search across past calls, emails and product documents. Resolves the customer deterministically, routes the question to exactly one platform capability, and answers only from what that capability returned. Use when: asked anything about a named customer or customer id (INS-xxxx / LND-xxxx), asked what to do about a customer, asked who needs attention today, or asked to find past conversations. Triggers: customer 360, c360, profile for, summarise customer, summarize customer, what should we do about, recommended action, next best action, what product, upsell, renewal, offer, we let them down, service failure, unresolved claim, stuck claim, who needs attention, decision queue, my feed, find calls about, search transcripts, churn risk, at risk customer."
---

# Customer 360 query

One entry point for every question about a customer on this platform. The
platform decides; this skill routes and reports.

## Non-negotiables

1. **Never compute a recommendation yourself.** Scoring lives in deterministic
   SQL functions. Call the function and report what it returned. If you find
   yourself reasoning about which action is best, stop — you are doing the
   engine's job and your answer will not match the product.
2. **Never state a number, product, action or date that is not in the rows you
   got back.** If a query returns nothing, say nothing matched. Do not fill a
   gap with a plausible value.
3. **Resolve the customer before anything else** (step 1). Never guess an id
   from a name.
4. **One capability per question.** Pick the narrowest match in the routing
   table. Do not chain three calls to be thorough — that is how answers start
   contradicting the UI.
5. **Report suppression honestly.** If a row comes back with `SUPPRESSED = TRUE`,
   say so and give the `SUPPRESSION_REASON`. It is a deliberate product
   decision, not a filter to hide.

> The warehouse auto-suspends after 60s, so the first query of a session may
> take ~20–30s to resume. That is expected; do not retry.

## Step 1 — resolve the customer (always first)

```sql
SELECT customer_id, full_name, domain, segment
FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER
WHERE UPPER(customer_id) = UPPER('<mention>')
   OR full_name ILIKE '%<mention>%'
ORDER BY IFF(UPPER(customer_id) = UPPER('<mention>'), 0, 1), full_name
LIMIT 1;
```

No row → ask for a customer id (e.g. `INS-1011`) or a full name. Do not proceed.
Question is about the portfolio rather than one person → skip to the
`DECISION_QUEUE` / `UNIFIED_FEED_FAST` routes.

## Step 2 — route to exactly one capability

| The question is about… | Call |
|---|---|
| Who they are, current state, relationship value | `SELECT * FROM CUSTOMER_360_DB.APP.V_CUSTOMER_PROFILE WHERE customer_id = '<id>';` |
| **Why** they are in that state, evidence behind it | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.WHY_THIS_STATE('<id>'));` |
| Everything that has happened, dated | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.CUSTOMER_TIMELINE('<id>'));` |
| A narrative catch-up on their history | `CALL CUSTOMER_360_DB.APP.SUMMARIZE_CUSTOMER('<id>');` |
| What retention/servicing action to take for an at-risk customer | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND('<id>', 'rm1', 0::FLOAT));` |
| What product / offer / renewal fits them | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_PRODUCT('<id>'));` |
| What we owe them after a service failure, stuck claim, complaint | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC('service_recovery', '<id>'));` |
| Who needs attention across the book | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.DECISION_QUEUE('ALL', 'rm1', 'team_alpha'));` |
| Today's prioritised worklist (all three decision types, ranked) | `SELECT * FROM TABLE(CUSTOMER_360_DB.APP.UNIFIED_FEED_FAST('ALL', 'rm1', 'team_alpha', 'rm1', 12::FLOAT));` |
| Find past calls / tickets / emails on a topic | Cortex Search — see below |
| What a product covers, its terms or price | Cortex Search — see below |

### Cortex Search

The payload is a JSON **string**, so the query text is embedded, not bound.
Escape single quotes by doubling them.

```sql
-- past calls, tickets, emails
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'CUSTOMER_360_DB.APP.INTERACTION_SEARCH',
  '{"query": "<text>", "columns": ["CUSTOMER_NAME","SUBJECT","CONTENT","CUSTOMER_ID"], "limit": 5}'
)):results;

-- product documentation
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'CUSTOMER_360_DB.APP.PRODUCT_SEARCH',
  '{"query": "<text>", "columns": ["PRODUCT_NAME","PRODUCT_TYPE","DOMAIN_ID","CONTENT"], "limit": 5}'
)):results;
```

## Step 3 — answer

Two to four sentences, plain English, written for a relationship manager.
No table, view, procedure or column names in the prose — say "the retention
engine", not `APP.RECOMMEND`. Then, when a recommendation was returned, give
the one-line evidence behind it:

- `RECOMMEND` → `ACTION_NAME`, rank 1, with `EFFECTIVENESS_RATE` and
  `SAMPLE_SIZE` ("72% track record over 53 cases") and `POLICY_STATUS` if it
  needs approval.
- `RECOMMEND_PRODUCT` / `RECOMMEND_GENERIC` → `CANDIDATE_NAME` /
  `PRODUCT_NAME` with `MATCH_REASONS` (the signals that matched).
- `WHY_THIS_STATE` → name the signals and say which were read from source
  systems versus extracted from what the customer said.

## Worked examples

**"What should we do about INS-1005?"**
Resolve → `INS-1005` / Suresh Reddy. At-risk wording → `RECOMMEND`. Top row is
Claim Escalation. Answer: *"Suresh Reddy is at critical churn risk. The engine
recommends Claim Escalation — it has resolved 58% of comparable cases across 24
of them, and it is inside your authority so it can go ahead without sign-off."*

**"We let INS-1001 down — what should we do to make it right?"**
Service-failure wording → `RECOMMEND_GENERIC('service_recovery', …)`, **not**
`RECOMMEND`. Top row is Expedite the claim with the TPA, matched on
`unresolved_claim=1, claim_friction=HIGH`.

**"What product suits Arun Mehta at renewal?"**
Resolve name → `INS-1011`. → `RECOMMEND_PRODUCT`. If the row comes back
`SUPPRESSED = TRUE`, lead with that: *"Nothing should be offered yet — he is in
high churn risk, so the platform holds the upsell back and asks you to deal with
the retention issue first."*

**"Who needs attention today?"**
No customer → `UNIFIED_FEED_FAST`. Report the split by `FEED_TYPE`
(RETENTION / SERVICE / OPPORTUNITY) and name the top two or three.

## Follow-ups

A follow-up with only a pronoun ("what about his renewal?", "and them?")
refers to the customer already resolved in this conversation. Carry that id
forward; do not re-ask. If the user names a different customer, switch — do
not keep using the previous one.
