-- =============================================================================
-- Signals, states and the decision queue for the scaled book (24_scale_data.sql).
--
-- Same logic as the per-customer engines, run set-based over the generated
-- customers only (INS-2xxx), so the original 30 customers are not touched:
--   * negative_sentiment, unresolved_claim  — rules, as ENGINE.EXTRACT_SIGNALS
--   * churn_intent + sentiment per call     — AI_COMPLETE / AI_SENTIMENT, as
--                                             APP.EXTRACT_SIGNALS_FOR
--   * email_escalation per latest thread    — AI_COMPLETE, as 14_signal_completion
--   * product_interest across recent calls  — AI_COMPLETE, as
--                                             APP.EXTRACT_PRODUCT_INTEREST
--   * state                                 — APP.COMPUTE_STATE_FOR's rules
-- Prompts are read from CONFIG.SIGNAL_DEFINITION, exactly as the procedures do.
-- Every AI signal keeps its verbatim quote and confidence in APP.SIGNAL_EVIDENCE.
-- Rule-derived signals (tickets, grievances, portability, renewals, payments,
-- employers…) need nothing here: APP.V_DERIVED_SIGNALS reads RAW directly.
-- Idempotent: clears prior rows for the generated customers first.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;

DELETE FROM APP.SIGNAL_EVIDENCE   WHERE customer_id LIKE 'INS-2%';
DELETE FROM ENGINE.SIGNAL         WHERE customer_id LIKE 'INS-2%';
DELETE FROM ENGINE.DECISION_QUEUE WHERE customer_id LIKE 'INS-2%';
DELETE FROM ENGINE.STATE_TRANSITION WHERE customer_id LIKE 'INS-2%';
DELETE FROM ENGINE.CUSTOMER_STATE WHERE customer_id LIKE 'INS-2%';

-- ── rules ────────────────────────────────────────────────────────────────────
INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value,
    numeric_value, confidence, evidence_ref, domain, extracted_at)
SELECT 'sig-sent-' || i.interaction_id, i.customer_id, 'ins_negative_sentiment', 'negative_sentiment',
    CASE WHEN i.sentiment_score < -0.6 THEN 'HIGH' WHEN i.sentiment_score < -0.3 THEN 'MEDIUM' ELSE 'LOW' END,
    ABS(LEAST(i.sentiment_score, 0)), 0.90, 'interaction:' || i.interaction_id, 'insurance', CURRENT_TIMESTAMP()
FROM CANONICAL.INTERACTION i
WHERE i.customer_id LIKE 'INS-2%' AND i.sentiment_score < 0;

INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value,
    numeric_value, confidence, evidence_ref, domain, extracted_at)
SELECT 'sig-claim-' || customer_id, customer_id, 'ins_unresolved_claim', 'unresolved_claim',
    COUNT(*)::VARCHAR, COUNT(*), 0.95, 'claims_system', 'insurance', CURRENT_TIMESTAMP()
FROM RAW.INSURANCE_CLAIMS
WHERE customer_id LIKE 'INS-2%' AND claim_status IN ('PENDING', 'UNDER_REVIEW')
GROUP BY customer_id;

-- ── calls: churn intent and sentiment ────────────────────────────────────────
CREATE OR REPLACE TEMPORARY TABLE APP.TMP_SCALE_CALLS AS
SELECT t.transcript_id, t.customer_id,
    PARSE_JSON(AI_COMPLETE(
        model => 'llama3.3-70b',
        prompt => p.extraction_prompt || '

TRANSCRIPT:
' || t.transcript_text || '

Return value as exactly one of HIGH, MEDIUM, LOW, NONE. Quote the single sentence from the
transcript that most supports your answer, verbatim. Give confidence between 0 and 1.',
        response_format => {'type':'json','schema':{'type':'object','properties':{
            'value':{'type':'string'},'quote':{'type':'string'},'confidence':{'type':'number'}},
            'required':['value','quote','confidence']}}
    )::VARCHAR) AS j,
    COALESCE(AI_SENTIMENT(t.transcript_text):categories[0]:sentiment::VARCHAR, 'neutral') AS sent
FROM RAW.INSURANCE_CALL_TRANSCRIPTS t
CROSS JOIN (SELECT extraction_prompt FROM CONFIG.SIGNAL_DEFINITION WHERE signal_id = 'ins_churn_intent') p
WHERE t.customer_id LIKE 'INS-2%';

INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value,
    numeric_value, confidence, evidence_ref, domain, extracted_at)
SELECT 'sig-x-' || customer_id || '-intent-' || transcript_id, customer_id, 'ins_churn_intent', 'churn_intent',
    UPPER(TRIM(j:value::VARCHAR)),
    CASE UPPER(TRIM(j:value::VARCHAR)) WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6 WHEN 'LOW' THEN 0.3 ELSE 0.0 END,
    j:confidence::FLOAT, 'transcript:' || transcript_id, 'insurance', CURRENT_TIMESTAMP()
FROM APP.TMP_SCALE_CALLS;
INSERT INTO APP.SIGNAL_EVIDENCE (signal_instance_id, customer_id, signal_name, quote, model, model_confidence)
SELECT 'sig-x-' || customer_id || '-intent-' || transcript_id, customer_id, 'churn_intent',
    j:quote::VARCHAR, 'llama3.3-70b', j:confidence::FLOAT
FROM APP.TMP_SCALE_CALLS;

INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value,
    numeric_value, confidence, evidence_ref, domain, extracted_at)
SELECT 'sig-x-' || customer_id || '-sent-' || transcript_id, customer_id, 'ins_negative_sentiment',
    'negative_sentiment',
    CASE WHEN n >= 0.7 THEN 'HIGH' WHEN n >= 0.45 THEN 'MEDIUM' ELSE 'LOW' END,
    n, 0.9, 'transcript:' || transcript_id, 'insurance', CURRENT_TIMESTAMP()
FROM (SELECT *, CASE sent WHEN 'negative' THEN 0.85 WHEN 'mixed' THEN 0.6
                          WHEN 'neutral' THEN 0.45 ELSE 0.2 END AS n FROM APP.TMP_SCALE_CALLS);
INSERT INTO APP.SIGNAL_EVIDENCE (signal_instance_id, customer_id, signal_name, quote, model, model_confidence)
SELECT 'sig-x-' || customer_id || '-sent-' || transcript_id, customer_id, 'negative_sentiment',
    'AI_SENTIMENT overall = ' || sent, 'AI_SENTIMENT', 0.9
FROM APP.TMP_SCALE_CALLS;

-- ── email: escalation tone of each customer's latest thread ──────────────────
CREATE OR REPLACE TEMPORARY TABLE APP.TMP_SCALE_MAIL AS
WITH latest AS (
    SELECT customer_id, ticket_id
    FROM RAW.EMAIL_MESSAGE WHERE customer_id LIKE 'INS-2%'
    GROUP BY customer_id, ticket_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY MAX(sent_at) DESC) = 1
), thread AS (
    SELECT l.customer_id, l.ticket_id,
        LISTAGG((CASE WHEN m.direction = 'INBOUND' THEN 'Customer: ' ELSE 'Insurer: ' END) || m.body, '\n---\n')
            WITHIN GROUP (ORDER BY m.thread_position) AS body
    FROM latest l JOIN RAW.EMAIL_MESSAGE m ON m.customer_id = l.customer_id AND m.ticket_id = l.ticket_id
    GROUP BY l.customer_id, l.ticket_id
)
SELECT t.customer_id, t.ticket_id,
    PARSE_JSON(AI_COMPLETE(
        model => 'llama3.3-70b',
        prompt => p.extraction_prompt || '

EMAIL THREAD:
' || t.body || '

Return value as exactly one of HIGH, MEDIUM, LOW, NONE. Quote the single sentence that most
supports your answer, verbatim. Give confidence between 0 and 1.',
        response_format => {'type':'json','schema':{'type':'object','properties':{
            'value':{'type':'string'},'quote':{'type':'string'},'confidence':{'type':'number'}},
            'required':['value','quote','confidence']}}
    )::VARCHAR) AS j
FROM thread t
CROSS JOIN (SELECT extraction_prompt FROM CONFIG.SIGNAL_DEFINITION WHERE signal_id = 'ins_x_emailtone') p;

INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value,
    numeric_value, confidence, evidence_ref, domain, extracted_at)
SELECT 'sig-mail-' || customer_id || '-' || ticket_id, customer_id, 'ins_x_emailtone', 'email_escalation',
    UPPER(TRIM(j:value::VARCHAR)),
    CASE UPPER(TRIM(j:value::VARCHAR)) WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6 ELSE 0.3 END,
    j:confidence::FLOAT, 'email:' || ticket_id, 'insurance', CURRENT_TIMESTAMP()
FROM APP.TMP_SCALE_MAIL
WHERE UPPER(TRIM(j:value::VARCHAR)) IN ('HIGH', 'MEDIUM', 'LOW');
INSERT INTO APP.SIGNAL_EVIDENCE (signal_instance_id, customer_id, signal_name, quote, model, model_confidence)
SELECT 'sig-mail-' || customer_id || '-' || ticket_id, customer_id, 'email_escalation',
    j:quote::VARCHAR, 'llama3.3-70b', j:confidence::FLOAT
FROM APP.TMP_SCALE_MAIL
WHERE UPPER(TRIM(j:value::VARCHAR)) IN ('HIGH', 'MEDIUM', 'LOW');

-- ── product interest across each customer's recent calls ─────────────────────
CREATE OR REPLACE TEMPORARY TABLE APP.TMP_SCALE_PROD AS
WITH blob AS (
    SELECT customer_id,
        LISTAGG('Call ' || call_date::VARCHAR || ': ' || transcript_text, '\n---\n')
            WITHIN GROUP (ORDER BY call_date DESC) AS calls
    FROM (SELECT * FROM RAW.INSURANCE_CALL_TRANSCRIPTS
          WHERE customer_id LIKE 'INS-2%'
          QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY call_date DESC) <= 5)
    GROUP BY customer_id
)
SELECT b.customer_id,
    PARSE_JSON(AI_COMPLETE(
        model => 'llama3.3-70b',
        prompt => p.extraction_prompt || '

CALLS (most recent first):
' || b.calls || '

Return the tag exactly as spelled in the list, or NONE. Quote the single sentence across
all calls that most supports your answer, verbatim. Give confidence between 0 and 1.',
        response_format => {'type':'json','schema':{'type':'object','properties':{
            'value':{'type':'string'},'quote':{'type':'string'},'confidence':{'type':'number'}},
            'required':['value','quote','confidence']}}
    )::VARCHAR) AS j
FROM blob b
CROSS JOIN (SELECT extraction_prompt FROM CONFIG.SIGNAL_DEFINITION WHERE signal_id = 'both_x_product_interest') p;

-- Guard: only the approved vocabulary becomes a signal, as in the procedure.
INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value,
    numeric_value, confidence, evidence_ref, domain, extracted_at)
SELECT 'sig-prod-' || customer_id, customer_id, 'both_x_product_interest', 'product_interest',
    LOWER(TRIM(j:value::VARCHAR)), 1.0, j:confidence::FLOAT, 'calls:recent5', 'insurance', CURRENT_TIMESTAMP()
FROM APP.TMP_SCALE_PROD
WHERE LOWER(TRIM(j:value::VARCHAR)) IN ('maternity_cover','critical_illness','senior_wellness',
    'corporate_topup','opd_cover','claim_protection','super_topup_cover');
INSERT INTO APP.SIGNAL_EVIDENCE (signal_instance_id, customer_id, signal_name, quote, model, model_confidence)
SELECT 'sig-prod-' || customer_id, customer_id, 'product_interest',
    j:quote::VARCHAR, 'llama3.3-70b', j:confidence::FLOAT
FROM APP.TMP_SCALE_PROD
WHERE LOWER(TRIM(j:value::VARCHAR)) IN ('maternity_cover','critical_illness','senior_wellness',
    'corporate_topup','opd_cover','claim_protection','super_topup_cover');

-- ── state: APP.COMPUTE_STATE_FOR's rules, set-based ──────────────────────────
INSERT INTO ENGINE.CUSTOMER_STATE (state_instance_id, customer_id, state_id, state_name, domain, severity,
    computed_score, effective_from, effective_to, is_current)
WITH tgt AS (
    SELECT w.customer_id, w.domain, r.target_state_id
    FROM APP.V_SIGNAL_WIDE w
    JOIN CONFIG.STATE_RULE r ON r.domain_id = w.domain AND r.active = TRUE
    WHERE w.customer_id LIKE 'INS-2%'
      AND CASE
        WHEN r.priority = 4 THEN
            (w.grievance_filed = 'HIGH' OR w.portability_intent = 'HIGH'
             OR (w.churn_intent = 'HIGH' AND w.negative_sentiment > 0.8 AND COALESCE(w.unresolved_claim, 0) > 0))
        WHEN r.priority = 3 THEN
            (w.portability_intent = 'MEDIUM' OR w.renewal_lateness = 'HIGH' OR w.coverage_downgrade = 'HIGH'
             OR (w.service_failure = 'HIGH' AND w.claim_friction = 'HIGH')
             OR (w.churn_intent IN ('HIGH', 'MEDIUM')
                 AND (w.negative_sentiment > 0.6 OR COALESCE(w.unresolved_claim, 0) > 0 OR w.renewal_proximity < 30)))
        WHEN r.priority = 2 THEN
            (w.service_failure IN ('HIGH', 'MEDIUM') OR w.ticket_reopen = 'HIGH' OR w.csat_low = 'HIGH'
             OR w.renewal_lateness = 'MEDIUM' OR w.claim_friction = 'HIGH' OR w.negative_sentiment > 0.4
             OR COALESCE(w.unresolved_claim, 0) > 0 OR w.renewal_proximity < 60)
        WHEN r.priority = 1 THEN TRUE
        ELSE FALSE END
    QUALIFY ROW_NUMBER() OVER (PARTITION BY w.customer_id ORDER BY r.priority DESC) = 1
), score AS (
    SELECT customer_id, ROUND(AVG(CASE signal_value WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6
                                   WHEN 'LOW' THEN 0.3 ELSE 0.0 END), 3) AS sc
    FROM APP.V_ALL_SIGNALS WHERE customer_id LIKE 'INS-2%' GROUP BY customer_id
)
SELECT 'state-x-' || t.customer_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
    t.customer_id, t.target_state_id, sd.state_name, t.domain, sd.severity, s.sc,
    CURRENT_TIMESTAMP(), '9999-12-31'::TIMESTAMP_NTZ, TRUE
FROM tgt t
JOIN CONFIG.STATE_DEFINITION sd ON sd.state_id = t.target_state_id
LEFT JOIN score s ON s.customer_id = t.customer_id;

-- first transition (none -> state) and a queue entry, as ENGINE.DETECT_TRANSITIONS
INSERT INTO ENGINE.STATE_TRANSITION (transition_id, customer_id, previous_state_id, previous_state_name,
    new_state_id, new_state_name, domain, severity_change, transition_date)
SELECT 'trans-' || customer_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
    customer_id, NULL, NULL, state_id, state_name, domain, severity, CURRENT_TIMESTAMP()
FROM ENGINE.CUSTOMER_STATE WHERE customer_id LIKE 'INS-2%' AND is_current;

INSERT INTO ENGINE.DECISION_QUEUE (queue_id, customer_id, customer_name, state_id, state_name, domain,
    urgency, severity, transition_id, status, created_at)
SELECT 'q-' || t.customer_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
    t.customer_id, c.full_name, t.new_state_id, t.new_state_name, t.domain,
    CASE WHEN t.severity_change >= 4 THEN 'CRITICAL' WHEN t.severity_change >= 3 THEN 'HIGH'
         WHEN t.severity_change >= 2 THEN 'MEDIUM' ELSE 'LOW' END,
    t.severity_change, t.transition_id, 'PENDING', CURRENT_TIMESTAMP()
FROM ENGINE.STATE_TRANSITION t
JOIN CANONICAL.CUSTOMER c ON c.customer_id = t.customer_id AND c.domain = t.domain
WHERE t.customer_id LIKE 'INS-2%' AND t.severity_change >= 2;

CALL APP.REFRESH_SIGNAL_SNAPSHOT();
