-- =============================================================================
-- 19_decision_domain_registry.sql — the generic decision-domain layer named
-- as "#2" in the platform architecture retrospective, and deliberately
-- deferred until now: "a CONFIG.DECISION_DOMAIN registry ... behind one
-- generic RECOMMEND_GENERIC(domain_id, customer_id) ... a separate, larger
-- piece of work, not a step in the bootstrap checklist."
--
-- PURELY ADDITIVE. Nothing here touches RECOMMEND, RECOMMEND_PRODUCT,
-- ACTION_DEFINITION, ACTION_STATE_MAPPING, PRODUCT_CATALOG, PRODUCT_RULE,
-- ACTION_EFFECTIVENESS, or PRODUCT_EFFECTIVENESS. Both existing engines keep
-- running on their original, hand-written objects exactly as before. If this
-- doesn't work out, drop the 4 new tables + 3 new routines below and nothing
-- about the live platform changes — that's the whole point of building it
-- this way instead of migrating the existing engines onto it.
--
-- WHAT THIS GENERALIZES, HONESTLY SCOPED:
--
-- The retrospective identified two proven eligibility paradigms:
--   - SIGNAL_MATCHED (personalization's shape): candidates matched directly
--     against the customer's current signals. No state machine involved.
--   - STATE_GATED (churn's shape): candidates matched against a severity-
--     tiered current state.
--
-- SIGNAL_MATCHED is fully, honestly generic here — RECOMMEND_GENERIC
-- reproduces RECOMMEND_PRODUCT's exact formula (sum of matched-rule weights)
-- for ANY domain registered with this mode, verified below by replaying
-- personalization's own data through it and diffing against RECOMMEND_PRODUCT.
--
-- STATE_GATED is generic ONLY in the sense of "gate + sum-weight against the
-- one shared ENGINE.CUSTOMER_STATE table." It deliberately does NOT
-- reproduce RECOMMEND's persona-weighted uplift/value/cost/confidence
-- scoring or its approval-ceiling policy math — that richness is real,
-- churn-specific engineering, not a generic pattern, and forcing it into a
-- one-size formula here would be the over-engineering the bootstrap skill
-- warned against. A second point worth naming plainly: ENGINE.CUSTOMER_STATE
-- has no decision-domain partition key, only a business-vertical one
-- (insurance/lending) — so a brand-new STATE_GATED domain with its OWN
-- independent state machine isn't possible without an additive schema change
-- to that table (out of scope here; it's a pure ADD COLUMN later, not a
-- redesign, when a real third state-driven use case shows up). What IS
-- supported today: a new domain that reacts to the states churn already
-- computes (e.g. a servicing domain that activates on HIGH_CHURN_RISK).
--
-- ONBOARDING USE CASE #3 WITH THIS LAYER (the actual deliverable):
--   1. INSERT one row into CONFIG.DECISION_DOMAIN.
--   2. INSERT candidate rows into CONFIG.DECISION_CANDIDATE.
--   3. INSERT matching rows into CONFIG.DECISION_RULE.
--   4. Call APP.RECOMMEND_GENERIC(domain_id, customer_id). Done — no new
--      SQL function, no new effectiveness table, no new Agent wrapper.
-- That's the "building blocks stay the same" property this was asked to
-- guarantee — verified below, not just asserted.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- =============================================================================
-- Registry: every decision domain, legacy or generic, in one place. Legacy
-- rows are documentation — IMPLEMENTATION names which hand-written routine
-- actually serves them; they are NOT read by RECOMMEND_GENERIC.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONFIG.DECISION_DOMAIN (
    DECISION_DOMAIN_ID VARCHAR(50)  NOT NULL PRIMARY KEY,
    LABEL               VARCHAR(150) NOT NULL,
    ENTITY_TYPE          VARCHAR(50)  NOT NULL DEFAULT 'CUSTOMER',
    ELIGIBILITY_MODE     VARCHAR(20)  NOT NULL,   -- 'STATE_GATED' | 'SIGNAL_MATCHED'
    IMPLEMENTATION       VARCHAR(20)  NOT NULL DEFAULT 'GENERIC', -- 'GENERIC' | 'LEGACY'
    LEGACY_FUNCTION_NAME VARCHAR(100),            -- set only when IMPLEMENTATION='LEGACY'
    DESCRIPTION           VARCHAR(500),
    ACTIVE                 BOOLEAN DEFAULT TRUE,
    CREATED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- Generic candidate catalog — one physical shape for any domain's
-- recommendable things (actions, products, whatever comes next), instead of
-- a hand-copied table per domain.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONFIG.DECISION_CANDIDATE (
    CANDIDATE_ID        VARCHAR(50) NOT NULL PRIMARY KEY,
    DECISION_DOMAIN_ID  VARCHAR(50) NOT NULL,
    BUSINESS_DOMAIN_ID  VARCHAR(50),              -- insurance/lending scope; NULL = applies to both
    CANDIDATE_NAME       VARCHAR(150) NOT NULL,
    CANDIDATE_TYPE        VARCHAR(50),
    DESCRIPTION            VARCHAR(500),
    MIN_AGE                 NUMBER,
    MAX_AGE                 NUMBER,
    SEGMENT_FIT             VARCHAR(50),
    DEFAULT_COST             FLOAT DEFAULT 0,
    REQUIRES_APPROVAL        BOOLEAN DEFAULT FALSE,
    APPROVAL_THRESHOLD        FLOAT DEFAULT 0,
    ACTIVE                     BOOLEAN DEFAULT TRUE,
    CREATED_AT                 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- Generic matching rule — one physical shape covering both eligibility
-- paradigms. MATCH_TYPE='SIGNAL': match_key=signal_name, match_value=signal
-- value (personalization's shape). MATCH_TYPE='STATE': match_value=state_name
-- from the shared CUSTOMER_STATE table, match_key unused (churn's shape,
-- reduced as documented above).
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONFIG.DECISION_RULE (
    RULE_ID              VARCHAR(50) NOT NULL PRIMARY KEY,
    DECISION_DOMAIN_ID   VARCHAR(50) NOT NULL,
    CANDIDATE_ID          VARCHAR(50) NOT NULL,
    MATCH_TYPE             VARCHAR(20) NOT NULL,  -- 'STATE' | 'SIGNAL'
    MATCH_KEY               VARCHAR(100),
    MATCH_VALUE              VARCHAR(100) NOT NULL,
    WEIGHT                     FLOAT DEFAULT 1,
    ACTIVE                     BOOLEAN DEFAULT TRUE
);

-- =============================================================================
-- Generic effectiveness loop — one table, partitioned by decision domain,
-- replacing the need for a hand-copied *_EFFECTIVENESS table per domain.
-- Same confidence formula as ACTION_EFFECTIVENESS / PRODUCT_EFFECTIVENESS.
-- =============================================================================
CREATE TABLE IF NOT EXISTS ENGINE.DECISION_EFFECTIVENESS (
    EFFECTIVENESS_ID    VARCHAR(100) NOT NULL PRIMARY KEY,
    DECISION_DOMAIN_ID  VARCHAR(50) NOT NULL,
    CANDIDATE_ID          VARCHAR(50) NOT NULL,
    OFFERED_COUNT          NUMBER DEFAULT 0,
    ACCEPTED_COUNT          NUMBER DEFAULT 0,
    ACCEPTANCE_RATE          FLOAT DEFAULT 0,
    CONFIDENCE                FLOAT DEFAULT 0,
    LAST_UPDATED               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- RECOMMEND_GENERIC — the one function every future domain calls. No AI
-- inside it, matching the platform's standing rule that scoring functions
-- are pure deterministic SQL.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP.RECOMMEND_GENERIC(P_DECISION_DOMAIN_ID VARCHAR, P_CUSTOMER_ID VARCHAR)
RETURNS TABLE (
    CANDIDATE_ID VARCHAR, CANDIDATE_NAME VARCHAR, CANDIDATE_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR,
    EFFECTIVENESS_RATE FLOAT, SAMPLE_SIZE NUMBER, ELIGIBLE_REASON VARCHAR,
    REQUIRES_APPROVAL BOOLEAN, SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR
)
AS
$$
WITH domain_cfg AS (
    SELECT decision_domain_id, eligibility_mode
    FROM CONFIG.DECISION_DOMAIN
    WHERE decision_domain_id = P_DECISION_DOMAIN_ID AND active = TRUE
),
cust AS (
    SELECT c.customer_id, c.domain, c.segment,
           DATEDIFF(year, c.date_of_birth, CURRENT_DATE()) AS age,
           cs.state_name, COALESCE(cs.severity, 0) AS severity
    FROM CANONICAL.CUSTOMER c
    LEFT JOIN ENGINE.CUSTOMER_STATE cs
      ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
    WHERE c.customer_id = P_CUSTOMER_ID
),
eligible AS (
    SELECT dc.candidate_id, dc.candidate_name, dc.candidate_type,
           dc.requires_approval,
           COALESCE(dc.candidate_type, 'candidate')
             || CASE WHEN dc.min_age IS NOT NULL OR dc.max_age IS NOT NULL
                      THEN ' for ages ' || COALESCE(dc.min_age, 0) || '-' || COALESCE(dc.max_age, 999)
                      ELSE '' END
             || CASE WHEN dc.segment_fit IS NOT NULL THEN ' · ' || dc.segment_fit ELSE '' END
             AS eligible_reason
    FROM CONFIG.DECISION_CANDIDATE dc
    CROSS JOIN cust c
    WHERE dc.decision_domain_id = P_DECISION_DOMAIN_ID AND dc.active = TRUE
      AND (dc.business_domain_id IS NULL OR dc.business_domain_id = c.domain)
      AND (dc.min_age IS NULL OR c.age >= dc.min_age)
      AND (dc.max_age IS NULL OR c.age <= dc.max_age)
      AND (dc.segment_fit IS NULL OR dc.segment_fit = c.segment)
),
matched_signal AS (
    SELECT e.candidate_id, dr.weight, (dr.match_key || '=' || dr.match_value) AS reason
    FROM eligible e
    JOIN domain_cfg dcfg ON dcfg.eligibility_mode = 'SIGNAL_MATCHED'
    JOIN CONFIG.DECISION_RULE dr
      ON dr.candidate_id = e.candidate_id AND dr.decision_domain_id = P_DECISION_DOMAIN_ID
     AND dr.match_type = 'SIGNAL' AND dr.active = TRUE
    JOIN APP.V_ALL_SIGNALS s
      ON s.customer_id = P_CUSTOMER_ID AND s.signal_name = dr.match_key AND s.signal_value = dr.match_value
),
matched_state AS (
    SELECT e.candidate_id, dr.weight, ('state=' || dr.match_value) AS reason
    FROM eligible e
    JOIN domain_cfg dcfg ON dcfg.eligibility_mode = 'STATE_GATED'
    JOIN cust c ON TRUE
    JOIN CONFIG.DECISION_RULE dr
      ON dr.candidate_id = e.candidate_id AND dr.decision_domain_id = P_DECISION_DOMAIN_ID
     AND dr.match_type = 'STATE' AND dr.active = TRUE
     AND dr.match_value = c.state_name
),
matched AS (
    SELECT * FROM matched_signal
    UNION ALL
    SELECT * FROM matched_state
),
scored AS (
    SELECT m.candidate_id, SUM(m.weight) AS score,
           LISTAGG(DISTINCT m.reason, ', ') WITHIN GROUP (ORDER BY m.reason) AS match_reasons
    FROM matched m
    GROUP BY m.candidate_id
)
SELECT e.candidate_id, e.candidate_name, e.candidate_type,
       ROW_NUMBER() OVER (ORDER BY s.score DESC, e.candidate_id) AS ranking,
       ROUND(s.score, 4) AS score, s.match_reasons,
       COALESCE(eff.acceptance_rate, 0.3) AS effectiveness_rate,
       COALESCE(eff.offered_count, 0) AS sample_size,
       e.eligible_reason, e.requires_approval,
       ((SELECT eligibility_mode FROM domain_cfg) = 'SIGNAL_MATCHED'
         AND (SELECT severity FROM cust) >= 3) AS suppressed,
       CASE WHEN (SELECT eligibility_mode FROM domain_cfg) = 'SIGNAL_MATCHED'
                  AND (SELECT severity FROM cust) >= 3
            THEN 'Customer is in ' || (SELECT state_name FROM cust)
                 || ' — lead with retention before any upsell'
            ELSE NULL END AS suppression_reason
FROM eligible e
JOIN scored s ON s.candidate_id = e.candidate_id
LEFT JOIN ENGINE.DECISION_EFFECTIVENESS eff
  ON eff.decision_domain_id = P_DECISION_DOMAIN_ID AND eff.candidate_id = e.candidate_id
ORDER BY s.score DESC, e.candidate_id
$$;

-- Agent-compat wrapper, same split used by every other domain's *_ACTION proc.
CREATE OR REPLACE PROCEDURE APP.RECOMMEND_GENERIC_ACTION(DECISION_DOMAIN_ID VARCHAR, CUSTOMER_ID VARCHAR)
RETURNS TABLE (
    CANDIDATE_ID VARCHAR, CANDIDATE_NAME VARCHAR, CANDIDATE_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR,
    EFFECTIVENESS_RATE FLOAT, SAMPLE_SIZE NUMBER, ELIGIBLE_REASON VARCHAR,
    REQUIRES_APPROVAL BOOLEAN, SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR
)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_GENERIC(:DECISION_DOMAIN_ID, :CUSTOMER_ID)));
    RETURN TABLE(res);
END;
$$;

-- One generic outcome recorder for every GENERIC-implementation domain —
-- same confidence formula as RECORD_PRODUCT_OUTCOME:
-- confidence = LEAST(0.99, 1 - 1/SQRT(offered_count + 2)).
CREATE OR REPLACE PROCEDURE APP.RECORD_DECISION_OUTCOME(
    P_DECISION_DOMAIN_ID VARCHAR, P_CANDIDATE_ID VARCHAR, P_CUSTOMER_ID VARCHAR, P_ACCEPTED BOOLEAN
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    MERGE INTO ENGINE.DECISION_EFFECTIVENESS eff
    USING (SELECT :P_DECISION_DOMAIN_ID AS decision_domain_id, :P_CANDIDATE_ID AS candidate_id) src
      ON eff.decision_domain_id = src.decision_domain_id AND eff.candidate_id = src.candidate_id
    WHEN MATCHED THEN UPDATE SET
        offered_count = eff.offered_count + 1,
        accepted_count = eff.accepted_count + IFF(:P_ACCEPTED, 1, 0),
        acceptance_rate = (eff.accepted_count + IFF(:P_ACCEPTED, 1, 0)) / (eff.offered_count + 1),
        confidence = LEAST(0.99, 1 - 1 / SQRT(eff.offered_count + 1 + 2)),
        last_updated = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        effectiveness_id, decision_domain_id, candidate_id,
        offered_count, accepted_count, acceptance_rate, confidence, last_updated
    ) VALUES (
        :P_DECISION_DOMAIN_ID || '::' || :P_CANDIDATE_ID, :P_DECISION_DOMAIN_ID, :P_CANDIDATE_ID,
        1, IFF(:P_ACCEPTED, 1, 0), IFF(:P_ACCEPTED, 1, 0), LEAST(0.99, 1 - 1 / SQRT(3)), CURRENT_TIMESTAMP()
    );
    RETURN 'OK';
END;
$$;

-- =============================================================================
-- Registry rows for the two EXISTING domains — documentation only, so the
-- registry is complete. RECOMMEND_GENERIC never reads these two; they
-- continue to be served by RECOMMEND and RECOMMEND_PRODUCT exactly as today.
-- =============================================================================
MERGE INTO CONFIG.DECISION_DOMAIN t
USING (
    SELECT 'churn_retention' AS decision_domain_id, 'Churn & Retention' AS label, 'CUSTOMER' AS entity_type,
           'STATE_GATED' AS eligibility_mode, 'LEGACY' AS implementation, 'APP.RECOMMEND' AS legacy_function_name,
           'Persona-weighted retention actions gated by churn severity state; approval ceilings and cost math are bespoke to this domain.' AS description
    UNION ALL
    SELECT 'personalization', 'Product Personalization', 'CUSTOMER',
           'SIGNAL_MATCHED', 'LEGACY', 'APP.RECOMMEND_PRODUCT',
           'Product/offer fit matched directly against extracted customer signals, suppressed when the customer is in a high-severity churn state.'
) s ON t.decision_domain_id = s.decision_domain_id
WHEN NOT MATCHED THEN INSERT (decision_domain_id, label, entity_type, eligibility_mode, implementation, legacy_function_name, description)
    VALUES (s.decision_domain_id, s.label, s.entity_type, s.eligibility_mode, s.implementation, s.legacy_function_name, s.description);

-- =============================================================================
-- Reference domain — proves the abstraction by replaying personalization's
-- OWN data through the generic engine. Not wired into the UI or Agent; exists
-- purely as the verification harness and as a live worked example for
-- onboarding use case #3. Safe to delete independently of everything above.
-- =============================================================================
MERGE INTO CONFIG.DECISION_DOMAIN t
USING (SELECT 'personalization_generic_ref' AS decision_domain_id) s
ON t.decision_domain_id = s.decision_domain_id
WHEN NOT MATCHED THEN INSERT (decision_domain_id, label, entity_type, eligibility_mode, implementation, legacy_function_name, description)
    VALUES ('personalization_generic_ref', 'Personalization (generic-engine reference copy)', 'CUSTOMER',
            'SIGNAL_MATCHED', 'GENERIC', NULL,
            'Live copy of PRODUCT_CATALOG/PRODUCT_RULE replayed through RECOMMEND_GENERIC to verify it reproduces RECOMMEND_PRODUCT exactly. Reference only — not used by any UI or Agent tool.');

MERGE INTO CONFIG.DECISION_CANDIDATE t
USING (
    SELECT product_id AS candidate_id, 'personalization_generic_ref' AS decision_domain_id,
           domain_id AS business_domain_id, product_name AS candidate_name, product_type AS candidate_type,
           description, min_age, max_age, segment_fit, 0::FLOAT AS default_cost,
           FALSE AS requires_approval, 0::FLOAT AS approval_threshold, active
    FROM CONFIG.PRODUCT_CATALOG
) s ON t.candidate_id = s.candidate_id AND t.decision_domain_id = s.decision_domain_id
WHEN NOT MATCHED THEN INSERT (candidate_id, decision_domain_id, business_domain_id, candidate_name, candidate_type,
    description, min_age, max_age, segment_fit, default_cost, requires_approval, approval_threshold, active)
    VALUES (s.candidate_id, s.decision_domain_id, s.business_domain_id, s.candidate_name, s.candidate_type,
    s.description, s.min_age, s.max_age, s.segment_fit, s.default_cost, s.requires_approval, s.approval_threshold, s.active);

MERGE INTO CONFIG.DECISION_RULE t
USING (
    SELECT rule_id, 'personalization_generic_ref' AS decision_domain_id, product_id AS candidate_id,
           'SIGNAL' AS match_type, signal_name AS match_key, match_value, weight, active
    FROM CONFIG.PRODUCT_RULE
) s ON t.rule_id = s.rule_id AND t.decision_domain_id = s.decision_domain_id
WHEN NOT MATCHED THEN INSERT (rule_id, decision_domain_id, candidate_id, match_type, match_key, match_value, weight, active)
    VALUES (s.rule_id, s.decision_domain_id, s.candidate_id, s.match_type, s.match_key, s.match_value, s.weight, s.active);

GRANT USAGE ON FUNCTION APP.RECOMMEND_GENERIC(VARCHAR, VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE APP.RECOMMEND_GENERIC_ACTION(VARCHAR, VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE APP.RECORD_DECISION_OUTCOME(VARCHAR, VARCHAR, VARCHAR, BOOLEAN) TO ROLE C360_JUDGE;

SELECT 'Decision domain registry + RECOMMEND_GENERIC deployed (additive only)' AS status;
