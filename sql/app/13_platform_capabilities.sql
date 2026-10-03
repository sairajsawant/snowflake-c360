-- =============================================================================
-- 13_platform_capabilities.sql — reusable platform capabilities
--
-- Moves logic that was hardcoded or re-derived client-side in the Streamlit
-- app into named Snowflake objects, so any client (this app, the Cortex
-- Agent, a future app) gets the same answer from one place.
--
--   APP.V_TRUST_FLAGS          replaces a static 4-customer dict in console.py
--   APP.CUSTOMER_TIMELINE(cid) replaces a 7-way UNION ALL embedded in sf.py
--   APP.DECISION_QUEUE(...)    replaces the queue() query embedded in sf.py
--   APP.V_ACTION_EFFECTIVENESS replaces a hardcoded 0.70 threshold in console.py
--   APP.PENDING_APPROVALS(...) replaces an N+1 Python loop calling RECOMMEND
--                               once per customer — genuinely needs Snowpark
--                               Python because RECOMMEND's cross-candidate
--                               normalization can't be correlated into a
--                               single SQL statement (confirmed: a LATERAL
--                               TABLE join against it throws "Unsupported
--                               subquery type cannot be evaluated").
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

-- =============================================================================
-- APP.V_TRUST_FLAGS — conflicting evidence / thin sample, computed for all
-- customers, not a hand-picked few.
-- =============================================================================
CREATE OR REPLACE VIEW APP.V_TRUST_FLAGS AS
WITH conflict AS (
    SELECT customer_id, signal_name,
           ARRAY_AGG(DISTINCT signal_value) WITHIN GROUP (ORDER BY signal_value) AS values_seen
    FROM ENGINE.SIGNAL
    GROUP BY customer_id, signal_name
    HAVING COUNT(DISTINCT signal_value) > 1
),
conflict_pick AS (
    SELECT customer_id, signal_name, values_seen,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY signal_name) AS rn
    FROM conflict
),
cand AS (
    SELECT cs.customer_id, ad.action_name, ae.confidence, ae.total_count
    FROM ENGINE.CUSTOMER_STATE cs
    JOIN CONFIG.ACTION_STATE_MAPPING asm
      ON asm.state_id = cs.state_id AND asm.domain_id = cs.domain AND asm.active = TRUE
    JOIN CONFIG.ACTION_DEFINITION ad ON ad.action_id = asm.action_id AND ad.active = TRUE
    LEFT JOIN ENGINE.ACTION_EFFECTIVENESS ae
      ON ae.action_id = asm.action_id AND ae.state_id = cs.state_id AND ae.domain_id = cs.domain
    WHERE cs.is_current = TRUE AND COALESCE(ae.confidence, 0) < 0.70
),
thin_pick AS (
    SELECT customer_id, action_name, COALESCE(confidence, 0) AS confidence,
           COALESCE(total_count, 0) AS total_count,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY COALESCE(confidence, 0) ASC) AS rn
    FROM cand
),
flags AS (
    SELECT customer_id, 'CONFLICTING EVIDENCE' AS flag,
           signal_name || ' arrived as both ' || ARRAY_TO_STRING(values_seen, ' and ')
             || ' from different evidence' AS detail,
           1 AS priority
    FROM conflict_pick WHERE rn = 1
    UNION ALL
    SELECT customer_id, 'THIN SAMPLE' AS flag,
           'candidate action (' || action_name || ') rests on n=' || total_count
             || ' at confidence ' || ROUND(confidence, 2) AS detail,
           2 AS priority
    FROM thin_pick WHERE rn = 1
)
SELECT customer_id, flag, detail
FROM flags
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY priority) = 1;

-- =============================================================================
-- APP.CUSTOMER_TIMELINE(cid) — every dated record for a customer, one stream.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP.CUSTOMER_TIMELINE(P_CUSTOMER_ID VARCHAR)
RETURNS TABLE (WHEN_AT TIMESTAMP_NTZ, SOURCE VARCHAR, WHAT VARCHAR, DETAIL VARCHAR)
AS
$$
SELECT effective_from::TIMESTAMP_NTZ AS when_at, 'Policy' AS source, change_type AS what,
       policy_id || ' · cover ' || TO_VARCHAR(sum_insured)
         || ' · premium ' || TO_VARCHAR(premium)
         || CASE WHEN renewal_status = 'LATE'
                 THEN ' · renewed ' || days_late::VARCHAR || ' days late' ELSE '' END AS detail
FROM CUSTOMER_360_DB.RAW.POLICY_VERSION WHERE customer_id = P_CUSTOMER_ID
UNION ALL
SELECT opened_at, 'Ticket', category,
       subject || CASE WHEN sla_breached THEN ' · SLA BREACHED' ELSE '' END
               || CASE WHEN reopen_count > 0 THEN ' · reopened ' || reopen_count::VARCHAR ELSE '' END
FROM CUSTOMER_360_DB.RAW.SUPPORT_TICKET WHERE customer_id = P_CUSTOMER_ID
UNION ALL
SELECT sent_at, 'Email', CASE WHEN direction = 'INBOUND' THEN 'From customer' ELSE 'To customer' END,
       subject
FROM CUSTOMER_360_DB.RAW.EMAIL_MESSAGE WHERE customer_id = P_CUSTOMER_ID
UNION ALL
SELECT filed_date::TIMESTAMP_NTZ, 'Claim', claim_status,
       claim_id || ' · ' || claim_type || ' · ' || TO_VARCHAR(claim_amount)
FROM CUSTOMER_360_DB.RAW.INSURANCE_CLAIMS WHERE customer_id = P_CUSTOMER_ID
UNION ALL
SELECT filed_date::TIMESTAMP_NTZ, 'Grievance', status,
       'IRDAI ' || igms_token || ' · ' || category
FROM CUSTOMER_360_DB.RAW.GRIEVANCE WHERE customer_id = P_CUSTOMER_ID
UNION ALL
SELECT requested_date::TIMESTAMP_NTZ, 'Portability', stage,
       target_insurer || ' quoted ' || TO_VARCHAR(quoted_premium)
         || ' against ' || TO_VARCHAR(current_premium)
FROM CUSTOMER_360_DB.RAW.PORTABILITY_REQUEST WHERE customer_id = P_CUSTOMER_ID
UNION ALL
SELECT interaction_date, 'Interaction', UPPER(interaction_type), subject
FROM CUSTOMER_360_DB.CANONICAL.INTERACTION WHERE customer_id = P_CUSTOMER_ID
ORDER BY when_at DESC
$$;

-- =============================================================================
-- APP.DECISION_QUEUE(scope, user, team) — "needs attention" is a platform
-- rule (severity >= 2 + scope), not a Python f-string.
-- =============================================================================
CREATE OR REPLACE FUNCTION APP.DECISION_QUEUE(P_SCOPE VARCHAR, P_USER VARCHAR, P_TEAM VARCHAR)
RETURNS TABLE (CUSTOMER_ID VARCHAR, FULL_NAME VARCHAR, DOMAIN VARCHAR, SEGMENT VARCHAR,
    STATE_NAME VARCHAR, SEVERITY NUMBER, RELATIONSHIP_VALUE FLOAT,
    ASSIGNED_USER VARCHAR, ASSIGNED_TEAM VARCHAR)
AS
$$
SELECT c.customer_id, c.full_name, c.domain, COALESCE(c.segment, '—') AS segment,
       cs.state_name, cs.severity, rv.relationship_value,
       ca.assigned_user, ca.assigned_team
FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER c
JOIN CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
     ON cs.customer_id = c.customer_id AND cs.is_current = TRUE AND cs.severity >= 2
LEFT JOIN CUSTOMER_360_DB.APP.V_RELATIONSHIP_VALUE rv
     ON rv.customer_id = c.customer_id AND rv.domain = c.domain
LEFT JOIN CUSTOMER_360_DB.CONFIG.CUSTOMER_ASSIGNMENT ca
     ON ca.customer_id = c.customer_id AND ca.domain = c.domain
WHERE P_SCOPE = 'ALL'
   OR (P_SCOPE = 'ASSIGNED' AND ca.assigned_user = P_USER)
   OR (P_SCOPE = 'TEAM' AND ca.assigned_team = P_TEAM)
ORDER BY cs.severity DESC, rv.relationship_value DESC NULLS LAST
$$;

-- =============================================================================
-- APP.V_ACTION_EFFECTIVENESS — the effectiveness join plus the thin-sample
-- threshold as a real column, not a magic number re-typed in console.py.
-- =============================================================================
CREATE OR REPLACE VIEW APP.V_ACTION_EFFECTIVENESS AS
SELECT ae.action_id, ad.action_name, ae.state_id, sd.state_name, ae.domain_id,
       ae.success_count, ae.total_count, ae.success_rate, ae.avg_uplift, ae.confidence,
       ae.confidence < 0.70 AS is_thin_sample
FROM ENGINE.ACTION_EFFECTIVENESS ae
JOIN CONFIG.ACTION_DEFINITION ad ON ad.action_id = ae.action_id
JOIN CONFIG.STATE_DEFINITION  sd ON sd.state_id  = ae.state_id;

-- =============================================================================
-- APP.PENDING_APPROVALS(scope, user, team, persona) — Snowpark Python.
-- For every customer in scope, run the real scoring function and keep the
-- top approval-gated candidate. Genuinely needs iteration: RECOMMEND
-- cross-normalizes each candidate against every other candidate for that
-- customer, so it cannot be expressed as one correlated SQL statement
-- (see header note — LATERAL TABLE against it fails to compile).
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP.PENDING_APPROVALS(
    P_SCOPE VARCHAR, P_USER VARCHAR, P_TEAM VARCHAR, P_PERSONA VARCHAR)
RETURNS TABLE (CUSTOMER_ID VARCHAR, FULL_NAME VARCHAR, STATE_NAME VARCHAR, SEVERITY NUMBER,
    RELATIONSHIP_VALUE FLOAT, ACTION_ID VARCHAR, ACTION_NAME VARCHAR,
    SCORE FLOAT, EFFECTIVENESS_RATE FLOAT, SAMPLE_SIZE NUMBER)
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
    StructField("STATE_NAME", StringType()),
    StructField("SEVERITY", IntegerType()),
    StructField("RELATIONSHIP_VALUE", DoubleType()),
    StructField("ACTION_ID", StringType()),
    StructField("ACTION_NAME", StringType()),
    StructField("SCORE", DoubleType()),
    StructField("EFFECTIVENESS_RATE", DoubleType()),
    StructField("SAMPLE_SIZE", IntegerType()),
])


def _lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def run(session, p_scope, p_user, p_team, p_persona):
    queue_rows = session.sql(f"""
        SELECT * FROM TABLE({DB}.APP.DECISION_QUEUE(
            {_lit(p_scope)}, {_lit(p_user)}, {_lit(p_team)}))
    """).collect()

    rows = []
    for c in queue_rows:
        top = session.sql(f"""
            SELECT * FROM TABLE({DB}.APP.RECOMMEND(
                {_lit(c['CUSTOMER_ID'])}, {_lit(p_persona)}, 0::FLOAT))
            WHERE REQUIRES_APPROVAL
            ORDER BY RANKING LIMIT 1
        """).collect()
        if top:
            a = top[0]
            rv = c["RELATIONSHIP_VALUE"]
            rows.append((
                c["CUSTOMER_ID"], c["FULL_NAME"], c["STATE_NAME"], int(c["SEVERITY"]),
                float(rv) if rv is not None else None,
                a["ACTION_ID"], a["ACTION_NAME"],
                float(a["SCORE"]), float(a["EFFECTIVENESS_RATE"]),
                int(a["SAMPLE_SIZE"]),
            ))

    return session.create_dataframe(rows, schema=OUT_SCHEMA)
$$;

GRANT SELECT ON VIEW APP.V_TRUST_FLAGS TO ROLE C360_JUDGE;
GRANT SELECT ON VIEW APP.V_ACTION_EFFECTIVENESS TO ROLE C360_JUDGE;
GRANT USAGE ON FUNCTION APP.CUSTOMER_TIMELINE(VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON FUNCTION APP.DECISION_QUEUE(VARCHAR, VARCHAR, VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE APP.PENDING_APPROVALS(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO ROLE C360_JUDGE;
