-- =============================================================================
-- 01_foundation.sql — Enterprise Customer Decisioning Platform
-- Database, schemas, CONFIG tables, RAW tables, seed data, synthetic data
-- =============================================================================

-- NOTE: SYSADMIN has CREATE DATABASE; ACCOUNTADMIN may be blocked by session scope.
USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;

-- ─── DATABASE & SCHEMAS ─────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS CUSTOMER_360_DB;
USE DATABASE CUSTOMER_360_DB;

CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS CANONICAL;
CREATE SCHEMA IF NOT EXISTS ENGINE;
CREATE SCHEMA IF NOT EXISTS CONFIG;
CREATE SCHEMA IF NOT EXISTS SEARCH;
CREATE SCHEMA IF NOT EXISTS EVAL;
CREATE SCHEMA IF NOT EXISTS APP;

-- =============================================================================
-- CONFIG TABLES (14)
-- =============================================================================
USE SCHEMA CONFIG;

-- 1. DOMAIN_PACK
CREATE OR REPLACE TABLE DOMAIN_PACK (
    domain_id       VARCHAR(50)   PRIMARY KEY,
    domain_name     VARCHAR(100)  NOT NULL,
    description     VARCHAR(500),
    entity_label    VARCHAR(50)   DEFAULT 'customer',
    relationship_label VARCHAR(50) DEFAULT 'policy',
    value_formula   VARCHAR(500),
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 2. SIGNAL_DEFINITION
CREATE OR REPLACE TABLE SIGNAL_DEFINITION (
    signal_id           VARCHAR(50)   PRIMARY KEY,
    domain_id           VARCHAR(50)   NOT NULL,
    signal_name         VARCHAR(100)  NOT NULL,
    signal_type         VARCHAR(50)   NOT NULL,
    extraction_method   VARCHAR(50)   NOT NULL,
    extraction_prompt   VARCHAR(2000),
    source_table        VARCHAR(200),
    weight              FLOAT         DEFAULT 1.0,
    active              BOOLEAN       DEFAULT TRUE,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 3. STATE_DEFINITION
CREATE OR REPLACE TABLE STATE_DEFINITION (
    state_id        VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    state_name      VARCHAR(100)  NOT NULL,
    severity        INT           DEFAULT 0,
    description     VARCHAR(500),
    color_code      VARCHAR(20),
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 4. STATE_RULE
CREATE OR REPLACE TABLE STATE_RULE (
    rule_id         VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    target_state_id VARCHAR(50)   NOT NULL,
    rule_expression VARCHAR(2000) NOT NULL,
    priority        INT           DEFAULT 0,
    description     VARCHAR(500),
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 5. ACTION_DEFINITION
CREATE OR REPLACE TABLE ACTION_DEFINITION (
    action_id       VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    action_name     VARCHAR(100)  NOT NULL,
    action_type     VARCHAR(50)   NOT NULL,
    description     VARCHAR(500),
    default_cost    FLOAT         DEFAULT 0,
    requires_approval BOOLEAN     DEFAULT FALSE,
    approval_threshold FLOAT      DEFAULT 0,
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 6. ACTION_STATE_MAPPING
CREATE OR REPLACE TABLE ACTION_STATE_MAPPING (
    mapping_id      VARCHAR(50)   PRIMARY KEY,
    action_id       VARCHAR(50)   NOT NULL,
    state_id        VARCHAR(50)   NOT NULL,
    domain_id       VARCHAR(50)   NOT NULL,
    priority        INT           DEFAULT 0,
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 7. POLICY_RULE
CREATE OR REPLACE TABLE POLICY_RULE (
    policy_id       VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    policy_name     VARCHAR(100)  NOT NULL,
    policy_type     VARCHAR(50)   NOT NULL,
    rule_expression VARCHAR(2000) NOT NULL,
    enforcement     VARCHAR(50)   DEFAULT 'BLOCK',
    description     VARCHAR(500),
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 8. SCORING_CONFIG
CREATE OR REPLACE TABLE SCORING_CONFIG (
    scoring_id      VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    persona         VARCHAR(50)   DEFAULT 'default',
    factor_name     VARCHAR(100)  NOT NULL,
    weight          FLOAT         NOT NULL,
    description     VARCHAR(500),
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 9. NOTIFICATION_CHANNEL
CREATE OR REPLACE TABLE NOTIFICATION_CHANNEL (
    channel_id      VARCHAR(50)   PRIMARY KEY,
    channel_type    VARCHAR(50)   NOT NULL,
    channel_name    VARCHAR(100)  NOT NULL,
    integration_name VARCHAR(200),
    config          VARIANT,
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 10. NOTIFICATION_RULE
CREATE OR REPLACE TABLE NOTIFICATION_RULE (
    rule_id         VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    trigger_event   VARCHAR(100)  NOT NULL,
    channel_id      VARCHAR(50)   NOT NULL,
    condition_expr  VARCHAR(1000),
    message_template VARCHAR(2000) NOT NULL,
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 11. SOURCE_MAPPING
CREATE OR REPLACE TABLE SOURCE_MAPPING (
    mapping_id      VARCHAR(50)   PRIMARY KEY,
    domain_id       VARCHAR(50)   NOT NULL,
    source_table    VARCHAR(200)  NOT NULL,
    target_entity   VARCHAR(100)  NOT NULL,
    mapping_rules   VARIANT,
    active          BOOLEAN       DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 12. USER_PERSONA
CREATE OR REPLACE TABLE USER_PERSONA (
    persona_id          VARCHAR(50)   PRIMARY KEY,
    persona_name        VARCHAR(100)  NOT NULL,
    default_view        VARCHAR(100),
    allowed_actions     VARIANT,
    data_scope_type     VARCHAR(20)   DEFAULT 'ALL',
    can_approve         BOOLEAN       DEFAULT FALSE,
    can_configure       BOOLEAN       DEFAULT FALSE,
    max_approval_value  FLOAT         DEFAULT 0,
    domain              VARCHAR(50),
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 13. USER_PERSONA_ASSIGNMENT
CREATE OR REPLACE TABLE USER_PERSONA_ASSIGNMENT (
    snowflake_role  VARCHAR(200)  NOT NULL,
    persona_id      VARCHAR(50)   NOT NULL,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (snowflake_role, persona_id)
);

-- 14. CUSTOMER_ASSIGNMENT
CREATE OR REPLACE TABLE CUSTOMER_ASSIGNMENT (
    customer_id     VARCHAR(50)   NOT NULL,
    assigned_user   VARCHAR(200),
    assigned_team   VARCHAR(200),
    domain          VARCHAR(50)   NOT NULL,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (customer_id, domain)
);

-- =============================================================================
-- RAW TABLES — INSURANCE
-- =============================================================================
USE SCHEMA RAW;

CREATE OR REPLACE TABLE INSURANCE_CUSTOMERS (
    customer_id     VARCHAR(50)   PRIMARY KEY,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    email           VARCHAR(200),
    phone           VARCHAR(50),
    date_of_birth   DATE,
    customer_since  DATE,
    segment         VARCHAR(50),
    lifetime_value  FLOAT,
    address_state   VARCHAR(50),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE INSURANCE_POLICIES (
    policy_id       VARCHAR(50)   PRIMARY KEY,
    customer_id     VARCHAR(50)   NOT NULL,
    policy_type     VARCHAR(100),
    policy_status   VARCHAR(50),
    premium_amount  FLOAT,
    coverage_amount FLOAT,
    start_date      DATE,
    end_date        DATE,
    renewal_date    DATE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE INSURANCE_CLAIMS (
    claim_id        VARCHAR(50)   PRIMARY KEY,
    policy_id       VARCHAR(50)   NOT NULL,
    customer_id     VARCHAR(50)   NOT NULL,
    claim_type      VARCHAR(100),
    claim_status    VARCHAR(50),
    claim_amount    FLOAT,
    filed_date      DATE,
    resolved_date   DATE,
    description     VARCHAR(2000),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE INSURANCE_PAYMENTS (
    payment_id      VARCHAR(50)   PRIMARY KEY,
    customer_id     VARCHAR(50)   NOT NULL,
    policy_id       VARCHAR(50),
    payment_amount  FLOAT,
    payment_date    DATE,
    payment_method  VARCHAR(50),
    payment_status  VARCHAR(50),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE INSURANCE_INTERACTIONS (
    interaction_id  VARCHAR(50)   PRIMARY KEY,
    customer_id     VARCHAR(50)   NOT NULL,
    channel         VARCHAR(50),
    interaction_type VARCHAR(100),
    subject         VARCHAR(500),
    sentiment_score FLOAT,
    duration_seconds INT,
    agent_id        VARCHAR(50),
    interaction_date TIMESTAMP_NTZ,
    notes           VARCHAR(2000),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE INSURANCE_CALL_TRANSCRIPTS (
    transcript_id   VARCHAR(50)   PRIMARY KEY,
    interaction_id  VARCHAR(50)   NOT NULL,
    customer_id     VARCHAR(50)   NOT NULL,
    transcript_text VARCHAR(16000),
    call_date       TIMESTAMP_NTZ,
    duration_seconds INT,
    agent_id        VARCHAR(50),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- RAW TABLES — LENDING
-- =============================================================================

CREATE OR REPLACE TABLE LENDING_CUSTOMERS (
    customer_id     VARCHAR(50)   PRIMARY KEY,
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    email           VARCHAR(200),
    phone           VARCHAR(50),
    date_of_birth   DATE,
    customer_since  DATE,
    credit_score    INT,
    annual_income   FLOAT,
    employment_status VARCHAR(50),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE LENDING_LOANS (
    loan_id         VARCHAR(50)   PRIMARY KEY,
    customer_id     VARCHAR(50)   NOT NULL,
    loan_type       VARCHAR(100),
    loan_status     VARCHAR(50),
    principal_amount FLOAT,
    interest_rate   FLOAT,
    term_months     INT,
    monthly_payment FLOAT,
    origination_date DATE,
    maturity_date   DATE,
    outstanding_balance FLOAT,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE LENDING_PAYMENTS (
    payment_id      VARCHAR(50)   PRIMARY KEY,
    loan_id         VARCHAR(50)   NOT NULL,
    customer_id     VARCHAR(50)   NOT NULL,
    payment_amount  FLOAT,
    payment_date    DATE,
    due_date        DATE,
    days_late       INT           DEFAULT 0,
    payment_status  VARCHAR(50),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE LENDING_INTERACTIONS (
    interaction_id  VARCHAR(50)   PRIMARY KEY,
    customer_id     VARCHAR(50)   NOT NULL,
    channel         VARCHAR(50),
    interaction_type VARCHAR(100),
    subject         VARCHAR(500),
    sentiment_score FLOAT,
    duration_seconds INT,
    agent_id        VARCHAR(50),
    interaction_date TIMESTAMP_NTZ,
    notes           VARCHAR(2000),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE LENDING_CALL_TRANSCRIPTS (
    transcript_id   VARCHAR(50)   PRIMARY KEY,
    interaction_id  VARCHAR(50)   NOT NULL,
    customer_id     VARCHAR(50)   NOT NULL,
    transcript_text VARCHAR(16000),
    call_date       TIMESTAMP_NTZ,
    duration_seconds INT,
    agent_id        VARCHAR(50),
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- ENGINE TABLES (pre-create for seed data)
-- =============================================================================
USE SCHEMA ENGINE;

CREATE TABLE IF NOT EXISTS ACTION_EFFECTIVENESS (
    effectiveness_id VARCHAR(50)  PRIMARY KEY,
    action_id       VARCHAR(50)   NOT NULL,
    state_id        VARCHAR(50)   NOT NULL,
    domain_id       VARCHAR(50)   NOT NULL,
    success_count   INT           DEFAULT 0,
    total_count     INT           DEFAULT 0,
    success_rate    FLOAT         DEFAULT 0,
    avg_uplift      FLOAT         DEFAULT 0,
    confidence      FLOAT         DEFAULT 0,
    last_updated    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- CONFIG SEED DATA
-- =============================================================================
USE SCHEMA CONFIG;

-- Domain Packs
INSERT INTO DOMAIN_PACK VALUES
    ('insurance', 'Insurance', 'Property & casualty insurance domain', 'customer', 'policy', 'SUM(premium_amount)', TRUE, CURRENT_TIMESTAMP()),
    ('lending', 'Lending', 'Consumer and commercial lending domain', 'customer', 'loan', 'SUM(outstanding_balance)', TRUE, CURRENT_TIMESTAMP());

-- Signal Definitions — Insurance
INSERT INTO SIGNAL_DEFINITION VALUES
    ('ins_churn_intent', 'insurance', 'churn_intent', 'behavioral', 'INTENT', 'Analyze the transcript for churn intent. Return HIGH if: competitor named, price/quote comparison, porting/switching stated, regulator (IRDAI) invoked, cancel/terminate mentioned, or explicit threat to leave. Return MEDIUM if: dissatisfaction expressed, considering alternatives, not renewing hinted. Return LOW otherwise.', 'RAW.INSURANCE_CALL_TRANSCRIPTS', 0.30, TRUE, CURRENT_TIMESTAMP()),
    ('ins_negative_sentiment', 'insurance', 'negative_sentiment', 'sentiment', 'SENTIMENT', NULL, 'RAW.INSURANCE_INTERACTIONS', 0.25, TRUE, CURRENT_TIMESTAMP()),
    ('ins_unresolved_claim', 'insurance', 'unresolved_claim', 'operational', 'SQL', NULL, 'RAW.INSURANCE_CLAIMS', 0.20, TRUE, CURRENT_TIMESTAMP()),
    ('ins_renewal_proximity', 'insurance', 'renewal_proximity', 'temporal', 'SQL', NULL, 'RAW.INSURANCE_POLICIES', 0.15, TRUE, CURRENT_TIMESTAMP()),
    ('ins_payment_irregularity', 'insurance', 'payment_irregularity', 'financial', 'SQL', NULL, 'RAW.INSURANCE_PAYMENTS', 0.10, TRUE, CURRENT_TIMESTAMP());

-- Signal Definitions — Lending
INSERT INTO SIGNAL_DEFINITION VALUES
    ('lend_payment_risk', 'lending', 'payment_risk', 'financial', 'SQL', NULL, 'RAW.LENDING_PAYMENTS', 0.30, TRUE, CURRENT_TIMESTAMP()),
    ('lend_hardship_intent', 'lending', 'hardship_intent', 'behavioral', 'INTENT', 'Analyze the following customer interaction. Identify if the customer expresses financial hardship, job loss, or inability to pay. Return HIGH, MEDIUM, LOW, or NONE.', 'RAW.LENDING_CALL_TRANSCRIPTS', 0.25, TRUE, CURRENT_TIMESTAMP()),
    ('lend_negative_sentiment', 'lending', 'negative_sentiment', 'sentiment', 'SENTIMENT', NULL, 'RAW.LENDING_INTERACTIONS', 0.20, TRUE, CURRENT_TIMESTAMP()),
    ('lend_delinquency', 'lending', 'delinquency', 'operational', 'SQL', NULL, 'RAW.LENDING_PAYMENTS', 0.15, TRUE, CURRENT_TIMESTAMP()),
    ('lend_credit_deterioration', 'lending', 'credit_deterioration', 'financial', 'SQL', NULL, 'RAW.LENDING_CUSTOMERS', 0.10, TRUE, CURRENT_TIMESTAMP());

-- State Definitions — Insurance
INSERT INTO STATE_DEFINITION VALUES
    ('ins_low_churn', 'insurance', 'LOW_CHURN_RISK', 1, 'Customer shows no significant churn indicators', '#4CAF50', TRUE, CURRENT_TIMESTAMP()),
    ('ins_medium_churn', 'insurance', 'MEDIUM_CHURN_RISK', 2, 'Customer shows some churn warning signs', '#FF9800', TRUE, CURRENT_TIMESTAMP()),
    ('ins_high_churn', 'insurance', 'HIGH_CHURN_RISK', 3, 'Customer at high risk of churning', '#F44336', TRUE, CURRENT_TIMESTAMP()),
    ('ins_critical_churn', 'insurance', 'CRITICAL_CHURN_RISK', 4, 'Customer actively trying to leave', '#9C27B0', TRUE, CURRENT_TIMESTAMP());

-- State Definitions — Lending
INSERT INTO STATE_DEFINITION VALUES
    ('lend_low_risk', 'lending', 'LOW_PAYMENT_RISK', 1, 'Payments on track', '#4CAF50', TRUE, CURRENT_TIMESTAMP()),
    ('lend_medium_risk', 'lending', 'MEDIUM_PAYMENT_RISK', 2, 'Some payment concerns', '#FF9800', TRUE, CURRENT_TIMESTAMP()),
    ('lend_high_risk', 'lending', 'HIGH_PAYMENT_RISK', 3, 'Significant payment risk', '#F44336', TRUE, CURRENT_TIMESTAMP()),
    ('lend_hardship', 'lending', 'HARDSHIP', 4, 'Customer in financial hardship', '#9C27B0', TRUE, CURRENT_TIMESTAMP());

-- State Rules — Insurance
INSERT INTO STATE_RULE VALUES
    ('ins_rule_critical', 'insurance', 'ins_critical_churn', 'churn_intent = ''HIGH'' AND negative_sentiment > 0.8 AND unresolved_claim > 0', 4, 'Critical: explicit churn intent + high negativity + open claim', TRUE, CURRENT_TIMESTAMP()),
    ('ins_rule_high', 'insurance', 'ins_high_churn', 'churn_intent IN (''HIGH'',''MEDIUM'') AND (negative_sentiment > 0.6 OR unresolved_claim > 0 OR renewal_proximity < 30)', 3, 'High: churn signals + supporting evidence', TRUE, CURRENT_TIMESTAMP()),
    ('ins_rule_medium', 'insurance', 'ins_medium_churn', 'negative_sentiment > 0.4 OR unresolved_claim > 0 OR renewal_proximity < 60', 2, 'Medium: individual risk factors present', TRUE, CURRENT_TIMESTAMP()),
    ('ins_rule_low', 'insurance', 'ins_low_churn', '1=1', 1, 'Default: low risk', TRUE, CURRENT_TIMESTAMP());

-- State Rules — Lending
INSERT INTO STATE_RULE VALUES
    ('lend_rule_hardship', 'lending', 'lend_hardship', 'hardship_intent = ''HIGH'' AND delinquency > 60', 4, 'Hardship: explicit hardship + severe delinquency', TRUE, CURRENT_TIMESTAMP()),
    ('lend_rule_high', 'lending', 'lend_high_risk', 'payment_risk = ''HIGH'' OR delinquency > 30 OR hardship_intent IN (''HIGH'',''MEDIUM'')', 3, 'High: payment risk or delinquency', TRUE, CURRENT_TIMESTAMP()),
    ('lend_rule_medium', 'lending', 'lend_medium_risk', 'payment_risk = ''MEDIUM'' OR delinquency > 0 OR negative_sentiment > 0.5', 2, 'Medium: some concerns', TRUE, CURRENT_TIMESTAMP()),
    ('lend_rule_low', 'lending', 'lend_low_risk', '1=1', 1, 'Default: low risk', TRUE, CURRENT_TIMESTAMP());

-- Action Definitions — Insurance
INSERT INTO ACTION_DEFINITION VALUES
    ('ins_claim_escalation', 'insurance', 'Claim Escalation', 'AUTONOMOUS', 'Escalate unresolved claim to priority queue', 50, FALSE, 0, TRUE, CURRENT_TIMESTAMP()),
    ('ins_retention_call', 'insurance', 'Retention Call', 'AUTONOMOUS', 'Schedule proactive retention call with dedicated agent', 25, FALSE, 0, TRUE, CURRENT_TIMESTAMP()),
    ('ins_retention_offer', 'insurance', 'Retention Offer', 'APPROVAL_REQUIRED', 'Discount or loyalty offer to retain customer', 500, TRUE, 5000, TRUE, CURRENT_TIMESTAMP()),
    ('ins_policy_review', 'insurance', 'Policy Review', 'AUTONOMOUS', 'Trigger comprehensive policy review', 15, FALSE, 0, TRUE, CURRENT_TIMESTAMP()),
    ('ins_manager_escalation', 'insurance', 'Manager Escalation', 'APPROVAL_REQUIRED', 'Escalate to senior management', 100, TRUE, 25000, TRUE, CURRENT_TIMESTAMP());

-- Action Definitions — Lending
INSERT INTO ACTION_DEFINITION VALUES
    ('lend_payment_plan', 'lending', 'Payment Plan', 'APPROVAL_REQUIRED', 'Restructure payment schedule', 200, TRUE, 10000, TRUE, CURRENT_TIMESTAMP()),
    ('lend_hardship_program', 'lending', 'Hardship Program', 'APPROVAL_REQUIRED', 'Enroll in hardship assistance program', 500, TRUE, 25000, TRUE, CURRENT_TIMESTAMP()),
    ('lend_collection_call', 'lending', 'Collection Call', 'AUTONOMOUS', 'Schedule collection outreach call', 25, FALSE, 0, TRUE, CURRENT_TIMESTAMP()),
    ('lend_rate_modification', 'lending', 'Rate Modification', 'APPROVAL_REQUIRED', 'Temporary interest rate reduction', 1000, TRUE, 50000, TRUE, CURRENT_TIMESTAMP()),
    ('lend_early_intervention', 'lending', 'Early Intervention', 'AUTONOMOUS', 'Proactive outreach before delinquency', 15, FALSE, 0, TRUE, CURRENT_TIMESTAMP());

-- Action-State Mappings — Insurance
INSERT INTO ACTION_STATE_MAPPING VALUES
    ('asm_ins_1', 'ins_claim_escalation', 'ins_high_churn', 'insurance', 1, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_2', 'ins_claim_escalation', 'ins_critical_churn', 'insurance', 1, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_3', 'ins_retention_call', 'ins_medium_churn', 'insurance', 1, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_4', 'ins_retention_call', 'ins_high_churn', 'insurance', 2, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_5', 'ins_retention_offer', 'ins_high_churn', 'insurance', 3, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_6', 'ins_retention_offer', 'ins_critical_churn', 'insurance', 2, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_7', 'ins_policy_review', 'ins_medium_churn', 'insurance', 2, TRUE, CURRENT_TIMESTAMP()),
    ('asm_ins_8', 'ins_manager_escalation', 'ins_critical_churn', 'insurance', 3, TRUE, CURRENT_TIMESTAMP());

-- Action-State Mappings — Lending
INSERT INTO ACTION_STATE_MAPPING VALUES
    ('asm_lend_1', 'lend_early_intervention', 'lend_medium_risk', 'lending', 1, TRUE, CURRENT_TIMESTAMP()),
    ('asm_lend_2', 'lend_collection_call', 'lend_high_risk', 'lending', 1, TRUE, CURRENT_TIMESTAMP()),
    ('asm_lend_3', 'lend_payment_plan', 'lend_high_risk', 'lending', 2, TRUE, CURRENT_TIMESTAMP()),
    ('asm_lend_4', 'lend_hardship_program', 'lend_hardship', 'lending', 1, TRUE, CURRENT_TIMESTAMP()),
    ('asm_lend_5', 'lend_rate_modification', 'lend_hardship', 'lending', 2, TRUE, CURRENT_TIMESTAMP());

-- Policy Rules — Insurance
INSERT INTO POLICY_RULE VALUES
    ('pol_ins_1', 'insurance', 'Max Retention Offer', 'VALUE_LIMIT', 'offer_amount <= 5000', 'BLOCK', 'Retention offers cannot exceed $5,000 without VP approval', TRUE, CURRENT_TIMESTAMP()),
    ('pol_ins_2', 'insurance', 'Claim Escalation Auto', 'AUTO_EXECUTE', 'action_type = ''AUTONOMOUS'' AND action_cost < 100', 'ALLOW', 'Low-cost autonomous actions execute without approval', TRUE, CURRENT_TIMESTAMP()),
    ('pol_ins_3', 'insurance', 'VP Approval Required', 'APPROVAL_GATE', 'offer_amount > 5000', 'REQUIRE_APPROVAL', 'Offers over $5K require VP approval', TRUE, CURRENT_TIMESTAMP());

-- Policy Rules — Lending
INSERT INTO POLICY_RULE VALUES
    ('pol_lend_1', 'lending', 'Payment Plan Limit', 'VALUE_LIMIT', 'term_extension <= 12', 'BLOCK', 'Payment plans limited to 12-month extension', TRUE, CURRENT_TIMESTAMP()),
    ('pol_lend_2', 'lending', 'Hardship Auto Enroll', 'AUTO_EXECUTE', 'action_type = ''AUTONOMOUS''', 'ALLOW', 'Autonomous lending actions execute without approval', TRUE, CURRENT_TIMESTAMP()),
    ('pol_lend_3', 'lending', 'Rate Mod Approval', 'APPROVAL_GATE', 'rate_reduction > 0.02', 'REQUIRE_APPROVAL', 'Rate reductions over 2% require approval', TRUE, CURRENT_TIMESTAMP());

-- Scoring Config
INSERT INTO SCORING_CONFIG VALUES
    ('sc_1', 'insurance', 'default', 'effectiveness_uplift', 0.40, 'Weight for action effectiveness uplift', TRUE, CURRENT_TIMESTAMP()),
    ('sc_2', 'insurance', 'default', 'business_value', 0.30, 'Weight for expected business value', TRUE, CURRENT_TIMESTAMP()),
    ('sc_3', 'insurance', 'default', 'action_cost', -0.10, 'Negative weight for action cost', TRUE, CURRENT_TIMESTAMP()),
    ('sc_4', 'insurance', 'default', 'confidence', 0.20, 'Weight for statistical confidence', TRUE, CURRENT_TIMESTAMP()),
    ('sc_5', 'lending', 'default', 'effectiveness_uplift', 0.35, 'Weight for action effectiveness uplift', TRUE, CURRENT_TIMESTAMP()),
    ('sc_6', 'lending', 'default', 'business_value', 0.35, 'Weight for expected business value', TRUE, CURRENT_TIMESTAMP()),
    ('sc_7', 'lending', 'default', 'action_cost', -0.10, 'Negative weight for action cost', TRUE, CURRENT_TIMESTAMP()),
    ('sc_8', 'lending', 'default', 'confidence', 0.20, 'Weight for statistical confidence', TRUE, CURRENT_TIMESTAMP()),
    ('sc_9', 'insurance', 'relationship_manager', 'effectiveness_uplift', 0.50, 'RM persona: higher weight on effectiveness', TRUE, CURRENT_TIMESTAMP()),
    ('sc_10', 'insurance', 'relationship_manager', 'business_value', 0.25, 'RM persona: moderate business value weight', TRUE, CURRENT_TIMESTAMP()),
    ('sc_11', 'insurance', 'relationship_manager', 'action_cost', -0.05, 'RM persona: lower cost sensitivity', TRUE, CURRENT_TIMESTAMP()),
    ('sc_12', 'insurance', 'relationship_manager', 'confidence', 0.20, 'RM persona: standard confidence weight', TRUE, CURRENT_TIMESTAMP()),
    ('sc_13', 'insurance', 'vp_executive', 'effectiveness_uplift', 0.30, 'VP persona: balanced effectiveness', TRUE, CURRENT_TIMESTAMP()),
    ('sc_14', 'insurance', 'vp_executive', 'business_value', 0.40, 'VP persona: higher business value focus', TRUE, CURRENT_TIMESTAMP()),
    ('sc_15', 'insurance', 'vp_executive', 'action_cost', -0.15, 'VP persona: more cost sensitive', TRUE, CURRENT_TIMESTAMP()),
    ('sc_16', 'insurance', 'vp_executive', 'confidence', 0.15, 'VP persona: less confidence weight', TRUE, CURRENT_TIMESTAMP());

-- Notification Channels
INSERT INTO NOTIFICATION_CHANNEL VALUES
    ('ch_slack', 'WEBHOOK', 'Slack - Retention Alerts', 'SLACK_NOTIFICATION_INT', NULL, TRUE, CURRENT_TIMESTAMP()),
    ('ch_email', 'EMAIL', 'Email - Team Notifications', 'EMAIL_NOTIFICATION_INT', NULL, TRUE, CURRENT_TIMESTAMP());

-- Notification Rules
INSERT INTO NOTIFICATION_RULE VALUES
    ('nr_1', 'insurance', 'STATE_TRANSITION_HIGH', 'ch_slack', 'new_state IN (''HIGH_CHURN_RISK'',''CRITICAL_CHURN_RISK'')', '🚨 *High Risk Alert*: {{customer_name}} transitioned to {{new_state}}. Previous: {{old_state}}. Recommended action: {{top_action}}.', TRUE, CURRENT_TIMESTAMP()),
    ('nr_2', 'insurance', 'STATE_TRANSITION_HIGH', 'ch_email', 'new_state IN (''HIGH_CHURN_RISK'',''CRITICAL_CHURN_RISK'')', 'Customer {{customer_name}} ({{customer_id}}) has transitioned to {{new_state}} from {{old_state}}. Top recommended action: {{top_action}}. Please review in the Decision Queue.', TRUE, CURRENT_TIMESTAMP()),
    ('nr_3', 'lending', 'STATE_TRANSITION_HIGH', 'ch_slack', 'new_state IN (''HIGH_PAYMENT_RISK'',''HARDSHIP'')', '🚨 *Payment Risk Alert*: {{customer_name}} transitioned to {{new_state}}. Recommended: {{top_action}}.', TRUE, CURRENT_TIMESTAMP()),
    ('nr_4', 'insurance', 'ACTION_REQUIRES_APPROVAL', 'ch_email', 'requires_approval = TRUE', 'Action "{{action_name}}" for {{customer_name}} requires approval. Amount: ${{amount}}. Please review.', TRUE, CURRENT_TIMESTAMP());

-- Source Mappings
INSERT INTO SOURCE_MAPPING VALUES
    ('sm_ins_cust', 'insurance', 'RAW.INSURANCE_CUSTOMERS', 'customer', PARSE_JSON('{"customer_id": "customer_id", "name": "first_name || '' '' || last_name"}'), TRUE, CURRENT_TIMESTAMP()),
    ('sm_ins_pol', 'insurance', 'RAW.INSURANCE_POLICIES', 'relationship', PARSE_JSON('{"relationship_id": "policy_id", "customer_id": "customer_id"}'), TRUE, CURRENT_TIMESTAMP()),
    ('sm_lend_cust', 'lending', 'RAW.LENDING_CUSTOMERS', 'customer', PARSE_JSON('{"customer_id": "customer_id", "name": "first_name || '' '' || last_name"}'), TRUE, CURRENT_TIMESTAMP()),
    ('sm_lend_loan', 'lending', 'RAW.LENDING_LOANS', 'relationship', PARSE_JSON('{"relationship_id": "loan_id", "customer_id": "customer_id"}'), TRUE, CURRENT_TIMESTAMP());

-- User Personas (4 rows)
INSERT INTO USER_PERSONA VALUES
    ('relationship_manager', 'Relationship Manager', 'Decision Queue', PARSE_JSON('["view_customer","execute_autonomous","request_approval"]'), 'ASSIGNED', FALSE, FALSE, 0, NULL, CURRENT_TIMESTAMP()),
    ('team_lead', 'Team Lead', 'Decision Queue', PARSE_JSON('["view_customer","execute_autonomous","approve_action","reject_action"]'), 'TEAM', TRUE, FALSE, 25000, NULL, CURRENT_TIMESTAMP()),
    ('vp_executive', 'VP Executive', 'Reports', PARSE_JSON('["view_customer","execute_autonomous","approve_action","reject_action","override"]'), 'ALL', TRUE, FALSE, 100000, NULL, CURRENT_TIMESTAMP()),
    ('analyst', 'Analyst', 'Reports', PARSE_JSON('["view_customer","view_reports"]'), 'ALL', FALSE, TRUE, 0, NULL, CURRENT_TIMESTAMP());

-- User Persona Assignments
INSERT INTO USER_PERSONA_ASSIGNMENT VALUES
    ('CUSTOMER_360_RM_ROLE', 'relationship_manager', CURRENT_TIMESTAMP()),
    ('CUSTOMER_360_LEAD_ROLE', 'team_lead', CURRENT_TIMESTAMP()),
    ('CUSTOMER_360_VP_ROLE', 'vp_executive', CURRENT_TIMESTAMP()),
    ('CUSTOMER_360_ANALYST_ROLE', 'analyst', CURRENT_TIMESTAMP()),
    ('ACCOUNTADMIN', 'vp_executive', CURRENT_TIMESTAMP());

-- Customer Assignments
INSERT INTO CUSTOMER_ASSIGNMENT VALUES
    ('INS-1001', 'agent_rm_1', 'team_alpha', 'insurance', CURRENT_TIMESTAMP()),
    ('INS-1005', 'agent_rm_1', 'team_alpha', 'insurance', CURRENT_TIMESTAMP()),
    ('INS-1011', 'agent_rm_2', 'team_alpha', 'insurance', CURRENT_TIMESTAMP()),
    ('INS-1003', 'agent_rm_2', 'team_beta', 'insurance', CURRENT_TIMESTAMP()),
    ('LND-2003', 'agent_rm_3', 'team_beta', 'lending', CURRENT_TIMESTAMP()),
    ('LND-2010', 'agent_rm_3', 'team_beta', 'lending', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC SEED DATA — Indian-localized RAW tables
-- =============================================================================
-- 20 insurance customers + 10 lending customers (Indian names, cities, INR)
-- 30 insurance policies (IRDAI-realistic products, premiums in ₹)
-- 15 insurance claims, 50 insurance payments
-- 55 insurance interactions, 23 insurance call transcripts
-- 15 lending loans (SBI/HDFC/ICICI rates), 31 lending payments (2026 dates)
-- 26 lending interactions, 11 lending call transcripts
-- Languages: Hindi, Hinglish, English (mix)
-- Scenarios: competitor switch, IRDAI complaint, discount request, mis-sell,
--   plan upgrade, network hospital, claim dispute, renewal negotiation,
--   job loss, balance transfer, pre-closure, moratorium, positive/referral
-- Deployed via: sql/01b_seed_data.sql
-- =============================================================================

-- =============================================================================
-- SEED DATA — ACTION_EFFECTIVENESS (baseline)
-- =============================================================================
USE SCHEMA ENGINE;

INSERT INTO ACTION_EFFECTIVENESS VALUES
    ('eff_ins_1', 'ins_claim_escalation', 'ins_high_churn', 'insurance', 32, 47, 0.6809, 0.21, 0.85, CURRENT_TIMESTAMP()),
    ('eff_ins_2', 'ins_retention_call', 'ins_medium_churn', 'insurance', 58, 112, 0.5179, 0.06, 0.92, CURRENT_TIMESTAMP()),
    ('eff_ins_3', 'ins_retention_call', 'ins_high_churn', 'insurance', 25, 56, 0.4464, 0.04, 0.78, CURRENT_TIMESTAMP()),
    ('eff_ins_4', 'ins_retention_offer', 'ins_high_churn', 'insurance', 38, 53, 0.7170, 0.28, 0.88, CURRENT_TIMESTAMP()),
    ('eff_ins_5', 'ins_retention_offer', 'ins_critical_churn', 'insurance', 12, 22, 0.5455, 0.15, 0.65, CURRENT_TIMESTAMP()),
    ('eff_ins_6', 'ins_policy_review', 'ins_medium_churn', 'insurance', 41, 89, 0.4607, 0.03, 0.90, CURRENT_TIMESTAMP()),
    ('eff_ins_7', 'ins_manager_escalation', 'ins_critical_churn', 'insurance', 8, 15, 0.5333, 0.18, 0.55, CURRENT_TIMESTAMP()),
    ('eff_ins_8', 'ins_claim_escalation', 'ins_critical_churn', 'insurance', 18, 28, 0.6429, 0.19, 0.80, CURRENT_TIMESTAMP()),
    ('eff_lend_1', 'lend_early_intervention', 'lend_medium_risk', 'lending', 35, 68, 0.5147, 0.08, 0.88, CURRENT_TIMESTAMP()),
    ('eff_lend_2', 'lend_collection_call', 'lend_high_risk', 'lending', 22, 45, 0.4889, 0.05, 0.82, CURRENT_TIMESTAMP()),
    ('eff_lend_3', 'lend_payment_plan', 'lend_high_risk', 'lending', 28, 38, 0.7368, 0.25, 0.86, CURRENT_TIMESTAMP()),
    ('eff_lend_4', 'lend_hardship_program', 'lend_hardship', 'lending', 15, 20, 0.7500, 0.30, 0.70, CURRENT_TIMESTAMP()),
    ('eff_lend_5', 'lend_rate_modification', 'lend_hardship', 'lending', 10, 14, 0.7143, 0.22, 0.62, CURRENT_TIMESTAMP());
