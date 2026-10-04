-- =============================================================================
-- 20_feed_performance.sql — a fast replacement for APP.UNIFIED_FEED.
--
-- ADDITIVE. APP.UNIFIED_FEED is left exactly as-is so this is revertible by
-- pointing the UI back at it; nothing else in the platform is touched.
--
-- WHY THE ORIGINAL IS SLOW
-- UNIFIED_FEED loops EVERY customer in scope and issues one scoring call each
-- (RECOMMEND for severity>=3, RECOMMEND_PRODUCT otherwise). At full-book scope
-- that is 30 sequential round-trips, most of a minute — and measured against
-- live data, 11 of those 30 can never return a row at all:
--
--   total customers ............... 30
--   retention path (sev>=3) ........ 8   (all 8 have a mapped action)
--   opportunity path with a match . 11
--   ------------------------------------
--   can produce a feed row ........ 19   <- 11 calls were pure waste
--
-- TWO CHANGES, BOTH EXACT (not sampling, nothing silently dropped):
--
-- 1. PRE-FILTER. One SQL statement decides up front which customers can
--    actually yield a row, replicating the engines' own eligibility exactly:
--    retention needs an ACTION_STATE_MAPPING row for the customer's current
--    state; opportunity needs at least one PRODUCT_RULE whose signal the
--    customer actually has, against a catalog entry they're age/segment
--    eligible for. A customer the engines would return nothing for is never
--    scored at all.
--
-- 2. TOP-N. The survivors are ranked in SQL (retention first, then severity,
--    then relationship value) and only the top P_LIMIT are scored. A feed is
--    a prioritised worklist — an RM works the top of it, nobody scrolls 30
--    cards — so this is better UX as well as faster.
--
-- The procedure reports how many it ranked vs. scored so the UI can say so
-- plainly rather than implying it covered the whole book.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

CREATE OR REPLACE PROCEDURE UNIFIED_FEED_TOP(
    P_SCOPE VARCHAR, P_USER VARCHAR, P_TEAM VARCHAR, P_PERSONA VARCHAR, P_LIMIT FLOAT
)
RETURNS TABLE (CUSTOMER_ID VARCHAR, FULL_NAME VARCHAR, DOMAIN VARCHAR, FEED_TYPE VARCHAR,
    STATE_NAME VARCHAR, SEVERITY NUMBER, RELATIONSHIP_VALUE FLOAT,
    HEADLINE VARCHAR, SCORE FLOAT, DETAIL VARCHAR, ELIGIBLE_TOTAL NUMBER)
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
    StructField("ELIGIBLE_TOTAL", IntegerType()),
])


def _lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def run(session, p_scope, p_user, p_team, p_persona, p_limit):
    limit = max(1, int(p_limit or 12))

    # One statement: scope -> eligibility (exactly mirroring each engine's own
    # matching rules) -> rank. Only survivors get scored below.
    candidates = session.sql(f"""
        WITH base AS (
            SELECT c.customer_id, c.full_name, c.domain, c.segment,
                   DATEDIFF(year, c.date_of_birth, CURRENT_DATE()) AS age,
                   cs.state_id, cs.state_name, COALESCE(cs.severity, 0) AS severity,
                   rv.relationship_value
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
        ),
        tagged AS (
            SELECT b.*,
                CASE
                  WHEN b.severity >= 3 AND EXISTS (
                        SELECT 1 FROM {DB}.CONFIG.ACTION_STATE_MAPPING m
                        WHERE m.state_id = b.state_id AND m.domain_id = b.domain AND m.active = TRUE)
                    THEN 'RETENTION'
                  WHEN b.severity < 3 AND EXISTS (
                        SELECT 1
                        FROM {DB}.CONFIG.PRODUCT_CATALOG pc
                        JOIN {DB}.CONFIG.PRODUCT_RULE pr
                          ON pr.product_id = pc.product_id AND pr.active = TRUE
                        JOIN {DB}.APP.V_ALL_SIGNALS s
                          ON s.customer_id = b.customer_id
                         AND s.signal_name = pr.signal_name AND s.signal_value = pr.match_value
                        WHERE pc.active = TRUE AND pc.domain_id = b.domain
                          AND b.age BETWEEN pc.min_age AND pc.max_age
                          AND (pc.segment_fit IS NULL OR pc.segment_fit = b.segment))
                    THEN 'OPPORTUNITY'
                  ELSE NULL
                END AS feed_type
            FROM base b
        )
        SELECT customer_id, full_name, domain, state_name, severity,
               relationship_value, feed_type,
               COUNT(*) OVER () AS eligible_total
        FROM tagged
        WHERE feed_type IS NOT NULL
        ORDER BY IFF(feed_type = 'RETENTION', 0, 1),
                 severity DESC,
                 COALESCE(relationship_value, 0) DESC,
                 customer_id
        LIMIT {limit}
    """).collect()

    eligible_total = int(candidates[0]["ELIGIBLE_TOTAL"]) if candidates else 0

    rows = []
    for c in candidates:
        cid, name, dom = c["CUSTOMER_ID"], c["FULL_NAME"], c["DOMAIN"]
        severity = int(c["SEVERITY"] or 0)
        state, rv, ftype = c["STATE_NAME"], c["RELATIONSHIP_VALUE"], c["FEED_TYPE"]

        if ftype == 'RETENTION':
            top = session.sql(f"""
                SELECT * FROM TABLE({DB}.APP.RECOMMEND({_lit(cid)}, {_lit(p_persona)}, 0::FLOAT))
                ORDER BY ranking LIMIT 1
            """).collect()
            if top:
                a = top[0]
                rows.append((cid, name, dom, 'RETENTION', state, severity, rv,
                             a["ACTION_NAME"], float(a["SCORE"]),
                             f"{a['EFFECTIVENESS_RATE']*100:.0f}% track record, n={a['SAMPLE_SIZE']}",
                             eligible_total))
        else:
            prod = session.sql(f"""
                SELECT * FROM TABLE({DB}.APP.RECOMMEND_PRODUCT({_lit(cid)}))
                WHERE NOT suppressed ORDER BY ranking LIMIT 1
            """).collect()
            if prod:
                p = prod[0]
                rows.append((cid, name, dom, 'OPPORTUNITY', state, severity, rv,
                             p["PRODUCT_NAME"], float(p["SCORE"]), p["MATCH_REASONS"],
                             eligible_total))

    return session.create_dataframe(rows, schema=OUT_SCHEMA)
$$;

GRANT USAGE ON PROCEDURE UNIFIED_FEED_TOP(VARCHAR, VARCHAR, VARCHAR, VARCHAR, FLOAT) TO ROLE C360_JUDGE;

SELECT 'Fast unified feed deployed (UNIFIED_FEED left intact)' AS status;
