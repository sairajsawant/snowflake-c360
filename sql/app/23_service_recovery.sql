-- =============================================================================
-- 23_service_recovery.sql — use case #3: "what do we owe this customer?"
--
-- THIS FILE IS THE POINT OF THE PLATFORM. Everything below is CONFIG ROWS.
-- There is no new scoring function, no new effectiveness table, no new chat
-- tool and no new Agent registration — APP.RECOMMEND_GENERIC, built in file
-- 19, already serves any SIGNAL_MATCHED domain. Onboarding a third decision
-- engine is four inserts, exactly as docs/bootstrap-new-usecase-skill.md says.
--
-- WHY THIS USE CASE
-- The signal taxonomy has three categories. Two had engines; SERVICE had none:
--   RISK        -> churn & retention      (APP.RECOMMEND)
--   OPPORTUNITY -> product personalization (APP.RECOMMEND_PRODUCT)
--   SERVICE     -> nothing
--
-- The SERVICE signals were populated and fed the churn rules only to raise
-- severity. Nothing ever acted on a service failure AS a service failure, and
-- measured on live data that produced two real defects:
--
--   1. INS-1001, INS-1017, INS-1019 each have unresolved_claim=1 but sit at
--      severity 2, so they appeared on NO feed at all. An unresolved claim is
--      the most damaging open item in health insurance and nobody was working
--      them.
--   2. LND-2004 and LND-2006 have csat_low=MEDIUM — customers we measurably
--      let down — and the platform's recommendation for both was "Top-up
--      Loan". We were upselling people we had just failed. Cross-domain
--      suppression didn't catch it because that only fires at severity >= 3.
--
-- Service recovery is a genuinely different question from the other two:
--   churn asks "will they leave", personalization asks "what can we sell",
--   service recovery asks "what do we owe them".
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- Re-runnable: clear this domain's config, then re-seed it.
DELETE FROM CONFIG.DECISION_RULE      WHERE decision_domain_id = 'service_recovery';
DELETE FROM CONFIG.DECISION_CANDIDATE WHERE decision_domain_id = 'service_recovery';
DELETE FROM CONFIG.DECISION_DOMAIN    WHERE decision_domain_id = 'service_recovery';

-- 1 ── register the domain ────────────────────────────────────────────────────
INSERT INTO CONFIG.DECISION_DOMAIN
    (decision_domain_id, label, entity_type, eligibility_mode, implementation,
     legacy_function_name, description)
SELECT 'service_recovery', 'Service Recovery', 'CUSTOMER',
       'SIGNAL_MATCHED', 'GENERIC', NULL,
       'Makes good on operational failures we caused — unresolved claims, repeat '
       || 'tickets, SLA breaches and low satisfaction. Distinct from retention '
       || '(will they leave) and personalization (what can we sell).';

-- 2 ── the candidates: what we can actually offer a let-down customer ─────────
INSERT INTO CONFIG.DECISION_CANDIDATE
    (candidate_id, decision_domain_id, business_domain_id, candidate_name,
     candidate_type, description, default_cost, requires_approval, approval_threshold, active)
SELECT 'svc_claim_expedite', 'service_recovery', 'insurance',
       'Expedite the claim with the TPA', 'claims',
       'Push the stuck claim to the top of the TPA queue and commit to a decision date.',
       2000, FALSE, 0, TRUE
UNION ALL SELECT 'svc_claims_manager', 'service_recovery', 'insurance',
       'Assign a dedicated claims manager', 'service',
       'One named person owns every open item end to end, so the customer stops re-explaining.',
       6000, FALSE, 0, TRUE
UNION ALL SELECT 'svc_ncb_protect', 'service_recovery', 'insurance',
       'Apology with no-claim bonus protection', 'goodwill',
       'Written apology plus protection of accrued no-claim bonus at next renewal.',
       9000, FALSE, 0, TRUE
UNION ALL SELECT 'svc_fee_waiver', 'service_recovery', NULL,
       'Waive the processing fee', 'goodwill',
       'Waive the servicing or processing charge on the affected request.',
       3500, FALSE, 0, TRUE
UNION ALL SELECT 'svc_priority_callback', 'service_recovery', NULL,
       'Priority callback from a senior advisor', 'service',
       'A senior advisor calls back within one working day to close the loop personally.',
       1200, FALSE, 0, TRUE;

-- 3 ── the rules: which service signals point at which remedy, and how hard ───
INSERT INTO CONFIG.DECISION_RULE
    (rule_id, decision_domain_id, candidate_id, match_type, match_key, match_value, weight, active)
SELECT 'svc_r01','service_recovery','svc_claim_expedite','SIGNAL','unresolved_claim','1',1.0,TRUE
UNION ALL SELECT 'svc_r02','service_recovery','svc_claim_expedite','SIGNAL','claim_friction','HIGH',0.6,TRUE
UNION ALL SELECT 'svc_r03','service_recovery','svc_claims_manager','SIGNAL','service_failure','HIGH',0.8,TRUE
UNION ALL SELECT 'svc_r04','service_recovery','svc_claims_manager','SIGNAL','ticket_reopen','HIGH',0.5,TRUE
UNION ALL SELECT 'svc_r05','service_recovery','svc_claims_manager','SIGNAL','unresolved_claim','1',0.4,TRUE
UNION ALL SELECT 'svc_r06','service_recovery','svc_ncb_protect','SIGNAL','service_failure','HIGH',0.5,TRUE
UNION ALL SELECT 'svc_r07','service_recovery','svc_ncb_protect','SIGNAL','unresolved_claim','1',0.3,TRUE
UNION ALL SELECT 'svc_r08','service_recovery','svc_fee_waiver','SIGNAL','service_failure','MEDIUM',0.4,TRUE
UNION ALL SELECT 'svc_r09','service_recovery','svc_fee_waiver','SIGNAL','ticket_reopen','MEDIUM',0.3,TRUE
UNION ALL SELECT 'svc_r10','service_recovery','svc_fee_waiver','SIGNAL','csat_low','MEDIUM',0.3,TRUE
UNION ALL SELECT 'svc_r11','service_recovery','svc_priority_callback','SIGNAL','csat_low','MEDIUM',0.35,TRUE
UNION ALL SELECT 'svc_r12','service_recovery','svc_priority_callback','SIGNAL','csat_low','HIGH',0.5,TRUE
UNION ALL SELECT 'svc_r13','service_recovery','svc_priority_callback','SIGNAL','service_failure','MEDIUM',0.3,TRUE
UNION ALL SELECT 'svc_r14','service_recovery','svc_priority_callback','SIGNAL','ticket_reopen','MEDIUM',0.2,TRUE;

-- 4 ── the suppression message in RECOMMEND_GENERIC was written when the only
--      generic domain was product personalization, so it says "before any
--      upsell". With a second generic domain that wording would be wrong.
--      Same logic, domain-neutral wording.
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
                 || ' — the retention action takes priority here'
            ELSE NULL END AS suppression_reason
FROM eligible e
JOIN scored s ON s.candidate_id = e.candidate_id
LEFT JOIN ENGINE.DECISION_EFFECTIVENESS eff
  ON eff.decision_domain_id = P_DECISION_DOMAIN_ID AND eff.candidate_id = e.candidate_id
ORDER BY s.score DESC, e.candidate_id
$$;

GRANT USAGE ON FUNCTION APP.RECOMMEND_GENERIC(VARCHAR, VARCHAR) TO ROLE C360_JUDGE;

SELECT 'Service Recovery registered — config only' AS status,
       (SELECT COUNT(*) FROM CONFIG.DECISION_CANDIDATE WHERE decision_domain_id='service_recovery') AS candidates,
       (SELECT COUNT(*) FROM CONFIG.DECISION_RULE WHERE decision_domain_id='service_recovery') AS rules;
