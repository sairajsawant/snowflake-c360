-- =============================================================================
-- 02_pipeline.sql — Canonical Dynamic Tables, Engine Tables, Signal Extraction,
--                   State Computation, Transition Detection, Decision Queue
-- NOTE: AI functions (CORTEX.COMPLETE, CORTEX.SUMMARIZE) require non-trial account.
--       Keyword-based fallback is used for intent extraction when AI is unavailable.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

-- Grant warehouse access if not already done
-- USE ROLE ACCOUNTADMIN;
-- GRANT USAGE, OPERATE ON WAREHOUSE COMPUTE_WH TO ROLE SYSADMIN;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
-- USE ROLE SYSADMIN;

-- =============================================================================
-- CANONICAL DYNAMIC TABLES (5)
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE CANONICAL.CUSTOMER
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    customer_id, first_name, last_name,
    first_name || ' ' || last_name AS full_name,
    email, phone, date_of_birth, customer_since, segment, lifetime_value,
    address_state AS region,
    NULL::INT AS credit_score, NULL::FLOAT AS annual_income, NULL::VARCHAR(50) AS employment_status,
    'insurance' AS source_system, 'insurance' AS domain, created_at, updated_at
FROM RAW.INSURANCE_CUSTOMERS
UNION ALL
SELECT
    customer_id, first_name, last_name,
    first_name || ' ' || last_name AS full_name,
    email, phone, date_of_birth, customer_since,
    NULL AS segment, NULL AS lifetime_value, NULL AS region,
    credit_score, annual_income, employment_status,
    'lending' AS source_system, 'lending' AS domain, created_at, updated_at
FROM RAW.LENDING_CUSTOMERS;

CREATE OR REPLACE DYNAMIC TABLE CANONICAL.ACCOUNT
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    policy_id AS account_id, customer_id, policy_type AS account_type, policy_status AS account_status,
    premium_amount AS periodic_amount, coverage_amount AS total_value, start_date, end_date, renewal_date,
    NULL::FLOAT AS interest_rate, NULL::FLOAT AS outstanding_balance,
    'insurance' AS source_system, 'insurance' AS domain, created_at, updated_at
FROM RAW.INSURANCE_POLICIES
UNION ALL
SELECT
    loan_id AS account_id, customer_id, loan_type AS account_type, loan_status AS account_status,
    monthly_payment AS periodic_amount, principal_amount AS total_value, origination_date AS start_date,
    maturity_date AS end_date, NULL AS renewal_date, interest_rate, outstanding_balance,
    'lending' AS source_system, 'lending' AS domain, created_at, updated_at
FROM RAW.LENDING_LOANS;

CREATE OR REPLACE DYNAMIC TABLE CANONICAL.PRODUCT
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    claim_id AS product_id, customer_id, policy_id AS account_id, claim_type AS product_type,
    claim_status AS product_status, claim_amount AS amount, filed_date AS start_date,
    resolved_date AS end_date, description,
    'insurance' AS source_system, 'insurance' AS domain, created_at, updated_at
FROM RAW.INSURANCE_CLAIMS
UNION ALL
SELECT
    payment_id AS product_id, customer_id, loan_id AS account_id, 'loan_payment' AS product_type,
    payment_status AS product_status, payment_amount AS amount, payment_date AS start_date,
    due_date AS end_date, NULL AS description,
    'lending' AS source_system, 'lending' AS domain, created_at, CURRENT_TIMESTAMP() AS updated_at
FROM RAW.LENDING_PAYMENTS;

CREATE OR REPLACE DYNAMIC TABLE CANONICAL.INTERACTION
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT interaction_id, customer_id, channel, interaction_type, subject, sentiment_score,
    duration_seconds, agent_id, interaction_date, notes,
    'insurance' AS source_system, 'insurance' AS domain, created_at
FROM RAW.INSURANCE_INTERACTIONS
UNION ALL
SELECT interaction_id, customer_id, channel, interaction_type, subject, sentiment_score,
    duration_seconds, agent_id, interaction_date, notes,
    'lending' AS source_system, 'lending' AS domain, created_at
FROM RAW.LENDING_INTERACTIONS;

CREATE OR REPLACE DYNAMIC TABLE CANONICAL.EVENT
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT transcript_id AS event_id, interaction_id, customer_id, 'call_transcript' AS event_type,
    transcript_text AS event_data, call_date AS event_date, duration_seconds, agent_id,
    'insurance' AS source_system, 'insurance' AS domain, created_at
FROM RAW.INSURANCE_CALL_TRANSCRIPTS
UNION ALL
SELECT transcript_id AS event_id, interaction_id, customer_id, 'call_transcript' AS event_type,
    transcript_text AS event_data, call_date AS event_date, duration_seconds, agent_id,
    'lending' AS source_system, 'lending' AS domain, created_at
FROM RAW.LENDING_CALL_TRANSCRIPTS;

-- =============================================================================
-- ENGINE.CUSTOMER_360 — Master 360 view
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE ENGINE.CUSTOMER_360
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    c.customer_id, c.full_name, c.email, c.phone, c.customer_since,
    c.segment, c.lifetime_value, c.region, c.credit_score, c.annual_income,
    c.domain, c.source_system,
    COUNT(DISTINCT a.account_id) AS relationship_count,
    SUM(a.periodic_amount) AS total_periodic_amount,
    SUM(COALESCE(a.outstanding_balance, a.total_value)) AS total_relationship_value,
    COUNT(DISTINCT CASE WHEN p.product_status IN ('PENDING','UNDER_REVIEW') THEN p.product_id END) AS open_issues,
    MAX(i.interaction_date) AS last_interaction_date,
    AVG(i.sentiment_score) AS avg_sentiment,
    COUNT(DISTINCT i.interaction_id) AS interaction_count,
    MIN(a.renewal_date) AS next_renewal_date,
    c.updated_at
FROM CANONICAL.CUSTOMER c
LEFT JOIN CANONICAL.ACCOUNT a ON c.customer_id = a.customer_id AND c.domain = a.domain
LEFT JOIN CANONICAL.PRODUCT p ON c.customer_id = p.customer_id AND c.domain = p.domain
LEFT JOIN CANONICAL.INTERACTION i ON c.customer_id = i.customer_id AND c.domain = i.domain
GROUP BY c.customer_id, c.full_name, c.email, c.phone, c.customer_since,
    c.segment, c.lifetime_value, c.region, c.credit_score, c.annual_income,
    c.domain, c.source_system, c.updated_at;

-- =============================================================================
-- ENGINE TABLES (regular tables for procedural pipeline)
-- =============================================================================

CREATE OR REPLACE TABLE ENGINE.INTERACTION_SUMMARY (
    summary_id VARCHAR(100) PRIMARY KEY, customer_id VARCHAR(50) NOT NULL,
    domain VARCHAR(50) NOT NULL, summary_text VARCHAR(5000),
    source_interactions VARIANT, generated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE ENGINE.SIGNAL (
    signal_instance_id VARCHAR(100) PRIMARY KEY, customer_id VARCHAR(50) NOT NULL,
    signal_id VARCHAR(50) NOT NULL, signal_name VARCHAR(100), signal_value VARCHAR(500),
    numeric_value FLOAT, confidence FLOAT, evidence_ref VARCHAR(500),
    domain VARCHAR(50), extracted_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE ENGINE.CUSTOMER_STATE (
    state_instance_id VARCHAR(100) PRIMARY KEY, customer_id VARCHAR(50) NOT NULL,
    state_id VARCHAR(50) NOT NULL, state_name VARCHAR(100), domain VARCHAR(50),
    severity INT, computed_score FLOAT,
    effective_from TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    effective_to TIMESTAMP_NTZ DEFAULT '9999-12-31'::TIMESTAMP_NTZ,
    is_current BOOLEAN DEFAULT TRUE
);

CREATE OR REPLACE TABLE ENGINE.STATE_TRANSITION (
    transition_id VARCHAR(100) PRIMARY KEY, customer_id VARCHAR(50) NOT NULL,
    previous_state_id VARCHAR(50), previous_state_name VARCHAR(100),
    new_state_id VARCHAR(50) NOT NULL, new_state_name VARCHAR(100),
    domain VARCHAR(50), severity_change INT,
    transition_date TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE ENGINE.DECISION_QUEUE (
    queue_id VARCHAR(100) PRIMARY KEY, customer_id VARCHAR(50) NOT NULL,
    customer_name VARCHAR(200), state_id VARCHAR(50) NOT NULL, state_name VARCHAR(100),
    domain VARCHAR(50), urgency VARCHAR(20), severity INT, transition_id VARCHAR(100),
    status VARCHAR(50) DEFAULT 'PENDING', assigned_to VARCHAR(200),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), resolved_at TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE ENGINE.ACTION_RECOMMENDATION (
    recommendation_id VARCHAR(100) PRIMARY KEY, customer_id VARCHAR(50) NOT NULL,
    queue_id VARCHAR(100), action_id VARCHAR(50) NOT NULL, action_name VARCHAR(100),
    domain VARCHAR(50), score FLOAT, effectiveness_rate FLOAT, expected_uplift FLOAT,
    expected_value FLOAT, action_cost FLOAT, confidence FLOAT, ranking INT,
    requires_approval BOOLEAN, status VARCHAR(50) DEFAULT 'RECOMMENDED',
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE ENGINE.ACTION_EXECUTION (
    execution_id VARCHAR(100) PRIMARY KEY, recommendation_id VARCHAR(100),
    customer_id VARCHAR(50) NOT NULL, action_id VARCHAR(50) NOT NULL,
    action_name VARCHAR(100), domain VARCHAR(50), execution_type VARCHAR(50),
    executed_by VARCHAR(200), approved_by VARCHAR(200), execution_notes VARCHAR(2000),
    status VARCHAR(50) DEFAULT 'EXECUTED', executed_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE ENGINE.ACTION_OUTCOME (
    outcome_id VARCHAR(100) PRIMARY KEY, execution_id VARCHAR(100) NOT NULL,
    customer_id VARCHAR(50) NOT NULL, action_id VARCHAR(50) NOT NULL,
    domain VARCHAR(50), outcome_type VARCHAR(50), state_before VARCHAR(100),
    state_after VARCHAR(100), success BOOLEAN, notes VARCHAR(2000),
    recorded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE ENGINE.NOTIFICATION_LOG (
    log_id VARCHAR(100) PRIMARY KEY, channel_id VARCHAR(50), channel_type VARCHAR(50),
    event_type VARCHAR(100), customer_id VARCHAR(50), domain VARCHAR(50),
    message VARCHAR(4000), status VARCHAR(50),
    sent_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- STREAMS
-- =============================================================================

CREATE OR REPLACE STREAM ENGINE.INTERACTION_STREAM ON DYNAMIC TABLE CANONICAL.INTERACTION SHOW_INITIAL_ROWS = TRUE;
CREATE OR REPLACE STREAM ENGINE.EVENT_STREAM ON DYNAMIC TABLE CANONICAL.EVENT SHOW_INITIAL_ROWS = TRUE;

-- =============================================================================
-- STORED PROCEDURES (pipeline logic)
-- =============================================================================

CREATE OR REPLACE PROCEDURE ENGINE.EXTRACT_SIGNALS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    -- Sentiment signals from interactions
    INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
    SELECT 'sig-sent-' || i.interaction_id, i.customer_id,
        CASE WHEN i.domain = 'insurance' THEN 'ins_negative_sentiment' ELSE 'lend_negative_sentiment' END,
        'negative_sentiment',
        CASE WHEN i.sentiment_score < -0.6 THEN 'HIGH' WHEN i.sentiment_score < -0.3 THEN 'MEDIUM' ELSE 'LOW' END,
        ABS(LEAST(i.sentiment_score, 0)), 0.90, 'interaction:' || i.interaction_id, i.domain, CURRENT_TIMESTAMP()
    FROM CANONICAL.INTERACTION i
    WHERE i.sentiment_score < 0 AND NOT EXISTS (SELECT 1 FROM ENGINE.SIGNAL s WHERE s.signal_instance_id = 'sig-sent-' || i.interaction_id);

    -- Intent from transcripts (keyword fallback; replace with AI_COMPLETE on non-trial accounts)
    INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
    SELECT 'sig-intent-' || e.event_id, e.customer_id,
        CASE WHEN e.domain = 'insurance' THEN 'ins_churn_intent' ELSE 'lend_hardship_intent' END,
        CASE WHEN e.domain = 'insurance' THEN 'churn_intent' ELSE 'hardship_intent' END,
        CASE
            WHEN e.domain = 'insurance' AND (LOWER(e.event_data) LIKE '%cancel%' OR LOWER(e.event_data) LIKE '%switch%' OR LOWER(e.event_data) LIKE '%done%') THEN 'HIGH'
            WHEN e.domain = 'insurance' AND (LOWER(e.event_data) LIKE '%considering%' OR LOWER(e.event_data) LIKE '%not renewing%') THEN 'MEDIUM'
            WHEN e.domain = 'lending' AND (LOWER(e.event_data) LIKE '%lost%job%' OR LOWER(e.event_data) LIKE '%can''t make%') THEN 'HIGH'
            WHEN e.domain = 'lending' AND (LOWER(e.event_data) LIKE '%trouble%' OR LOWER(e.event_data) LIKE '%struggling%') THEN 'MEDIUM'
            ELSE 'LOW'
        END,
        CASE WHEN LOWER(e.event_data) LIKE '%cancel%' OR LOWER(e.event_data) LIKE '%lost%job%' THEN 1.0
             WHEN LOWER(e.event_data) LIKE '%considering%' OR LOWER(e.event_data) LIKE '%trouble%' THEN 0.6 ELSE 0.3 END,
        0.75, 'transcript:' || e.event_id, e.domain, CURRENT_TIMESTAMP()
    FROM CANONICAL.EVENT e
    WHERE NOT EXISTS (SELECT 1 FROM ENGINE.SIGNAL s WHERE s.signal_instance_id = 'sig-intent-' || e.event_id);

    -- Unresolved claims
    INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
    SELECT 'sig-claim-' || c.customer_id, c.customer_id, 'ins_unresolved_claim', 'unresolved_claim', c.cnt::VARCHAR, c.cnt, 0.95, 'claims_system', 'insurance', CURRENT_TIMESTAMP()
    FROM (SELECT customer_id, COUNT(*) AS cnt FROM RAW.INSURANCE_CLAIMS WHERE claim_status IN ('PENDING','UNDER_REVIEW') GROUP BY customer_id) c
    WHERE NOT EXISTS (SELECT 1 FROM ENGINE.SIGNAL s WHERE s.signal_instance_id = 'sig-claim-' || c.customer_id);

    -- Renewal proximity
    INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
    SELECT 'sig-renew-' || p.customer_id, p.customer_id, 'ins_renewal_proximity', 'renewal_proximity', p.days_to_renewal::VARCHAR, p.days_to_renewal, 0.99, 'policy_system', 'insurance', CURRENT_TIMESTAMP()
    FROM (SELECT customer_id, MIN(DATEDIFF(day,CURRENT_DATE(),renewal_date)) AS days_to_renewal FROM RAW.INSURANCE_POLICIES WHERE renewal_date > CURRENT_DATE() GROUP BY customer_id) p
    WHERE NOT EXISTS (SELECT 1 FROM ENGINE.SIGNAL s WHERE s.signal_instance_id = 'sig-renew-' || p.customer_id);

    -- Delinquency
    INSERT INTO ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name, signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
    SELECT 'sig-delinq-' || lp.customer_id, lp.customer_id, 'lend_delinquency', 'delinquency', lp.max_days_late::VARCHAR, lp.max_days_late, 0.95, 'payment_system', 'lending', CURRENT_TIMESTAMP()
    FROM (SELECT customer_id, MAX(days_late) AS max_days_late FROM RAW.LENDING_PAYMENTS WHERE payment_date > DATEADD(day,-90,CURRENT_DATE()) GROUP BY customer_id HAVING MAX(days_late) > 0) lp
    WHERE NOT EXISTS (SELECT 1 FROM ENGINE.SIGNAL s WHERE s.signal_instance_id = 'sig-delinq-' || lp.customer_id);

    RETURN 'Signals extracted successfully';
END;
$$;

CREATE OR REPLACE PROCEDURE ENGINE.COMPUTE_STATES()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE ENGINE.CUSTOMER_STATE SET is_current = FALSE, effective_to = CURRENT_TIMESTAMP()
    WHERE is_current = TRUE AND customer_id IN (SELECT DISTINCT customer_id FROM ENGINE.SIGNAL);

    INSERT INTO ENGINE.CUSTOMER_STATE (state_instance_id, customer_id, state_id, state_name, domain, severity, computed_score, effective_from, effective_to, is_current)
    WITH signal_summary AS (
        SELECT s.customer_id, s.domain,
            MAX(CASE WHEN s.signal_name = 'churn_intent' THEN s.signal_value END) AS churn_intent,
            MAX(CASE WHEN s.signal_name = 'hardship_intent' THEN s.signal_value END) AS hardship_intent,
            MAX(CASE WHEN s.signal_name = 'negative_sentiment' THEN s.numeric_value END) AS negative_sentiment,
            SUM(CASE WHEN s.signal_name = 'unresolved_claim' THEN s.numeric_value ELSE 0 END) AS unresolved_claim,
            MIN(CASE WHEN s.signal_name = 'renewal_proximity' THEN s.numeric_value END) AS renewal_proximity,
            MAX(CASE WHEN s.signal_name = 'delinquency' THEN s.numeric_value END) AS delinquency,
            SUM(s.numeric_value * COALESCE(sd.weight, 1.0)) AS weighted_score
        FROM ENGINE.SIGNAL s LEFT JOIN CONFIG.SIGNAL_DEFINITION sd ON s.signal_id = sd.signal_id
        GROUP BY s.customer_id, s.domain
    ),
    scored AS (
        SELECT ss.customer_id, ss.domain, ss.weighted_score,
            CASE
                WHEN ss.domain = 'insurance' AND ss.churn_intent = 'HIGH' AND ss.negative_sentiment > 0.8 AND ss.unresolved_claim > 0 THEN 'ins_critical_churn'
                WHEN ss.domain = 'insurance' AND ss.churn_intent IN ('HIGH','MEDIUM') AND (ss.negative_sentiment > 0.6 OR ss.unresolved_claim > 0 OR ss.renewal_proximity < 30) THEN 'ins_high_churn'
                WHEN ss.domain = 'insurance' AND (ss.negative_sentiment > 0.4 OR ss.unresolved_claim > 0 OR ss.renewal_proximity < 60) THEN 'ins_medium_churn'
                WHEN ss.domain = 'insurance' THEN 'ins_low_churn'
                WHEN ss.domain = 'lending' AND ss.hardship_intent = 'HIGH' AND ss.delinquency > 60 THEN 'lend_hardship'
                WHEN ss.domain = 'lending' AND (ss.hardship_intent IN ('HIGH','MEDIUM') OR ss.delinquency > 30) THEN 'lend_high_risk'
                WHEN ss.domain = 'lending' AND (ss.negative_sentiment > 0.5 OR ss.delinquency > 0) THEN 'lend_medium_risk'
                WHEN ss.domain = 'lending' THEN 'lend_low_risk'
            END AS computed_state_id
        FROM signal_summary ss
    )
    SELECT 'state-' || sc.customer_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
        sc.customer_id, sc.computed_state_id, sd.state_name, sc.domain, sd.severity,
        sc.weighted_score, CURRENT_TIMESTAMP(), '9999-12-31'::TIMESTAMP_NTZ, TRUE
    FROM scored sc JOIN CONFIG.STATE_DEFINITION sd ON sc.computed_state_id = sd.state_id
    WHERE NOT EXISTS (SELECT 1 FROM ENGINE.CUSTOMER_STATE cs WHERE cs.customer_id = sc.customer_id AND cs.is_current = TRUE);

    RETURN 'States computed successfully';
END;
$$;

CREATE OR REPLACE PROCEDURE ENGINE.DETECT_TRANSITIONS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO ENGINE.STATE_TRANSITION (transition_id, customer_id, previous_state_id, previous_state_name, new_state_id, new_state_name, domain, severity_change, transition_date)
    SELECT 'trans-' || curr.customer_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
        curr.customer_id, prev.state_id, prev.state_name, curr.state_id, curr.state_name,
        curr.domain, curr.severity - COALESCE(prev.severity, 0), CURRENT_TIMESTAMP()
    FROM ENGINE.CUSTOMER_STATE curr
    LEFT JOIN ENGINE.CUSTOMER_STATE prev ON curr.customer_id = prev.customer_id AND prev.is_current = FALSE
        AND prev.effective_to = (SELECT MAX(p2.effective_to) FROM ENGINE.CUSTOMER_STATE p2 WHERE p2.customer_id = curr.customer_id AND p2.is_current = FALSE)
    WHERE curr.is_current = TRUE AND (prev.state_id IS NULL OR prev.state_id != curr.state_id)
      AND NOT EXISTS (SELECT 1 FROM ENGINE.STATE_TRANSITION t WHERE t.customer_id = curr.customer_id AND t.new_state_id = curr.state_id AND t.transition_date > DATEADD(minute,-5,CURRENT_TIMESTAMP()));

    INSERT INTO ENGINE.DECISION_QUEUE (queue_id, customer_id, customer_name, state_id, state_name, domain, urgency, severity, transition_id, status, created_at)
    SELECT 'q-' || t.customer_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3'),
        t.customer_id, c.full_name, t.new_state_id, t.new_state_name, t.domain,
        CASE WHEN sdef.severity >= 4 THEN 'CRITICAL' WHEN sdef.severity >= 3 THEN 'HIGH' WHEN sdef.severity >= 2 THEN 'MEDIUM' ELSE 'LOW' END,
        sdef.severity, t.transition_id, 'PENDING', CURRENT_TIMESTAMP()
    FROM ENGINE.STATE_TRANSITION t
    JOIN CONFIG.STATE_DEFINITION sdef ON t.new_state_id = sdef.state_id
    JOIN CANONICAL.CUSTOMER c ON t.customer_id = c.customer_id AND t.domain = c.domain
    WHERE sdef.severity >= 2 AND t.transition_date > DATEADD(minute,-5,CURRENT_TIMESTAMP())
      AND NOT EXISTS (SELECT 1 FROM ENGINE.DECISION_QUEUE q WHERE q.customer_id = t.customer_id AND q.state_id = t.new_state_id AND q.status = 'PENDING');

    RETURN 'Transitions detected successfully';
END;
$$;

-- =============================================================================
-- TASKS (scheduled pipeline)
-- =============================================================================

CREATE OR REPLACE TASK ENGINE.EXTRACT_SIGNALS_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
AS CALL ENGINE.EXTRACT_SIGNALS();

CREATE OR REPLACE TASK ENGINE.COMPUTE_STATES_TASK
    WAREHOUSE = COMPUTE_WH
    AFTER ENGINE.EXTRACT_SIGNALS_TASK
AS CALL ENGINE.COMPUTE_STATES();

CREATE OR REPLACE TASK ENGINE.DETECT_TRANSITIONS_TASK
    WAREHOUSE = COMPUTE_WH
    AFTER ENGINE.COMPUTE_STATES_TASK
AS CALL ENGINE.DETECT_TRANSITIONS();

-- Resume tasks (children first, then root)
ALTER TASK ENGINE.DETECT_TRANSITIONS_TASK RESUME;
ALTER TASK ENGINE.COMPUTE_STATES_TASK RESUME;
ALTER TASK ENGINE.EXTRACT_SIGNALS_TASK RESUME;
