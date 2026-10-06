# Validation Checklist — Customer 360 Decisioning Platform

## A. Foundation & Schema (5 checks)
- [x] Database CUSTOMER_360_DB exists with 7 schemas
- [x] RAW tables: 20 ins customers, 30 policies, 15 claims, 50 payments, 40 interactions, 10 transcripts
- [x] RAW tables: 10 lending customers, 15 loans, 40 payments, 20 interactions, 5 transcripts
- [x] CONFIG tables: 14 tables populated (DOMAIN_PACK, SIGNAL_DEFINITION, etc.)
- [x] Key demo customers present: C1023 (Sarah Chen), C1045 (Raj Patel), C1067 (Maria Santos), C1089 (James Wilson), C2001 (Priya Sharma), C2015 (Tom Nguyen)

## B. Pipeline & DT Health (7 checks)
- [x] 5 CANONICAL Dynamic Tables active (CUSTOMER=30, ACCOUNT=45, PRODUCT=55, INTERACTION=60, EVENT=15)
- [x] ENGINE.CUSTOMER_360 DT active (30 rows, joins all canonical tables)
- [x] No duplicate customers in CANONICAL.CUSTOMER
- [x] Source system tagging (insurance/lending) correct
- [x] Streams created: INTERACTION_STREAM, EVENT_STREAM
- [x] 3 tasks created and resumed: EXTRACT_SIGNALS_TASK -> COMPUTE_STATES_TASK -> DETECT_TRANSITIONS_TASK
- [x] Task chain executes without error (verified via CALL ENGINE.EXTRACT_SIGNALS/COMPUTE_STATES/DETECT_TRANSITIONS)

## C. Signal Extraction (6 checks)
- [x] ENGINE.SIGNAL populated (70+ signals)
- [x] Sentiment signals extracted from negative interactions
- [x] Intent signals extracted from transcripts (keyword fallback on trial; AI_COMPLETE on full account)
- [x] Unresolved claims signal for C1023, C1067
- [x] Renewal proximity signal for insurance customers
- [x] Delinquency signal for lending customers with late payments

## D. State Engine (6 checks)
- [x] All customers with signals have computed states
- [x] C1023 (Sarah Chen) = HIGH_CHURN_RISK
- [x] C1045 (Raj Patel) = LOW_CHURN_RISK
- [x] C1067 (Maria Santos) = HIGH_CHURN_RISK
- [x] C1089 (James Wilson) = MEDIUM_CHURN_RISK
- [x] SCD2 pattern: is_current + effective_from/to

## E. Decision Queue & Recommendations (6 checks)
- [x] Queue populated with severity >= 2 transitions
- [x] Urgency levels assigned correctly (CRITICAL/HIGH/MEDIUM/LOW)
- [x] RECOMMEND_ACTION returns ranked candidates for C1023
- [x] Scoring uses SCORING_CONFIG weights per persona
- [x] Retention Offer for Maria requires approval
- [x] No recommendations for LOW_CHURN_RISK customers

## F. Effectiveness & Learning (5 checks)
- [x] ACTION_EFFECTIVENESS pre-seeded with 13 baseline rows
- [x] Sample sizes range from 14 to 112
- [x] RECORD_OUTCOME updates effectiveness (verified: 32/47 -> 34/50 for claim_escalation)
- [x] Confidence values in 0.55-0.92 range
- [x] Idempotency: duplicate outcome recording returns SKIPPED

## G. Closed-Loop (4 checks)
- [x] RUN_DEMO executes all 12 acts successfully
- [x] Simulate -> Extract -> State -> Queue -> Recommend -> Execute -> Outcome -> Effectiveness
- [x] Effectiveness rate changes after outcome recording
- [x] Decision queue item marked RESOLVED after action execution

## H. Cortex Search (4 checks)
- [x] SEARCH.INTERACTION_DOCUMENTS table populated (61 docs)
- [ ] Cortex Search Service created (BLOCKED: trial account, AI embedding unavailable)
- [ ] Search returns relevant results for customer queries
- [ ] Filter by customer_id works

## I. Semantic View & Analyst (5 checks)
- [x] Semantic View YAML created with 3 tables, 2 relationships, 3 verified queries
- [x] YAML uploaded to @APP.SEMANTIC_STAGE
- [ ] Semantic View object created (BLOCKED: DDL not available on this account)
- [ ] Verified queries return correct results
- [ ] Persona-filtered queries work

## J. Cortex Agent (5 checks)
- [ ] Agent DDL written (BLOCKED: trial account limitations)
- [x] Tool stored procedures created and verified (GET_CUSTOMER_360, GET_DECISION_QUEUE, SUMMARIZE_CUSTOMER)
- [x] Agent Chat page uses keyword-based routing as fallback
- [ ] Agent selects correct tools
- [ ] Agent handles unknown customer gracefully

## K. Notifications (6 checks)
- [x] NOTIFICATION_CHANNEL table: 2 channels (Slack webhook, email)
- [x] NOTIFICATION_RULE table: 4 rules (2 insurance, 1 lending, 1 approval)
- [x] DISPATCH_NOTIFICATION formats templates correctly
- [x] NOTIFICATION_LOG populated (3 notifications for C1023 transition)
- [ ] Actual Slack delivery (requires webhook URL setup)
- [ ] Actual email delivery (requires email integration setup)

## L. Domain Portability (4 checks)
- [x] Lending states computed: C2001=HIGH_PAYMENT_RISK, C2015=HIGH_PAYMENT_RISK
- [x] Lending signals extracted (delinquency, hardship_intent, negative_sentiment)
- [x] Lending actions recommended via RECOMMEND_ACTION
- [x] Same SPs work for both domains (generic, config-driven)

## M. Edge Cases (5 checks)
- [x] Duplicate event handling (idempotent signal extraction via NOT EXISTS)
- [x] Missing signals: customers default to LOW state
- [x] Empty queue renders gracefully in Streamlit
- [x] Config changes via st.data_editor (read-only for non-analyst personas)
- [ ] Freshness detection (requires DT staleness monitoring setup)

## N. Personas (6 checks)
- [x] USER_PERSONA table: 4 personas
- [x] USER_PERSONA_ASSIGNMENT: 5 role mappings
- [x] RM: POLICY_CHECK returns BLOCKED for approval actions
- [x] Team Lead: can_approve = TRUE, max_approval = $25,000
- [x] VP: can_approve = TRUE, max_approval = $100,000
- [x] Analyst: can_configure = TRUE, can_approve = FALSE

## O. Streamlit Application (7 checks)
- [x] APP.CUSTOMER_360_APP deployed
- [x] 7 pages created with correct navigation
- [x] Decision flow stepper on every page
- [x] Persona selector in sidebar affects visibility
- [x] Domain selector switches data context
- [x] @st.dialog for approval workflow
- [x] Simulate New Event button on Queue page

## Summary
**Total Checks: 74**
**Passing: 59 (80%)**
**Blocked (trial account): 11 (15%)**
**Not Tested: 4 (5%)**

Key blockers on trial account:
1. AI_COMPLETE/AI_SUMMARIZE/AI_EMBED unavailable (Cortex Search, AI signal extraction)
2. Semantic View DDL not available
3. Cortex Agent DDL not available
4. Notification integrations require external webhook/email setup
