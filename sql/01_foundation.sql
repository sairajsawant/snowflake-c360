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
    ('ins_churn_intent', 'insurance', 'churn_intent', 'behavioral', 'INTENT', 'Analyze the following customer interaction transcript. Identify if the customer expresses any intent to cancel, switch providers, or leave. Return HIGH, MEDIUM, LOW, or NONE.', 'RAW.INSURANCE_CALL_TRANSCRIPTS', 0.30, TRUE, CURRENT_TIMESTAMP()),
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
    ('C1023', 'agent_rm_1', 'team_alpha', 'insurance', CURRENT_TIMESTAMP()),
    ('C1045', 'agent_rm_1', 'team_alpha', 'insurance', CURRENT_TIMESTAMP()),
    ('C1067', 'agent_rm_2', 'team_alpha', 'insurance', CURRENT_TIMESTAMP()),
    ('C1089', 'agent_rm_2', 'team_beta', 'insurance', CURRENT_TIMESTAMP()),
    ('C2001', 'agent_rm_3', 'team_beta', 'lending', CURRENT_TIMESTAMP()),
    ('C2015', 'agent_rm_3', 'team_beta', 'lending', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — INSURANCE CUSTOMERS (20)
-- =============================================================================
USE SCHEMA RAW;

INSERT INTO INSURANCE_CUSTOMERS VALUES
    ('C1023', 'Sarah', 'Chen', 'sarah.chen@email.com', '555-0101', '1985-03-15', '2019-06-01', 'Premium Individual', 42300, 'CA', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1045', 'Raj', 'Patel', 'raj.patel@email.com', '555-0102', '1978-11-22', '2017-01-15', 'Premium Family', 67800, 'TX', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1067', 'Maria', 'Santos', 'maria.santos@email.com', '555-0103', '1990-07-08', '2020-03-20', 'Standard Individual', 18500, 'FL', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1089', 'James', 'Wilson', 'james.wilson@email.com', '555-0104', '1982-09-30', '2018-11-10', 'Premium Individual', 35200, 'NY', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1002', 'Emily', 'Johnson', 'emily.j@email.com', '555-0105', '1995-01-14', '2021-07-01', 'Standard Individual', 12400, 'WA', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1003', 'Michael', 'Brown', 'mbrown@email.com', '555-0106', '1972-05-20', '2015-09-15', 'Premium Family', 89200, 'IL', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1004', 'Lisa', 'Davis', 'ldavis@email.com', '555-0107', '1988-12-03', '2019-02-28', 'Standard Family', 28900, 'OH', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1005', 'Robert', 'Martinez', 'rmartinez@email.com', '555-0108', '1980-06-17', '2016-04-10', 'Premium Individual', 51600, 'AZ', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1006', 'Jennifer', 'Taylor', 'jtaylor@email.com', '555-0109', '1993-08-25', '2022-01-05', 'Standard Individual', 8700, 'GA', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1007', 'David', 'Anderson', 'danderson@email.com', '555-0110', '1975-02-11', '2014-06-20', 'Premium Family', 94500, 'PA', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1008', 'Amanda', 'Thomas', 'athomas@email.com', '555-0111', '1987-10-09', '2020-08-12', 'Standard Individual', 15300, 'NC', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1009', 'Kevin', 'Jackson', 'kjackson@email.com', '555-0112', '1991-04-28', '2021-03-01', 'Standard Individual', 11200, 'MI', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1010', 'Susan', 'White', 'swhite@email.com', '555-0113', '1970-07-16', '2013-11-15', 'Premium Family', 102000, 'NJ', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1011', 'Brian', 'Harris', 'bharris@email.com', '555-0114', '1984-03-05', '2018-05-22', 'Standard Family', 32100, 'VA', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1012', 'Nicole', 'Clark', 'nclark@email.com', '555-0115', '1996-09-19', '2022-06-10', 'Standard Individual', 7500, 'CO', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1013', 'Christopher', 'Lewis', 'clewis@email.com', '555-0116', '1979-01-30', '2016-08-01', 'Premium Individual', 58400, 'MA', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1014', 'Michelle', 'Robinson', 'mrobinson@email.com', '555-0117', '1986-11-12', '2019-10-15', 'Standard Family', 24600, 'TN', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1015', 'Daniel', 'Walker', 'dwalker@email.com', '555-0118', '1992-06-07', '2021-01-20', 'Standard Individual', 13800, 'OR', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1016', 'Stephanie', 'Hall', 'shall@email.com', '555-0119', '1983-08-21', '2017-12-05', 'Premium Individual', 45900, 'MN', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C1017', 'Andrew', 'Allen', 'aallen@email.com', '555-0120', '1977-04-14', '2015-03-25', 'Premium Family', 71300, 'WI', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — INSURANCE POLICIES (30)
-- =============================================================================

INSERT INTO INSURANCE_POLICIES VALUES
    ('POL-1001', 'C1023', 'Auto', 'ACTIVE', 1800, 50000, '2023-06-01', '2024-06-01', DATEADD(day, 21, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1002', 'C1023', 'Home', 'ACTIVE', 2400, 350000, '2023-01-15', '2024-01-15', DATEADD(day, 45, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1003', 'C1045', 'Auto', 'ACTIVE', 2200, 75000, '2023-03-01', '2024-03-01', DATEADD(day, 120, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1004', 'C1045', 'Home', 'ACTIVE', 3100, 500000, '2022-07-01', '2023-07-01', DATEADD(day, 90, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1005', 'C1045', 'Life', 'ACTIVE', 1500, 1000000, '2020-01-01', '2030-01-01', '2030-01-01', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1006', 'C1067', 'Auto', 'ACTIVE', 1400, 30000, '2023-09-01', '2024-09-01', DATEADD(day, 60, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1007', 'C1067', 'Renters', 'ACTIVE', 600, 25000, '2023-04-01', '2024-04-01', DATEADD(day, 30, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1008', 'C1089', 'Auto', 'ACTIVE', 1900, 60000, '2023-05-15', '2024-05-15', DATEADD(day, 75, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1009', 'C1089', 'Home', 'ACTIVE', 2800, 400000, '2022-11-01', '2023-11-01', DATEADD(day, 50, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1010', 'C1002', 'Auto', 'ACTIVE', 1200, 25000, '2023-07-01', '2024-07-01', DATEADD(day, 150, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1011', 'C1003', 'Auto', 'ACTIVE', 2000, 80000, '2023-02-01', '2024-02-01', DATEADD(day, 100, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1012', 'C1003', 'Home', 'ACTIVE', 3500, 600000, '2022-09-01', '2023-09-01', DATEADD(day, 200, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1013', 'C1003', 'Life', 'ACTIVE', 2500, 2000000, '2018-01-01', '2038-01-01', '2038-01-01', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1014', 'C1004', 'Auto', 'ACTIVE', 1600, 45000, '2023-08-01', '2024-08-01', DATEADD(day, 180, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1015', 'C1005', 'Auto', 'ACTIVE', 1700, 55000, '2023-04-01', '2024-04-01', DATEADD(day, 110, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1016', 'C1005', 'Home', 'ACTIVE', 2600, 380000, '2022-06-01', '2023-06-01', DATEADD(day, 80, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1017', 'C1006', 'Auto', 'ACTIVE', 1100, 20000, '2023-10-01', '2024-10-01', DATEADD(day, 250, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1018', 'C1007', 'Auto', 'ACTIVE', 2300, 90000, '2023-01-01', '2024-01-01', DATEADD(day, 70, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1019', 'C1007', 'Home', 'ACTIVE', 4000, 750000, '2021-05-01', '2024-05-01', DATEADD(day, 40, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1020', 'C1007', 'Life', 'ACTIVE', 3000, 3000000, '2017-01-01', '2037-01-01', '2037-01-01', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1021', 'C1008', 'Auto', 'ACTIVE', 1300, 35000, '2023-06-15', '2024-06-15', DATEADD(day, 160, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1022', 'C1009', 'Auto', 'ACTIVE', 1150, 28000, '2023-09-01', '2024-09-01', DATEADD(day, 220, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1023', 'C1010', 'Auto', 'ACTIVE', 2100, 70000, '2023-03-15', '2024-03-15', DATEADD(day, 130, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1024', 'C1010', 'Home', 'ACTIVE', 4500, 900000, '2021-01-01', '2024-01-01', DATEADD(day, 60, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1025', 'C1011', 'Auto', 'ACTIVE', 1550, 42000, '2023-07-01', '2024-07-01', DATEADD(day, 140, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1026', 'C1012', 'Auto', 'ACTIVE', 950, 18000, '2023-11-01', '2024-11-01', DATEADD(day, 300, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1027', 'C1013', 'Auto', 'ACTIVE', 1800, 65000, '2023-02-15', '2024-02-15', DATEADD(day, 95, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1028', 'C1014', 'Auto', 'ACTIVE', 1450, 40000, '2023-05-01', '2024-05-01', DATEADD(day, 170, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1029', 'C1015', 'Auto', 'ACTIVE', 1250, 30000, '2023-08-15', '2024-08-15', DATEADD(day, 190, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('POL-1030', 'C1016', 'Auto', 'ACTIVE', 1950, 58000, '2023-04-15', '2024-04-15', DATEADD(day, 105, CURRENT_DATE()), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — INSURANCE CLAIMS (15)
-- =============================================================================

INSERT INTO INSURANCE_CLAIMS VALUES
    ('CLM-2847', 'POL-1001', 'C1023', 'Collision', 'PENDING', 8500, DATEADD(day, -18, CURRENT_DATE()), NULL, 'Rear-end collision at intersection. Vehicle damage to rear bumper and trunk. Customer claims other driver was at fault.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2848', 'POL-1002', 'C1023', 'Property', 'RESOLVED', 3200, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 'Water damage from burst pipe. Kitchen and living room affected.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2850', 'POL-1006', 'C1067', 'Collision', 'PENDING', 12000, DATEADD(day, -25, CURRENT_DATE()), NULL, 'Multi-vehicle accident on highway. Significant front-end damage.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2851', 'POL-1006', 'C1067', 'Comprehensive', 'PENDING', 4500, DATEADD(day, -10, CURRENT_DATE()), NULL, 'Windshield cracked from road debris. Full replacement needed.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2852', 'POL-1007', 'C1067', 'Property', 'PENDING', 2800, DATEADD(day, -5, CURRENT_DATE()), NULL, 'Theft of electronics from rental apartment.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2853', 'POL-1008', 'C1089', 'Collision', 'UNDER_REVIEW', 6200, DATEADD(day, -12, CURRENT_DATE()), NULL, 'Parking lot accident. Moderate side panel damage.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2854', 'POL-1011', 'C1003', 'Comprehensive', 'RESOLVED', 1800, DATEADD(day, -45, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 'Hail damage to vehicle roof and hood.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2855', 'POL-1012', 'C1003', 'Property', 'RESOLVED', 15000, DATEADD(day, -120, CURRENT_DATE()), DATEADD(day, -80, CURRENT_DATE()), 'Storm damage to roof and siding.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2856', 'POL-1014', 'C1004', 'Collision', 'RESOLVED', 3500, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -40, CURRENT_DATE()), 'Minor fender bender in traffic.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2857', 'POL-1018', 'C1007', 'Comprehensive', 'RESOLVED', 900, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -20, CURRENT_DATE()), 'Windshield chip repair.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2858', 'POL-1019', 'C1007', 'Property', 'PENDING', 22000, DATEADD(day, -8, CURRENT_DATE()), NULL, 'Fire damage to kitchen. Major renovation needed.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2859', 'POL-1023', 'C1010', 'Collision', 'RESOLVED', 5500, DATEADD(day, -75, CURRENT_DATE()), DATEADD(day, -50, CURRENT_DATE()), 'Intersection accident. Vehicle totaled.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2860', 'POL-1025', 'C1011', 'Comprehensive', 'UNDER_REVIEW', 2200, DATEADD(day, -15, CURRENT_DATE()), NULL, 'Vandalism damage to vehicle exterior.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2861', 'POL-1027', 'C1013', 'Collision', 'RESOLVED', 4100, DATEADD(day, -50, CURRENT_DATE()), DATEADD(day, -35, CURRENT_DATE()), 'Rear-end collision. Bumper and taillight replacement.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('CLM-2862', 'POL-1030', 'C1016', 'Comprehensive', 'RESOLVED', 1500, DATEADD(day, -40, CURRENT_DATE()), DATEADD(day, -25, CURRENT_DATE()), 'Deer strike damage. Hood and fender repair.', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — INSURANCE PAYMENTS (50)
-- =============================================================================

INSERT INTO INSURANCE_PAYMENTS VALUES
    ('PAY-I001', 'C1023', 'POL-1001', 150.00, DATEADD(day, -180, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I002', 'C1023', 'POL-1001', 150.00, DATEADD(day, -150, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I003', 'C1023', 'POL-1001', 150.00, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I004', 'C1023', 'POL-1001', 150.00, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I005', 'C1023', 'POL-1001', 150.00, DATEADD(day, -60, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I006', 'C1023', 'POL-1002', 200.00, DATEADD(day, -150, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I007', 'C1023', 'POL-1002', 200.00, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I008', 'C1023', 'POL-1002', 200.00, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-I009', 'C1045', 'POL-1003', 183.33, DATEADD(day, -180, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I010', 'C1045', 'POL-1003', 183.33, DATEADD(day, -150, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I011', 'C1045', 'POL-1003', 183.33, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I012', 'C1045', 'POL-1003', 183.33, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I013', 'C1045', 'POL-1003', 183.33, DATEADD(day, -60, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I014', 'C1045', 'POL-1003', 183.33, DATEADD(day, -30, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I015', 'C1045', 'POL-1004', 258.33, DATEADD(day, -180, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I016', 'C1045', 'POL-1004', 258.33, DATEADD(day, -150, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I017', 'C1045', 'POL-1004', 258.33, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I018', 'C1067', 'POL-1006', 116.67, DATEADD(day, -150, CURRENT_DATE()), 'CREDIT_CARD', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I019', 'C1067', 'POL-1006', 116.67, DATEADD(day, -120, CURRENT_DATE()), 'CREDIT_CARD', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I020', 'C1067', 'POL-1006', 116.67, DATEADD(day, -90, CURRENT_DATE()), 'CREDIT_CARD', 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-I021', 'C1067', 'POL-1006', 116.67, DATEADD(day, -60, CURRENT_DATE()), 'CREDIT_CARD', 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-I022', 'C1067', 'POL-1007', 50.00, DATEADD(day, -120, CURRENT_DATE()), 'CREDIT_CARD', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I023', 'C1067', 'POL-1007', 50.00, DATEADD(day, -90, CURRENT_DATE()), 'CREDIT_CARD', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I024', 'C1089', 'POL-1008', 158.33, DATEADD(day, -150, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I025', 'C1089', 'POL-1008', 158.33, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I026', 'C1089', 'POL-1008', 158.33, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I027', 'C1089', 'POL-1009', 233.33, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I028', 'C1089', 'POL-1009', 233.33, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I029', 'C1002', 'POL-1010', 100.00, DATEADD(day, -150, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I030', 'C1002', 'POL-1010', 100.00, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I031', 'C1002', 'POL-1010', 100.00, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I032', 'C1003', 'POL-1011', 166.67, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I033', 'C1003', 'POL-1011', 166.67, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I034', 'C1003', 'POL-1011', 166.67, DATEADD(day, -60, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I035', 'C1004', 'POL-1014', 133.33, DATEADD(day, -90, CURRENT_DATE()), 'CHECK', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I036', 'C1004', 'POL-1014', 133.33, DATEADD(day, -60, CURRENT_DATE()), 'CHECK', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I037', 'C1005', 'POL-1015', 141.67, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I038', 'C1005', 'POL-1015', 141.67, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I039', 'C1005', 'POL-1016', 216.67, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I040', 'C1006', 'POL-1017', 91.67, DATEADD(day, -60, CURRENT_DATE()), 'CREDIT_CARD', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I041', 'C1007', 'POL-1018', 191.67, DATEADD(day, -120, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I042', 'C1007', 'POL-1018', 191.67, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I043', 'C1007', 'POL-1019', 333.33, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I044', 'C1008', 'POL-1021', 108.33, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I045', 'C1009', 'POL-1022', 95.83, DATEADD(day, -60, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I046', 'C1010', 'POL-1023', 175.00, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I047', 'C1010', 'POL-1024', 375.00, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I048', 'C1011', 'POL-1025', 129.17, DATEADD(day, -60, CURRENT_DATE()), 'CHECK', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I049', 'C1013', 'POL-1027', 150.00, DATEADD(day, -90, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP()),
    ('PAY-I050', 'C1016', 'POL-1030', 162.50, DATEADD(day, -60, CURRENT_DATE()), 'ACH', 'COMPLETED', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — INSURANCE INTERACTIONS (40)
-- =============================================================================

INSERT INTO INSURANCE_INTERACTIONS VALUES
    ('INT-I001', 'C1023', 'PHONE', 'complaint', 'Claim status inquiry - frustrated about delay', -0.82, 480, 'AGT-101', DATEADD(minute, -11, CURRENT_TIMESTAMP()), 'Customer called about CLM-2847. Very upset about 18-day delay.', CURRENT_TIMESTAMP()),
    ('INT-I002', 'C1023', 'EMAIL', 'inquiry', 'Policy renewal question', -0.15, NULL, 'AGT-102', DATEADD(day, -5, CURRENT_TIMESTAMP()), 'Asked about renewal options and competitor rates.', CURRENT_TIMESTAMP()),
    ('INT-I003', 'C1023', 'PHONE', 'complaint', 'Previous claim follow-up', -0.65, 320, 'AGT-103', DATEADD(day, -10, CURRENT_TIMESTAMP()), 'Called again about claim. Mentioned might switch providers.', CURRENT_TIMESTAMP()),
    ('INT-I004', 'C1023', 'CHAT', 'inquiry', 'Coverage question', 0.10, 180, 'AGT-104', DATEADD(day, -30, CURRENT_TIMESTAMP()), 'Asked about adding umbrella coverage.', CURRENT_TIMESTAMP()),
    ('INT-I005', 'C1023', 'EMAIL', 'service', 'Address change request', 0.30, NULL, 'AGT-102', DATEADD(day, -60, CURRENT_TIMESTAMP()), 'Routine address update.', CURRENT_TIMESTAMP()),
    ('INT-I006', 'C1045', 'PHONE', 'inquiry', 'Coverage review', 0.45, 240, 'AGT-101', DATEADD(day, -15, CURRENT_TIMESTAMP()), 'Annual coverage review. Happy with service.', CURRENT_TIMESTAMP()),
    ('INT-I007', 'C1045', 'EMAIL', 'service', 'Payment confirmation', 0.60, NULL, 'AGT-102', DATEADD(day, -30, CURRENT_TIMESTAMP()), 'Confirmed auto-pay setup.', CURRENT_TIMESTAMP()),
    ('INT-I008', 'C1045', 'CHAT', 'inquiry', 'Discount question', 0.20, 120, 'AGT-104', DATEADD(day, -45, CURRENT_TIMESTAMP()), 'Asked about multi-policy discount.', CURRENT_TIMESTAMP()),
    ('INT-I009', 'C1067', 'PHONE', 'complaint', 'Multiple claims frustration', -0.91, 600, 'AGT-101', DATEADD(day, -3, CURRENT_TIMESTAMP()), 'Extremely frustrated. 3 pending claims. Wants to cancel.', CURRENT_TIMESTAMP()),
    ('INT-I010', 'C1067', 'PHONE', 'complaint', 'Claim status check', -0.75, 360, 'AGT-103', DATEADD(day, -8, CURRENT_TIMESTAMP()), 'Checking on collision claim. Unhappy with process.', CURRENT_TIMESTAMP()),
    ('INT-I011', 'C1067', 'EMAIL', 'complaint', 'Written complaint', -0.88, NULL, 'AGT-102', DATEADD(day, -6, CURRENT_TIMESTAMP()), 'Formal complaint about claim handling times.', CURRENT_TIMESTAMP()),
    ('INT-I012', 'C1067', 'CHAT', 'inquiry', 'Cancellation policy question', -0.70, 150, 'AGT-104', DATEADD(day, -2, CURRENT_TIMESTAMP()), 'Asked about policy cancellation fees.', CURRENT_TIMESTAMP()),
    ('INT-I013', 'C1089', 'PHONE', 'inquiry', 'Claim update request', -0.35, 200, 'AGT-101', DATEADD(day, -7, CURRENT_TIMESTAMP()), 'Checking on parking lot accident claim.', CURRENT_TIMESTAMP()),
    ('INT-I014', 'C1089', 'EMAIL', 'service', 'Document submission', 0.10, NULL, 'AGT-102', DATEADD(day, -9, CURRENT_TIMESTAMP()), 'Submitted accident photos for claim.', CURRENT_TIMESTAMP()),
    ('INT-I015', 'C1089', 'PHONE', 'inquiry', 'Rate comparison', -0.25, 300, 'AGT-103', DATEADD(day, -20, CURRENT_TIMESTAMP()), 'Comparing rates. Got quotes from competitors.', CURRENT_TIMESTAMP()),
    ('INT-I016', 'C1002', 'CHAT', 'inquiry', 'Coverage question', 0.30, 90, 'AGT-104', DATEADD(day, -14, CURRENT_TIMESTAMP()), 'Asked about roadside assistance.', CURRENT_TIMESTAMP()),
    ('INT-I017', 'C1002', 'EMAIL', 'service', 'ID card request', 0.50, NULL, 'AGT-102', DATEADD(day, -20, CURRENT_TIMESTAMP()), 'Requested new insurance ID cards.', CURRENT_TIMESTAMP()),
    ('INT-I018', 'C1003', 'PHONE', 'service', 'Thank you call', 0.85, 120, 'AGT-101', DATEADD(day, -25, CURRENT_TIMESTAMP()), 'Called to thank for quick claim resolution.', CURRENT_TIMESTAMP()),
    ('INT-I019', 'C1003', 'EMAIL', 'inquiry', 'Policy upgrade', 0.40, NULL, 'AGT-102', DATEADD(day, -35, CURRENT_TIMESTAMP()), 'Interested in upgrading coverage.', CURRENT_TIMESTAMP()),
    ('INT-I020', 'C1004', 'PHONE', 'inquiry', 'Premium question', -0.10, 180, 'AGT-103', DATEADD(day, -12, CURRENT_TIMESTAMP()), 'Asked why premium increased.', CURRENT_TIMESTAMP()),
    ('INT-I021', 'C1005', 'EMAIL', 'service', 'Auto-pay setup', 0.55, NULL, 'AGT-102', DATEADD(day, -18, CURRENT_TIMESTAMP()), 'Set up automatic payments.', CURRENT_TIMESTAMP()),
    ('INT-I022', 'C1005', 'PHONE', 'inquiry', 'Bundling discount', 0.35, 200, 'AGT-101', DATEADD(day, -40, CURRENT_TIMESTAMP()), 'Asked about bundling auto + home.', CURRENT_TIMESTAMP()),
    ('INT-I023', 'C1006', 'CHAT', 'inquiry', 'New driver question', 0.15, 100, 'AGT-104', DATEADD(day, -22, CURRENT_TIMESTAMP()), 'Adding teen driver to policy.', CURRENT_TIMESTAMP()),
    ('INT-I024', 'C1007', 'PHONE', 'complaint', 'Fire claim urgency', -0.60, 420, 'AGT-101', DATEADD(day, -6, CURRENT_TIMESTAMP()), 'Urgent call about kitchen fire claim.', CURRENT_TIMESTAMP()),
    ('INT-I025', 'C1007', 'EMAIL', 'inquiry', 'Temporary housing', -0.30, NULL, 'AGT-102', DATEADD(day, -5, CURRENT_TIMESTAMP()), 'Needs temporary housing info while kitchen repaired.', CURRENT_TIMESTAMP()),
    ('INT-I026', 'C1008', 'CHAT', 'service', 'Payment method change', 0.25, 80, 'AGT-104', DATEADD(day, -16, CURRENT_TIMESTAMP()), 'Changed payment method to new card.', CURRENT_TIMESTAMP()),
    ('INT-I027', 'C1009', 'EMAIL', 'inquiry', 'Coverage limits', 0.10, NULL, 'AGT-102', DATEADD(day, -28, CURRENT_TIMESTAMP()), 'Asked about increasing liability limits.', CURRENT_TIMESTAMP()),
    ('INT-I028', 'C1010', 'PHONE', 'service', 'Policy review', 0.70, 300, 'AGT-101', DATEADD(day, -10, CURRENT_TIMESTAMP()), 'Annual review. Very satisfied. Loyal customer.', CURRENT_TIMESTAMP()),
    ('INT-I029', 'C1010', 'EMAIL', 'service', 'Referral', 0.90, NULL, 'AGT-102', DATEADD(day, -15, CURRENT_TIMESTAMP()), 'Referred a friend. Asking about referral bonus.', CURRENT_TIMESTAMP()),
    ('INT-I030', 'C1011', 'PHONE', 'complaint', 'Vandalism claim', -0.45, 250, 'AGT-103', DATEADD(day, -13, CURRENT_TIMESTAMP()), 'Filed vandalism claim. Worried about rate increase.', CURRENT_TIMESTAMP()),
    ('INT-I031', 'C1012', 'CHAT', 'inquiry', 'First-time buyer question', 0.20, 150, 'AGT-104', DATEADD(day, -8, CURRENT_TIMESTAMP()), 'New customer with coverage questions.', CURRENT_TIMESTAMP()),
    ('INT-I032', 'C1013', 'EMAIL', 'service', 'Proof of insurance', 0.45, NULL, 'AGT-102', DATEADD(day, -11, CURRENT_TIMESTAMP()), 'Requested proof of insurance for registration.', CURRENT_TIMESTAMP()),
    ('INT-I033', 'C1014', 'PHONE', 'inquiry', 'Family plan', 0.30, 240, 'AGT-101', DATEADD(day, -19, CURRENT_TIMESTAMP()), 'Interested in adding family members.', CURRENT_TIMESTAMP()),
    ('INT-I034', 'C1015', 'CHAT', 'service', 'App help', 0.15, 60, 'AGT-104', DATEADD(day, -24, CURRENT_TIMESTAMP()), 'Needed help with mobile app.', CURRENT_TIMESTAMP()),
    ('INT-I035', 'C1016', 'EMAIL', 'inquiry', 'Deer strike claim', 0.05, NULL, 'AGT-102', DATEADD(day, -38, CURRENT_TIMESTAMP()), 'Follow-up on resolved deer strike claim.', CURRENT_TIMESTAMP()),
    ('INT-I036', 'C1017', 'PHONE', 'inquiry', 'Life insurance review', 0.50, 360, 'AGT-101', DATEADD(day, -9, CURRENT_TIMESTAMP()), 'Annual life insurance review.', CURRENT_TIMESTAMP()),
    ('INT-I037', 'C1023', 'PHONE', 'service', 'Billing inquiry', 0.20, 120, 'AGT-101', DATEADD(day, -90, CURRENT_TIMESTAMP()), 'Routine billing question.', CURRENT_TIMESTAMP()),
    ('INT-I038', 'C1045', 'EMAIL', 'service', 'Policy documents', 0.65, NULL, 'AGT-102', DATEADD(day, -60, CURRENT_TIMESTAMP()), 'Requested digital copies of all policies.', CURRENT_TIMESTAMP()),
    ('INT-I039', 'C1067', 'PHONE', 'complaint', 'Rate increase complaint', -0.55, 280, 'AGT-103', DATEADD(day, -45, CURRENT_TIMESTAMP()), 'Unhappy about rate increase at renewal.', CURRENT_TIMESTAMP()),
    ('INT-I040', 'C1089', 'CHAT', 'inquiry', 'Coverage question', 0.00, 140, 'AGT-104', DATEADD(day, -35, CURRENT_TIMESTAMP()), 'General coverage adequacy question.', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — INSURANCE CALL TRANSCRIPTS (10)
-- =============================================================================

INSERT INTO INSURANCE_CALL_TRANSCRIPTS VALUES
    ('TRN-I001', 'INT-I001', 'C1023', 'Agent: Thank you for calling. How can I help you today?\nCustomer: I''m calling about my claim, CLM-2847. It''s been 18 days and I haven''t heard anything. This is completely unacceptable.\nAgent: I understand your frustration, Ms. Chen. Let me look into that for you.\nCustomer: I''ve been a loyal customer for over 5 years and this is how I''m treated? I''ve already gotten quotes from two other insurers and honestly, I''m seriously considering switching before my renewal comes up next month.\nAgent: I''m sorry to hear that. Let me escalate this to our priority claims team right away.\nCustomer: You need to do something because right now I don''t see any reason to stay. My neighbor switched to Progressive and they handled his claim in 3 days.\nAgent: I completely understand. I''m going to flag this as urgent and have our claims manager call you within 24 hours.\nCustomer: Fine, but if I don''t hear back by tomorrow, I''m done.', DATEADD(minute, -11, CURRENT_TIMESTAMP()), 480, 'AGT-101', CURRENT_TIMESTAMP()),
    ('TRN-I002', 'INT-I003', 'C1023', 'Agent: Hello Ms. Chen, I''m following up on your claim.\nCustomer: Yes, I called last week too and nothing has changed. This is my second call about this claim.\nAgent: I see that in our records. Let me check the latest status.\nCustomer: Look, I''ve been patient but my policy is up for renewal in about 3 weeks. If this isn''t resolved by then, I''m not renewing. Plain and simple.\nAgent: I understand. Let me speak with our claims adjuster.\nCustomer: Please do. I like your company but this experience has really shaken my confidence.', DATEADD(day, -10, CURRENT_TIMESTAMP()), 320, 'AGT-103', CURRENT_TIMESTAMP()),
    ('TRN-I003', 'INT-I009', 'C1067', 'Agent: Good morning, how can I assist you?\nCustomer: I want to cancel all my policies. I have three claims pending and nobody is helping me.\nAgent: I''m sorry to hear that, Ms. Santos. Can you tell me more about what''s going on?\nCustomer: I had a car accident 25 days ago, then my windshield cracked, and now someone stole electronics from my apartment. Three claims, zero resolution. I''ve spent hours on the phone.\nAgent: That''s a lot to deal with at once. Let me review all three claims.\nCustomer: Don''t bother reviewing. I want cancellation. What are the fees?\nAgent: Before we discuss cancellation, let me see if we can get these claims expedited. I understand your frustration.\nCustomer: You have one week. If I don''t see movement on at least two of these claims, I''m gone.', DATEADD(day, -3, CURRENT_TIMESTAMP()), 600, 'AGT-101', CURRENT_TIMESTAMP()),
    ('TRN-I004', 'INT-I010', 'C1067', 'Agent: Thank you for calling. How may I help?\nCustomer: I''m checking on my collision claim from the highway accident. CLM-2850.\nAgent: Let me pull that up. I see it was filed 25 days ago.\nCustomer: 25 days and still pending? This is exactly why I''m looking at other companies.\nAgent: I understand your concern. The adjuster notes show they''re waiting for the other driver''s insurance to respond.\nCustomer: That''s not my problem. I pay my premiums on time and I expect service in return.', DATEADD(day, -8, CURRENT_TIMESTAMP()), 360, 'AGT-103', CURRENT_TIMESTAMP()),
    ('TRN-I005', 'INT-I006', 'C1045', 'Agent: Good afternoon, Mr. Patel. How can I help today?\nCustomer: Hi! I just wanted to do my annual review. We have auto, home, and life with you.\nAgent: Absolutely. Let me pull up your portfolio.\nCustomer: Everything has been great this year. The hail damage claim was handled really well.\nAgent: I''m glad to hear that. Looking at your policies, your coverage looks comprehensive.\nCustomer: Yeah, I''m happy. Maybe look at increasing my life insurance a bit.\nAgent: Sure, I can run some quotes for you.', DATEADD(day, -15, CURRENT_TIMESTAMP()), 240, 'AGT-101', CURRENT_TIMESTAMP()),
    ('TRN-I006', 'INT-I013', 'C1089', 'Agent: Hello Mr. Wilson, calling about your claim?\nCustomer: Yes, claim CLM-2853. It''s been under review for 12 days.\nAgent: Let me check. Yes, I see the adjuster is finalizing the estimate.\nCustomer: I got a quote from GEICO that''s about $200 less per year. Just something to think about.\nAgent: I appreciate you letting us know. Let me see what we can do about your rate at renewal.\nCustomer: I''m not in a rush to switch, but if the claim takes much longer, my patience is wearing thin.', DATEADD(day, -7, CURRENT_TIMESTAMP()), 200, 'AGT-101', CURRENT_TIMESTAMP()),
    ('TRN-I007', 'INT-I024', 'C1007', 'Agent: Good morning, Mr. Anderson. I see you''re calling about your fire claim.\nCustomer: Yes, the kitchen fire. CLM-2858. We need this resolved quickly. We can''t use our kitchen.\nAgent: I completely understand the urgency. Let me check the status.\nCustomer: We''ve been a customer for over 10 years and always paid on time. We need your support now.\nAgent: Absolutely. I''m going to request emergency temporary housing coverage and expedite the claim assessment.\nCustomer: Thank you. We''re loyal customers but this is really stressful.', DATEADD(day, -6, CURRENT_TIMESTAMP()), 420, 'AGT-101', CURRENT_TIMESTAMP()),
    ('TRN-I008', 'INT-I030', 'C1011', 'Agent: How can I help you today?\nCustomer: Someone vandalized my car last night. I need to file a claim.\nAgent: I''m sorry to hear that. Let me help you get that started.\nCustomer: Will this affect my rates? I''m already paying quite a bit.\nAgent: Comprehensive claims typically have less impact on rates than at-fault accidents.\nCustomer: Okay, that''s somewhat reassuring. Let''s proceed with the claim.', DATEADD(day, -13, CURRENT_TIMESTAMP()), 250, 'AGT-103', CURRENT_TIMESTAMP()),
    ('TRN-I009', 'INT-I015', 'C1089', 'Agent: Hello, how can I assist you today?\nCustomer: I''ve been doing some comparison shopping. I got quotes from a few companies.\nAgent: I understand. Would you like to review your current coverage and rates?\nCustomer: Sure. I''m paying about $4,700 total for auto and home. GEICO quoted me $4,200 and State Farm was at $4,400.\nAgent: Let me look at what discounts we might be able to apply.\nCustomer: I''d prefer to stay but the numbers need to work.', DATEADD(day, -20, CURRENT_TIMESTAMP()), 300, 'AGT-103', CURRENT_TIMESTAMP()),
    ('TRN-I010', 'INT-I039', 'C1067', 'Agent: Thank you for calling.\nCustomer: Why did my rate go up? I got the renewal notice and it''s 15% higher.\nAgent: Let me review your policy. I see you had a rate adjustment based on claims history.\nCustomer: But I''m the victim in these claims! The accident wasn''t my fault and the theft isn''t my fault either.\nAgent: I understand. Some adjustments are based on claim frequency regardless of fault.\nCustomer: That doesn''t seem fair. I''m seriously reconsidering my options.', DATEADD(day, -45, CURRENT_TIMESTAMP()), 280, 'AGT-103', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — LENDING CUSTOMERS (10)
-- =============================================================================

INSERT INTO LENDING_CUSTOMERS VALUES
    ('C2001', 'Priya', 'Sharma', 'priya.sharma@email.com', '555-0201', '1987-04-12', '2020-06-15', 720, 85000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2015', 'Tom', 'Nguyen', 'tom.nguyen@email.com', '555-0202', '1994-08-30', '2023-01-10', 640, 52000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2003', 'Lisa', 'Park', 'lpark@email.com', '555-0203', '1982-12-05', '2019-03-20', 780, 110000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2004', 'Marcus', 'Johnson', 'mjohnson@email.com', '555-0204', '1990-06-18', '2021-08-01', 680, 68000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2005', 'Anna', 'Williams', 'awilliams@email.com', '555-0205', '1985-09-22', '2018-11-15', 750, 95000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2006', 'Derek', 'Thompson', 'dthompson@email.com', '555-0206', '1976-03-08', '2017-05-01', 800, 145000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2007', 'Rachel', 'Garcia', 'rgarcia@email.com', '555-0207', '1992-11-14', '2022-02-28', 660, 55000, 'SELF_EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2008', 'Steven', 'Lee', 'slee@email.com', '555-0208', '1988-07-25', '2020-09-10', 710, 78000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2009', 'Karen', 'Robinson', 'krobinson@email.com', '555-0209', '1973-01-19', '2016-04-15', 760, 120000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('C2010', 'Tyler', 'Martinez', 'tmartinez@email.com', '555-0210', '1998-05-03', '2023-06-01', 620, 42000, 'EMPLOYED', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — LENDING LOANS (15)
-- =============================================================================

INSERT INTO LENDING_LOANS VALUES
    ('LN-3001', 'C2001', 'Personal', 'ACTIVE', 25000, 0.089, 60, 518.96, '2022-06-15', '2027-06-15', 18500, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3002', 'C2001', 'Auto', 'ACTIVE', 32000, 0.059, 72, 527.42, '2023-01-10', '2029-01-10', 28800, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3003', 'C2015', 'Personal', 'ACTIVE', 15000, 0.129, 48, 400.72, '2023-06-01', '2027-06-01', 12500, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3004', 'C2003', 'Mortgage', 'ACTIVE', 350000, 0.042, 360, 1718.19, '2020-03-15', '2050-03-15', 320000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3005', 'C2003', 'Auto', 'ACTIVE', 28000, 0.049, 60, 528.15, '2022-09-01', '2027-09-01', 15400, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3006', 'C2004', 'Personal', 'ACTIVE', 20000, 0.109, 48, 517.26, '2022-08-01', '2026-08-01', 10800, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3007', 'C2005', 'Mortgage', 'ACTIVE', 280000, 0.038, 360, 1302.50, '2019-11-15', '2049-11-15', 258000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3008', 'C2005', 'HELOC', 'ACTIVE', 50000, 0.065, 120, 567.74, '2021-06-01', '2031-06-01', 38000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3009', 'C2006', 'Mortgage', 'ACTIVE', 420000, 0.035, 360, 1886.44, '2018-05-01', '2048-05-01', 378000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3010', 'C2006', 'Auto', 'ACTIVE', 45000, 0.039, 60, 826.69, '2023-03-01', '2028-03-01', 36000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3011', 'C2007', 'Personal', 'ACTIVE', 12000, 0.149, 36, 416.27, '2023-02-28', '2026-02-28', 8400, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3012', 'C2008', 'Auto', 'ACTIVE', 22000, 0.069, 60, 434.84, '2022-09-10', '2027-09-10', 13200, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3013', 'C2009', 'Mortgage', 'ACTIVE', 300000, 0.040, 360, 1432.25, '2017-04-15', '2047-04-15', 268000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3014', 'C2010', 'Personal', 'ACTIVE', 8000, 0.169, 36, 283.79, '2023-09-01', '2026-09-01', 6800, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),
    ('LN-3015', 'C2001', 'HELOC', 'ACTIVE', 40000, 0.072, 120, 467.53, '2021-12-01', '2031-12-01', 32000, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — LENDING PAYMENTS (40)
-- =============================================================================

INSERT INTO LENDING_PAYMENTS VALUES
    ('PAY-L001', 'LN-3001', 'C2001', 518.96, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L002', 'LN-3001', 'C2001', 518.96, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L003', 'LN-3001', 'C2001', 518.96, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 5, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L004', 'LN-3001', 'C2001', 518.96, CURRENT_DATE(), CURRENT_DATE(), 12, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L005', 'LN-3002', 'C2001', 527.42, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L006', 'LN-3002', 'C2001', 527.42, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L007', 'LN-3002', 'C2001', 527.42, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 8, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L008', 'LN-3003', 'C2015', 400.72, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 15, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L009', 'LN-3003', 'C2015', 400.72, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 22, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L010', 'LN-3003', 'C2015', 200.00, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 35, 'PARTIAL', CURRENT_TIMESTAMP()),
    ('PAY-L011', 'LN-3004', 'C2003', 1718.19, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L012', 'LN-3004', 'C2003', 1718.19, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L013', 'LN-3004', 'C2003', 1718.19, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L014', 'LN-3005', 'C2003', 528.15, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L015', 'LN-3005', 'C2003', 528.15, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L016', 'LN-3006', 'C2004', 517.26, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L017', 'LN-3006', 'C2004', 517.26, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 3, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L018', 'LN-3006', 'C2004', 517.26, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L019', 'LN-3007', 'C2005', 1302.50, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L020', 'LN-3007', 'C2005', 1302.50, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L021', 'LN-3007', 'C2005', 1302.50, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L022', 'LN-3008', 'C2005', 567.74, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L023', 'LN-3008', 'C2005', 567.74, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L024', 'LN-3009', 'C2006', 1886.44, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L025', 'LN-3009', 'C2006', 1886.44, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L026', 'LN-3009', 'C2006', 1886.44, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L027', 'LN-3010', 'C2006', 826.69, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L028', 'LN-3010', 'C2006', 826.69, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L029', 'LN-3011', 'C2007', 416.27, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 10, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L030', 'LN-3011', 'C2007', 416.27, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 18, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L031', 'LN-3011', 'C2007', 300.00, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 25, 'PARTIAL', CURRENT_TIMESTAMP()),
    ('PAY-L032', 'LN-3012', 'C2008', 434.84, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L033', 'LN-3012', 'C2008', 434.84, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L034', 'LN-3012', 'C2008', 434.84, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 2, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L035', 'LN-3013', 'C2009', 1432.25, DATEADD(day, -90, CURRENT_DATE()), DATEADD(day, -90, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L036', 'LN-3013', 'C2009', 1432.25, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L037', 'LN-3013', 'C2009', 1432.25, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 0, 'ON_TIME', CURRENT_TIMESTAMP()),
    ('PAY-L038', 'LN-3014', 'C2010', 283.79, DATEADD(day, -60, CURRENT_DATE()), DATEADD(day, -60, CURRENT_DATE()), 8, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L039', 'LN-3014', 'C2010', 283.79, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 15, 'LATE', CURRENT_TIMESTAMP()),
    ('PAY-L040', 'LN-3015', 'C2001', 467.53, DATEADD(day, -30, CURRENT_DATE()), DATEADD(day, -30, CURRENT_DATE()), 10, 'LATE', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — LENDING INTERACTIONS (20)
-- =============================================================================

INSERT INTO LENDING_INTERACTIONS VALUES
    ('INT-L001', 'C2001', 'PHONE', 'complaint', 'Payment difficulty discussion', -0.65, 420, 'AGT-201', DATEADD(day, -3, CURRENT_TIMESTAMP()), 'Customer mentioned job change affecting income. Having trouble making payments on time.', CURRENT_TIMESTAMP()),
    ('INT-L002', 'C2001', 'EMAIL', 'inquiry', 'Payment plan request', -0.40, NULL, 'AGT-202', DATEADD(day, -7, CURRENT_TIMESTAMP()), 'Asked about restructuring payment schedule.', CURRENT_TIMESTAMP()),
    ('INT-L003', 'C2001', 'PHONE', 'service', 'Account review', -0.20, 300, 'AGT-201', DATEADD(day, -30, CURRENT_TIMESTAMP()), 'Quarterly account review. Mentioned tight finances.', CURRENT_TIMESTAMP()),
    ('INT-L004', 'C2015', 'PHONE', 'complaint', 'Hardship discussion', -0.85, 540, 'AGT-201', DATEADD(day, -5, CURRENT_TIMESTAMP()), 'Customer lost job. Cannot make full payments. Requesting hardship options.', CURRENT_TIMESTAMP()),
    ('INT-L005', 'C2015', 'EMAIL', 'inquiry', 'Forbearance request', -0.70, NULL, 'AGT-202', DATEADD(day, -10, CURRENT_TIMESTAMP()), 'Formal request for payment forbearance.', CURRENT_TIMESTAMP()),
    ('INT-L006', 'C2003', 'PHONE', 'service', 'Rate inquiry', 0.50, 180, 'AGT-201', DATEADD(day, -12, CURRENT_TIMESTAMP()), 'Asked about refinancing at lower rate.', CURRENT_TIMESTAMP()),
    ('INT-L007', 'C2003', 'EMAIL', 'service', 'Payment confirmation', 0.60, NULL, 'AGT-202', DATEADD(day, -20, CURRENT_TIMESTAMP()), 'Confirmed extra principal payment.', CURRENT_TIMESTAMP()),
    ('INT-L008', 'C2004', 'PHONE', 'inquiry', 'Late payment explanation', -0.30, 200, 'AGT-203', DATEADD(day, -8, CURRENT_TIMESTAMP()), 'Explained late payment was due to payroll delay.', CURRENT_TIMESTAMP()),
    ('INT-L009', 'C2005', 'EMAIL', 'service', 'Auto-pay setup', 0.45, NULL, 'AGT-202', DATEADD(day, -15, CURRENT_TIMESTAMP()), 'Set up automatic payments for all accounts.', CURRENT_TIMESTAMP()),
    ('INT-L010', 'C2006', 'PHONE', 'service', 'Account review', 0.70, 240, 'AGT-201', DATEADD(day, -18, CURRENT_TIMESTAMP()), 'Annual review. Excellent payment history. Happy customer.', CURRENT_TIMESTAMP()),
    ('INT-L011', 'C2007', 'PHONE', 'complaint', 'Payment difficulty', -0.55, 360, 'AGT-203', DATEADD(day, -6, CURRENT_TIMESTAMP()), 'Self-employed income fluctuating. Struggling with payments.', CURRENT_TIMESTAMP()),
    ('INT-L012', 'C2007', 'EMAIL', 'inquiry', 'Payment options', -0.40, NULL, 'AGT-202', DATEADD(day, -14, CURRENT_TIMESTAMP()), 'Asked about changing payment date to align with income.', CURRENT_TIMESTAMP()),
    ('INT-L013', 'C2008', 'CHAT', 'inquiry', 'Balance inquiry', 0.10, 90, 'AGT-204', DATEADD(day, -9, CURRENT_TIMESTAMP()), 'Checked remaining balance on auto loan.', CURRENT_TIMESTAMP()),
    ('INT-L014', 'C2009', 'EMAIL', 'service', 'Tax documents', 0.55, NULL, 'AGT-202', DATEADD(day, -22, CURRENT_TIMESTAMP()), 'Requested mortgage interest statement.', CURRENT_TIMESTAMP()),
    ('INT-L015', 'C2010', 'PHONE', 'complaint', 'Rate complaint', -0.50, 280, 'AGT-203', DATEADD(day, -4, CURRENT_TIMESTAMP()), 'Unhappy with high interest rate. Late payments making it worse.', CURRENT_TIMESTAMP()),
    ('INT-L016', 'C2010', 'EMAIL', 'inquiry', 'Refinance question', -0.25, NULL, 'AGT-202', DATEADD(day, -11, CURRENT_TIMESTAMP()), 'Asked about refinancing options despite late payments.', CURRENT_TIMESTAMP()),
    ('INT-L017', 'C2001', 'CHAT', 'inquiry', 'Online banking help', 0.00, 120, 'AGT-204', DATEADD(day, -45, CURRENT_TIMESTAMP()), 'Needed help setting up online payment portal.', CURRENT_TIMESTAMP()),
    ('INT-L018', 'C2015', 'PHONE', 'complaint', 'Collections concern', -0.75, 300, 'AGT-201', DATEADD(day, -15, CURRENT_TIMESTAMP()), 'Worried about collections. Asking for alternatives.', CURRENT_TIMESTAMP()),
    ('INT-L019', 'C2004', 'EMAIL', 'service', 'Document upload', 0.20, NULL, 'AGT-202', DATEADD(day, -25, CURRENT_TIMESTAMP()), 'Uploaded proof of income for review.', CURRENT_TIMESTAMP()),
    ('INT-L020', 'C2006', 'EMAIL', 'service', 'Extra payment', 0.80, NULL, 'AGT-202', DATEADD(day, -8, CURRENT_TIMESTAMP()), 'Made extra principal payment of $5,000 on mortgage.', CURRENT_TIMESTAMP());

-- =============================================================================
-- SYNTHETIC DATA — LENDING CALL TRANSCRIPTS (5)
-- =============================================================================

INSERT INTO LENDING_CALL_TRANSCRIPTS VALUES
    ('TRN-L001', 'INT-L001', 'C2001', 'Agent: Hello Ms. Sharma, how can I help you today?\nCustomer: Hi, I need to talk about my loans. I recently changed jobs and there was a gap in income. I''m having trouble keeping up with all three payments.\nAgent: I''m sorry to hear that. Let me look at your accounts.\nCustomer: I have the personal loan, auto loan, and HELOC. The total monthly is over $1,500 and with the new job, I''m making less than before.\nAgent: I understand. We have several options we can explore, including payment restructuring.\nCustomer: That would be helpful. I don''t want to default but I literally can''t make the full payments right now. Can we look at reducing the payments for a few months?\nAgent: Absolutely. Let me see what programs are available for your situation.', DATEADD(day, -3, CURRENT_TIMESTAMP()), 420, 'AGT-201', CURRENT_TIMESTAMP()),
    ('TRN-L002', 'INT-L004', 'C2015', 'Agent: Good morning, Mr. Nguyen. What can I do for you?\nCustomer: I lost my job two weeks ago. I can''t make my loan payment. I don''t know what to do.\nAgent: I''m very sorry to hear that. Please know we have programs to help in situations like this.\nCustomer: I''ve only been a customer for about a year. Will that matter?\nAgent: Every customer has access to our hardship programs regardless of tenure.\nCustomer: I might be able to make a partial payment, like half. But the full amount is impossible right now.\nAgent: Let me look into our forbearance and hardship programs. We want to work with you on this.\nCustomer: Thank you. I was really stressed about calling but I didn''t want to just stop paying.', DATEADD(day, -5, CURRENT_TIMESTAMP()), 540, 'AGT-201', CURRENT_TIMESTAMP()),
    ('TRN-L003', 'INT-L011', 'C2007', 'Agent: Thank you for calling. How can I assist?\nCustomer: I''m self-employed and my income has been really inconsistent lately. I''ve been late on my last few payments.\nAgent: I see that in your account. Let''s talk about what''s happening.\nCustomer: Some months I make good money, others not so much. The fixed payment doesn''t work with variable income.\nAgent: We might be able to adjust your payment date or explore a modified payment plan.\nCustomer: That would help a lot. I want to pay, I just need more flexibility.', DATEADD(day, -6, CURRENT_TIMESTAMP()), 360, 'AGT-203', CURRENT_TIMESTAMP()),
    ('TRN-L004', 'INT-L010', 'C2006', 'Agent: Hello Mr. Thompson, how can I help today?\nCustomer: Just calling for my annual review. Everything is going well.\nAgent: Great to hear! You have an excellent payment history across all accounts.\nCustomer: I actually wanted to discuss making extra payments on the mortgage. I just put $5,000 toward principal.\nAgent: That''s excellent. That will significantly reduce your interest over the life of the loan.\nCustomer: We''re really happy with your service. Been here almost 10 years now.', DATEADD(day, -18, CURRENT_TIMESTAMP()), 240, 'AGT-201', CURRENT_TIMESTAMP()),
    ('TRN-L005', 'INT-L015', 'C2010', 'Agent: How can I help you today?\nCustomer: My interest rate on the personal loan is 16.9%. That''s really high. And I know I''ve been late a couple times which probably doesn''t help.\nAgent: You''re right that payment history does affect rate options. Let me look at your account.\nCustomer: Is there any way to get a lower rate? The high rate is making it harder to pay on time, which keeps the rate high. It''s a cycle.\nAgent: I understand the concern. With improved payment history, we can review the rate in 6 months.\nCustomer: Six months is a long time when you''re struggling.', DATEADD(day, -4, CURRENT_TIMESTAMP()), 280, 'AGT-203', CURRENT_TIMESTAMP());

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
