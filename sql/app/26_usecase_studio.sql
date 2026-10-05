-- =============================================================================
-- 26_usecase_studio.sql — the kernel behind the c360-usecase orchestrator skill.
--
-- A domain expert describes a use case in CoCo CLI; specialist subagents build it
-- as DRAFT configuration; it is simulated and checked against hard bounds; and it
-- reaches production only through RELEASE_RUN, after recorded approvals, as a
-- versioned change with a one-call rollback.
--
-- Everything that must be true regardless of what a model does lives HERE, in
-- Snowflake, not in a prompt:
--   * drafts are isolated per run (STUDIO.DRAFT_*), production is untouched
--   * one engine (APP.PACK_ENGINE) serves both the simulation and production —
--     what you simulate is exactly what ships
--   * VALIDATE_RUN enforces the bounds (weights, catalog-only actions, cited
--     guardrails, guardrails can't be removed, legacy engines can't be edited)
--   * RELEASE_RUN refuses unless the CURRENT draft (by hash) was approved at
--     the simulation and release gates and the simulation had 0 violations
--   * every release snapshots what it replaced; ROLLBACK_RUN restores it
--
-- Purely additive: no existing table, view or routine is altered.
-- =============================================================================
USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

CREATE SCHEMA IF NOT EXISTS STUDIO COMMENT = 'Use-case studio: runs, approval ledger, isolated drafts';

-- ── production registries this layer adds ────────────────────────────────────
CREATE TABLE IF NOT EXISTS CONFIG.PACK_META (
    DECISION_DOMAIN_ID VARCHAR(50) PRIMARY KEY,
    VERSION            NUMBER        DEFAULT 1,
    PRIORITY_TIER      VARCHAR(20),          -- PROTECT | RETAIN | SERVICE | GROW
    OWNER              VARCHAR(100),
    OBJECTIVE          VARCHAR(500),
    SUCCESS_METRIC     VARCHAR(500),
    RELEASED_BY_RUN    VARCHAR(60),
    RELEASED_AT        TIMESTAMP_NTZ
);

-- Guardrails: a customer matching one is never offered anything by the pack.
-- Every row must carry a citation (enforced by VALIDATE_RUN).
CREATE TABLE IF NOT EXISTS CONFIG.GUARDRAIL (
    GUARDRAIL_ID       VARCHAR(80) PRIMARY KEY,
    DECISION_DOMAIN_ID VARCHAR(50) NOT NULL,
    MATCH_KEY          VARCHAR(100) NOT NULL,  -- signal name
    MATCH_VALUE        VARCHAR(100) NOT NULL,
    REASON             VARCHAR(300) NOT NULL,
    CITATION           VARCHAR(300),
    ACTIVE             BOOLEAN DEFAULT TRUE
);

-- Signals defined as configuration: SQL (structured/derived) or AI_LABEL
-- (AI_COMPLETE picks one label from a fixed list and quotes its evidence).
CREATE TABLE IF NOT EXISTS CONFIG.CUSTOM_SIGNAL (
    SIGNAL_NAME     VARCHAR(100) PRIMARY KEY,
    VERSION         NUMBER DEFAULT 1,
    METHOD          VARCHAR(20) NOT NULL,      -- SQL | AI_LABEL
    DEFINITION      VARCHAR(16000) NOT NULL,   -- SELECT text, or JSON {instruction, labels, source}
    CATEGORY        VARCHAR(30),               -- RISK | SERVICE | OPPORTUNITY
    DESCRIPTION     VARCHAR(500),
    OWNER           VARCHAR(100),
    ACTIVE          BOOLEAN DEFAULT TRUE,
    RELEASED_BY_RUN VARCHAR(60),
    RELEASED_AT     TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS APP.CUSTOM_SIGNAL_VALUE (
    CUSTOMER_ID   VARCHAR(50),
    DOMAIN        VARCHAR(20),
    SIGNAL_NAME   VARCHAR(100),
    SIGNAL_VALUE  VARCHAR(100),
    NUMERIC_VALUE FLOAT,
    CONFIDENCE    FLOAT,
    EVIDENCE_REF  VARCHAR(200),
    QUOTE         VARCHAR(2000),
    VERSION       NUMBER,
    COMPUTED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ── studio: runs, ledger, drafts ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS STUDIO.RUN (
    RUN_ID             VARCHAR(60) PRIMARY KEY,
    MODE               VARCHAR(20),     -- NEW | MODIFY
    DECISION_DOMAIN_ID VARCHAR(50),
    BRIEF              VARCHAR(2000),
    STATUS             VARCHAR(20) DEFAULT 'DRAFT',   -- DRAFT | RELEASED | ROLLED_BACK | ABANDONED
    CREATED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    RELEASED_AT        TIMESTAMP_NTZ
);
CREATE TABLE IF NOT EXISTS STUDIO.RUN_LEDGER (
    RUN_ID        VARCHAR(60),
    GATE          VARCHAR(10),
    DECISION      VARCHAR(20),      -- APPROVE | REJECT | EDIT | RELEASED | ROLLED_BACK
    APPROVER      VARCHAR(100),
    ARTIFACT_HASH VARCHAR(64),
    COMMENT       VARCHAR(2000),
    TS            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE TABLE IF NOT EXISTS STUDIO.DRAFT_DOMAIN (
    RUN_ID VARCHAR(60), DECISION_DOMAIN_ID VARCHAR(50), LABEL VARCHAR(150),
    ELIGIBILITY_MODE VARCHAR(20) DEFAULT 'SIGNAL_MATCHED', DESCRIPTION VARCHAR(500),
    PRIORITY_TIER VARCHAR(20), OWNER VARCHAR(100), OBJECTIVE VARCHAR(500), SUCCESS_METRIC VARCHAR(500)
);
CREATE TABLE IF NOT EXISTS STUDIO.DRAFT_CANDIDATE (
    RUN_ID VARCHAR(60), CANDIDATE_ID VARCHAR(50), DECISION_DOMAIN_ID VARCHAR(50),
    BUSINESS_DOMAIN_ID VARCHAR(50), CANDIDATE_NAME VARCHAR(150), CANDIDATE_TYPE VARCHAR(50),
    DESCRIPTION VARCHAR(500), MIN_AGE NUMBER, MAX_AGE NUMBER, SEGMENT_FIT VARCHAR(50),
    DEFAULT_COST FLOAT DEFAULT 0, REQUIRES_APPROVAL BOOLEAN DEFAULT FALSE,
    CATALOG_REF VARCHAR(50)          -- the PRODUCT_CATALOG / ACTION_DEFINITION id it offers
);
CREATE TABLE IF NOT EXISTS STUDIO.DRAFT_RULE (
    RUN_ID VARCHAR(60), RULE_ID VARCHAR(50), DECISION_DOMAIN_ID VARCHAR(50), CANDIDATE_ID VARCHAR(50),
    MATCH_TYPE VARCHAR(20) DEFAULT 'SIGNAL', MATCH_KEY VARCHAR(100), MATCH_VALUE VARCHAR(100), WEIGHT FLOAT
);
CREATE TABLE IF NOT EXISTS STUDIO.DRAFT_GUARDRAIL (
    RUN_ID VARCHAR(60), GUARDRAIL_ID VARCHAR(80), DECISION_DOMAIN_ID VARCHAR(50),
    MATCH_KEY VARCHAR(100), MATCH_VALUE VARCHAR(100), REASON VARCHAR(300), CITATION VARCHAR(300)
);
CREATE TABLE IF NOT EXISTS STUDIO.DRAFT_SIGNAL (
    RUN_ID VARCHAR(60), SIGNAL_NAME VARCHAR(100), METHOD VARCHAR(20), DEFINITION VARCHAR(16000),
    CATEGORY VARCHAR(30), DESCRIPTION VARCHAR(500)
);
CREATE TABLE IF NOT EXISTS STUDIO.DRAFT_SIGNAL_VALUE (
    RUN_ID VARCHAR(60), CUSTOMER_ID VARCHAR(50), DOMAIN VARCHAR(20), SIGNAL_NAME VARCHAR(100),
    SIGNAL_VALUE VARCHAR(100), NUMERIC_VALUE FLOAT, CONFIDENCE FLOAT, EVIDENCE_REF VARCHAR(200),
    QUOTE VARCHAR(2000)
);
CREATE TRANSIENT TABLE IF NOT EXISTS STUDIO.WORK_TEXT (RUN_ID VARCHAR(60), CUSTOMER_ID VARCHAR(50), TXT VARCHAR);
CREATE TRANSIENT TABLE IF NOT EXISTS STUDIO.WORK_SIM (
    RUN_ID VARCHAR(60), SIDE VARCHAR(10), CUSTOMER_ID VARCHAR, CANDIDATE_ID VARCHAR, CANDIDATE_NAME VARCHAR,
    CANDIDATE_TYPE VARCHAR, RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR, REQUIRES_APPROVAL BOOLEAN,
    SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR, STATE_NAME VARCHAR, SEVERITY NUMBER
);
CREATE TABLE IF NOT EXISTS STUDIO.SIMULATION (
    RUN_ID VARCHAR(60), ARTIFACT_HASH VARCHAR(64), VIOLATIONS NUMBER, FAILED_BOUNDS NUMBER,
    SUMMARY VARIANT, TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE TABLE IF NOT EXISTS STUDIO.RELEASE_LOG (
    RUN_ID VARCHAR(60), DECISION_DOMAIN_ID VARCHAR(50), VERSION NUMBER,
    BEFORE_SNAPSHOT VARIANT, CHANGE_SUMMARY VARIANT,
    RELEASED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), ROLLED_BACK_AT TIMESTAMP_NTZ
);

-- ── registry views: the platform's self-description, read by every agent ─────
-- Every signal, where it comes from, how many customers have it, who uses it.
CREATE OR REPLACE VIEW STUDIO.V_SIGNAL_CATALOG AS
WITH used AS (
    SELECT match_key AS signal_name, decision_domain_id AS used_by FROM CONFIG.DECISION_RULE
     WHERE active AND match_type = 'SIGNAL'
    UNION SELECT signal_name, 'personalization' FROM CONFIG.PRODUCT_RULE WHERE active
    UNION SELECT s.value::VARCHAR, 'churn_retention'
      FROM (SELECT ARRAY_CONSTRUCT('churn_intent','negative_sentiment','unresolved_claim','renewal_proximity',
                   'grievance_filed','portability_intent','renewal_lateness','coverage_downgrade',
                   'service_failure','claim_friction','ticket_reopen','csat_low') a), LATERAL FLATTEN(a) s
), used_agg AS (
    SELECT signal_name, ARRAY_AGG(DISTINCT used_by) WITHIN GROUP (ORDER BY used_by) AS used_by
    FROM used GROUP BY signal_name
), sig AS (
    SELECT signal_name, origin, signal_value, customer_id FROM APP.SIGNAL_SNAPSHOT
    UNION ALL
    SELECT v.signal_name, 'CUSTOM', v.signal_value, v.customer_id
    FROM APP.CUSTOM_SIGNAL_VALUE v JOIN CONFIG.CUSTOM_SIGNAL c ON c.signal_name = v.signal_name AND c.active
)
SELECT s.signal_name,
       MAX(s.origin) AS origin,
       COUNT(DISTINCT s.customer_id) AS customers,
       ARRAY_AGG(DISTINCT s.signal_value) WITHIN GROUP (ORDER BY s.signal_value) AS observed_values,
       ANY_VALUE(u.used_by) AS used_by
FROM sig s LEFT JOIN used_agg u ON u.signal_name = s.signal_name
GROUP BY s.signal_name;

-- Everything a pack may offer. Packs choose from here only (VALIDATE_RUN B5).
CREATE OR REPLACE VIEW STUDIO.V_ACTION_CATALOG AS
SELECT product_id AS catalog_ref, product_name AS name, product_type AS type, domain_id AS business_domain,
       segment_fit, min_age, max_age, 'PRODUCT' AS kind FROM CONFIG.PRODUCT_CATALOG WHERE active
UNION ALL
SELECT action_id, action_name, action_type, domain_id, NULL, NULL, NULL, 'ACTION'
FROM CONFIG.ACTION_DEFINITION;

CREATE OR REPLACE VIEW STUDIO.V_USECASE_REGISTRY AS
SELECT d.decision_domain_id, d.label, d.eligibility_mode, d.implementation, d.active,
       COALESCE(m.version, 1) AS version, m.priority_tier, m.owner, m.objective,
       (SELECT COUNT(*) FROM CONFIG.DECISION_CANDIDATE c WHERE c.decision_domain_id = d.decision_domain_id AND c.active) AS candidates,
       (SELECT COUNT(*) FROM CONFIG.DECISION_RULE r WHERE r.decision_domain_id = d.decision_domain_id AND r.active) AS rules,
       (SELECT COUNT(*) FROM CONFIG.GUARDRAIL g WHERE g.decision_domain_id = d.decision_domain_id AND g.active) AS guardrails
FROM CONFIG.DECISION_DOMAIN d
LEFT JOIN CONFIG.PACK_META m ON m.decision_domain_id = d.decision_domain_id;

-- Problem pattern -> the simplest Snowflake tool that fits (read by c360-scout).
CREATE TABLE IF NOT EXISTS STUDIO.CAPABILITY (
    PROBLEM_PATTERN VARCHAR(200), SNOWFLAKE_TOOL VARCHAR(200), PRECONDITION VARCHAR(300),
    IN_MINI_STUDIO BOOLEAN, FALLBACK VARCHAR(300)
);
DELETE FROM STUDIO.CAPABILITY;
INSERT INTO STUDIO.CAPABILITY
SELECT 'Who should get X (targeting by fit)', 'Rules over signals → APP.PACK_ENGINE',
       'Signals with coverage exist; candidates exist in the action catalog', TRUE, 'Catalog request for a missing action'
UNION ALL SELECT 'What customers said (calls, emails)', 'AI_COMPLETE with a fixed label list + evidence quote (AI_LABEL signal)',
       'Text linked to the customer', TRUE, NULL
UNION ALL SELECT 'A fact derivable from records', 'SQL signal (structured / derived)', 'Source columns mapped in CANONICAL/RAW', TRUE, NULL
UNION ALL SELECT 'Propensity from past outcomes', 'SNOWFLAKE.ML.CLASSIFICATION',
       '≥ 200 labelled outcomes for the pack', FALSE, 'Rules now; collect outcomes via RECORD_DECISION_OUTCOME'
UNION ALL SELECT 'How many over time (portfolio)', 'SNOWFLAKE.ML.FORECAST',
       '≥ 2 seasonal cycles; not already known (e.g. renewals due are computed, not forecast)', FALSE, 'Bottom-up sum of scores'
UNION ALL SELECT 'Something unusual is happening', 'SNOWFLAKE.ML.ANOMALY_DETECTION', 'Stable baseline history', FALSE, 'SQL bands'
UNION ALL SELECT 'Ad-hoc question about the book', 'Cortex Agent over the semantic view ($c360-customer-query)',
       'Semantic view covers the entities', TRUE, NULL;

-- ── signals the packs read: platform signals + released custom signals ───────
-- Reads the same signal snapshot the feed uses (APP.REFRESH_SIGNAL_SNAPSHOT keeps
-- it current), so a whole-book simulation runs in seconds instead of
-- re-deriving every signal per call.
CREATE OR REPLACE VIEW APP.V_PACK_SIGNALS AS
SELECT customer_id, domain, signal_name, signal_value FROM APP.SIGNAL_SNAPSHOT
UNION ALL
SELECT v.customer_id, v.domain, v.signal_name, v.signal_value
FROM APP.CUSTOM_SIGNAL_VALUE v
JOIN CONFIG.CUSTOM_SIGNAL c ON c.signal_name = v.signal_name AND c.active;

-- =============================================================================
-- APP.PACK_ENGINE(run_id, domain) — set-based form of APP.RECOMMEND_GENERIC.
-- run_id NULL  -> production config;  run_id given -> that run's draft config
-- (plus its draft signals). Same eligibility, same sum-of-matched-weights score,
-- same ranking and tie-break, same severity suppression; guardrails added on
-- top. Parity with RECOMMEND_GENERIC is checked in the verification below.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP.PACK_ENGINE(P_RUN_ID VARCHAR, P_DOMAIN_ID VARCHAR)
RETURNS TABLE (
    CUSTOMER_ID VARCHAR, CANDIDATE_ID VARCHAR, CANDIDATE_NAME VARCHAR, CANDIDATE_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR, REQUIRES_APPROVAL BOOLEAN,
    SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR, STATE_NAME VARCHAR, SEVERITY NUMBER
)
AS
$$
WITH dom AS (
    SELECT decision_domain_id, eligibility_mode FROM CUSTOMER_360_DB.CONFIG.DECISION_DOMAIN
     WHERE P_RUN_ID IS NULL AND decision_domain_id = P_DOMAIN_ID AND active
    UNION ALL
    SELECT decision_domain_id, eligibility_mode FROM CUSTOMER_360_DB.STUDIO.DRAFT_DOMAIN
     WHERE run_id = P_RUN_ID AND decision_domain_id = P_DOMAIN_ID
),
cand AS (
    SELECT candidate_id, business_domain_id, candidate_name, candidate_type, min_age, max_age,
           segment_fit, requires_approval
    FROM CUSTOMER_360_DB.CONFIG.DECISION_CANDIDATE
     WHERE P_RUN_ID IS NULL AND decision_domain_id = P_DOMAIN_ID AND active
    UNION ALL
    SELECT candidate_id, business_domain_id, candidate_name, candidate_type, min_age, max_age,
           segment_fit, requires_approval
    FROM CUSTOMER_360_DB.STUDIO.DRAFT_CANDIDATE
     WHERE run_id = P_RUN_ID AND decision_domain_id = P_DOMAIN_ID
),
rul AS (
    SELECT candidate_id, match_type, match_key, match_value, weight FROM CUSTOMER_360_DB.CONFIG.DECISION_RULE
     WHERE P_RUN_ID IS NULL AND decision_domain_id = P_DOMAIN_ID AND active
    UNION ALL
    SELECT candidate_id, match_type, match_key, match_value, weight FROM CUSTOMER_360_DB.STUDIO.DRAFT_RULE
     WHERE run_id = P_RUN_ID AND decision_domain_id = P_DOMAIN_ID
),
grd AS (
    SELECT match_key, match_value, reason FROM CUSTOMER_360_DB.CONFIG.GUARDRAIL
     WHERE P_RUN_ID IS NULL AND decision_domain_id = P_DOMAIN_ID AND active
    UNION ALL
    SELECT match_key, match_value, reason FROM CUSTOMER_360_DB.STUDIO.DRAFT_GUARDRAIL
     WHERE run_id = P_RUN_ID AND decision_domain_id = P_DOMAIN_ID
),
sig AS (
    SELECT customer_id, signal_name, signal_value FROM CUSTOMER_360_DB.APP.V_PACK_SIGNALS
     WHERE signal_name NOT IN (SELECT signal_name FROM CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL WHERE run_id = P_RUN_ID)
    UNION ALL
    SELECT customer_id, signal_name, signal_value FROM CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL_VALUE
     WHERE run_id = P_RUN_ID
),
cust AS (
    SELECT c.customer_id, c.domain, c.segment, DATEDIFF(year, c.date_of_birth, CURRENT_DATE()) AS age,
           cs.state_name, COALESCE(cs.severity, 0) AS severity
    FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER c
    LEFT JOIN CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
      ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
),
eligible AS (
    SELECT cu.customer_id, cu.severity, cu.state_name, ca.candidate_id, ca.candidate_name,
           ca.candidate_type, ca.requires_approval
    FROM cust cu JOIN cand ca
      ON (ca.business_domain_id IS NULL OR ca.business_domain_id = cu.domain)
     AND (ca.min_age IS NULL OR cu.age >= ca.min_age)
     AND (ca.max_age IS NULL OR cu.age <= ca.max_age)
     AND (ca.segment_fit IS NULL OR ca.segment_fit = cu.segment)
),
matched AS (
    SELECT e.customer_id, e.candidate_id, r.weight, (r.match_key || '=' || r.match_value) AS reason
    FROM eligible e
    JOIN dom d ON d.eligibility_mode = 'SIGNAL_MATCHED'
    JOIN rul r ON r.candidate_id = e.candidate_id AND r.match_type = 'SIGNAL'
    JOIN sig s ON s.customer_id = e.customer_id AND s.signal_name = r.match_key AND s.signal_value = r.match_value
    UNION ALL
    SELECT e.customer_id, e.candidate_id, r.weight, ('state=' || r.match_value)
    FROM eligible e
    JOIN dom d ON d.eligibility_mode = 'STATE_GATED'
    JOIN rul r ON r.candidate_id = e.candidate_id AND r.match_type = 'STATE' AND r.match_value = e.state_name
),
scored AS (
    SELECT customer_id, candidate_id, SUM(weight) AS score,
           LISTAGG(DISTINCT reason, ', ') WITHIN GROUP (ORDER BY reason) AS match_reasons
    FROM matched GROUP BY customer_id, candidate_id
),
guard AS (
    SELECT s.customer_id, MIN(g.reason) AS reason
    FROM sig s JOIN grd g ON g.match_key = s.signal_name AND g.match_value = s.signal_value
    GROUP BY s.customer_id
)
SELECT e.customer_id, e.candidate_id, e.candidate_name, e.candidate_type,
       ROW_NUMBER() OVER (PARTITION BY e.customer_id ORDER BY sc.score DESC, e.candidate_id) AS ranking,
       ROUND(sc.score, 4) AS score, sc.match_reasons, e.requires_approval,
       ((d.eligibility_mode = 'SIGNAL_MATCHED' AND e.severity >= 3) OR gu.customer_id IS NOT NULL) AS suppressed,
       CASE WHEN d.eligibility_mode = 'SIGNAL_MATCHED' AND e.severity >= 3
              THEN 'Customer is in ' || e.state_name || ' — lead with retention before any upsell'
            WHEN gu.customer_id IS NOT NULL THEN 'Guardrail: ' || gu.reason END AS suppression_reason,
       e.state_name, e.severity
FROM eligible e
JOIN scored sc ON sc.customer_id = e.customer_id AND sc.candidate_id = e.candidate_id
CROSS JOIN dom d
LEFT JOIN guard gu ON gu.customer_id = e.customer_id
$$;

-- Production serving for any released pack: one customer's ranked offers.
CREATE OR REPLACE FUNCTION APP.RECOMMEND_PACK(P_DOMAIN_ID VARCHAR, P_CUSTOMER_ID VARCHAR)
RETURNS TABLE (CANDIDATE_ID VARCHAR, CANDIDATE_NAME VARCHAR, RANKING NUMBER, SCORE FLOAT,
               MATCH_REASONS VARCHAR, SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR)
AS
$$
SELECT candidate_id, candidate_name, ranking, score, match_reasons, suppressed, suppression_reason
FROM TABLE(CUSTOMER_360_DB.APP.PACK_ENGINE(NULL::VARCHAR, P_DOMAIN_ID))
WHERE customer_id = P_CUSTOMER_ID
$$;

-- Hash of everything a run would release. Approvals are bound to it: change
-- the draft after approving and the approval no longer counts.
CREATE OR REPLACE FUNCTION STUDIO.DRAFT_HASH(P_RUN_ID VARCHAR)
RETURNS VARCHAR
AS
$$
SELECT MD5(
    COALESCE((SELECT LISTAGG(decision_domain_id||'|'||label||'|'||eligibility_mode||'|'||COALESCE(priority_tier,''), '~')
                     WITHIN GROUP (ORDER BY decision_domain_id) FROM CUSTOMER_360_DB.STUDIO.DRAFT_DOMAIN WHERE run_id = P_RUN_ID), '')
 || '#' || COALESCE((SELECT LISTAGG(candidate_id||'|'||candidate_name||'|'||COALESCE(catalog_ref,'')||'|'||COALESCE(min_age,-1)||'|'||COALESCE(max_age,-1)||'|'||COALESCE(segment_fit,''), '~')
                     WITHIN GROUP (ORDER BY candidate_id) FROM CUSTOMER_360_DB.STUDIO.DRAFT_CANDIDATE WHERE run_id = P_RUN_ID), '')
 || '#' || COALESCE((SELECT LISTAGG(rule_id||'|'||candidate_id||'|'||match_key||'|'||match_value||'|'||weight, '~')
                     WITHIN GROUP (ORDER BY rule_id) FROM CUSTOMER_360_DB.STUDIO.DRAFT_RULE WHERE run_id = P_RUN_ID), '')
 || '#' || COALESCE((SELECT LISTAGG(guardrail_id||'|'||match_key||'|'||match_value||'|'||COALESCE(citation,''), '~')
                     WITHIN GROUP (ORDER BY guardrail_id) FROM CUSTOMER_360_DB.STUDIO.DRAFT_GUARDRAIL WHERE run_id = P_RUN_ID), '')
 || '#' || COALESCE((SELECT LISTAGG(signal_name||'|'||method||'|'||MD5(definition), '~')
                     WITHIN GROUP (ORDER BY signal_name) FROM CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL WHERE run_id = P_RUN_ID), '')
 || '#' || COALESCE((SELECT MD5(LISTAGG(customer_id||'|'||signal_name||'|'||signal_value, '~')
                     WITHIN GROUP (ORDER BY customer_id, signal_name)) FROM CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = P_RUN_ID), '')
)
$$;

-- =============================================================================
-- STUDIO.START_RUN — open a run. MODIFY copies the live pack into the draft
-- so the expert edits a full copy and the simulator can compare before/after.
-- =============================================================================
CREATE OR REPLACE PROCEDURE STUDIO.START_RUN(P_RUN_ID VARCHAR, P_MODE VARCHAR, P_DOMAIN_ID VARCHAR, P_BRIEF VARCHAR)
RETURNS VARIANT
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_impl VARCHAR; v_exists NUMBER;
BEGIN
    SELECT COUNT(*), MAX(implementation) INTO :v_exists, :v_impl
      FROM CUSTOMER_360_DB.CONFIG.DECISION_DOMAIN WHERE decision_domain_id = :P_DOMAIN_ID;
    IF (UPPER(:P_MODE) = 'NEW' AND :v_exists > 0) THEN
        RETURN OBJECT_CONSTRUCT('status','REFUSED','reason','A use case with id ' || :P_DOMAIN_ID || ' already exists — use MODIFY.');
    END IF;
    IF (UPPER(:P_MODE) = 'MODIFY' AND :v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','REFUSED','reason','No live use case ' || :P_DOMAIN_ID || ' to modify.');
    END IF;
    IF (UPPER(:P_MODE) = 'MODIFY' AND :v_impl = 'LEGACY') THEN
        RETURN OBJECT_CONSTRUCT('status','REFUSED','reason', :P_DOMAIN_ID ||
            ' is a LEGACY engine with bespoke scoring; tune it through CONFIG.SCORING_CONFIG in the app (Analyst / Domain Expert), not through a pack release.');
    END IF;

    DELETE FROM CUSTOMER_360_DB.STUDIO.DRAFT_DOMAIN       WHERE run_id = :P_RUN_ID;
    DELETE FROM CUSTOMER_360_DB.STUDIO.DRAFT_CANDIDATE    WHERE run_id = :P_RUN_ID;
    DELETE FROM CUSTOMER_360_DB.STUDIO.DRAFT_RULE         WHERE run_id = :P_RUN_ID;
    DELETE FROM CUSTOMER_360_DB.STUDIO.DRAFT_GUARDRAIL    WHERE run_id = :P_RUN_ID;
    DELETE FROM CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL       WHERE run_id = :P_RUN_ID;
    DELETE FROM CUSTOMER_360_DB.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = :P_RUN_ID;
    DELETE FROM CUSTOMER_360_DB.STUDIO.RUN                WHERE run_id = :P_RUN_ID;
    INSERT INTO CUSTOMER_360_DB.STUDIO.RUN (run_id, mode, decision_domain_id, brief)
    SELECT :P_RUN_ID, UPPER(:P_MODE), :P_DOMAIN_ID, :P_BRIEF;

    IF (UPPER(:P_MODE) = 'MODIFY') THEN
        INSERT INTO CUSTOMER_360_DB.STUDIO.DRAFT_DOMAIN
        SELECT :P_RUN_ID, d.decision_domain_id, d.label, d.eligibility_mode, d.description,
               m.priority_tier, m.owner, m.objective, m.success_metric
        FROM CUSTOMER_360_DB.CONFIG.DECISION_DOMAIN d
        LEFT JOIN CUSTOMER_360_DB.CONFIG.PACK_META m ON m.decision_domain_id = d.decision_domain_id
        WHERE d.decision_domain_id = :P_DOMAIN_ID;
        INSERT INTO CUSTOMER_360_DB.STUDIO.DRAFT_CANDIDATE
        SELECT :P_RUN_ID, candidate_id, decision_domain_id, business_domain_id, candidate_name, candidate_type,
               description, min_age, max_age, segment_fit, default_cost, requires_approval,
               COALESCE(REGEXP_SUBSTR(description, '\\[catalog:([a-z0-9_]+)\\]', 1, 1, 'e'), candidate_id)
        FROM CUSTOMER_360_DB.CONFIG.DECISION_CANDIDATE WHERE decision_domain_id = :P_DOMAIN_ID AND active;
        INSERT INTO CUSTOMER_360_DB.STUDIO.DRAFT_RULE
        SELECT :P_RUN_ID, rule_id, decision_domain_id, candidate_id, match_type, match_key, match_value, weight
        FROM CUSTOMER_360_DB.CONFIG.DECISION_RULE WHERE decision_domain_id = :P_DOMAIN_ID AND active;
        INSERT INTO CUSTOMER_360_DB.STUDIO.DRAFT_GUARDRAIL
        SELECT :P_RUN_ID, guardrail_id, decision_domain_id, match_key, match_value, reason, citation
        FROM CUSTOMER_360_DB.CONFIG.GUARDRAIL WHERE decision_domain_id = :P_DOMAIN_ID AND active;
    END IF;

    INSERT INTO CUSTOMER_360_DB.STUDIO.RUN_LEDGER (run_id, gate, decision, approver, artifact_hash, comment)
    SELECT :P_RUN_ID, 'G0', 'OPENED', CURRENT_USER(), CUSTOMER_360_DB.STUDIO.DRAFT_HASH(:P_RUN_ID), :P_BRIEF;
    RETURN OBJECT_CONSTRUCT('status','OK','run_id',:P_RUN_ID,'mode',UPPER(:P_MODE),'domain',:P_DOMAIN_ID);
END;
$$;

-- Record a gate decision against the CURRENT draft hash.
CREATE OR REPLACE PROCEDURE STUDIO.APPROVE(P_RUN_ID VARCHAR, P_GATE VARCHAR, P_DECISION VARCHAR, P_APPROVER VARCHAR, P_COMMENT VARCHAR)
RETURNS VARIANT
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE v_hash VARCHAR;
BEGIN
    v_hash := (SELECT CUSTOMER_360_DB.STUDIO.DRAFT_HASH(:P_RUN_ID));
    INSERT INTO CUSTOMER_360_DB.STUDIO.RUN_LEDGER (run_id, gate, decision, approver, artifact_hash, comment)
    SELECT :P_RUN_ID, UPPER(:P_GATE), UPPER(:P_DECISION), :P_APPROVER, :v_hash, :P_COMMENT;
    RETURN OBJECT_CONSTRUCT('run_id',:P_RUN_ID,'gate',UPPER(:P_GATE),'decision',UPPER(:P_DECISION),'artifact_hash',:v_hash);
END;
$$;

-- =============================================================================
-- STUDIO.MATERIALIZE_SIGNAL — compute a draft signal for the whole book into the
-- run's sandbox. SQL: the definition must be a single SELECT returning
-- (customer_id, domain, signal_value, numeric_value, confidence, evidence_ref, quote).
-- AI_LABEL: definition JSON {"instruction": ..., "labels": [...], "source": "calls"|"emails"};
-- AI_COMPLETE picks exactly one label per customer from the fixed list and quotes
-- the sentence that justifies it — same pattern as every AI signal on the platform.
-- =============================================================================
CREATE OR REPLACE PROCEDURE STUDIO.MATERIALIZE_SIGNAL(P_RUN_ID VARCHAR, P_SIGNAL_NAME VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, re

DB = "CUSTOMER_360_DB"
FORBIDDEN = re.compile(r"\b(insert|update|delete|merge|create|alter|drop|truncate|grant|revoke|call|execute|put|copy)\b", re.I)


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def run(session, run_id, name):
    rows = session.sql(f"SELECT method, definition FROM {DB}.STUDIO.DRAFT_SIGNAL "
                       f"WHERE run_id = {q(run_id)} AND signal_name = {q(name)}").collect()
    if not rows:
        return {"status": "ERROR", "reason": f"No draft signal {name} in run {run_id}"}
    method, definition = rows[0]["METHOD"].upper(), rows[0]["DEFINITION"]
    session.sql(f"DELETE FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = {q(run_id)} AND signal_name = {q(name)}").collect()

    scanned = None
    if method == "SQL":
        body = definition.strip().rstrip(";")
        if ";" in body or FORBIDDEN.search(body) or not re.match(r"^\s*(select|with)\b", body, re.I):
            return {"status": "REFUSED", "reason": "A SQL signal must be one read-only SELECT."}
        session.sql(f"""
            INSERT INTO {DB}.STUDIO.DRAFT_SIGNAL_VALUE
            SELECT {q(run_id)}, customer_id, domain, {q(name)}, signal_value::VARCHAR, numeric_value::FLOAT,
                   confidence::FLOAT, evidence_ref::VARCHAR, quote::VARCHAR
            FROM ({body}) WHERE signal_value IS NOT NULL AND signal_value::VARCHAR <> 'NONE'
        """).collect()
    elif method == "AI_LABEL":
        spec = json.loads(definition)
        labels = spec["labels"]                      # {label: definition} or [label, ...]
        if isinstance(labels, list):
            labels = {l: "" for l in labels}
        labels = {k.lower(): v for k, v in labels.items() if k.lower() != "none"}
        instruction = spec["instruction"]
        src = spec.get("source", "calls")
        model = spec.get("model", "llama3.1-70b").replace("'", "")
        # only the customer's own words: an event the agent mentions is not evidence
        if src == "emails":
            blob = f"""SELECT customer_id, LISTAGG(body, '\\n---\\n') WITHIN GROUP (ORDER BY sent_at DESC) AS txt
                       FROM (SELECT * FROM {DB}.RAW.EMAIL_MESSAGE WHERE direction = 'INBOUND'
                             QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sent_at DESC) <= 3)
                       GROUP BY customer_id"""
            ref = "'emails:recent3'"
        else:
            blob = f"""SELECT t.customer_id,
                              LISTAGG(REGEXP_REPLACE(l.value, '^Customer: *', ''), '\\n')
                                  WITHIN GROUP (ORDER BY t.call_date DESC, l.index) AS txt
                       FROM (SELECT * FROM {DB}.RAW.INSURANCE_CALL_TRANSCRIPTS
                             QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY call_date DESC) <= 3) t,
                            LATERAL SPLIT_TO_TABLE(t.transcript_text, '\\n') l
                       WHERE l.value LIKE 'Customer:%'
                       GROUP BY t.customer_id"""
            ref = "'calls:recent3'"
        # enriched sampling: only texts that could contain the event go to the model
        pre = [w.lower().replace("'", "") for w in spec.get("prefilter", []) if w.strip()]
        if pre:
            blob = f"SELECT * FROM ({blob}) WHERE REGEXP_LIKE(LOWER(txt), '.*(" + "|".join(pre) + ").*', 's')"
        # stage the text first: AI calls over a flat table are batched in parallel
        session.sql(f"DELETE FROM {DB}.STUDIO.WORK_TEXT WHERE run_id = {q(run_id)}").collect()
        session.sql(f"INSERT INTO {DB}.STUDIO.WORK_TEXT SELECT {q(run_id)}, customer_id, txt FROM ({blob})").collect()
        blob = f"SELECT customer_id, txt FROM {DB}.STUDIO.WORK_TEXT WHERE run_id = {q(run_id)}"
        scanned = session.sql(f"SELECT COUNT(*) FROM ({blob})").collect()[0][0]
        defs = "\n".join(f"- {k}: {v}" if v else f"- {k}" for k, v in labels.items())
        prompt = (instruction + "\n\nLabels (pick exactly one):\n" + defs +
                  "\n- none: nothing above clearly applies\nIf in doubt, answer none. Quote the one or two consecutive "
                  "sentences from the text that prove the label, verbatim, without a speaker prefix. Give confidence "
                  "between 0 and 1.\n\nWHAT THE CUSTOMER SAID:\n")
        session.sql(f"""
            INSERT INTO {DB}.STUDIO.DRAFT_SIGNAL_VALUE
            SELECT {q(run_id)}, b.customer_id, 'insurance', {q(name)}, LOWER(TRIM(j:value::VARCHAR)),
                   1.0, j:confidence::FLOAT, {ref},
                   REGEXP_REPLACE(j:quote::VARCHAR, '^(Customer|Agent): *', '')
            FROM (
                SELECT customer_id, PARSE_JSON(AI_COMPLETE(
                    model => '{model}',
                    prompt => {q(prompt)} || txt,
                    response_format => {{'type':'json','schema':{{'type':'object','properties':{{
                        'value':{{'type':'string'}},'quote':{{'type':'string'}},'confidence':{{'type':'number'}}}},
                        'required':['value','quote','confidence']}}}})::VARCHAR) AS j
                FROM ({blob})
            ) b
            WHERE LOWER(TRIM(j:value::VARCHAR)) IN ({", ".join(q(l) for l in labels)})
        """).collect()
    else:
        return {"status": "ERROR", "reason": f"Unknown method {method}"}

    dist = session.sql(f"""SELECT signal_value, COUNT(*) n FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE
                           WHERE run_id = {q(run_id)} AND signal_name = {q(name)} GROUP BY 1 ORDER BY 2 DESC""").collect()
    total = session.sql(f"SELECT COUNT(*) n FROM {DB}.CANONICAL.CUSTOMER WHERE domain = 'insurance'").collect()[0]["N"]
    samples = session.sql(f"""SELECT customer_id, signal_value, quote, confidence FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE
                              WHERE run_id = {q(run_id)} AND signal_name = {q(name)}
                              QUALIFY ROW_NUMBER() OVER (PARTITION BY signal_value ORDER BY confidence DESC, customer_id) <= 2
                              ORDER BY signal_value""").collect()
    n = sum(r["N"] for r in dist)
    return {"status": "OK", "signal": name, "method": method, "customers": n,
            "scanned": scanned if method == "AI_LABEL" else None,
            "coverage_pct": round(100.0 * n / total, 1) if total else 0,
            "distribution": {r["SIGNAL_VALUE"]: r["N"] for r in dist},
            "samples": [{"customer_id": r["CUSTOMER_ID"], "value": r["SIGNAL_VALUE"],
                         "quote": r["QUOTE"], "confidence": r["CONFIDENCE"]} for r in samples]}
$$;

-- =============================================================================
-- STUDIO.EVALUATE_SIGNAL — precision of an AI_LABEL signal. A second, independent
-- AI pass checks every positive: does the quoted sentence, by itself, prove the
-- label as defined? Returns precision with a Wilson 95% interval per label and
-- the rejected examples, so the builder can tighten the definitions.
-- =============================================================================
CREATE TABLE IF NOT EXISTS STUDIO.SIGNAL_EVAL (
    RUN_ID VARCHAR(60), SIGNAL_NAME VARCHAR(100), CUSTOMER_ID VARCHAR(50), SIGNAL_VALUE VARCHAR(100),
    QUOTE VARCHAR(2000), VERIFIED BOOLEAN, JUDGE_REASON VARCHAR(500), TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE STUDIO.EVALUATE_SIGNAL(P_RUN_ID VARCHAR, P_SIGNAL_NAME VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, math
DB = "CUSTOMER_360_DB"


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (round(max(0.0, c - h), 3), round(min(1.0, c + h), 3))


def run(session, run_id, name):
    rid = q(run_id)
    spec = session.sql(f"SELECT method, definition FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid} AND signal_name = {q(name)}").collect()
    if not spec:
        return {"status": "ERROR", "reason": "no such draft signal"}
    if spec[0]["METHOD"].upper() != "AI_LABEL":
        return {"status": "SKIPPED", "reason": "precision applies to AI_LABEL signals; SQL signals are checked by coverage and distribution"}
    spec_json = json.loads(spec[0]["DEFINITION"])
    labels = spec_json["labels"]
    model = spec_json.get("model", "llama3.1-70b").replace("'", "")
    if isinstance(labels, list):
        labels = {l: l for l in labels}
    defs = "\n".join(f"- {k}: {v}" for k, v in labels.items() if k.lower() != "none")
    prompt = ("You are verifying a label assigned to an insurance customer. Definitions:\n" + defs +
              "\n\nAnswer verified=true only if the quoted words below, said by the customer, clearly prove "
              "the label exactly as defined. Otherwise verified=false. Give a short reason.\n\n")
    session.sql(f"DELETE FROM {DB}.STUDIO.SIGNAL_EVAL WHERE run_id = {rid} AND signal_name = {q(name)}").collect()
    session.sql(f"""
        INSERT INTO {DB}.STUDIO.SIGNAL_EVAL (run_id, signal_name, customer_id, signal_value, quote, verified, judge_reason)
        SELECT {rid}, {q(name)}, customer_id, signal_value, quote, j:verified::BOOLEAN, j:reason::VARCHAR
        FROM (
            SELECT v.customer_id, v.signal_value, v.quote, PARSE_JSON(AI_COMPLETE(
                model => '{model}',
                prompt => {q(prompt)} || 'LABEL: ' || v.signal_value || '\nQUOTE: ' || COALESCE(v.quote, ''),
                response_format => {{'type':'json','schema':{{'type':'object','properties':{{
                    'verified':{{'type':'boolean'}},'reason':{{'type':'string'}}}},'required':['verified','reason']}}}})::VARCHAR) AS j
            FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE v
            WHERE v.run_id = {rid} AND v.signal_name = {q(name)}
        )""").collect()
    by = session.sql(f"""SELECT signal_value, COUNT(*) n, COUNT_IF(verified) k FROM {DB}.STUDIO.SIGNAL_EVAL
                         WHERE run_id = {rid} AND signal_name = {q(name)} GROUP BY 1 ORDER BY 1""").collect()
    rejected = session.sql(f"""SELECT customer_id, signal_value, quote, judge_reason FROM {DB}.STUDIO.SIGNAL_EVAL
                               WHERE run_id = {rid} AND signal_name = {q(name)} AND NOT verified
                               ORDER BY signal_value, customer_id LIMIT 6""").collect()
    n = sum(r["N"] for r in by)
    k = sum(r["K"] for r in by)
    lo, hi = wilson(k, n)
    return {"signal": name, "checked": n, "verified": k, "precision": round(k / n, 3) if n else None,
            "ci95": [lo, hi], "passes_gate": lo >= 0.70,
            "by_label": {r["SIGNAL_VALUE"]: {"checked": r["N"], "verified": r["K"],
                                             "ci95": list(wilson(r["K"], r["N"]))} for r in by},
            "rejected_examples": [{"customer_id": r["CUSTOMER_ID"], "label": r["SIGNAL_VALUE"],
                                   "quote": r["QUOTE"], "why": r["JUDGE_REASON"]} for r in rejected]}
$$;

-- =============================================================================
-- STUDIO.VALIDATE_RUN — the bounds. A run cannot be released with any FAIL.
-- =============================================================================
CREATE OR REPLACE PROCEDURE STUDIO.VALIDATE_RUN(P_RUN_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
DB = "CUSTOMER_360_DB"
W_MIN, W_MAX = 0.05, 2.0


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def one(session, sql):
    r = session.sql(sql).collect()
    return r[0][0] if r else None


def run(session, run_id):
    rid = q(run_id)
    meta = session.sql(f"SELECT mode, decision_domain_id FROM {DB}.STUDIO.RUN WHERE run_id = {rid}").collect()
    if not meta:
        return {"status": "ERROR", "reason": "unknown run"}
    mode, dom = meta[0]["MODE"], meta[0]["DECISION_DOMAIN_ID"]
    checks = []

    def add(cid, title, ok, detail, level="FAIL"):
        checks.append({"id": cid, "check": title, "result": "PASS" if ok else level, "detail": detail})

    impl = one(session, f"SELECT implementation FROM {DB}.CONFIG.DECISION_DOMAIN WHERE decision_domain_id = {q(dom)}")
    add("B1", "Only generic packs are released as config (legacy engines are tuned in the app)",
        impl in (None, "GENERIC"), f"implementation={impl or 'new'}")

    n_dom = one(session, f"SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_DOMAIN WHERE run_id = {rid}")
    n_cand = one(session, f"SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_CANDIDATE WHERE run_id = {rid}")
    n_rule = one(session, f"SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_RULE WHERE run_id = {rid}")
    add("B0", "Pack is complete (domain, ≥1 candidate, ≥1 rule)", n_dom == 1 and n_cand > 0 and n_rule > 0,
        f"domain={n_dom}, candidates={n_cand}, rules={n_rule}")

    unknown = [r[0] for r in session.sql(f"""
        SELECT DISTINCT r.match_key FROM {DB}.STUDIO.DRAFT_RULE r
        WHERE r.run_id = {rid} AND r.match_type = 'SIGNAL'
          AND r.match_key NOT IN (SELECT signal_name FROM {DB}.CONFIG.SIGNAL_DEFINITION)
          AND r.match_key NOT IN (SELECT signal_name FROM {DB}.CONFIG.CUSTOM_SIGNAL WHERE active)
          AND r.match_key NOT IN (SELECT signal_name FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid})
          AND r.match_key NOT IN (SELECT DISTINCT signal_name FROM {DB}.APP.SIGNAL_SNAPSHOT)""").collect()]
    add("B2", "Every rule reads a registered signal", not unknown, f"unknown={unknown}")

    dead = [f"{r[0]}={r[1]}" for r in session.sql(f"""
        WITH vals AS (
            SELECT DISTINCT signal_name, signal_value FROM {DB}.APP.V_PACK_SIGNALS
             WHERE signal_name NOT IN (SELECT signal_name FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid})
            UNION
            SELECT DISTINCT signal_name, signal_value FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = {rid})
        SELECT r.match_key, r.match_value FROM {DB}.STUDIO.DRAFT_RULE r
        LEFT JOIN vals v ON v.signal_name = r.match_key AND v.signal_value = r.match_value
        WHERE r.run_id = {rid} AND r.match_type = 'SIGNAL' AND v.signal_name IS NULL
        """).collect()]
    add("B3", "Every rule value occurs in the data (no dead rules)", not dead, f"dead={dead}", level="WARN")

    bad_w = [f"{r[0]}:{r[1]}" for r in session.sql(f"""
        SELECT rule_id, weight FROM {DB}.STUDIO.DRAFT_RULE
        WHERE run_id = {rid} AND (weight < {W_MIN} OR weight > {W_MAX} OR weight IS NULL)""").collect()]
    add("B4", f"Rule weights within [{W_MIN}, {W_MAX}]", not bad_w, f"out_of_bounds={bad_w}")

    off_cat = [r[0] for r in session.sql(f"""
        SELECT c.candidate_id FROM {DB}.STUDIO.DRAFT_CANDIDATE c
        WHERE c.run_id = {rid} AND COALESCE(c.catalog_ref, '') NOT IN (SELECT catalog_ref FROM {DB}.STUDIO.V_ACTION_CATALOG)
          AND c.candidate_id NOT IN (SELECT candidate_id FROM {DB}.CONFIG.DECISION_CANDIDATE
                                     WHERE decision_domain_id = {q(dom)} AND active)""").collect()]
    add("B5", "Every offer exists in the action/product catalog", not off_cat,
        f"not_in_catalog={off_cat} — raise a catalog request instead")

    tier = one(session, f"SELECT priority_tier FROM {DB}.STUDIO.DRAFT_DOMAIN WHERE run_id = {rid}")
    n_g = one(session, f"SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_GUARDRAIL WHERE run_id = {rid}")
    add("B6", "Growth packs carry at least one guardrail", tier != "GROW" or n_g > 0, f"tier={tier}, guardrails={n_g}")

    uncited = [r[0] for r in session.sql(f"""
        SELECT guardrail_id FROM {DB}.STUDIO.DRAFT_GUARDRAIL
        WHERE run_id = {rid} AND (citation IS NULL OR LENGTH(TRIM(citation)) < 8)""").collect()]
    add("B7", "Every guardrail is cited", not uncited, f"uncited={uncited}")

    removed = [r[0] for r in session.sql(f"""
        SELECT g.guardrail_id FROM {DB}.CONFIG.GUARDRAIL g
        LEFT JOIN (SELECT match_key, match_value FROM {DB}.STUDIO.DRAFT_GUARDRAIL WHERE run_id = {rid}) d
          ON d.match_key = g.match_key AND d.match_value = g.match_value
        WHERE g.decision_domain_id = {q(dom)} AND g.active AND d.match_key IS NULL""").collect()]
    add("B8", "No live guardrail is removed", not removed, f"removed={removed}")

    empty_sig = [r[0] for r in session.sql(f"""
        SELECT s.signal_name FROM {DB}.STUDIO.DRAFT_SIGNAL s
        LEFT JOIN (SELECT DISTINCT signal_name FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = {rid}) v
          ON v.signal_name = s.signal_name
        WHERE s.run_id = {rid} AND v.signal_name IS NULL""").collect()]
    add("B9", "Every new signal is materialized with coverage > 0", not empty_sig, f"empty={empty_sig}")

    fails = sum(1 for c in checks if c["result"] == "FAIL")
    return {"run_id": run_id, "mode": mode, "domain": dom, "failed": fails,
            "warnings": sum(1 for c in checks if c["result"] == "WARN"), "checks": sorted(checks, key=lambda c: c["id"])}
$$;

-- =============================================================================
-- STUDIO.SIMULATE — run the draft through the production engine over the whole
-- book and report reach, mix, suppression, violations, determinism, and (for
-- MODIFY) before/after against the live version.
-- =============================================================================
CREATE OR REPLACE PROCEDURE STUDIO.SIMULATE(P_RUN_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
DB = "CUSTOMER_360_DB"


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def run(session, run_id):
    rid = q(run_id)
    meta = session.sql(f"SELECT mode, decision_domain_id FROM {DB}.STUDIO.RUN WHERE run_id = {rid}").collect()
    if not meta:
        return {"status": "ERROR", "reason": "unknown run"}
    mode, dom = meta[0]["MODE"], meta[0]["DECISION_DOMAIN_ID"]
    session.sql(f"DELETE FROM {DB}.STUDIO.WORK_SIM WHERE run_id = {rid}").collect()
    session.sql(f"""INSERT INTO {DB}.STUDIO.WORK_SIM SELECT {rid}, 'AFTER', *
                    FROM TABLE({DB}.APP.PACK_ENGINE({rid}, {q(dom)}))""").collect()
    session.sql(f"""INSERT INTO {DB}.STUDIO.WORK_SIM SELECT {rid}, 'BEFORE', *
                    FROM TABLE({DB}.APP.PACK_ENGINE(NULL::VARCHAR, {q(dom)}))""").collect()
    A = f"(SELECT * FROM {DB}.STUDIO.WORK_SIM WHERE run_id = {rid} AND side = 'AFTER')"
    B = f"(SELECT * FROM {DB}.STUDIO.WORK_SIM WHERE run_id = {rid} AND side = 'BEFORE')"

    def stats(t):
        r = session.sql(f"""SELECT COUNT(DISTINCT customer_id) matched,
                                   COUNT(DISTINCT IFF(NOT suppressed, customer_id, NULL)) reached,
                                   COUNT(DISTINCT IFF(suppressed, customer_id, NULL)) suppressed
                            FROM {t}""").collect()[0]
        mix = session.sql(f"""SELECT candidate_name, COUNT(*) n FROM {t}
                              WHERE ranking = 1 AND NOT suppressed GROUP BY 1 ORDER BY 2 DESC""").collect()
        sup = session.sql(f"""SELECT suppression_reason, COUNT(DISTINCT customer_id) n FROM {t}
                              WHERE suppressed GROUP BY 1 ORDER BY 2 DESC""").collect()
        return {"customers_matched": r["MATCHED"], "customers_reached": r["REACHED"],
                "customers_suppressed": r["SUPPRESSED"],
                "top_offer_mix": {m["CANDIDATE_NAME"]: m["N"] for m in mix},
                "suppressed_by": {s["SUPPRESSION_REASON"]: s["N"] for s in sup}}

    after = stats(A)
    before = stats(B) if mode == "MODIFY" else None

    # independent invariants — must all be zero
    v_guard = session.sql(f"""
        SELECT COUNT(DISTINCT a.customer_id) FROM {A} a
        JOIN {DB}.STUDIO.DRAFT_GUARDRAIL g ON g.run_id = {rid}
        JOIN (SELECT customer_id, signal_name, signal_value FROM {DB}.APP.V_PACK_SIGNALS
              UNION ALL SELECT customer_id, signal_name, signal_value FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = {rid}) s
          ON s.customer_id = a.customer_id AND s.signal_name = g.match_key AND s.signal_value = g.match_value
        WHERE NOT a.suppressed""").collect()[0][0]
    v_sev = session.sql(f"SELECT COUNT(DISTINCT customer_id) FROM {A} x WHERE NOT suppressed AND severity >= 3").collect()[0][0]
    v_rank = session.sql(f"""SELECT COUNT(*) FROM (SELECT customer_id FROM {A} x GROUP BY customer_id
                            HAVING COUNT(*) <> MAX(ranking) OR MIN(ranking) <> 1)""").collect()[0][0]
    h1 = session.sql(f"SELECT HASH_AGG(customer_id, candidate_id, ranking, score, suppressed) FROM {A} x").collect()[0][0]
    h2 = session.sql(f"""SELECT HASH_AGG(customer_id, candidate_id, ranking, score, suppressed)
                         FROM TABLE({DB}.APP.PACK_ENGINE({rid}, {q(dom)}))""").collect()[0][0]
    violations = {"offer_to_guardrailed_customer": v_guard, "offer_to_high_risk_customer": v_sev,
                  "ranking_gaps": v_rank, "non_deterministic": 0 if h1 == h2 else 1}

    # cross-pack conflicts: reached customers that another live pack also acts on
    conflicts = session.sql(f"""
        SELECT 'service_recovery' AS pack, COUNT(DISTINCT a.customer_id) n
        FROM {A} a JOIN TABLE({DB}.APP.PACK_ENGINE(NULL::VARCHAR, 'service_recovery')) s
          ON s.customer_id = a.customer_id AND NOT s.suppressed
        WHERE NOT a.suppressed AND {q(dom)} <> 'service_recovery'""").collect()

    examples = session.sql(f"""
        SELECT a.customer_id, c.full_name, a.candidate_name, a.score, a.match_reasons
        FROM {A} a JOIN {DB}.CANONICAL.CUSTOMER c ON c.customer_id = a.customer_id
        WHERE a.ranking = 1 AND NOT a.suppressed
        QUALIFY ROW_NUMBER() OVER (PARTITION BY a.candidate_name ORDER BY a.score DESC, a.customer_id) = 1
        ORDER BY a.score DESC LIMIT 4""").collect()

    diff = None
    if mode == "MODIFY":
        d = session.sql(f"""
            WITH b AS (SELECT customer_id, candidate_id FROM {B} x WHERE ranking = 1 AND NOT suppressed),
                 a AS (SELECT customer_id, candidate_id FROM {A} x WHERE ranking = 1 AND NOT suppressed)
            SELECT COUNT_IF(b.customer_id IS NULL) gained, COUNT_IF(a.customer_id IS NULL) lost,
                   COUNT_IF(a.customer_id IS NOT NULL AND b.customer_id IS NOT NULL AND a.candidate_id <> b.candidate_id) changed_offer,
                   COUNT_IF(a.candidate_id = b.candidate_id) unchanged
            FROM a FULL OUTER JOIN b ON a.customer_id = b.customer_id""").collect()[0]
        diff = {"customers_gained": d["GAINED"], "customers_lost": d["LOST"],
                "offer_changed": d["CHANGED_OFFER"], "unchanged": d["UNCHANGED"]}

    bounds = json.loads(session.sql(f"CALL {DB}.STUDIO.VALIDATE_RUN({rid})").collect()[0][0])
    n_viol = sum(int(v) for v in violations.values())
    h = session.sql(f"SELECT {DB}.STUDIO.DRAFT_HASH({rid})").collect()[0][0]
    summary = {"run_id": run_id, "mode": mode, "domain": dom, "artifact_hash": h,
               "after": after, "before": before, "diff": diff,
               "violations": violations, "violation_total": n_viol,
               "conflicts_with_live_packs": {c["PACK"]: c["N"] for c in conflicts},
               "examples": [{"customer_id": e["CUSTOMER_ID"], "name": e["FULL_NAME"], "offer": e["CANDIDATE_NAME"],
                             "score": e["SCORE"], "because": e["MATCH_REASONS"]} for e in examples],
               "bounds": bounds}
    session.sql(f"""INSERT INTO {DB}.STUDIO.SIMULATION (run_id, artifact_hash, violations, failed_bounds, summary)
                    SELECT {rid}, {q(h)}, {n_viol}, {bounds['failed']}, PARSE_JSON({q(json.dumps(summary))})""").collect()
    return summary
$$;

-- =============================================================================
-- STUDIO.RELEASE_RUN — the only path to production. Refuses unless:
--   * the latest simulation is for the CURRENT draft hash, with 0 violations
--     and 0 failed bounds, and
--   * gates G3 (simulation) and G4 (release) were approved for that same hash.
-- Snapshots what it replaces, then swaps the pack's rows in one transaction.
-- =============================================================================
CREATE OR REPLACE PROCEDURE STUDIO.RELEASE_RUN(P_RUN_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
DB = "CUSTOMER_360_DB"


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def rows(session, sql):
    return [r.as_dict() for r in session.sql(sql).collect()]


def run(session, run_id):
    rid = q(run_id)
    meta = session.sql(f"SELECT mode, decision_domain_id, status FROM {DB}.STUDIO.RUN WHERE run_id = {rid}").collect()
    if not meta:
        return {"status": "REFUSED", "reason": "unknown run"}
    mode, dom, status = meta[0]["MODE"], meta[0]["DECISION_DOMAIN_ID"], meta[0]["STATUS"]
    if status != "DRAFT":
        return {"status": "REFUSED", "reason": f"run is {status}"}
    h = session.sql(f"SELECT {DB}.STUDIO.DRAFT_HASH({rid})").collect()[0][0]

    sim = session.sql(f"""SELECT violations, failed_bounds, artifact_hash FROM {DB}.STUDIO.SIMULATION
                          WHERE run_id = {rid} ORDER BY ts DESC LIMIT 1""").collect()
    if not sim or sim[0]["ARTIFACT_HASH"] != h:
        return {"status": "REFUSED", "reason": "No simulation for the current draft — run STUDIO.SIMULATE first."}
    if sim[0]["VIOLATIONS"] or sim[0]["FAILED_BOUNDS"]:
        return {"status": "REFUSED", "reason": f"Simulation has {sim[0]['VIOLATIONS']} violations and "
                                               f"{sim[0]['FAILED_BOUNDS']} failed bounds."}
    for gate in ("G3", "G4"):
        ok = session.sql(f"""SELECT COUNT(*) FROM {DB}.STUDIO.RUN_LEDGER
                             WHERE run_id = {rid} AND gate = '{gate}' AND decision = 'APPROVE'
                               AND artifact_hash = {q(h)}""").collect()[0][0]
        if not ok:
            return {"status": "REFUSED", "reason": f"Gate {gate} has no approval for the current draft (hash {h[:8]})."}

    before = {
        "domain": rows(session, f"SELECT * FROM {DB}.CONFIG.DECISION_DOMAIN WHERE decision_domain_id = {q(dom)}"),
        "meta": rows(session, f"SELECT * FROM {DB}.CONFIG.PACK_META WHERE decision_domain_id = {q(dom)}"),
        "candidates": rows(session, f"SELECT * FROM {DB}.CONFIG.DECISION_CANDIDATE WHERE decision_domain_id = {q(dom)}"),
        "rules": rows(session, f"SELECT * FROM {DB}.CONFIG.DECISION_RULE WHERE decision_domain_id = {q(dom)}"),
        "guardrails": rows(session, f"SELECT * FROM {DB}.CONFIG.GUARDRAIL WHERE decision_domain_id = {q(dom)}"),
        "signals": rows(session, f"""SELECT * FROM {DB}.CONFIG.CUSTOM_SIGNAL WHERE signal_name IN
                                     (SELECT signal_name FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid})"""),
    }
    version = (session.sql(f"SELECT COALESCE(MAX(version), 0) FROM {DB}.CONFIG.PACK_META WHERE decision_domain_id = {q(dom)}")
               .collect()[0][0] or 0) + 1

    session.sql("BEGIN TRANSACTION").collect()
    try:
        # signals first, so the pack never references a signal that isn't live
        for s in rows(session, f"SELECT * FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid}"):
            name = s["SIGNAL_NAME"]
            session.sql(f"""MERGE INTO {DB}.CONFIG.CUSTOM_SIGNAL t
                USING (SELECT {q(name)} n) src ON t.signal_name = src.n
                WHEN MATCHED THEN UPDATE SET version = t.version + 1, method = {q(s['METHOD'])},
                     definition = {q(s['DEFINITION'])}, category = {q(s['CATEGORY'] or '')},
                     description = {q(s['DESCRIPTION'] or '')}, active = TRUE,
                     released_by_run = {rid}, released_at = CURRENT_TIMESTAMP()
                WHEN NOT MATCHED THEN INSERT (signal_name, version, method, definition, category, description,
                     owner, active, released_by_run, released_at)
                VALUES ({q(name)}, 1, {q(s['METHOD'])}, {q(s['DEFINITION'])}, {q(s['CATEGORY'] or '')},
                        {q(s['DESCRIPTION'] or '')}, CURRENT_USER(), TRUE, {rid}, CURRENT_TIMESTAMP())""").collect()
            session.sql(f"DELETE FROM {DB}.APP.CUSTOM_SIGNAL_VALUE WHERE signal_name = {q(name)}").collect()
            session.sql(f"""INSERT INTO {DB}.APP.CUSTOM_SIGNAL_VALUE (customer_id, domain, signal_name, signal_value,
                                numeric_value, confidence, evidence_ref, quote, version)
                            SELECT customer_id, domain, signal_name, signal_value, numeric_value, confidence,
                                   evidence_ref, quote, (SELECT version FROM {DB}.CONFIG.CUSTOM_SIGNAL WHERE signal_name = {q(name)})
                            FROM {DB}.STUDIO.DRAFT_SIGNAL_VALUE WHERE run_id = {rid} AND signal_name = {q(name)}""").collect()
            # register in the platform signal catalog so discovery and the agents see it
            session.sql(f"""MERGE INTO {DB}.CONFIG.SIGNAL_DEFINITION t
                USING (SELECT 'cs_' || {q(name)} AS sid) src ON t.signal_id = src.sid
                WHEN MATCHED THEN UPDATE SET active = TRUE, extraction_prompt = {q(s['DEFINITION'][:4000])}
                WHEN NOT MATCHED THEN INSERT (signal_id, domain_id, signal_name, signal_type, extraction_method,
                     extraction_prompt, source_table, weight, active, category, created_at)
                VALUES (src.sid, 'insurance', {q(name)}, 'custom', {q(s['METHOD'])},
                        {q(s['DEFINITION'][:4000])}, 'APP.CUSTOM_SIGNAL_VALUE', 0.15, TRUE,
                        {q(s['CATEGORY'] or '')}, CURRENT_TIMESTAMP())""").collect()

        d = rows(session, f"SELECT * FROM {DB}.STUDIO.DRAFT_DOMAIN WHERE run_id = {rid}")[0]
        session.sql(f"""MERGE INTO {DB}.CONFIG.DECISION_DOMAIN t
            USING (SELECT {q(dom)} id) src ON t.decision_domain_id = src.id
            WHEN MATCHED THEN UPDATE SET label = {q(d['LABEL'])}, description = {q(d['DESCRIPTION'] or '')}, active = TRUE
            WHEN NOT MATCHED THEN INSERT (decision_domain_id, label, entity_type, eligibility_mode, implementation, description)
            VALUES ({q(dom)}, {q(d['LABEL'])}, 'CUSTOMER', {q(d['ELIGIBILITY_MODE'])}, 'GENERIC', {q(d['DESCRIPTION'] or '')})""").collect()
        session.sql(f"""MERGE INTO {DB}.CONFIG.PACK_META t
            USING (SELECT {q(dom)} id) src ON t.decision_domain_id = src.id
            WHEN MATCHED THEN UPDATE SET version = {version}, priority_tier = {q(d['PRIORITY_TIER'] or '')},
                 owner = {q(d['OWNER'] or '')}, objective = {q(d['OBJECTIVE'] or '')},
                 success_metric = {q(d['SUCCESS_METRIC'] or '')}, released_by_run = {rid}, released_at = CURRENT_TIMESTAMP()
            WHEN NOT MATCHED THEN INSERT (decision_domain_id, version, priority_tier, owner, objective, success_metric,
                 released_by_run, released_at)
            VALUES ({q(dom)}, {version}, {q(d['PRIORITY_TIER'] or '')}, {q(d['OWNER'] or '')}, {q(d['OBJECTIVE'] or '')},
                    {q(d['SUCCESS_METRIC'] or '')}, {rid}, CURRENT_TIMESTAMP())""").collect()

        for t in ("DECISION_RULE", "DECISION_CANDIDATE", "GUARDRAIL"):
            session.sql(f"DELETE FROM {DB}.CONFIG.{t} WHERE decision_domain_id = {q(dom)}").collect()
        session.sql(f"""INSERT INTO {DB}.CONFIG.DECISION_CANDIDATE (candidate_id, decision_domain_id, business_domain_id,
                            candidate_name, candidate_type, description, min_age, max_age, segment_fit, default_cost,
                            requires_approval, approval_threshold, active)
                        SELECT candidate_id, decision_domain_id, business_domain_id, candidate_name, candidate_type,
                               COALESCE(description, '') || ' [catalog:' || COALESCE(catalog_ref, candidate_id) || ']',
                               min_age, max_age, segment_fit, default_cost, requires_approval, 0, TRUE
                        FROM {DB}.STUDIO.DRAFT_CANDIDATE WHERE run_id = {rid}""").collect()
        session.sql(f"""INSERT INTO {DB}.CONFIG.DECISION_RULE (rule_id, decision_domain_id, candidate_id, match_type,
                            match_key, match_value, weight, active)
                        SELECT rule_id, decision_domain_id, candidate_id, match_type, match_key, match_value, weight, TRUE
                        FROM {DB}.STUDIO.DRAFT_RULE WHERE run_id = {rid}""").collect()
        session.sql(f"""INSERT INTO {DB}.CONFIG.GUARDRAIL (guardrail_id, decision_domain_id, match_key, match_value,
                            reason, citation, active)
                        SELECT guardrail_id, decision_domain_id, match_key, match_value, reason, citation, TRUE
                        FROM {DB}.STUDIO.DRAFT_GUARDRAIL WHERE run_id = {rid}""").collect()

        counts = session.sql(f"""SELECT
            (SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_CANDIDATE WHERE run_id = {rid}) c,
            (SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_RULE WHERE run_id = {rid}) r,
            (SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_GUARDRAIL WHERE run_id = {rid}) g,
            (SELECT COUNT(*) FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid}) s""").collect()[0]
        change = {"version": version, "candidates": counts["C"], "rules": counts["R"],
                  "guardrails": counts["G"], "signals": counts["S"],
                  "config_rows": 1 + counts["C"] + counts["R"] + counts["G"] + counts["S"]}
        session.sql(f"""INSERT INTO {DB}.STUDIO.RELEASE_LOG (run_id, decision_domain_id, version, before_snapshot, change_summary)
                        SELECT {rid}, {q(dom)}, {version}, PARSE_JSON({q(json.dumps(before, default=str))}),
                               PARSE_JSON({q(json.dumps(change))})""").collect()
        session.sql(f"UPDATE {DB}.STUDIO.RUN SET status = 'RELEASED', released_at = CURRENT_TIMESTAMP() WHERE run_id = {rid}").collect()
        session.sql(f"""INSERT INTO {DB}.STUDIO.RUN_LEDGER (run_id, gate, decision, approver, artifact_hash, comment)
                        SELECT {rid}, 'G4', 'RELEASED', CURRENT_USER(), {q(h)}, {q(json.dumps(change))}""").collect()
        session.sql("COMMIT").collect()
    except Exception as e:
        session.sql("ROLLBACK").collect()
        return {"status": "ERROR", "reason": str(e)[:500]}
    return {"status": "RELEASED", "run_id": run_id, "domain": dom, **change,
            "serve_with": f"SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_PACK('{dom}', '<customer_id>'))",
            "rollback_with": f"CALL CUSTOMER_360_DB.STUDIO.ROLLBACK_RUN('{run_id}')"}
$$;

-- =============================================================================
-- STUDIO.ROLLBACK_RUN — restore exactly what a release replaced.
-- =============================================================================
CREATE OR REPLACE PROCEDURE STUDIO.ROLLBACK_RUN(P_RUN_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
DB = "CUSTOMER_360_DB"


def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def restore(session, table, recs):
    for r in recs:
        cols = [k for k in r.keys()]
        session.sql(f"INSERT INTO {DB}.CONFIG.{table} ({', '.join(cols)}) "
                    f"SELECT {', '.join(q(r[c]) for c in cols)}").collect()


def run(session, run_id):
    rid = q(run_id)
    rel = session.sql(f"""SELECT decision_domain_id, before_snapshot FROM {DB}.STUDIO.RELEASE_LOG
                          WHERE run_id = {rid} AND rolled_back_at IS NULL ORDER BY released_at DESC LIMIT 1""").collect()
    if not rel:
        return {"status": "REFUSED", "reason": "No un-rolled-back release for this run."}
    newer = session.sql(f"""SELECT COUNT(*) FROM {DB}.STUDIO.RELEASE_LOG l
                            WHERE l.decision_domain_id = {q(rel[0]['DECISION_DOMAIN_ID'])} AND l.rolled_back_at IS NULL
                              AND l.released_at > (SELECT MAX(released_at) FROM {DB}.STUDIO.RELEASE_LOG WHERE run_id = {rid})""").collect()[0][0]
    if newer:
        return {"status": "REFUSED", "reason": "A newer release of this pack exists — roll that back first."}
    dom = rel[0]["DECISION_DOMAIN_ID"]
    before = json.loads(rel[0]["BEFORE_SNAPSHOT"])
    session.sql("BEGIN TRANSACTION").collect()
    try:
        for t in ("DECISION_RULE", "DECISION_CANDIDATE", "GUARDRAIL", "PACK_META", "DECISION_DOMAIN"):
            session.sql(f"DELETE FROM {DB}.CONFIG.{t} WHERE decision_domain_id = {q(dom)}").collect()
        restore(session, "DECISION_DOMAIN", before["domain"])
        restore(session, "PACK_META", before["meta"])
        restore(session, "DECISION_CANDIDATE", before["candidates"])
        restore(session, "DECISION_RULE", before["rules"])
        restore(session, "GUARDRAIL", before["guardrails"])
        drafted = [r[0] for r in session.sql(f"SELECT signal_name FROM {DB}.STUDIO.DRAFT_SIGNAL WHERE run_id = {rid}").collect()]
        prior = {s["SIGNAL_NAME"] for s in before["signals"]}
        for name in drafted:
            if name not in prior:   # signal was new in this release: retire it
                session.sql(f"UPDATE {DB}.CONFIG.CUSTOM_SIGNAL SET active = FALSE WHERE signal_name = {q(name)}").collect()
                session.sql(f"DELETE FROM {DB}.APP.CUSTOM_SIGNAL_VALUE WHERE signal_name = {q(name)}").collect()
                session.sql(f"UPDATE {DB}.CONFIG.SIGNAL_DEFINITION SET active = FALSE WHERE signal_id = 'cs_' || {q(name)}").collect()
        session.sql(f"UPDATE {DB}.STUDIO.RELEASE_LOG SET rolled_back_at = CURRENT_TIMESTAMP() WHERE run_id = {rid}").collect()
        session.sql(f"UPDATE {DB}.STUDIO.RUN SET status = 'ROLLED_BACK' WHERE run_id = {rid}").collect()
        session.sql(f"""INSERT INTO {DB}.STUDIO.RUN_LEDGER (run_id, gate, decision, approver, comment)
                        SELECT {rid}, 'G4', 'ROLLED_BACK', CURRENT_USER(), 'restored pre-release snapshot'""").collect()
        session.sql("COMMIT").collect()
    except Exception as e:
        session.sql("ROLLBACK").collect()
        return {"status": "ERROR", "reason": str(e)[:500]}
    return {"status": "ROLLED_BACK", "run_id": run_id, "domain": dom}
$$;

-- ── access for the judge role ────────────────────────────────────────────────
GRANT USAGE ON SCHEMA STUDIO TO ROLE C360_JUDGE;
GRANT SELECT ON ALL VIEWS IN SCHEMA STUDIO TO ROLE C360_JUDGE;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA STUDIO TO ROLE C360_JUDGE;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA STUDIO TO ROLE C360_JUDGE;
GRANT USAGE ON ALL FUNCTIONS IN SCHEMA STUDIO TO ROLE C360_JUDGE;
GRANT USAGE ON FUNCTION APP.PACK_ENGINE(VARCHAR, VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON FUNCTION APP.RECOMMEND_PACK(VARCHAR, VARCHAR) TO ROLE C360_JUDGE;
GRANT SELECT ON VIEW APP.V_PACK_SIGNALS TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE APP.CUSTOM_SIGNAL_VALUE TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE CONFIG.CUSTOM_SIGNAL TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE CONFIG.GUARDRAIL TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE CONFIG.PACK_META TO ROLE C360_JUDGE;

SELECT 'Use-case studio kernel deployed (additive only)' AS status;
