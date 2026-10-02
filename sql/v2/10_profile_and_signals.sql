-- =============================================================================
-- Customer profile + deterministic signals from the new sources.
--
-- The brief was: unstructured signals -> customer profile -> next action ->
-- feedback loop, and keep it deterministic. So of the nine new signals below,
-- eight are pure SQL over observable facts (a grievance was filed; a renewal
-- was 4 days late; three tickets breached SLA). Only email tone needs a model,
-- and even that is bounded by a JSON schema.
--
-- Each source contributes something the others cannot:
--   grievance        regulatory exposure      — the strongest single predictor
--   portability      competitive intent       — an act, not an inference
--   service_failure  operational failure      — SLA breaches we caused
--   ticket_reopen    unresolved friction      — we said fixed, it wasn't
--   csat             stated satisfaction      — cheap, direct
--   renewal_lateness payment intent           — leading indicator of lapse
--   coverage_change  product disengagement    — downgrades precede exit
--   claim_friction   moment-of-truth failure  — where insurers actually lose
--   group_exposure   decision-maker leverage  — HR owns the renewal
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP_V2;

-- ─── The profile: one row per customer, everything the engine reasons over ──
CREATE OR REPLACE VIEW V_CUSTOMER_PROFILE AS
WITH tickets AS (
    SELECT customer_id,
        COUNT(*)                                                  AS tickets_total,
        COUNT_IF(opened_at >= DATEADD(day,-90,CURRENT_TIMESTAMP())) AS tickets_90d,
        COUNT_IF(status = 'OPEN')                                 AS tickets_open,
        COUNT_IF(sla_breached)                                    AS sla_breaches,
        COUNT_IF(sla_breached AND opened_at >= DATEADD(day,-90,CURRENT_TIMESTAMP())) AS sla_breaches_90d,
        SUM(reopen_count)                                         AS reopens,
        AVG(csat_score)                                           AS csat_avg,
        MIN(csat_score)                                           AS csat_min,
        MAX(opened_at)                                            AS last_ticket_at
    FROM CUSTOMER_360_DB.RAW.SUPPORT_TICKET GROUP BY customer_id
),
mail AS (
    SELECT customer_id,
        COUNT(*)                        AS email_messages,
        COUNT(DISTINCT ticket_id)       AS email_threads,
        COUNT_IF(direction = 'INBOUND') AS emails_from_customer,
        MAX(sent_at)                    AS last_email_at
    FROM CUSTOMER_360_DB.RAW.EMAIL_MESSAGE GROUP BY customer_id
),
renew AS (
    -- Take the LATEST version per policy first, then aggregate across policies.
    -- Aggregating straight over every version picks one policy arbitrarily, so a
    -- customer with health + motor cover reports whichever renewed last.
    SELECT customer_id,
        COUNT(*)                        AS policy_count,
        SUM(policy_versions)            AS policy_versions,
        MAX(versions)                   AS tenure_renewals,
        SUM(late_renewals)              AS late_renewals,
        SUM(lapsed_renewals)            AS lapsed_renewals,
        SUM(upgrades)                   AS upgrades,
        SUM(downgrades)                 AS downgrades,
        MAX(peak_ncb)                   AS peak_ncb,
        MAX(latest_ncb)                 AS current_ncb,
        MAX(latest_days_late)           AS last_renewal_days_late,
        SUM(latest_premium)             AS current_premium,
        SUM(earliest_premium)           AS first_premium,
        SUM(latest_cover)               AS current_cover,
        MIN(first_date)                 AS first_cover_date
    FROM (
        SELECT customer_id, policy_id,
            COUNT(*)                                   AS policy_versions,
            MAX(version_no)                            AS versions,
            COUNT_IF(renewal_status = 'LATE')          AS late_renewals,
            COUNT_IF(renewal_status = 'LAPSED')        AS lapsed_renewals,
            COUNT_IF(change_type = 'UPGRADE')          AS upgrades,
            COUNT_IF(change_type = 'DOWNGRADE')        AS downgrades,
            MAX(no_claim_bonus_pct)                    AS peak_ncb,
            MAX_BY(no_claim_bonus_pct, version_no)     AS latest_ncb,
            MAX_BY(days_late, version_no)              AS latest_days_late,
            MAX_BY(premium, version_no)                AS latest_premium,
            MIN_BY(premium, version_no)                AS earliest_premium,
            MAX_BY(sum_insured, version_no)            AS latest_cover,
            MIN(effective_from)                        AS first_date
        FROM CUSTOMER_360_DB.RAW.POLICY_VERSION GROUP BY customer_id, policy_id
    ) GROUP BY customer_id
),
grv AS (
    SELECT customer_id, COUNT(*) AS grievances,
           COUNT_IF(status IN ('REGISTERED','UNDER_REVIEW','ESCALATED')) AS grievances_open,
           COUNT_IF(escalated_to_ombudsman) AS ombudsman_cases,
           MAX(filed_date) AS last_grievance_date
    FROM CUSTOMER_360_DB.RAW.GRIEVANCE GROUP BY customer_id
),
port AS (
    SELECT customer_id, COUNT(*) AS portability_requests,
           MAX_BY(stage, requested_date)          AS portability_stage,
           MAX_BY(target_insurer, requested_date) AS portability_target,
           MAX_BY(quoted_premium, requested_date) AS competitor_quote,
           MAX_BY(current_premium, requested_date) AS our_premium,
           MAX(requested_date)                    AS last_portability_date
    FROM CUSTOMER_360_DB.RAW.PORTABILITY_REQUEST GROUP BY customer_id
),
grp AS (
    SELECT m.customer_id, e.employer_id, e.employer_name, e.employee_count,
           e.hr_contact_name, e.hr_contact_email, e.annual_premium AS group_premium,
           e.renewal_date AS group_renewal_date, e.broker_name, m.member_role
    FROM CUSTOMER_360_DB.RAW.EMPLOYER_MEMBER m
    JOIN CUSTOMER_360_DB.RAW.EMPLOYER e ON e.employer_id = m.employer_id
),
clm AS (
    SELECT customer_id, COUNT(*) AS claims_total,
           COUNT_IF(claim_status IN ('PENDING','PRIORITY')) AS claims_open,
           COUNT_IF(claim_status = 'REJECTED')              AS claims_rejected,
           SUM(claim_amount)                                AS claims_value,
           -- age of the oldest OPEN claim only — a long-settled claim is history,
           -- not friction, and must not count toward the claim_friction signal
           MAX(CASE WHEN claim_status IN ('PENDING','PRIORITY')
                    THEN DATEDIFF(day, filed_date, CURRENT_DATE()) END) AS oldest_claim_age_days
    FROM CUSTOMER_360_DB.RAW.INSURANCE_CLAIMS GROUP BY customer_id
)
SELECT c.customer_id, c.full_name, c.domain, c.segment, c.region,
       c.customer_since, DATEDIFF(year, c.customer_since, CURRENT_DATE()) AS tenure_years,
       rv.relationship_value,
       cs.state_name, cs.severity,
       t.tickets_total, t.tickets_90d, t.tickets_open, t.sla_breaches, t.sla_breaches_90d,
       t.reopens, t.csat_avg, t.csat_min, t.last_ticket_at,
       m.email_messages, m.email_threads, m.emails_from_customer, m.last_email_at,
       r.policy_count, r.tenure_renewals, r.late_renewals, r.lapsed_renewals, r.upgrades, r.downgrades,
       r.peak_ncb, r.current_ncb, r.last_renewal_days_late,
       r.first_premium, r.current_premium, r.current_cover, r.first_cover_date,
       g.grievances, g.grievances_open, g.ombudsman_cases, g.last_grievance_date,
       p.portability_requests, p.portability_stage, p.portability_target,
       p.competitor_quote, p.our_premium,
       CASE WHEN p.competitor_quote IS NOT NULL AND p.our_premium > 0
            THEN ROUND((1 - p.competitor_quote / p.our_premium) * 100, 1) END AS competitor_discount_pct,
       e.employer_id, e.employer_name, e.employee_count, e.hr_contact_name,
       e.hr_contact_email, e.group_premium, e.group_renewal_date, e.broker_name, e.member_role,
       cl.claims_total, cl.claims_open, cl.claims_rejected, cl.claims_value,
       cl.oldest_claim_age_days
FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER c
LEFT JOIN CUSTOMER_360_DB.APP_V2.V_RELATIONSHIP_VALUE rv
       ON rv.customer_id = c.customer_id AND rv.domain = c.domain
LEFT JOIN CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE cs
       ON cs.customer_id = c.customer_id AND cs.is_current = TRUE
LEFT JOIN tickets t ON t.customer_id = c.customer_id
LEFT JOIN mail    m ON m.customer_id = c.customer_id
LEFT JOIN renew   r ON r.customer_id = c.customer_id
LEFT JOIN grv     g ON g.customer_id = c.customer_id
LEFT JOIN port    p ON p.customer_id = c.customer_id
LEFT JOIN grp     e ON e.customer_id = c.customer_id
LEFT JOIN clm    cl ON cl.customer_id = c.customer_id;


-- ─── Deterministic signals, computed straight from the profile ──────────────
-- No model, no sampling: these are facts with thresholds, so the same inputs
-- always produce the same signal values.
CREATE OR REPLACE VIEW V_DERIVED_SIGNALS AS
SELECT customer_id, domain, signal_name, signal_value, numeric_value,
       confidence, evidence_ref
FROM (
    SELECT customer_id, domain, 'grievance_filed' AS signal_name,
           CASE WHEN grievances_open > 0 THEN 'HIGH'
                WHEN grievances > 0 THEN 'MEDIUM' ELSE 'NONE' END AS signal_value,
           COALESCE(grievances_open, 0)::FLOAT AS numeric_value,
           1.0 AS confidence,
           'grievance:' || COALESCE(last_grievance_date::VARCHAR,'none') AS evidence_ref
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'portability_intent',
           CASE WHEN portability_stage IN ('FORM_REQUESTED','SUBMITTED') THEN 'HIGH'
                WHEN portability_stage = 'ENQUIRY' THEN 'MEDIUM' ELSE 'NONE' END,
           COALESCE(portability_requests,0)::FLOAT, 1.0,
           'portability:' || COALESCE(portability_target,'none')
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'service_failure',
           CASE WHEN sla_breaches_90d >= 3 THEN 'HIGH'
                WHEN sla_breaches_90d >= 1 THEN 'MEDIUM' ELSE 'NONE' END,
           COALESCE(sla_breaches_90d,0)::FLOAT, 1.0,
           'tickets:sla_breach_90d'
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'ticket_reopen',
           CASE WHEN reopens >= 3 THEN 'HIGH'
                WHEN reopens >= 1 THEN 'MEDIUM' ELSE 'NONE' END,
           COALESCE(reopens,0)::FLOAT, 1.0, 'tickets:reopen_count'
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'csat_low',
           CASE WHEN csat_min <= 2 THEN 'HIGH'
                WHEN csat_avg < 3.5 THEN 'MEDIUM' ELSE 'NONE' END,
           COALESCE(csat_avg, 0)::FLOAT, 0.9, 'tickets:csat'
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'renewal_lateness',
           CASE WHEN lapsed_renewals > 0 OR last_renewal_days_late >= 15 THEN 'HIGH'
                WHEN last_renewal_days_late > 0 THEN 'MEDIUM' ELSE 'NONE' END,
           COALESCE(last_renewal_days_late,0)::FLOAT, 1.0, 'policy_version:renewal_status'
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'coverage_downgrade',
           CASE WHEN downgrades > 0 THEN 'HIGH' ELSE 'NONE' END,
           COALESCE(downgrades,0)::FLOAT, 1.0, 'policy_version:change_type'
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'claim_friction',
           CASE WHEN claims_rejected > 0 OR oldest_claim_age_days > 30 THEN 'HIGH'
                WHEN claims_open > 0 THEN 'MEDIUM' ELSE 'NONE' END,
           COALESCE(claims_open,0)::FLOAT, 1.0, 'claims:age_and_status'
    FROM V_CUSTOMER_PROFILE
    UNION ALL
    SELECT customer_id, domain, 'group_exposure',
           CASE WHEN employee_count >= 150 THEN 'HIGH'
                WHEN employee_count >= 50 THEN 'MEDIUM'
                WHEN employee_count IS NOT NULL THEN 'LOW' ELSE 'NONE' END,
           COALESCE(employee_count,0)::FLOAT, 1.0,
           'employer:' || COALESCE(employer_name,'none')
    FROM V_CUSTOMER_PROFILE
)
WHERE signal_value <> 'NONE';


-- Register the new signals so they appear in config exactly like the originals.
DELETE FROM CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION WHERE signal_id LIKE 'ins_v2_%';
INSERT INTO CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION
    (signal_id, domain_id, signal_name, signal_type, extraction_method,
     extraction_prompt, source_table, weight, active, created_at)
VALUES
 ('ins_v2_grievance','insurance','grievance_filed','regulatory','SQL',NULL,'RAW.GRIEVANCE',0.35,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_portability','insurance','portability_intent','competitive','SQL',NULL,'RAW.PORTABILITY_REQUEST',0.30,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_service','insurance','service_failure','operational','SQL',NULL,'RAW.SUPPORT_TICKET',0.20,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_reopen','insurance','ticket_reopen','operational','SQL',NULL,'RAW.SUPPORT_TICKET',0.15,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_csat','insurance','csat_low','satisfaction','SQL',NULL,'RAW.SUPPORT_TICKET',0.15,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_renewal','insurance','renewal_lateness','financial','SQL',NULL,'RAW.POLICY_VERSION',0.25,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_downgrade','insurance','coverage_downgrade','product','SQL',NULL,'RAW.POLICY_VERSION',0.20,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_claimfric','insurance','claim_friction','operational','SQL',NULL,'RAW.INSURANCE_CLAIMS',0.25,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_group','insurance','group_exposure','relationship','SQL',NULL,'RAW.EMPLOYER',0.30,TRUE,CURRENT_TIMESTAMP()),
 ('ins_v2_emailtone','insurance','email_escalation','behavioural','INTENT',
  'Read this email thread between a customer and their insurer. Judge how far the customer has escalated: NONE if routine, LOW if a simple request, MEDIUM if dissatisfied, HIGH if they threaten to leave, invoke a regulator, or demand written justification. Quote the sentence that most supports your answer.',
  'RAW.EMAIL_MESSAGE',0.25,TRUE,CURRENT_TIMESTAMP());

SELECT 'Profile and derived signals created' AS status;
