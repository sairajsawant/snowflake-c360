-- =============================================================================
-- 17_personalization.sql — first-buy/renewal personalization, reusing the
-- same deterministic-scoring shape as the churn engine's RECOMMEND, not a
-- new paradigm.
--
-- Guardrail, deliberately: AI_COMPLETE appears exactly once in this file,
-- in EXTRACT_PRODUCT_INTEREST, and its output is constrained to a FIXED,
-- pre-approved vocabulary (the same 10 tags CONFIG.PRODUCT_RULE scores
-- against) — the model classifies into existing categories, it cannot
-- invent a new product or a new reason. The actual recommendation —
-- which product, in what order — comes entirely out of RECOMMEND_PRODUCT,
-- a pure SQL table function with zero AI calls, exactly like APP.RECOMMEND.
-- Same inputs always produce the same ranked output; verified below.
--
-- Deliberately NOT built on CUSTOMER_STATE/COMPUTE_STATE_FOR: that state
-- machine was purpose-built for "something is wrong, escalate" severity
-- tiers. Product fit is a different shape — eligibility + signal match,
-- not escalating severity — so this is a parallel, equally-deterministic
-- engine keyed off CONFIG.PRODUCT_RULE, not a forced reuse of STATE_RULE.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- =============================================================================
-- Product catalog — doesn't exist anywhere in the account yet.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONFIG.PRODUCT_CATALOG (
    product_id       VARCHAR(50) PRIMARY KEY,
    domain_id        VARCHAR(50),
    product_name     VARCHAR(150),
    product_type     VARCHAR(30),   -- RIDER | ADDON | PLAN | LOAN_PRODUCT
    min_age          NUMBER,
    max_age          NUMBER,
    segment_fit      VARCHAR(50),   -- NULL = any segment
    min_amount       FLOAT,         -- premium or loan amount band
    max_amount       FLOAT,
    description      VARCHAR(500),
    terms_text       VARCHAR(2000),
    active           BOOLEAN DEFAULT TRUE,
    created_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

DELETE FROM CONFIG.PRODUCT_CATALOG;
INSERT INTO CONFIG.PRODUCT_CATALOG
    (product_id, domain_id, product_name, product_type, min_age, max_age,
     segment_fit, min_amount, max_amount, description, terms_text)
VALUES
 ('ins_prod_maternity','insurance','Maternity Cover Add-on','RIDER',21,45,NULL,8000,15000,
  'Covers normal and C-section delivery, pre/post-natal care up to 90 days before and after.',
  'Waiting period 24 months from rider start. Covers delivery expenses up to the rider sum insured. Pre-existing pregnancy at the time of purchase is excluded. Newborn is covered automatically for the first 90 days.'),
 ('ins_prod_critical','insurance','Critical Illness Rider','RIDER',25,65,NULL,10000,25000,
  'Lump-sum payout on diagnosis of 15 listed critical illnesses including cancer, stroke, kidney failure.',
  'Survival period of 30 days post-diagnosis required for payout. Waiting period 90 days from rider start for illness-related claims. Lump sum is paid in addition to, not instead of, the base sum insured.'),
 ('ins_prod_senior','insurance','Senior Citizen Wellness Plan','PLAN',60,80,'Senior Citizen',20000,40000,
  'Enhanced cover for customers above 60, includes annual health checkup and home nursing after hospitalisation.',
  'Pre-policy medical checkup mandatory above age 65. Co-payment of 10 percent applies on all claims. Home nursing covered up to 15 days per claim, subject to a treating doctor recommendation.'),
 ('ins_prod_corp_topup','insurance','Corporate Group Top-up Cover','ADDON',18,65,'Corporate Group',5000,12000,
  'Additional individual cover on top of the employer group policy, portable if employment changes.',
  'Top-up sum insured is individual, not pooled with the group limit. Remains in force for 30 days after employment ends, convertible to an individual policy within that window without fresh underwriting.'),
 ('ins_prod_opd','insurance','OPD and Daycare Cover','ADDON',18,70,NULL,3000,6000,
  'Covers outpatient consultations, diagnostics and daycare procedures not requiring 24-hour hospitalisation.',
  'Annual OPD limit as per the selected sum insured. Daycare procedures covered per the insurer list of 150+ procedures. Claims settled by reimbursement only, no cashless OPD network.'),
 ('ins_prod_ncb_protect','insurance','No-Claim Bonus Protector','RIDER',18,70,NULL,1500,3000,
  'Protects the accumulated no-claim bonus percentage even after one claim in a policy year.',
  'Applies to one claim per policy year. NCB is preserved at the pre-claim level at renewal. Does not apply if more than one claim is filed in the same year.'),
 ('lend_prod_topup','lending','Top-up Loan','LOAN_PRODUCT',21,60,NULL,100000,2000000,
  'Additional loan on top of an existing, well-serviced loan, at the same or better rate.',
  'Available after 12 months of clean repayment history on the existing loan. Combined loan-to-value capped at 80 percent of current asset valuation. Processing fee 0.5 percent of top-up amount.'),
 ('lend_prod_ratelock','lending','Rate Lock Renewal','LOAN_PRODUCT',21,65,NULL,0,0,
  'Locks the current interest rate for the next renewal cycle, protecting against rate hikes.',
  'Must be requested within 30 days of the renewal notice. Lock is valid for 12 months. A processing fee applies and is waived for customers with zero late payments in the prior 12 months.'),
 ('lend_prod_emiholiday','lending','EMI Holiday Plan','LOAN_PRODUCT',21,65,NULL,0,0,
  'Defers up to 3 months of EMI, added to the loan tenure, for customers facing temporary hardship.',
  'Maximum 3 months in any 12-month period. Interest continues to accrue during the holiday and is added to the outstanding principal. Available once the loan has completed 6 months of repayment.'),
 ('lend_prod_baltransfer','lending','Balance Transfer — Lower Rate','LOAN_PRODUCT',21,60,NULL,100000,5000000,
  'Transfers an existing high-rate loan to a lower rate, reducing EMI or tenure.',
  'Available for loans with at least 12 months remaining tenure. A processing fee of 1 percent of outstanding balance applies. Foreclosure charges on the original loan, if any, are the customer responsibility.');

-- =============================================================================
-- Cortex Search over product literature — same pattern as APP.INTERACTION_SEARCH.
-- =============================================================================
CREATE OR REPLACE TABLE PRODUCT_DOCUMENT AS
SELECT product_id, domain_id, product_name, product_type,
       description || ' ' || terms_text AS content
FROM CONFIG.PRODUCT_CATALOG WHERE active;

CREATE OR REPLACE CORTEX SEARCH SERVICE PRODUCT_SEARCH
  ON content
  ATTRIBUTES product_id, domain_id, product_name, product_type
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 hour'
  AS (SELECT product_id, domain_id, product_name, product_type, content FROM PRODUCT_DOCUMENT);

-- =============================================================================
-- tenure_segment — deterministic, added to the existing derived-signals view.
-- Full restate: the 11 existing branches plus this one new branch.
-- =============================================================================
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
    UNION ALL
    SELECT customer_id, 'insurance' AS domain, 'renewal_proximity',
           CASE WHEN days_to_next <= 30 THEN 'HIGH'
                WHEN days_to_next <= 60 THEN 'MEDIUM' ELSE 'NONE' END,
           days_to_next::FLOAT, 1.0, 'policy:' || policy_id
    FROM (
        SELECT policy_id, customer_id,
               DATEDIFF(day, CURRENT_DATE(),
                   CASE WHEN anchor >= CURRENT_DATE() THEN anchor
                        ELSE DATEADD(year, 1, anchor) END) AS days_to_next,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY
                   DATEDIFF(day, CURRENT_DATE(),
                       CASE WHEN anchor >= CURRENT_DATE() THEN anchor
                            ELSE DATEADD(year, 1, anchor) END)) AS rn
        FROM (
            SELECT policy_id, customer_id,
                DATE_FROM_PARTS(YEAR(CURRENT_DATE()), MONTH(renewal_date),
                    LEAST(DAY(renewal_date),
                          DAY(LAST_DAY(DATE_FROM_PARTS(YEAR(CURRENT_DATE()), MONTH(renewal_date), 1)))
                    )) AS anchor
            FROM CUSTOMER_360_DB.RAW.INSURANCE_POLICIES
            WHERE policy_status = 'ACTIVE' AND renewal_date IS NOT NULL
        )
    ) WHERE rn = 1
    UNION ALL
    SELECT customer_id, 'insurance', 'payment_irregularity',
           CASE WHEN irregular_count >= 2 THEN 'HIGH'
                WHEN irregular_count = 1 THEN 'MEDIUM' ELSE 'NONE' END,
           irregular_count::FLOAT, 1.0, 'payments:failed_or_pending'
    FROM (
        SELECT customer_id, COUNT(*) AS irregular_count
        FROM CUSTOMER_360_DB.RAW.INSURANCE_PAYMENTS
        WHERE payment_status IN ('FAILED','PENDING')
        GROUP BY customer_id
    )
    UNION ALL
    -- tenure_segment: how long the relationship has run, a timing signal for
    -- which products make sense (new relationship vs long-tenured renewal).
    SELECT customer_id, domain, 'tenure_segment',
           CASE WHEN DATEDIFF(year, customer_since, CURRENT_DATE()) < 3 THEN 'EARLY'
                ELSE 'MATURE' END,
           DATEDIFF(year, customer_since, CURRENT_DATE())::FLOAT, 1.0,
           'customer_since:' || customer_since::VARCHAR
    FROM V_CUSTOMER_PROFILE WHERE customer_since IS NOT NULL
)
WHERE signal_value <> 'NONE';

-- Register the 2 new signals.
DELETE FROM CONFIG.SIGNAL_DEFINITION WHERE signal_id IN ('ins_x_tenure','lend_x_tenure','both_x_product_interest');
INSERT INTO CONFIG.SIGNAL_DEFINITION
    (signal_id, domain_id, signal_name, signal_type, extraction_method,
     extraction_prompt, source_table, weight, active, category, created_at)
SELECT 'ins_x_tenure','insurance','tenure_segment','relationship','SQL',NULL,
       'CANONICAL.CUSTOMER',0.1,TRUE,'OPPORTUNITY',CURRENT_TIMESTAMP()
UNION ALL
SELECT 'lend_x_tenure','lending','tenure_segment','relationship','SQL',NULL,
       'CANONICAL.CUSTOMER',0.1,TRUE,'OPPORTUNITY',CURRENT_TIMESTAMP()
UNION ALL
SELECT 'both_x_product_interest','insurance','product_interest','behavioural','INTENT',
       'Classify what product the customer has expressed interest in across these calls. '
       || 'Pick exactly one tag from this fixed list, or NONE if nothing matches: '
       || 'maternity_cover, critical_illness, senior_wellness, corporate_topup, opd_cover, '
       || 'claim_protection, loan_topup, rate_reduction, payment_relief, balance_transfer. '
       || 'Never invent a tag outside this list.',
       'RAW.INSURANCE_CALL_TRANSCRIPTS + RAW.LENDING_CALL_TRANSCRIPTS',0.3,TRUE,'OPPORTUNITY',CURRENT_TIMESTAMP();

-- =============================================================================
-- EXTRACT_PRODUCT_INTEREST — the ONLY AI_COMPLETE call in this file.
-- Classification into a fixed vocabulary, not generation. Multi-call: reads
-- the customer's recent transcripts, not just one.
-- =============================================================================
CREATE OR REPLACE PROCEDURE EXTRACT_PRODUCT_INTEREST(P_CUSTOMER_ID VARCHAR)
RETURNS OBJECT
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_blob VARCHAR; v_prompt VARCHAR; v_json VARIANT;
    v_val VARCHAR; v_quote VARCHAR; v_conf FLOAT;
    v_sid VARCHAR; v_stamp VARCHAR; v_signal_id VARCHAR;
BEGIN
    SELECT domain INTO :v_dom FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id = :P_CUSTOMER_ID;

    IF (:v_dom = 'insurance') THEN
        SELECT LISTAGG('Call ' || call_date::VARCHAR || ': ' || transcript_text, '\n---\n')
          WITHIN GROUP (ORDER BY call_date DESC)
          INTO :v_blob
        FROM (SELECT * FROM CUSTOMER_360_DB.RAW.INSURANCE_CALL_TRANSCRIPTS
              WHERE customer_id = :P_CUSTOMER_ID ORDER BY call_date DESC LIMIT 5);
        v_signal_id := 'both_x_product_interest';
    ELSE
        SELECT LISTAGG('Call ' || call_date::VARCHAR || ': ' || transcript_text, '\n---\n')
          WITHIN GROUP (ORDER BY call_date DESC)
          INTO :v_blob
        FROM (SELECT * FROM CUSTOMER_360_DB.RAW.LENDING_CALL_TRANSCRIPTS
              WHERE customer_id = :P_CUSTOMER_ID ORDER BY call_date DESC LIMIT 5);
        v_signal_id := 'both_x_product_interest';
    END IF;

    IF (:v_blob IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'NO_TRANSCRIPTS');
    END IF;

    SELECT extraction_prompt INTO :v_prompt
    FROM CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION WHERE signal_id = 'both_x_product_interest';

    SELECT AI_COMPLETE(
        model => 'llama3.3-70b',
        prompt => :v_prompt || '

CALLS (most recent first):
' || :v_blob || '

Return the tag exactly as spelled in the list, or NONE. Quote the single sentence across
all calls that most supports your answer, verbatim. Give confidence between 0 and 1.',
        response_format => {'type':'json','schema':{'type':'object','properties':{
            'value':{'type':'string'},'quote':{'type':'string'},'confidence':{'type':'number'}},
            'required':['value','quote','confidence']}}
    ) INTO :v_json;

    v_val   := LOWER(TRIM(:v_json:value::VARCHAR));
    v_quote := :v_json:quote::VARCHAR;
    v_conf  := :v_json:confidence::FLOAT;

    -- Guard: reject anything outside the approved vocabulary rather than trust the model.
    IF (:v_val NOT IN ('maternity_cover','critical_illness','senior_wellness','corporate_topup',
                       'opd_cover','claim_protection','super_topup_cover','loan_topup',
                       'rate_reduction','payment_relief','balance_transfer')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'NONE', 'raw_value', :v_val);
    END IF;

    v_stamp := TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');
    v_sid := 'sig-prod-' || :P_CUSTOMER_ID || '-' || :v_stamp;

    DELETE FROM CUSTOMER_360_DB.ENGINE.SIGNAL
     WHERE customer_id = :P_CUSTOMER_ID AND signal_name = 'product_interest';

    INSERT INTO CUSTOMER_360_DB.ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id, signal_name,
        signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
    SELECT :v_sid, :P_CUSTOMER_ID, :v_signal_id, 'product_interest',
        :v_val, 1.0, :v_conf, 'calls:recent5', :v_dom, CURRENT_TIMESTAMP();
    INSERT INTO CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE (signal_instance_id, customer_id, signal_name, quote, model, model_confidence)
    VALUES (:v_sid, :P_CUSTOMER_ID, 'product_interest', :v_quote, 'llama3.3-70b', :v_conf);

    RETURN OBJECT_CONSTRUCT('status', 'EXTRACTED', 'value', :v_val, 'quote', :v_quote, 'confidence', :v_conf);
END;
$$;

-- =============================================================================
-- CONFIG.PRODUCT_RULE — deterministic scoring config, same spirit as
-- SCORING_CONFIG. Which signals move a product's fit score, and by how much.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONFIG.PRODUCT_RULE (
    rule_id      VARCHAR(50) PRIMARY KEY,
    product_id   VARCHAR(50),
    signal_name  VARCHAR(100),
    match_value  VARCHAR(50),
    weight       FLOAT,
    active       BOOLEAN DEFAULT TRUE
);

DELETE FROM CONFIG.PRODUCT_RULE;
INSERT INTO CONFIG.PRODUCT_RULE (rule_id, product_id, signal_name, match_value, weight)
VALUES
 ('pr001','ins_prod_maternity','product_interest','maternity_cover',0.8),
 ('pr002','ins_prod_maternity','tenure_segment','EARLY',0.2),
 ('pr003','ins_prod_critical','product_interest','critical_illness',0.8),
 ('pr004','ins_prod_senior','product_interest','senior_wellness',0.7),
 ('pr005','ins_prod_senior','tenure_segment','MATURE',0.3),
 ('pr006','ins_prod_corp_topup','product_interest','corporate_topup',0.7),
 ('pr007','ins_prod_corp_topup','group_exposure','HIGH',0.3),
 ('pr008','ins_prod_opd','product_interest','opd_cover',0.8),
 ('pr009','ins_prod_ncb_protect','product_interest','claim_protection',0.6),
 ('pr010','ins_prod_ncb_protect','claim_friction','MEDIUM',0.4),
 ('pr011','lend_prod_topup','product_interest','loan_topup',0.8),
 ('pr012','lend_prod_topup','tenure_segment','MATURE',0.2),
 ('pr013','lend_prod_ratelock','product_interest','rate_reduction',0.5),
 ('pr014','lend_prod_ratelock','renewal_proximity','HIGH',0.5),
 ('pr015','lend_prod_emiholiday','product_interest','payment_relief',0.7),
 ('pr016','lend_prod_emiholiday','payment_irregularity','MEDIUM',0.3),
 ('pr017','lend_prod_baltransfer','product_interest','balance_transfer',0.8),
 ('pr018','lend_prod_baltransfer','product_interest','rate_reduction',0.5);

-- =============================================================================
-- Effectiveness loop — identical shape to ENGINE.ACTION_EFFECTIVENESS.
-- =============================================================================
CREATE TABLE IF NOT EXISTS ENGINE.PRODUCT_EFFECTIVENESS (
    effectiveness_id   VARCHAR(50) PRIMARY KEY,
    product_id         VARCHAR(50),
    domain_id          VARCHAR(50),
    offered_count      NUMBER DEFAULT 0,
    accepted_count      NUMBER DEFAULT 0,
    acceptance_rate      FLOAT DEFAULT 0,
    confidence              FLOAT DEFAULT 0,
    last_updated          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- RECOMMEND_PRODUCT — pure SQL table function. No AI_COMPLETE. Deterministic:
-- identical inputs always produce identical output, verified after deploy.
-- =============================================================================
CREATE OR REPLACE FUNCTION RECOMMEND_PRODUCT(P_CUSTOMER_ID VARCHAR)
RETURNS TABLE (PRODUCT_ID VARCHAR, PRODUCT_NAME VARCHAR, PRODUCT_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR, ACCEPTANCE_RATE FLOAT,
    SAMPLE_SIZE NUMBER, ELIGIBLE_REASON VARCHAR)
AS
$$
WITH cust AS (
    SELECT customer_id, domain, segment,
           DATEDIFF(year, date_of_birth, CURRENT_DATE()) AS age
    FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id = P_CUSTOMER_ID
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
       s.eligible_reason
FROM scored s
LEFT JOIN ENGINE.PRODUCT_EFFECTIVENESS pe ON pe.product_id = s.product_id
ORDER BY s.score DESC, s.product_id
$$;

-- =============================================================================
-- RECORD_PRODUCT_OUTCOME — the loop closes.
-- =============================================================================
CREATE OR REPLACE PROCEDURE RECORD_PRODUCT_OUTCOME(P_CUSTOMER_ID VARCHAR, P_PRODUCT_ID VARCHAR, P_ACCEPTED BOOLEAN)
RETURNS OBJECT
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_eff VARCHAR; v_exists NUMBER;
BEGIN
    SELECT domain_id INTO :v_dom FROM CONFIG.PRODUCT_CATALOG WHERE product_id = :P_PRODUCT_ID;
    SELECT COUNT(*) INTO :v_exists FROM ENGINE.PRODUCT_EFFECTIVENESS WHERE product_id = :P_PRODUCT_ID;

    IF (:v_exists = 0) THEN
        INSERT INTO ENGINE.PRODUCT_EFFECTIVENESS (effectiveness_id, product_id, domain_id,
            offered_count, accepted_count, acceptance_rate, confidence, last_updated)
        SELECT 'peff-' || :P_PRODUCT_ID, :P_PRODUCT_ID, :v_dom,
            1, CASE WHEN :P_ACCEPTED THEN 1 ELSE 0 END,
            CASE WHEN :P_ACCEPTED THEN 1.0 ELSE 0.0 END,
            LEAST(0.99, 1 - 1.0/SQRT(2)), CURRENT_TIMESTAMP();
    ELSE
        UPDATE ENGINE.PRODUCT_EFFECTIVENESS
           SET offered_count = offered_count + 1,
               accepted_count = accepted_count + CASE WHEN :P_ACCEPTED THEN 1 ELSE 0 END,
               acceptance_rate = (accepted_count + CASE WHEN :P_ACCEPTED THEN 1 ELSE 0 END)::FLOAT
                                  / (offered_count + 1),
               confidence = LEAST(0.99, 1 - 1.0/SQRT(offered_count + 2)),
               last_updated = CURRENT_TIMESTAMP()
         WHERE product_id = :P_PRODUCT_ID;
    END IF;

    RETURN OBJECT_CONSTRUCT('status', 'RECORDED', 'product_id', :P_PRODUCT_ID, 'accepted', :P_ACCEPTED);
END;
$$;

-- =============================================================================
-- Agent-compatible procedure wrapper, same split as RECOMMEND / RECOMMEND_ACTION.
-- =============================================================================
CREATE OR REPLACE PROCEDURE RECOMMEND_PRODUCT_ACTION(CUSTOMER_ID VARCHAR)
RETURNS TABLE (PRODUCT_ID VARCHAR, PRODUCT_NAME VARCHAR, PRODUCT_TYPE VARCHAR,
    RANKING NUMBER, SCORE FLOAT, MATCH_REASONS VARCHAR, ACCEPTANCE_RATE FLOAT,
    SAMPLE_SIZE NUMBER, ELIGIBLE_REASON VARCHAR)
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

GRANT SELECT ON TABLE CONFIG.PRODUCT_CATALOG TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE CONFIG.PRODUCT_RULE TO ROLE C360_JUDGE;
GRANT SELECT ON TABLE ENGINE.PRODUCT_EFFECTIVENESS TO ROLE C360_JUDGE;
GRANT USAGE ON FUNCTION RECOMMEND_PRODUCT(VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE EXTRACT_PRODUCT_INTEREST(VARCHAR) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE RECORD_PRODUCT_OUTCOME(VARCHAR, VARCHAR, BOOLEAN) TO ROLE C360_JUDGE;
GRANT USAGE ON PROCEDURE RECOMMEND_PRODUCT_ACTION(VARCHAR) TO ROLE C360_JUDGE;

SELECT 'Personalization engine deployed' AS status;
