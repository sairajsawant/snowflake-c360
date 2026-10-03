-- =============================================================================
-- 18_cross_domain.sql — cross-domain suppression + one unified persona feed.
--
-- The gap found while writing up the architecture review: RECOMMEND_PRODUCT
-- had no idea a customer was in CRITICAL_CHURN_RISK — it would cheerfully
-- suggest an upsell to someone about to leave. Fixed by making the
-- personalization engine aware of the churn engine's current state, without
-- merging the two engines together.
--
-- Transparent, not silent: a suppressed product still appears in the ranked
-- output with SUPPRESSED=TRUE and a reason, rather than vanishing — same
-- "show your work" principle as every other recommendation in this platform.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- =============================================================================
-- RECOMMEND_PRODUCT — add churn-state awareness. Severity >= 3 (HIGH or
-- CRITICAL, either domain — the scale is consistent) suppresses, doesn't hide.
-- =============================================================================
CREATE OR REPLACE FUNCTION RECOMMEND_PRODUCT(P_CUSTOMER_ID VARCHAR)
RETURNS TABLE (PRODUCT_ID VARCHAR, PRODUCT_NAME VARCHAR, PRODUCT_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR, ACCEPTANCE_RATE FLOAT,
    SAMPLE_SIZE NUMBER, ELIGIBLE_REASON VARCHAR, SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR)
AS
$$
WITH cust AS (
    SELECT c.customer_id, c.domain, c.segment,
           DATEDIFF(year, c.date_of_birth, CURRENT_DATE()) AS age,
           cs.state_name, COALESCE(cs.severity, 0) AS severity
    FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER c
    LEFT JOIN CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
      ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
    WHERE c.customer_id = P_CUSTOMER_ID
),
eligible AS (
    SELECT pc.product_id, pc.product_name, pc.product_type, pc.domain_id,
           c.customer_id,
           pc.product_type || ' for ages ' || pc.min_age || '-' || pc.max_age
             || CASE WHEN pc.segment_fit IS NOT NULL THEN ' · ' || pc.segment_fit ELSE '' END
             AS eligible_reason
    FROM CONFIG.PRODUCT_CATALOG pc
    JOIN cust c
      ON pc.domain_id = c.domain
     AND c.age BETWEEN pc.min_age AND pc.max_age
     AND (pc.segment_fit IS NULL OR pc.segment_fit = c.segment)
    WHERE pc.active = TRUE
),
sig AS (
    SELECT customer_id, signal_name, signal_value
    FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS WHERE customer_id = P_CUSTOMER_ID
),
scored AS (
    SELECT e.product_id, e.product_name, e.product_type, e.eligible_reason,
           SUM(pr.weight) AS score,
           LISTAGG(DISTINCT pr.signal_name || '=' || pr.match_value, ', ')
             WITHIN GROUP (ORDER BY pr.signal_name || '=' || pr.match_value) AS match_reasons
    FROM eligible e
    JOIN CONFIG.PRODUCT_RULE pr ON pr.product_id = e.product_id AND pr.active = TRUE
    JOIN sig s ON s.signal_name = pr.signal_name AND s.signal_value = pr.match_value
    GROUP BY e.product_id, e.product_name, e.product_type, e.eligible_reason
)
SELECT s.product_id, s.product_name, s.product_type,
       ROW_NUMBER() OVER (ORDER BY s.score DESC, s.product_id) AS ranking,
       ROUND(s.score, 4), s.match_reasons,
       COALESCE(pe.acceptance_rate, 0.3), COALESCE(pe.offered_count, 0),
       s.eligible_reason,
       (SELECT severity >= 3 FROM cust) AS suppressed,
       CASE WHEN (SELECT severity >= 3 FROM cust)
            THEN 'Customer is in ' || (SELECT state_name FROM cust)
                 || ' — lead with retention before any upsell'
            ELSE NULL END AS suppression_reason
FROM scored s
LEFT JOIN ENGINE.PRODUCT_EFFECTIVENESS pe ON pe.product_id = s.product_id
ORDER BY s.score DESC, s.product_id
$$;

-- Agent-compat wrapper, same split as before — signature grew by 2 columns.
CREATE OR REPLACE PROCEDURE RECOMMEND_PRODUCT_ACTION(CUSTOMER_ID VARCHAR)
RETURNS TABLE (PRODUCT_ID VARCHAR, PRODUCT_NAME VARCHAR, PRODUCT_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR, ACCEPTANCE_RATE FLOAT,
    SAMPLE_SIZE NUMBER, ELIGIBLE_REASON VARCHAR, SUPPRESSED BOOLEAN, SUPPRESSION_REASON VARCHAR)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    res := (SELECT * FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND_PRODUCT(:CUSTOMER_ID)));
    RETURN TABLE(res);
END;
$$;

-- =============================================================================
-- UNIFIED_FEED — Snowpark Python. For every customer in a persona's scope:
-- if churn severity is HIGH/CRITICAL, the retention action wins; otherwise
-- the top (non-suppressed) product opportunity, if any. One ranked list,
-- not two pages to check. Genuinely needs iteration: each customer's
-- RECOMMEND/RECOMMEND_PRODUCT call does its own cross-candidate
-- normalization, same justification as PENDING_APPROVALS.
-- =============================================================================
CREATE OR REPLACE PROCEDURE UNIFIED_FEED(P_SCOPE VARCHAR, P_USER VARCHAR, P_TEAM VARCHAR, P_PERSONA VARCHAR)
RETURNS TABLE (CUSTOMER_ID VARCHAR, FULL_NAME VARCHAR, DOMAIN VARCHAR, FEED_TYPE VARCHAR,
    STATE_NAME VARCHAR, SEVERITY NUMBER, RELATIONSHIP_VALUE FLOAT,
    HEADLINE VARCHAR, SCORE FLOAT, DETAIL VARCHAR)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
from snowflake.snowpark.types import (
    StructType, StructField, StringType, DoubleType, IntegerType,
)

DB = "CUSTOMER_360_DB"

OUT_SCHEMA = StructType([
    StructField("CUSTOMER_ID", StringType()),
    StructField("FULL_NAME", StringType()),
    StructField("DOMAIN", StringType()),
    StructField("FEED_TYPE", StringType()),
    StructField("STATE_NAME", StringType()),
    StructField("SEVERITY", IntegerType()),
    StructField("RELATIONSHIP_VALUE", DoubleType()),
    StructField("HEADLINE", StringType()),
    StructField("SCORE", DoubleType()),
    StructField("DETAIL", StringType()),
])


def _lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def run(session, p_scope, p_user, p_team, p_persona):
    scope_rows = session.sql(f"""
        SELECT c.customer_id, c.full_name, c.domain, cs.state_name,
               COALESCE(cs.severity, 0) AS severity, rv.relationship_value
        FROM {DB}.CANONICAL.CUSTOMER c
        LEFT JOIN {DB}.ENGINE.CUSTOMER_STATE cs
          ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
        LEFT JOIN {DB}.APP.V_RELATIONSHIP_VALUE rv
          ON rv.customer_id = c.customer_id AND rv.domain = c.domain
        LEFT JOIN {DB}.CONFIG.CUSTOMER_ASSIGNMENT ca
          ON ca.customer_id = c.customer_id AND ca.domain = c.domain
        WHERE {_lit(p_scope)} = 'ALL'
           OR ({_lit(p_scope)} = 'ASSIGNED' AND ca.assigned_user = {_lit(p_user)})
           OR ({_lit(p_scope)} = 'TEAM' AND ca.assigned_team = {_lit(p_team)})
    """).collect()

    rows = []
    for c in scope_rows:
        cid, name, dom = c["CUSTOMER_ID"], c["FULL_NAME"], c["DOMAIN"]
        severity = int(c["SEVERITY"] or 0)
        state, rv = c["STATE_NAME"], c["RELATIONSHIP_VALUE"]

        if severity >= 3:
            top = session.sql(f"""
                SELECT * FROM TABLE({DB}.APP.RECOMMEND({_lit(cid)}, {_lit(p_persona)}, 0::FLOAT))
                ORDER BY ranking LIMIT 1
            """).collect()
            if top:
                a = top[0]
                rows.append((cid, name, dom, 'RETENTION', state, severity, rv,
                             a["ACTION_NAME"], float(a["SCORE"]),
                             f"{a['EFFECTIVENESS_RATE']*100:.0f}% track record, n={a['SAMPLE_SIZE']}"))
                continue

        prod = session.sql(f"""
            SELECT * FROM TABLE({DB}.APP.RECOMMEND_PRODUCT({_lit(cid)}))
            WHERE NOT suppressed ORDER BY ranking LIMIT 1
        """).collect()
        if prod:
            p = prod[0]
            rows.append((cid, name, dom, 'OPPORTUNITY', state, severity, rv,
                         p["PRODUCT_NAME"], float(p["SCORE"]), p["MATCH_REASONS"]))

    rows.sort(key=lambda r: (0 if r[3] == 'RETENTION' else 1, -(r[5] or 0), -(r[8] or 0)))
    return session.create_dataframe(rows, schema=OUT_SCHEMA)
$$;

GRANT USAGE ON FUNCTION RECOMMEND_PRODUCT(VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE RECOMMEND_PRODUCT_ACTION(VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE UNIFIED_FEED(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO ROLE C360_JUDGE;

SELECT 'Cross-domain suppression + unified feed deployed' AS status;
