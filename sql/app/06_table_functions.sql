-- =============================================================================
-- Table functions.
--
-- Snowpark does not surface the column names declared in a procedure's
-- RETURNS TABLE(...) — session.sql("CALL proc(...)").to_pandas() comes back
-- without them, and RESULT_SCAN on the CALL is no more reliable. A SQL table
-- function is SELECTable, so SELECT * FROM TABLE(fn(...)) returns a properly
-- named, properly typed result set every time.
--
-- The procedures stay in place (they are the documented API and work fine from
-- the CLI and from other procedures); these are what the Streamlit app reads.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

CREATE OR REPLACE FUNCTION RECOMMEND(
    P_CUSTOMER_ID VARCHAR, P_PERSONA VARCHAR, P_OFFER_AMOUNT FLOAT)
RETURNS TABLE (ACTION_ID VARCHAR, ACTION_NAME VARCHAR, ACTION_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, EFFECTIVENESS_RATE FLOAT, SAMPLE_SIZE NUMBER,
    EXPECTED_UPLIFT FLOAT, CONFIDENCE FLOAT, EXPECTED_VALUE FLOAT,
    TOTAL_COST FLOAT, REQUIRES_APPROVAL BOOLEAN, POLICY_STATUS VARCHAR,
    W_UPLIFT FLOAT, W_VALUE FLOAT, W_COST FLOAT, W_CONF FLOAT,
    PART_UPLIFT FLOAT, PART_VALUE FLOAT, PART_COST FLOAT, PART_CONF FLOAT,
    COST_CEILING FLOAT, RELATIONSHIP_VALUE FLOAT)
AS
$$
WITH ctx AS (
    SELECT cs.customer_id, cs.state_id, cs.domain,
           rv.relationship_value, cc.cost_ceiling
    FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
    JOIN CUSTOMER_360_DB.APP.V_RELATIONSHIP_VALUE rv
      ON rv.customer_id = cs.customer_id AND rv.domain = cs.domain
    JOIN CUSTOMER_360_DB.APP.V_COST_CEILING cc ON cc.domain_id = cs.domain
    WHERE cs.customer_id = P_CUSTOMER_ID AND cs.is_current = TRUE
),
wts AS (
    SELECT c.domain,
        COALESCE(p.w_uplift, d.w_uplift) AS w_uplift,
        COALESCE(p.w_value,  d.w_value)  AS w_value,
        COALESCE(p.w_cost,   d.w_cost)   AS w_cost,
        COALESCE(p.w_conf,   d.w_conf)   AS w_conf
    FROM ctx c
    LEFT JOIN CUSTOMER_360_DB.APP.V_SCORING p
           ON p.domain_id = c.domain AND p.persona = P_PERSONA
    LEFT JOIN CUSTOMER_360_DB.APP.V_SCORING d
           ON d.domain_id = c.domain AND d.persona = 'default'
),
cand AS (
    SELECT ad.action_id, ad.action_name, ad.action_type, ad.requires_approval,
           ad.approval_threshold, ad.default_cost,
           COALESCE(ae.success_rate, 0.30) AS eff_rate,
           COALESCE(ae.total_count, 0)     AS sample_size,
           COALESCE(ae.avg_uplift, 0.05)   AS uplift,
           COALESCE(ae.confidence, 0.40)   AS conf,
           c.relationship_value, c.cost_ceiling, c.domain,
           ad.default_cost
             + CASE WHEN ad.requires_approval THEN COALESCE(P_OFFER_AMOUNT,0) ELSE 0 END AS total_cost
    FROM ctx c
    JOIN CUSTOMER_360_DB.CONFIG.ACTION_STATE_MAPPING asm
      ON asm.state_id = c.state_id AND asm.domain_id = c.domain AND asm.active = TRUE
    JOIN CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad
      ON ad.action_id = asm.action_id AND ad.active = TRUE
    LEFT JOIN CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS ae
      ON ae.action_id = ad.action_id AND ae.state_id = c.state_id AND ae.domain_id = c.domain
),
norm AS (
    SELECT cand.*,
        cand.relationship_value * cand.eff_rate * cand.uplift AS ev,
        cand.uplift / NULLIF(MAX(cand.uplift) OVER (), 0) AS un,
        (cand.relationship_value * cand.eff_rate * cand.uplift)
          / NULLIF(MAX(cand.relationship_value * cand.eff_rate * cand.uplift) OVER (), 0) AS vn,
        cand.total_cost / NULLIF(cand.cost_ceiling, 0) AS cn
    FROM cand
),
scored AS (
    SELECT n.*, w.w_uplift, w.w_value, w.w_cost, w.w_conf,
        w.w_uplift * n.un   AS part_uplift,
        w.w_value  * n.vn   AS part_value,
        w.w_cost   * n.cn   AS part_cost,
        w.w_conf   * n.conf AS part_conf,
        w.w_uplift * n.un + w.w_value * n.vn + w.w_cost * n.cn + w.w_conf * n.conf AS score
    FROM norm n CROSS JOIN wts w
)
SELECT action_id, action_name, action_type,
    ROW_NUMBER() OVER (ORDER BY score DESC),
    ROUND(score,4), eff_rate, sample_size, uplift, conf, ROUND(ev,0),
    total_cost, requires_approval,
    CASE
        WHEN NOT requires_approval AND default_cost < 8300 THEN 'AUTONOMOUS'
        WHEN NOT requires_approval THEN 'AUTONOMOUS_REVIEW'
        WHEN COALESCE(P_OFFER_AMOUNT,0) > 415000 THEN 'VP_APPROVAL'
        ELSE 'REQUIRES_APPROVAL'
    END,
    w_uplift, w_value, w_cost, w_conf,
    ROUND(part_uplift,4), ROUND(part_value,4), ROUND(part_cost,4), ROUND(part_conf,4),
    cost_ceiling, relationship_value
FROM scored ORDER BY score DESC
$$;

CREATE OR REPLACE FUNCTION POLICY_CHECK_TABLE(
    P_ACTION_ID VARCHAR, P_PERSONA VARCHAR, P_OFFER_AMOUNT FLOAT)
RETURNS TABLE (POLICY_ID VARCHAR, POLICY_NAME VARCHAR, POLICY_TYPE VARCHAR,
    RULE_EXPRESSION VARCHAR, SUBSTITUTED VARCHAR, VERDICT VARCHAR, ENFORCEMENT VARCHAR)
AS
$$
WITH a AS (
    SELECT ad.action_id, ad.action_type, ad.default_cost,
           ad.requires_approval, ad.approval_threshold, ad.domain_id
    FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad WHERE ad.action_id = P_ACTION_ID
)
SELECT pr.policy_id, pr.policy_name, pr.policy_type, pr.rule_expression,
    CASE pr.policy_type
        WHEN 'AUTO_EXECUTE'  THEN 'action_type=' || a.action_type
                                  || ', action_cost=' || TO_VARCHAR(a.default_cost)
        WHEN 'VALUE_LIMIT'   THEN 'offer_amount=' || TO_VARCHAR(COALESCE(P_OFFER_AMOUNT,0))
        WHEN 'APPROVAL_GATE' THEN 'offer_amount=' || TO_VARCHAR(COALESCE(P_OFFER_AMOUNT,0))
        ELSE 'not applicable to this action'
    END,
    CASE
        WHEN pr.policy_type = 'AUTO_EXECUTE' THEN
            CASE WHEN a.action_type = 'AUTONOMOUS' AND a.default_cost < 8300
                 THEN 'ALLOW' ELSE 'SKIP' END
        WHEN pr.policy_type = 'VALUE_LIMIT' AND pr.policy_id = 'pol_ins_1' THEN
            CASE WHEN NOT a.requires_approval THEN 'SKIP'
                 WHEN COALESCE(P_OFFER_AMOUNT,0) <= 415000 THEN 'PASS' ELSE 'BLOCK' END
        WHEN pr.policy_type = 'APPROVAL_GATE' AND pr.policy_id = 'pol_ins_3' THEN
            CASE WHEN NOT a.requires_approval THEN 'SKIP'
                 WHEN COALESCE(P_OFFER_AMOUNT,0) > 415000 THEN 'REQUIRE_APPROVAL' ELSE 'PASS' END
        ELSE 'SKIP'
    END,
    pr.enforcement
FROM a
JOIN CUSTOMER_360_DB.CONFIG.POLICY_RULE pr
  ON pr.domain_id = a.domain_id AND pr.active = TRUE
ORDER BY pr.policy_id
$$;

-- Signals written by a given run, with their evidence quotes. Replaces reading
-- the EXTRACT_SIGNALS_FOR procedure's return value.
CREATE OR REPLACE FUNCTION SIGNALS_FOR_TRANSCRIPT(P_CUSTOMER_ID VARCHAR, P_TRANSCRIPT_ID VARCHAR)
RETURNS TABLE (SIGNAL_NAME VARCHAR, SIGNAL_VALUE VARCHAR, NUMERIC_VALUE FLOAT,
               CONFIDENCE FLOAT, QUOTE VARCHAR, METHOD VARCHAR)
AS
$$
SELECT s.signal_name, s.signal_value, s.numeric_value, s.confidence,
       e.quote,
       CASE WHEN e.model = 'AI_SENTIMENT' THEN 'AI_SENTIMENT' ELSE 'AI_COMPLETE' END
FROM CUSTOMER_360_DB.ENGINE.SIGNAL s
LEFT JOIN CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE e
       ON e.signal_instance_id = s.signal_instance_id
WHERE s.customer_id = P_CUSTOMER_ID
  AND s.evidence_ref = 'transcript:' || P_TRANSCRIPT_ID
ORDER BY s.signal_name
$$;

GRANT USAGE ON ALL FUNCTIONS IN SCHEMA CUSTOMER_360_DB.APP TO ROLE C360_JUDGE;

SELECT 'APP table functions created' AS status;
