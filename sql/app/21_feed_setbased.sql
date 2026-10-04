-- =============================================================================
-- 21_feed_setbased.sql — the feed computed in ONE SQL statement, no loop.
--
-- ADDITIVE. UNIFIED_FEED and UNIFIED_FEED_TOP both stay; this is a third
-- object, so reverting is a one-line change in the UI.
--
-- WHY THIS EXISTS
-- Limiting the loop to the top 12 (file 20) cut the work by 60% but still took
-- ~47s, because the cost was never the scoring maths — it was 12 sequential
-- round-trips inside a Snowpark procedure, ~4s each. Capping the list harder
-- would only trade coverage for speed.
--
-- The actual fix is to stop looping. Both engines' scoring is pure relational
-- maths over config tables, so the per-customer calls collapse into one
-- set-based statement by turning each engine's per-customer normalisation
-- window, `MAX(...) OVER ()`, into `MAX(...) OVER (PARTITION BY customer_id)`
-- and picking each customer's top row with QUALIFY. Same arithmetic, same
-- inputs, every customer at once — one query instead of twelve.
--
-- This reproduces APP.RECOMMEND (at offer = 0, which is what a feed shows)
-- and APP.RECOMMEND_PRODUCT exactly; verified by diffing this function's
-- output against the loop-based UNIFIED_FEED_TOP row for row. Both originals
-- remain the single source of truth for a single customer — this is a
-- read-optimised projection of them for the list view, not a competing
-- implementation of the rules.
--
-- One deliberate difference: ties are broken by action_id / product_id so the
-- feed is deterministic. APP.RECOMMEND ranks on score alone, so an exact tie
-- there is arbitrary; making it stable here is a strict improvement.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

CREATE OR REPLACE FUNCTION UNIFIED_FEED_FAST(
    P_SCOPE VARCHAR, P_USER VARCHAR, P_TEAM VARCHAR, P_PERSONA VARCHAR, P_LIMIT FLOAT
)
RETURNS TABLE (CUSTOMER_ID VARCHAR, FULL_NAME VARCHAR, DOMAIN VARCHAR, FEED_TYPE VARCHAR,
    STATE_NAME VARCHAR, SEVERITY NUMBER, RELATIONSHIP_VALUE FLOAT,
    HEADLINE VARCHAR, SCORE FLOAT, DETAIL VARCHAR, ELIGIBLE_TOTAL NUMBER)
AS
$$
WITH scope AS (
    SELECT c.customer_id, c.full_name, c.domain, c.segment,
           DATEDIFF(year, c.date_of_birth, CURRENT_DATE()) AS age,
           cs.state_id, cs.state_name, COALESCE(cs.severity, 0) AS severity
    FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER c
    LEFT JOIN CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
      ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
    LEFT JOIN CUSTOMER_360_DB.CONFIG.CUSTOMER_ASSIGNMENT ca
      ON ca.customer_id = c.customer_id AND ca.domain = c.domain
    WHERE P_SCOPE = 'ALL'
       OR (P_SCOPE = 'ASSIGNED' AND ca.assigned_user = P_USER)
       OR (P_SCOPE = 'TEAM' AND ca.assigned_team = P_TEAM)
),
-- ── retention branch: APP.RECOMMEND's maths, partitioned by customer ────────
ret_ctx AS (
    SELECT s.customer_id, s.full_name, s.domain, s.state_id, s.state_name, s.severity,
           rv.relationship_value, cc.cost_ceiling
    FROM scope s
    JOIN CUSTOMER_360_DB.APP.V_RELATIONSHIP_VALUE rv
      ON rv.customer_id = s.customer_id AND rv.domain = s.domain
    JOIN CUSTOMER_360_DB.APP.V_COST_CEILING cc ON cc.domain_id = s.domain
    WHERE s.severity >= 3
),
ret_cand AS (
    SELECT c.customer_id, c.full_name, c.domain, c.state_name, c.severity,
           c.relationship_value, c.cost_ceiling,
           ad.action_id, ad.action_name,
           COALESCE(ae.success_rate, 0.30) AS eff_rate,
           COALESCE(ae.total_count, 0)     AS sample_size,
           COALESCE(ae.avg_uplift, 0.05)   AS uplift,
           COALESCE(ae.confidence, 0.40)   AS conf,
           ad.default_cost                 AS total_cost   -- feed shows offer = 0
    FROM ret_ctx c
    JOIN CUSTOMER_360_DB.CONFIG.ACTION_STATE_MAPPING asm
      ON asm.state_id = c.state_id AND asm.domain_id = c.domain AND asm.active = TRUE
    JOIN CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION ad
      ON ad.action_id = asm.action_id AND ad.active = TRUE
    LEFT JOIN CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS ae
      ON ae.action_id = ad.action_id AND ae.state_id = c.state_id AND ae.domain_id = c.domain
),
ret_norm AS (
    SELECT r.*,
        r.uplift / NULLIF(MAX(r.uplift) OVER (PARTITION BY r.customer_id), 0) AS un,
        (r.relationship_value * r.eff_rate * r.uplift)
          / NULLIF(MAX(r.relationship_value * r.eff_rate * r.uplift)
                   OVER (PARTITION BY r.customer_id), 0) AS vn,
        r.total_cost / NULLIF(r.cost_ceiling, 0) AS cn
    FROM ret_cand r
),
ret_top AS (
    SELECT n.customer_id, n.full_name, n.domain, n.state_name, n.severity,
           n.relationship_value, n.action_name, n.eff_rate, n.sample_size,
           COALESCE(p.w_uplift, d.w_uplift) * n.un
         + COALESCE(p.w_value,  d.w_value)  * n.vn
         + COALESCE(p.w_cost,   d.w_cost)   * n.cn
         + COALESCE(p.w_conf,   d.w_conf)   * n.conf AS score
    FROM ret_norm n
    LEFT JOIN CUSTOMER_360_DB.APP.V_SCORING p
           ON p.domain_id = n.domain AND p.persona = P_PERSONA
    LEFT JOIN CUSTOMER_360_DB.APP.V_SCORING d
           ON d.domain_id = n.domain AND d.persona = 'default'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY n.customer_id
                               ORDER BY score DESC, n.action_id) = 1
),
-- ── opportunity branch: APP.RECOMMEND_PRODUCT's maths, partitioned ──────────
opp_match AS (
    SELECT s.customer_id, s.full_name, s.domain, s.state_name, s.severity,
           pc.product_id, pc.product_name,
           SUM(pr.weight) AS score,
           LISTAGG(DISTINCT pr.signal_name || '=' || pr.match_value, ', ')
             WITHIN GROUP (ORDER BY pr.signal_name || '=' || pr.match_value) AS match_reasons
    FROM scope s
    JOIN CUSTOMER_360_DB.CONFIG.PRODUCT_CATALOG pc
      ON pc.active = TRUE AND pc.domain_id = s.domain
     AND s.age BETWEEN pc.min_age AND pc.max_age
     AND (pc.segment_fit IS NULL OR pc.segment_fit = s.segment)
    JOIN CUSTOMER_360_DB.CONFIG.PRODUCT_RULE pr
      ON pr.product_id = pc.product_id AND pr.active = TRUE
    -- SIGNAL_SNAPSHOT is the materialised form of V_ALL_SIGNALS (see file 22).
    -- Identical contents, refreshed on the same 1-minute cadence as the rest of
    -- the pipeline; reading the view directly here cost ~10s per feed load.
    JOIN CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT sig
      ON sig.customer_id = s.customer_id
     AND sig.signal_name = pr.signal_name AND sig.signal_value = pr.match_value
    WHERE s.severity < 3          -- severity >= 3 is suppressed by the product engine
    GROUP BY s.customer_id, s.full_name, s.domain, s.state_name, s.severity,
             pc.product_id, pc.product_name
),
-- ── service-recovery branch: the generic engine's config, read set-based ───
-- Registered entirely as CONFIG rows (see file 23) — this reads the same
-- DECISION_CANDIDATE / DECISION_RULE tables APP.RECOMMEND_GENERIC uses, so
-- the feed and the engine cannot disagree. A customer we failed outranks a
-- customer we could sell to: service is placed above opportunity below.
svc_match AS (
    SELECT s.customer_id, s.full_name, s.domain, s.state_name, s.severity,
           dc.candidate_id, dc.candidate_name,
           SUM(dr.weight) AS score,
           LISTAGG(DISTINCT dr.match_key || '=' || dr.match_value, ', ')
             WITHIN GROUP (ORDER BY dr.match_key || '=' || dr.match_value) AS match_reasons
    FROM scope s
    JOIN CUSTOMER_360_DB.CONFIG.DECISION_CANDIDATE dc
      ON dc.decision_domain_id = 'service_recovery' AND dc.active = TRUE
     AND (dc.business_domain_id IS NULL OR dc.business_domain_id = s.domain)
     AND (dc.min_age IS NULL OR s.age >= dc.min_age)
     AND (dc.max_age IS NULL OR s.age <= dc.max_age)
     AND (dc.segment_fit IS NULL OR dc.segment_fit = s.segment)
    JOIN CUSTOMER_360_DB.CONFIG.DECISION_RULE dr
      ON dr.decision_domain_id = 'service_recovery' AND dr.candidate_id = dc.candidate_id
     AND dr.match_type = 'SIGNAL' AND dr.active = TRUE
    JOIN CUSTOMER_360_DB.APP.SIGNAL_SNAPSHOT sig
      ON sig.customer_id = s.customer_id
     AND sig.signal_name = dr.match_key AND sig.signal_value = dr.match_value
    WHERE s.severity < 3          -- at severity >= 3 the retention action leads
    GROUP BY s.customer_id, s.full_name, s.domain, s.state_name, s.severity,
             dc.candidate_id, dc.candidate_name
),
svc_top AS (
    SELECT m.*, rv.relationship_value
    FROM svc_match m
    LEFT JOIN CUSTOMER_360_DB.APP.V_RELATIONSHIP_VALUE rv
      ON rv.customer_id = m.customer_id AND rv.domain = m.domain
    QUALIFY ROW_NUMBER() OVER (PARTITION BY m.customer_id
                               ORDER BY m.score DESC, m.candidate_id) = 1
),
opp_top AS (
    SELECT m.*, rv.relationship_value
    FROM opp_match m
    LEFT JOIN CUSTOMER_360_DB.APP.V_RELATIONSHIP_VALUE rv
      ON rv.customer_id = m.customer_id AND rv.domain = m.domain
    -- never offer a product to someone we owe a service remedy
    WHERE m.customer_id NOT IN (SELECT customer_id FROM svc_top)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY m.customer_id
                               ORDER BY m.score DESC, m.product_id) = 1
),
feed AS (
    SELECT customer_id, full_name, domain, 'RETENTION' AS feed_type, state_name, severity,
           relationship_value, action_name AS headline, ROUND(score, 4) AS score,
           ROUND(eff_rate * 100) || '% track record, n=' || sample_size AS detail
    FROM ret_top
    UNION ALL
    SELECT customer_id, full_name, domain, 'SERVICE', state_name, severity,
           relationship_value, candidate_name, ROUND(score, 4), match_reasons
    FROM svc_top
    UNION ALL
    SELECT customer_id, full_name, domain, 'OPPORTUNITY', state_name, severity,
           relationship_value, product_name, ROUND(score, 4), match_reasons
    FROM opp_top
)
SELECT customer_id, full_name, domain, feed_type, state_name, severity,
       relationship_value, headline, score, detail,
       COUNT(*) OVER () AS eligible_total
FROM feed
QUALIFY ROW_NUMBER() OVER (
    ORDER BY CASE feed_type WHEN 'RETENTION' THEN 0 WHEN 'SERVICE' THEN 1 ELSE 2 END,
             severity DESC, COALESCE(relationship_value, 0) DESC, customer_id
) <= P_LIMIT
ORDER BY CASE feed_type WHEN 'RETENTION' THEN 0 WHEN 'SERVICE' THEN 1 ELSE 2 END,
         severity DESC, COALESCE(relationship_value, 0) DESC, customer_id
$$;

GRANT USAGE ON FUNCTION UNIFIED_FEED_FAST(VARCHAR, VARCHAR, VARCHAR, VARCHAR, FLOAT) TO ROLE C360_JUDGE;

SELECT 'Set-based unified feed deployed' AS status;
