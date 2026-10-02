-- =============================================================================
-- APP_V2 — foundation for the v2 Streamlit app.
--
-- Additive only. Nothing in APP, ENGINE, CONFIG, CANONICAL or RAW is altered,
-- so the original app keeps working exactly as it does today.
--
-- Why this schema exists: APP.RECOMMEND_ACTION is broken in the live account
-- (it selects sc.effectiveness_weight / pr.approval_required, which do not
-- exist — SCORING_CONFIG is long-format and POLICY_RULE has no action_id).
-- That is why ENGINE.ACTION_RECOMMENDATION has never held a row. APP_V2
-- reimplements the decisioning path correctly against the real schema.
-- =============================================================================

USE DATABASE CUSTOMER_360_DB;
CREATE SCHEMA IF NOT EXISTS APP_V2;
USE SCHEMA APP_V2;

-- ─── Run scoping ────────────────────────────────────────────────────────────
-- Every scenario a judge runs gets a run_id. UNDO_RUN(run_id) reverses exactly
-- that run, so repeated hands-on demos never pollute each other.
CREATE TABLE IF NOT EXISTS RUN_LOG (
    run_id       VARCHAR(60) PRIMARY KEY,
    customer_id  VARCHAR(50),
    persona      VARCHAR(50),
    scenario     VARCHAR(50),
    started_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    status       VARCHAR(20)   DEFAULT 'OPEN'
);

CREATE TABLE IF NOT EXISTS RUN_ARTIFACT (
    run_id       VARCHAR(60),
    object_type  VARCHAR(60),   -- TRANSCRIPT | SIGNAL | STATE | TRANSITION | QUEUE | RECOMMENDATION | EXECUTION | OUTCOME | NOTIFICATION | SUMMARY | EFFECTIVENESS
    object_id    VARCHAR(120),
    detail       VARCHAR(500),
    created_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Evidence quotes. ENGINE.SIGNAL has no span/quote column and altering a shared
-- table would change behaviour for the original app, so quotes live alongside.
CREATE TABLE IF NOT EXISTS SIGNAL_EVIDENCE (
    signal_instance_id VARCHAR(120) PRIMARY KEY,
    customer_id        VARCHAR(50),
    signal_name        VARCHAR(100),
    quote              VARCHAR(2000),
    model              VARCHAR(60),
    model_confidence   FLOAT,
    created_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─── Corrected approval ceilings ────────────────────────────────────────────
-- CONFIG.USER_PERSONA.max_approval_value is still 25,000 / 100,000 while
-- POLICY_RULE and ACTION_DEFINITION are in rupees (₹4,15,000 / ₹20,75,000),
-- which makes every approval-gated action unapprovable by every persona.
-- This override applies the ×83 conversion without editing shared CONFIG.
-- To fix it properly in CONFIG instead, run:
--   UPDATE CUSTOMER_360_DB.CONFIG.USER_PERSONA SET max_approval_value = 2075000 WHERE persona_id='team_lead';
--   UPDATE CUSTOMER_360_DB.CONFIG.USER_PERSONA SET max_approval_value = 8300000 WHERE persona_id='vp_executive';
CREATE OR REPLACE TABLE PERSONA_LIMIT (
    persona_id        VARCHAR(50) PRIMARY KEY,
    max_approval_inr  FLOAT,
    note              VARCHAR(200)
);
INSERT INTO PERSONA_LIMIT VALUES
    ('relationship_manager', 0,       'Cannot approve — unchanged'),
    ('analyst',              0,       'Cannot approve — unchanged'),
    ('team_lead',            2075000, 'CONFIG holds 25,000 — never INR-converted'),
    ('vp_executive',         8300000, 'CONFIG holds 100,000 — never INR-converted');

-- ─── Scoring weights, pivoted ───────────────────────────────────────────────
-- CONFIG.SCORING_CONFIG is long-format (factor_name, weight). Pivot it so the
-- recommender can read one row per (domain, persona), falling back to 'default'.
CREATE OR REPLACE VIEW V_SCORING AS
WITH w AS (
    SELECT domain_id, persona,
        MAX(CASE WHEN factor_name='effectiveness_uplift' THEN weight END) AS w_uplift,
        MAX(CASE WHEN factor_name='business_value'       THEN weight END) AS w_value,
        MAX(CASE WHEN factor_name='action_cost'          THEN weight END) AS w_cost,
        MAX(CASE WHEN factor_name='confidence'           THEN weight END) AS w_conf
    FROM CUSTOMER_360_DB.CONFIG.SCORING_CONFIG WHERE active = TRUE
    GROUP BY domain_id, persona
)
SELECT * FROM w;

-- ─── Signal resolution ──────────────────────────────────────────────────────
-- Mirrors the (now fixed) severity_ranked_signals logic in ENGINE.COMPUTE_STATES:
-- most severe label wins, then larger numeric, then most recent.
CREATE OR REPLACE VIEW V_SIGNAL_RESOLVED AS
SELECT customer_id, domain, signal_id, signal_name, signal_value, numeric_value,
       confidence, evidence_ref, extracted_at
FROM (
    SELECT s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.customer_id, s.signal_name
            ORDER BY CASE s.signal_value WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2
                                         WHEN 'LOW' THEN 1 ELSE 0 END DESC,
                     s.numeric_value DESC, s.extracted_at DESC
        ) AS rn
    FROM CUSTOMER_360_DB.ENGINE.SIGNAL s
)
WHERE rn = 1;

-- One row per customer with every signal as a column, for rule evaluation.
CREATE OR REPLACE VIEW V_SIGNAL_WIDE AS
SELECT customer_id, domain,
    MAX(CASE WHEN signal_name='churn_intent'      THEN signal_value  END) AS churn_intent,
    MAX(CASE WHEN signal_name='hardship_intent'   THEN signal_value  END) AS hardship_intent,
    MAX(CASE WHEN signal_name='payment_risk'      THEN signal_value  END) AS payment_risk,
    MAX(CASE WHEN signal_name='negative_sentiment' THEN numeric_value END) AS negative_sentiment,
    MAX(CASE WHEN signal_name='unresolved_claim'  THEN numeric_value END) AS unresolved_claim,
    MAX(CASE WHEN signal_name='renewal_proximity' THEN numeric_value END) AS renewal_proximity,
    MAX(CASE WHEN signal_name='delinquency'       THEN numeric_value END) AS delinquency
FROM V_SIGNAL_RESOLVED
GROUP BY customer_id, domain;

-- ─── Relationship value ─────────────────────────────────────────────────────
-- APP.RECOMMEND_ACTION hardcodes expected_value as uplift × 50000, so a
-- ₹15.8 L corporate account and a ₹25,000 retail policy score identically.
-- This view supplies the real figure per customer and domain.
CREATE OR REPLACE VIEW V_RELATIONSHIP_VALUE AS
SELECT c.customer_id, c.domain,
       COALESCE(c.lifetime_value,
                (SELECT SUM(a.outstanding_balance) FROM CUSTOMER_360_DB.CANONICAL.ACCOUNT a
                  WHERE a.customer_id = c.customer_id AND a.domain = c.domain),
                0) AS relationship_value
FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER c;

-- Highest configured action cost per domain. Used as a FIXED normalisation
-- ceiling for cost so that a modified offer amount genuinely moves the ranking
-- instead of always normalising to 1.0 against the candidate set.
CREATE OR REPLACE VIEW V_COST_CEILING AS
SELECT domain_id, MAX(default_cost) AS cost_ceiling
FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION WHERE active = TRUE GROUP BY domain_id;

SELECT 'APP_V2 foundation ready' AS status;
