# Skill: bootstrap a new decision use case on this platform

This is a transcription, not a proposal — it's the exact recipe followed twice
on this codebase (churn/retention in `sql/app/01-13`, personalization in
`sql/app/17-18`), extracted so a third use case (underwriting, collections
prioritization, fraud triage, whatever's next) is a checklist, not a
re-derivation from first principles.

Use this when: a new "detect signals → decide → act → learn" loop is needed
for a new kind of customer decision. Don't use this for a one-off report or
a UI tweak — this is for a genuine new decision engine.

## Before you start: the one fork you must choose deliberately

Every use case needs an **eligibility/matching paradigm** — how a candidate
(an action, a product, whatever this use case ranks) gets attached to a
customer. There are two proven shapes on this platform; pick one on purpose,
don't default into one by accident:

- **State-gated** (churn's shape): customer gets classified into a severity-
  tiered state (`ENGINE.CUSTOMER_STATE`), candidates are mapped to states
  (`CONFIG.ACTION_STATE_MAPPING`). Right for use cases that are fundamentally
  about escalating severity — "how bad is this, what do we do about it."
- **Signal-matched** (personalization's shape): candidates are matched
  directly against whatever signals the customer currently has
  (`CONFIG.PRODUCT_RULE` joined to `APP.V_ALL_SIGNALS`), no state machine
  involved. Right for use cases that are about *fit*, not severity —
  "what applies to this person," where nothing is escalating.

Underwriting, for example, is neither — it's a one-time (or rare)
origination decision for an entity that may have no history at all. Don't
force it into either shape without checking the three frictions named in the
architecture review (no-history applicants, non-RM action type, multi-year
feedback loop) first. If none of the existing shapes fit, that's a signal to
extend the platform, not to bend the use case.

## The checklist

### 1. Scope the entity and data
What's being decided about whom, and which `RAW.*` tables hold the evidence?
List them explicitly before writing anything — `DISCOVER_SIGNALS` (see step
2) can only propose signals from tables that exist.

### 2. Register signals — run discovery first, don't hand-write from scratch
Run `CALL APP.DISCOVER_SIGNALS()` against the new source tables before
writing a single `SIGNAL_DEFINITION` row by hand. It proposes deterministic
candidates for structured columns (dates → proximity, low-cardinality
columns → flags) and AI-classified candidates for free text, for free. Only
hand-write a signal if discovery genuinely can't reach it — e.g.
`product_interest` in `sql/app/17_personalization.sql`, which needed a
*multi-call* synthesis discovery has no concept of.

Assign each new signal a `category` (`RISK` / `SERVICE` / `OPPORTUNITY` —
see `sql/app/16_signal_discovery.sql`; don't invent a fourth bucket without
revisiting the whole taxonomy, the UI groups by exactly these three).

**If any signal needs an AI classification** (an `INTENT`-method signal),
constrain it to a fixed, pre-approved vocabulary and enforce that vocabulary
in *two* places independently: the prompt text, and a hardcoded guard in the
procedure that rejects anything outside the list. See
`EXTRACT_PRODUCT_INTEREST` in `sql/app/17_personalization.sql` — and note
the bug that verification caught: the guard-list and the prompt's vocabulary
drifted out of sync after an edit. Keep them next to each other in the file,
and re-verify both after touching either one.

### 3. Define candidates and eligibility
Decide what's being ranked (an action, a product, a decision) and write the
`CONFIG.*_RULE` or `CONFIG.ACTION_STATE_MAPPING`-equivalent table: which
signals move a candidate's score, by how much, and what makes a candidate
eligible in the first place (age/segment/domain bounds — see
`CONFIG.PRODUCT_CATALOG`'s `min_age`/`max_age`/`segment_fit` columns for the
pattern).

### 4. Write the deterministic scoring function — no AI calls inside it
One SQL table function: eligible-candidates CTE → signal-match CTE →
score CTE → rank. Template: `APP.RECOMMEND_PRODUCT` in
`sql/app/17_personalization.sql`. This is the one piece of the whole loop
that must never call `AI_COMPLETE` — the model gets to classify and extract
upstream of this function, never to decide inside it.

**Verify determinism before moving on**, don't assume it: call the function
5 times for the same customer, diff the output. If anything differs,
look first at any `LISTAGG`/aggregate without an explicit `ORDER BY` —
that's the exact bug this caught in `RECOMMEND_PRODUCT` the first time.

### 5. Check cross-domain interaction, don't assume isolation
Before shipping, ask: does this use case's output make sense for a customer
who's in a bad state in *another* domain? Churn didn't know about
personalization and briefly recommended upselling someone about to leave —
see `sql/app/18_cross_domain.sql` for the fix pattern (the new engine reads
the other domain's current state and marks candidates `SUPPRESSED` with a
reason — never silently drops them; the UI shows suppressed candidates, not
an empty list, so the reasoning is visible).

### 6. Effectiveness loop
One table (`offered_count`, `accepted_count`, `acceptance_rate`,
`confidence`), one `RECORD_*_OUTCOME` procedure, same formula every time:
`confidence = LEAST(0.99, 1 - 1/SQRT(offered_count + 2))`. Template:
`ENGINE.PRODUCT_EFFECTIVENESS` / `APP.RECORD_PRODUCT_OUTCOME`.

### 7. Register with the Agent
Add a thin `*_ACTION` procedure wrapper (same signature as the table
function, just callable by the Agent's `generic` tool type) and register it
plus any new Cortex Search service in `CUSTOMER_360_AGENT`'s
`tool_resources`. Update the agent's `orchestration` instructions text to
say explicitly which questions route to the new tool and which don't —
vague instructions make the agent chain tools it doesn't need.

### 8. UI surface
At minimum: wire the new intent into `sf.chat_classify`'s intent list and
`sf.run_chat`'s dispatch (`streamlit/utils/sf.py`) so it's reachable from
the chat without a dedicated page. Add a dedicated console page only if the
use case needs its own dense view (Signal Discovery and My Feed both
warranted one; most things don't).

### 9. Verify before calling it done
- **Determinism**: 5 identical calls, diffed (step 4).
- **Guardrail**: any AI classification rejects out-of-vocabulary output,
  and the test actually exercises a value *not* in the vocabulary, not just
  the happy path.
- **Cross-domain**: at least one customer in a bad state in another domain,
  confirm this use case's output accounts for it (step 5).
- **Effectiveness loop closes**: record two outcomes (one accept, one
  decline), confirm `acceptance_rate` moves and the new rate is visible in
  the scoring function's next call — not just written to the table.

## Update: the generic path now exists for SIGNAL_MATCHED use cases

`sql/app/19_decision_domain_registry.sql` built the registry this section
used to call future work: `CONFIG.DECISION_DOMAIN`, `CONFIG.DECISION_CANDIDATE`,
`CONFIG.DECISION_RULE`, `ENGINE.DECISION_EFFECTIVENESS`, and one function,
`APP.RECOMMEND_GENERIC(decision_domain_id, customer_id)`. It's purely
additive — churn and personalization still run on `RECOMMEND` and
`RECOMMEND_PRODUCT` exactly as before; nothing existing was touched, so it
can be deleted without affecting either live engine.

**For a new SIGNAL_MATCHED use case (fit, not severity), steps 3, 4, 6, 7 of
this checklist collapse into config inserts — skip writing a new scoring
function or effectiveness table entirely:**
1. `INSERT` one row into `CONFIG.DECISION_DOMAIN` (`eligibility_mode =
   'SIGNAL_MATCHED'`, `implementation = 'GENERIC'`).
2. `INSERT` candidates into `CONFIG.DECISION_CANDIDATE`.
3. `INSERT` matching rows into `CONFIG.DECISION_RULE` (`match_type='SIGNAL'`,
   `match_key` = signal_name, `match_value` = signal value, `weight`).
4. Call `APP.RECOMMEND_GENERIC(your_domain_id, customer_id)` — ranked,
   suppressed-against-churn-severity, effectiveness-aware, out of the box.
   Record outcomes with the existing `APP.RECORD_DECISION_OUTCOME`.

Verified by replaying personalization's own `PRODUCT_CATALOG`/`PRODUCT_RULE`
data through `RECOMMEND_GENERIC` under a reference domain id
(`personalization_generic_ref`) and diffing against `RECOMMEND_PRODUCT` for
8 real customers — byte-identical candidate sets, rankings, scores, and
suppression flags everywhere both returned rows.

**STATE_GATED use cases are only partially covered**, and that limit is
deliberate, not an oversight: `APP.RECOMMEND_GENERIC` supports gating
candidates against the *existing, shared* `ENGINE.CUSTOMER_STATE` table
(useful for a new domain that reacts to churn states churn already
computes), but it does **not** reproduce `RECOMMEND`'s persona-weighted
uplift/value/cost/confidence scoring or its approval-ceiling policy math —
that's real, bespoke engineering, and forcing it into one generic formula
would have been exactly the over-engineering this doc warns against. A
third use case that needs its *own* independent state machine still needs
`CUSTOMER_STATE` to gain a decision-domain partition key first (an additive
`ALTER TABLE ... ADD COLUMN`, not a redesign) — that remains genuinely
future work, not something to improvise mid-bootstrap. `COMPUTE_STATE_FOR`'s
hardcoded predicates are likewise still untouched.
