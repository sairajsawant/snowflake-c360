# Customer 360 Decisioning Platform

**Snowflake CoCo CLI Hackathon 2026 · GCC Edition**
**Team:** Simplifiers · **Problem statement:** #2 — Customer 360 and Next Best Action Engine

One platform that turns every customer touchpoint — policies, claims, payments, calls,
emails and tickets — into a single live customer view, reads what customers actually
say with Cortex AI, recommends the next best action with approved business rules, and
learns from every outcome. Everything runs inside Snowflake.

---

## Try it

| | |
|---|---|
| **App** | [Customer 360 Decisioning Platform](https://app.snowflake.com/KRYZXYH/eg26106/#/streamlit-apps/CUSTOMER_360_DB.APP.CUSTOMER_360_APP) |
| **Account** | `KRYZXYH-EG26106` |
| **User** | `C360_JUDGE` |
| **Password** | `N!#^la4M#5ypy1` |
| **Role** | `C360_JUDGE` (default) |
| **Warehouse** | `COMPUTE_WH` (default) |

The judge role can use the app, the Cortex Agent, the semantic view, both Cortex Search
services and the published CoCo CLI skills. Runs you make in the app are recorded and
can be undone from the sidebar (**Start over**), so you can't break anything for the
next judge.

> The first page load can take a few seconds while the warehouse starts.

---

## The problem

Insurers and lenders already hold the evidence of what a customer is about to do —
it's spread across systems nobody reads together.

- **Scattered data.** Policies, claims, payments, calls, emails and tickets live in separate systems.
- **Missed warnings.** A customer threatens to switch insurers on a call while their claim
  sits stuck for weeks. Nobody links the two.
- **Inconsistent action.** Every relationship manager decides alone, and nobody learns
  which actions actually work.

**Who it's for**

| Persona | Sees | Can do |
|---|---|---|
| Relationship Manager | their own book | work a ranked daily list, act on recommendations |
| Team Lead | the team's customers | approve larger offers (up to ₹83 lakh) |
| Analyst / Domain Expert | the whole book | tune signals, weights and rules without code |

Context: Indian health insurance and retail lending — IRDAI grievances, cashless
pre-authorisation, portability, EMI stress.

---

## Our approach: an enterprise decisioning platform

We built a platform that any customer use case plugs into, instead of a single churn
model. Five ideas carry it:

1. **Layered and isolated.** Unify → Understand → Decide → Act. Each layer only reads from
   the one before it, so any layer can change without touching the rest.
2. **AI reads, rules decide.** Cortex AI extracts facts from conversations into a fixed
   vocabulary, and every signal keeps the exact sentence that justifies it. Recommendations
   are scored by deterministic rules over measured track records, so the same input always
   gives the same, explainable answer.
3. **Learns from outcomes.** Every accepted or declined action updates the success rate and
   confidence the scoring reads next time.
4. **People in the loop.** The platform watches every customer on a schedule and routes each
   decision to the person with the right authority. Spending limits are enforced per role.
5. **Configuration-driven.** Signals, weights, limits, rules — and whole new use cases — are
   configuration. A third decision engine (Service Recovery) was added with 19 configuration
   rows and no engine code.

---

## Architecture

![High-level architecture](docs/images/architecture.png)

| Layer | What it does | Snowflake features |
|---|---|---|
| **1 · Unify** | 18 source tables mapped into one canonical model (customer, account, product, interaction, event) and a unified profile; a semantic view gives every consumer the same governed definitions | Dynamic Tables, Streams, Semantic View |
| **2 · Understand** | 25 signal definitions across Risk, Service and Opportunity; AI signals carry their evidence quote and confidence; daily discovery proposes new signals for an analyst to approve | AI_COMPLETE, AI_SENTIMENT, AI_SUMMARIZE, Snowpark |
| **3 · Decide** | Three independent engines — churn & retention, personalization, service recovery — on a shared signal vocabulary, with cross-domain suppression so nobody is upsold while at risk or owed a fix | Deterministic SQL scoring, decision registry |
| **4 · Act** | My Feed, chat, Cortex Agent and Scenario Studio; approvals by role; outcomes feed the learning loop | Streamlit in Snowflake, Cortex Agent, Cortex Search |
| **Orchestration** | Scheduled pipeline, change detection, daily signal discovery | Streams & Tasks, Snowpark Python |
| **Governance** | Personas and scopes, approval limits, full audit trail with undo | Role-based access |

---

## What's in the app

The app has two modes, picked in the sidebar. **Acting as** switches the persona, which
changes what you see and what you're allowed to approve.

### Scenario Studio — the full loop on any customer

Pick a situation, give the system something new to react to, then walk the five stages.
Every figure is read back from Snowflake after the write that produced it.

| Step | What happens |
|---|---|
| **Stage an event** | Choose any of the 30 customers. Describe what happened in your own words and AI writes a realistic call grounded in that customer's real policies and claims — or pick a past call, or paste your own |
| **Detect** | The call is stored and read for signals; each one shows the evidence quote and confidence |
| **Understand** | The customer's state is recomputed; conflicting evidence is resolved by severity |
| **Decide** | Approved actions are ranked for your role, with the scoring explained and every spending limit checked |
| **Act** | The action is carried out, the customer is notified, and a call brief is written from their own evidence. A follow-up call can be fed back into the loop |
| **Learn** | The outcome is recorded and the recommender is re-run on the same customer to show what changed |

Four ready-made scenarios:

| Scenario | Customer | Shows |
|---|---|---|
| **A · Save the corporate account** | Arun Mehta (INS-1011) | the whole loop end to end, with contradictory evidence resolved |
| **B · When the machine must ask** | Suresh Reddy (INS-1005) | spending limits that block, and a person approving with a change |
| **C · Same engine, different industry** | Rekha Acharya (LND-2010) | the same engine running on lending, only configuration differs |
| **D · A customer we barely know** | Vikram Malhotra (INS-1007) | restraint — one weak signal is not grounds for an intervention |

### Operations Console — the everyday product

| Page | What it's for |
|---|---|
| **My Feed** | Today's ranked worklist across all three engines: at risk first, then customers we owe a fix, then genuine opportunities |
| **Decision Queue** | Who needs attention, ordered by severity and relationship value |
| **Approvals** | Offers waiting on your authority |
| **Customer 360** | Profile, why they're in their state, timeline, tickets, email threads, policy history, regulatory filings, recommendation |
| **Portfolio & Learning** | Value at risk by state, and each action's real track record |
| **Ask the data** | A chat that answers questions about any customer and remembers who you were asking about |
| **Config Studio** | Scoring weights by role, approval limits, state rules and signal definitions |
| **Signal Discovery** | Daily suggestions for new signals, ready to approve or dismiss |

---

## How to test each feature

Each check takes a minute or two. Unless noted, stay in the default persona
(**Relationship Manager 1**).

**1. One live customer view**
Operations Console → **Customer 360** → pick *INS-1011 — Arun Mehta*. You'll see his
relationship value, open tickets and SLA breaches, and alerts above the tabs. Open
**Why this state** to see every signal behind his risk level, which ones were read from
source systems and which were extracted from what he said.

**2. AI that cites its evidence**
In **Why this state**, the evidence column shows the transcript each AI signal came from.
In Scenario Studio, the **Detect** step shows each extracted signal with its supporting
quote and confidence.

**3. Next best action, explained**
Customer 360 → **Recommendation** tab. Each action shows its rank, track record, sample
size and whether it needs approval. Switch **Acting as** to **Team Lead** and reopen it —
roles weigh cost and value differently, so the order can change.

**4. The ranked worklist**
Operations Console → **My Feed**. Customers at risk come first with the retention action,
then customers we owe after a service failure, then product opportunities. Click
**Refresh** to bring the signals up to date.

**5. Cross-domain suppression**
In My Feed, notice that nobody at high risk is offered a product. In **Ask the data**,
type *"What product should we offer Arun Mehta at renewal?"* — the product comes back
held back, and **See the data behind this** gives the reason: he's at high churn risk, so
retention comes before any upsell.

**6. Ask in plain English, with follow-ups**
**Ask the data**, then try in order:
- *"Summarise customer INS-1005 for me"*
- *"What should we do about him?"* — resolves "him" to Suresh Reddy and runs the retention engine
- *"We let INS-1001 down — what should we do to make it right?"* — routes to service recovery
- *"Find calls about customers threatening to switch insurers"* — searches past calls
- *"What does the Super Top-up Health Cover include?"* — searches product documents

Each answer names the capability it used, and **See the data behind this** shows the
exact rows it came from.

**7. Human in the loop and spending limits**
Scenario Studio → **B · When the machine must ask** → walk to **Decide**. As a
Relationship Manager you can't approve the strongest option. Switch **Acting as** to
**Team Lead**, then approve or change the offer amount and watch the limit checks
re-evaluate. Operations Console → **Approvals** lists everything waiting on you.

**8. The learning loop**
Scenario Studio → **A** → complete **Act**, then **Learn**. The outcome updates the
action's track record, and the recommender is re-run on the same customer to show the
new ranking. **Portfolio & Learning** shows each action's success rate and flags any
that haven't been tried enough to trust.

**9. Domain portability**
Scenario Studio → **C · Same engine, different industry**. The same engine runs a lending
customer through the same steps with lending-specific actions.

**10. Restraint**
Scenario Studio → **D · A customer we barely know**. With only one weak signal, nothing
is recommended, and the app explains why.

**11. Configuration, not releases**
Switch **Acting as** to **Analyst / Domain Expert** → **Config Studio**. Review scoring weights by role,
approval limits, the state ladder and every signal definition, with how each one is found.

**12. Self-improving signal layer**
**Signal Discovery** (as Analyst / Domain Expert) → **Run discovery now**. The platform scans data
nothing is using yet, proposes new signals with an AI summary of what changed, and waits
for you to promote or dismiss each one.

**13. Cortex Agent**
In Snowsight, open **AI & ML → Agents** (or Snowflake Intelligence) and choose
`CUSTOMER_360_AGENT`. Ask *"Who needs attention today?"* or *"What should we do about
Suresh Reddy?"*. It uses the same tools as the app.

**14. Governed analytics**
In Snowsight, open **AI & ML → Cortex Analyst** with the semantic view
`CUSTOMER_360_DB.APP.CUSTOMER_DECISIONING_VIEW` and ask a portfolio question in plain English.

**15. CoCo CLI skills**
The four skills are published to the stage `@CUSTOMER_360_DB.APP.SKILLS/`. With CoCo CLI
connected to the account, add them with `cortex skill add @CUSTOMER_360_DB.APP.SKILLS/`,
confirm with `cortex skill list`, then ask *"What should we do about Suresh Reddy?"*.

---

## Snowflake capabilities used

| Capability | Used for |
|---|---|
| Dynamic Tables | keeping the unified customer view current |
| Streams & Tasks | detecting change and running the pipeline on schedule |
| Snowpark Python | portfolio-wide scoring and signal discovery |
| Semantic View | shared, governed business definitions |
| AI_COMPLETE | intent from calls, held to a fixed list, with structured output |
| AI_SENTIMENT | tone of every conversation |
| AI_SUMMARIZE | a customer's history in one paragraph |
| Cortex Search | searching calls, emails and product documents |
| Cortex Agent | natural-language access to every tool |
| Streamlit in Snowflake | the app, running next to the data |
| Role-based access | each persona sees only its own book |
| CoCo CLI | built the platform and packages it as reusable skills |

## CoCo CLI

CoCo CLI was used end to end: to generate the synthetic seed data, to build the
pipeline, semantic view and agent, and to package the platform as four reusable skills
published to a Snowflake stage.

| Skill | What it does |
|---|---|
| **c360-customer-query** | answers any question about a customer by routing it to the one capability that answers it, grounded in what that capability returns |
| **c360-signal-onboarding** | discovers, reviews and adds new signals for every engine to use |
| **c360-decision-domain** | onboards a new decision use case as configuration |
| **c360-decision-audit** | verifies a decision engine is repeatable, guarded and learning |

---

## Data

A small, high-quality synthetic Indian dataset, generated with CoCo CLI from Kaggle and
IRDAI samples. No real customer data is used.

| | |
|---|---|
| Customers | 30 (20 health insurance, 10 retail lending) |
| Source tables | 18, about 870 records |
| Conversations | 34 call transcripts in English and Hinglish, 162 emails, 151 support tickets |
| Transactions | policies and 249 policy versions, 81 payments, claims, loans |
| Reference | 11 product documents, IRDAI grievances and portability requests |
| Live signals | 184, half of them read from what customers said |

## Enterprise readiness

- **Stays in Snowflake** — data, AI and the app all run inside the account.
- **Scoped by role** — relationship managers see their own book, team leads their team, analysts everything.
- **Spending limits** — offers above a role's limit wait for someone with the authority.
- **Evidence for every signal** — each AI signal keeps the quote and confidence behind it.
- **Repeatable decisions** — the same input always gives the same answer.
- **Full audit trail** — every recommendation, action and outcome is recorded and reversible.

## Built to extend

- **A new use case in 1–3 days.** Register a domain, add candidates and matching rules.
  Service Recovery was added this way: 19 configuration rows, no engine changes, and the
  existing engines returned identical results before and after.
- **A new domain in about 3 weeks** with a domain expert — for example mutual funds, with
  use cases like SIP stop risk, redemption intent on calls, tax-season fund fit and failed
  mandate recovery.
- **Scales at marginal cost.** The customer view refreshes incrementally, so AI cost grows
  with new conversations and rule cost with changed customers, not with the size of the book.
- **Next:** connect real CRM, policy, loan and contact-centre sources; post approved actions
  to Slack and Jira; finer access policies by region and branch; an AI wizard that drafts a
  new use case's configuration for a person to approve.

## Repository layout

| Folder | Contents |
|---|---|
| `sql/` | platform build, layer by layer |
| `streamlit/` | the app |
| `skills/` | the four CoCo CLI skills |
| `deck/` | submission deck and its editable architecture diagrams |
| `docs/` | architecture image and the use-case onboarding playbook |
| `scripts/` | data generation helpers |
