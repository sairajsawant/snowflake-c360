-- =============================================================================
-- New source systems.
--
-- The platform had 11 tables, all transaction systems, with no written channel
-- worth reading and a 6-year average hole between acquisition and first record.
-- These six tables close that, and each one surfaces a DIFFERENT signal so the
-- decision engine has independent evidence rather than one source restated.
--
--   SUPPORT_TICKET      service quality over time   — SLA breach, reopens, CSAT
--   EMAIL_MESSAGE       the written channel         — escalating language, threads
--   GRIEVANCE           regulatory escalation       — IRDAI IGMS, ombudsman
--   PORTABILITY_REQUEST competitive intent          — a regulated, observable act
--   POLICY_VERSION      product usage over years    — renewal timeliness, upgrades
--   EMPLOYER            the corporate decision-maker— group policies, HR contact
--
-- Everything keys on customer_id and carries customer_email / customer_phone so
-- the sources can be joined the way a real integration would have to.
-- Additive: no existing table is altered.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA RAW;

-- ─── Support tickets: the service-quality record ────────────────────────────
CREATE OR REPLACE TABLE SUPPORT_TICKET (
    ticket_id          VARCHAR(40)  PRIMARY KEY,
    customer_id        VARCHAR(50)  NOT NULL,
    customer_email     VARCHAR(200),
    customer_phone     VARCHAR(50),
    domain             VARCHAR(20)  NOT NULL,
    channel            VARCHAR(20)  NOT NULL,   -- EMAIL | PHONE | CHAT
    category           VARCHAR(60)  NOT NULL,
    priority           VARCHAR(20)  NOT NULL,   -- LOW | MEDIUM | HIGH | URGENT
    subject            VARCHAR(300),
    linked_policy_id   VARCHAR(50),
    linked_claim_id    VARCHAR(50),
    opened_at          TIMESTAMP_NTZ NOT NULL,
    first_response_at  TIMESTAMP_NTZ,
    resolved_at        TIMESTAMP_NTZ,
    sla_target_hours   INT,
    sla_breached       BOOLEAN      DEFAULT FALSE,
    reopen_count       INT          DEFAULT 0,
    status             VARCHAR(20)  NOT NULL,   -- OPEN | PENDING | RESOLVED | CLOSED
    csat_score         INT,                     -- 1..5, null if not surveyed
    agent_id           VARCHAR(50),
    created_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─── Email: the written channel, as threads ─────────────────────────────────
CREATE OR REPLACE TABLE EMAIL_MESSAGE (
    message_id      VARCHAR(40)  PRIMARY KEY,
    ticket_id       VARCHAR(40),
    customer_id     VARCHAR(50)  NOT NULL,
    customer_email  VARCHAR(200),
    direction       VARCHAR(10)  NOT NULL,      -- INBOUND | OUTBOUND
    from_address    VARCHAR(200),
    to_address      VARCHAR(200),
    subject         VARCHAR(300),
    body            VARCHAR(8000) NOT NULL,
    thread_position INT          NOT NULL,
    sent_at         TIMESTAMP_NTZ NOT NULL,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─── Regulatory escalation (IRDAI IGMS) ─────────────────────────────────────
CREATE OR REPLACE TABLE GRIEVANCE (
    grievance_id   VARCHAR(40)  PRIMARY KEY,
    customer_id    VARCHAR(50)  NOT NULL,
    customer_email VARCHAR(200),
    policy_id      VARCHAR(50),
    igms_token     VARCHAR(40),
    filed_date     DATE         NOT NULL,
    category       VARCHAR(80),
    description    VARCHAR(1000),
    status         VARCHAR(30),                 -- REGISTERED | UNDER_REVIEW | RESOLVED | ESCALATED
    resolution_date DATE,
    escalated_to_ombudsman BOOLEAN DEFAULT FALSE,
    created_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─── Portability: competitive intent as a regulated, observable act ─────────
CREATE OR REPLACE TABLE PORTABILITY_REQUEST (
    request_id       VARCHAR(40) PRIMARY KEY,
    customer_id      VARCHAR(50) NOT NULL,
    customer_email   VARCHAR(200),
    policy_id        VARCHAR(50),
    requested_date   DATE        NOT NULL,
    target_insurer   VARCHAR(100),
    current_premium  FLOAT,
    quoted_premium   FLOAT,
    stage            VARCHAR(40),               -- ENQUIRY | FORM_REQUESTED | SUBMITTED | WITHDRAWN | COMPLETED
    status           VARCHAR(20),
    notes            VARCHAR(500),
    created_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─── Product usage over time: how the policy itself evolved ─────────────────
CREATE OR REPLACE TABLE POLICY_VERSION (
    version_id        VARCHAR(40) PRIMARY KEY,
    policy_id         VARCHAR(50) NOT NULL,
    customer_id       VARCHAR(50) NOT NULL,
    version_no        INT         NOT NULL,
    effective_from    DATE        NOT NULL,
    effective_to      DATE,
    sum_insured       FLOAT,
    premium           FLOAT,
    change_type       VARCHAR(30),              -- NEW | RENEWAL | UPGRADE | DOWNGRADE | REINSTATEMENT
    renewal_status    VARCHAR(20),              -- ON_TIME | LATE | LAPSED | NA
    days_late         INT         DEFAULT 0,
    no_claim_bonus_pct FLOAT      DEFAULT 0,
    riders            VARCHAR(300),
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─── The corporate decision-maker ───────────────────────────────────────────
CREATE OR REPLACE TABLE EMPLOYER (
    employer_id        VARCHAR(40) PRIMARY KEY,
    employer_name      VARCHAR(200) NOT NULL,
    industry           VARCHAR(80),
    city               VARCHAR(80),
    group_policy_id    VARCHAR(50),
    employee_count     INT,
    hr_contact_name    VARCHAR(120),
    hr_contact_email   VARCHAR(200),
    hr_contact_phone   VARCHAR(50),
    annual_premium     FLOAT,
    relationship_since DATE,
    renewal_date       DATE,
    broker_name        VARCHAR(120),
    created_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE EMPLOYER_MEMBER (
    employer_id  VARCHAR(40) NOT NULL,
    customer_id  VARCHAR(50) NOT NULL,
    member_role  VARCHAR(40),                   -- EMPLOYEE | HR_ADMIN | DEPENDENT
    joined_date  DATE,
    created_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (employer_id, customer_id)
);

SELECT 'New source tables created' AS status;
