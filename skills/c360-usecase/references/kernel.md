# Studio kernel API (CUSTOMER_360_DB)

Deployed by `sql/app/26_usecase_studio.sql`. These procedures are the only way a
run touches production; they enforce the rules, the prompts don't have to.

## Registries (read)

| Object | What it tells you |
|---|---|
| `STUDIO.V_SIGNAL_CATALOG` | every live signal: origin, customers covered, observed values, `used_by` packs |
| `STUDIO.V_ACTION_CATALOG` | everything a pack may offer (`catalog_ref`, name, type, segment/age fit) |
| `STUDIO.V_USECASE_REGISTRY` | every decision pack: mode, implementation (GENERIC/LEGACY), version, tier, owner, counts |
| `STUDIO.CAPABILITY` | problem pattern → simplest Snowflake tool, precondition, whether this studio builds it |
| `CONFIG.GUARDRAIL` | live guardrails per pack, with citation |
| `APP.SIGNAL_SNAPSHOT` | current signal values per customer (what packs read) |

## Run lifecycle

```sql
CALL STUDIO.START_RUN(run_id, 'NEW'|'MODIFY', domain_id, brief);   -- MODIFY copies the live pack into the draft
CALL STUDIO.APPROVE(run_id, gate, 'APPROVE'|'REJECT'|'EDIT', who, comment);  -- bound to the current draft hash
SELECT STUDIO.DRAFT_HASH(run_id);
```

## Draft tables (write — all keyed by run_id)

| Table | Columns to fill |
|---|---|
| `STUDIO.DRAFT_DOMAIN` | run_id, decision_domain_id, label, eligibility_mode ('SIGNAL_MATCHED'), description, priority_tier, owner, objective, success_metric |
| `STUDIO.DRAFT_SIGNAL` | run_id, signal_name, method ('SQL'\|'AI_LABEL'), definition, category, description |
| `STUDIO.DRAFT_CANDIDATE` | run_id, candidate_id, decision_domain_id, business_domain_id, candidate_name, candidate_type, description, min_age, max_age, segment_fit, default_cost, requires_approval, catalog_ref |
| `STUDIO.DRAFT_RULE` | run_id, rule_id, decision_domain_id, candidate_id, match_type ('SIGNAL'), match_key (signal), match_value, weight |
| `STUDIO.DRAFT_GUARDRAIL` | run_id, guardrail_id, decision_domain_id, match_key (signal), match_value, reason, citation |

Use `INSERT … SELECT … UNION ALL SELECT …` (not `VALUES`).

## Signals

```sql
CALL STUDIO.MATERIALIZE_SIGNAL(run_id, signal_name);  -- whole book, into STUDIO.DRAFT_SIGNAL_VALUE
CALL STUDIO.EVALUATE_SIGNAL(run_id, signal_name);     -- AI_LABEL only: precision + Wilson 95% CI, rejected examples
```

**SQL** definition: one read-only SELECT returning
`customer_id, domain, signal_value, numeric_value, confidence, evidence_ref, quote`
(rows with value NULL or 'NONE' are dropped). Fully qualify tables.

**AI_LABEL** definition (JSON):
```json
{"instruction": "...what to look for, whose household...",
 "labels": {"label_a": "precise definition, incl. what is NOT this", "label_b": "..."},
 "source": "calls" | "emails",
 "prefilter": ["keyword", "..."],           // optional: only texts containing one go to the model
 "model": "llama3.1-70b"}                   // optional
```
Only the customer's own words are read (agent lines are dropped). The model must
pick one label or none and quote the proof.

## Simulate, release, rollback

```sql
CALL STUDIO.VALIDATE_RUN(run_id);  -- bounds B0–B9, see bounds.md
CALL STUDIO.SIMULATE(run_id);      -- whole book through APP.PACK_ENGINE (the production engine);
                                   -- reach, mix, suppression, violations, conflicts, before/after, bounds
CALL STUDIO.RELEASE_RUN(run_id);   -- refuses unless latest simulation is for the current hash with 0 violations
                                   -- and 0 failed bounds, and G3 + G4 are approved for that hash
CALL STUDIO.ROLLBACK_RUN(run_id);  -- restores exactly what the release replaced (newest release first)
```

## Serving

```sql
SELECT * FROM TABLE(APP.RECOMMEND_PACK(domain_id, customer_id));      -- one customer
SELECT * FROM TABLE(APP.PACK_ENGINE(NULL::VARCHAR, domain_id));       -- whole book, live config
SELECT * FROM TABLE(APP.PACK_ENGINE(run_id, domain_id));              -- whole book, a run's draft
```

`APP.PACK_ENGINE` is the set-based form of `APP.RECOMMEND_GENERIC` (same
eligibility, score, ranking and severity suppression — verified row for row),
plus guardrails and custom signals.
