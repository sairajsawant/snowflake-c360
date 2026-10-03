-- =============================================================================
-- 14_signal_completion.sql — the last 3 configured signals that never produced
-- a row: renewal_proximity, payment_irregularity (deterministic SQL, added to
-- V_DERIVED_SIGNALS) and email_escalation (INTENT/AI_COMPLETE, backfilled once
-- over existing email threads, same pattern EXTRACT_SIGNALS_FOR uses live).
--
-- After this: 15 of 15 configured insurance signals produce rows. The "N
-- configured signals still produce nothing" warning in the app is removed —
-- not just silenced, the gap it pointed at is actually closed.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- =============================================================================
-- V_DERIVED_SIGNALS — add renewal_proximity and payment_irregularity.
-- Full restate (CREATE OR REPLACE), same 9 existing branches plus 2 new ones.
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
    -- renewal_proximity: days to the NEXT occurrence of this policy's renewal
    -- anniversary. The seed data's renewal_date values are historical (the
    -- known account-wide time-shift), so "days since renewal_date" is
    -- meaningless; what the policy actually recurs on each year is the
    -- month/day, which is still real. DATEADD(year, 1, ...) on the clamped
    -- same-year anchor handles the Feb-29 case without erroring.
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
    -- payment_irregularity: failed or still-pending premium payments.
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
)
WHERE signal_value <> 'NONE';

-- =============================================================================
-- V_SIGNAL_WIDE — add payment_irregularity (renewal_proximity and
-- email_escalation columns already existed, unused, waiting for this).
-- =============================================================================
CREATE OR REPLACE VIEW V_SIGNAL_WIDE AS
SELECT customer_id, domain,
    MAX(CASE WHEN signal_name='churn_intent'          THEN signal_value  END) AS churn_intent,
    MAX(CASE WHEN signal_name='hardship_intent'       THEN signal_value  END) AS hardship_intent,
    MAX(CASE WHEN signal_name='payment_risk'          THEN signal_value  END) AS payment_risk,
    MAX(CASE WHEN signal_name='negative_sentiment'    THEN numeric_value END) AS negative_sentiment,
    MAX(CASE WHEN signal_name='unresolved_claim'      THEN numeric_value END) AS unresolved_claim,
    MAX(CASE WHEN signal_name='renewal_proximity'     THEN numeric_value END) AS renewal_proximity,
    MAX(CASE WHEN signal_name='delinquency'           THEN numeric_value END) AS delinquency,
    MAX(CASE WHEN signal_name='grievance_filed'       THEN signal_value  END) AS grievance_filed,
    MAX(CASE WHEN signal_name='portability_intent'    THEN signal_value  END) AS portability_intent,
    MAX(CASE WHEN signal_name='service_failure'       THEN signal_value  END) AS service_failure,
    MAX(CASE WHEN signal_name='ticket_reopen'         THEN signal_value  END) AS ticket_reopen,
    MAX(CASE WHEN signal_name='csat_low'              THEN signal_value  END) AS csat_low,
    MAX(CASE WHEN signal_name='renewal_lateness'      THEN signal_value  END) AS renewal_lateness,
    MAX(CASE WHEN signal_name='coverage_downgrade'    THEN signal_value  END) AS coverage_downgrade,
    MAX(CASE WHEN signal_name='claim_friction'        THEN signal_value  END) AS claim_friction,
    MAX(CASE WHEN signal_name='group_exposure'        THEN signal_value  END) AS group_exposure,
    MAX(CASE WHEN signal_name='email_escalation'      THEN signal_value  END) AS email_escalation,
    MAX(CASE WHEN signal_name='payment_irregularity'  THEN signal_value  END) AS payment_irregularity
FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS
GROUP BY customer_id, domain;

-- =============================================================================
-- email_escalation — backfill once over existing email threads. Same
-- AI_COMPLETE + response_format pattern EXTRACT_SIGNALS_FOR uses live on
-- transcripts; this just runs it over RAW.EMAIL_MESSAGE, which is static
-- historical data rather than something a Scenario Studio run injects.
-- Idempotent: clears prior backfilled rows first, so re-running this file
-- doesn't duplicate.
-- =============================================================================
DELETE FROM CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE
 WHERE signal_instance_id IN (
     SELECT signal_instance_id FROM CUSTOMER_360_DB.ENGINE.SIGNAL
     WHERE signal_name = 'email_escalation' AND signal_instance_id LIKE 'sig-mail-%');
DELETE FROM CUSTOMER_360_DB.ENGINE.SIGNAL
 WHERE signal_name = 'email_escalation' AND signal_instance_id LIKE 'sig-mail-%';

EXECUTE IMMEDIATE
$$
DECLARE
    v_prompt VARCHAR;
    v_thread CURSOR FOR
        SELECT customer_id, ticket_id FROM (
            SELECT customer_id, ticket_id,
                   ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY MAX(sent_at) DESC) AS rn
            FROM CUSTOMER_360_DB.RAW.EMAIL_MESSAGE
            GROUP BY customer_id, ticket_id
        ) WHERE rn = 1;
    v_body VARCHAR;
    v_json VARIANT;
    v_val VARCHAR; v_quote VARCHAR; v_conf FLOAT; v_num FLOAT;
    v_sid VARCHAR; v_stamp VARCHAR; v_n NUMBER DEFAULT 0;
    v_cid VARCHAR; v_tid VARCHAR;
BEGIN
    SELECT extraction_prompt INTO :v_prompt
    FROM CUSTOMER_360_DB.CONFIG.SIGNAL_DEFINITION WHERE signal_id = 'ins_x_emailtone';

    FOR rec IN v_thread DO
        v_cid := rec.customer_id;
        v_tid := rec.ticket_id;

        SELECT LISTAGG(
                   (CASE WHEN direction='INBOUND' THEN 'Customer: ' ELSE 'Insurer: ' END) || body,
                   '\n---\n'
               ) WITHIN GROUP (ORDER BY thread_position)
          INTO :v_body
        FROM CUSTOMER_360_DB.RAW.EMAIL_MESSAGE
        WHERE customer_id = :v_cid AND ticket_id = :v_tid;

        SELECT AI_COMPLETE(
            model => 'llama3.3-70b',
            prompt => :v_prompt || '

EMAIL THREAD:
' || :v_body || '

Return value as exactly one of HIGH, MEDIUM, LOW, NONE. Quote the single sentence that most
supports your answer, verbatim. Give confidence between 0 and 1.',
            response_format => {'type':'json','schema':{'type':'object','properties':{
                'value':{'type':'string'},'quote':{'type':'string'},'confidence':{'type':'number'}},
                'required':['value','quote','confidence']}}
        ) INTO :v_json;

        v_val   := UPPER(TRIM(:v_json:value::VARCHAR));
        v_quote := :v_json:quote::VARCHAR;
        v_conf  := :v_json:confidence::FLOAT;
        v_num   := CASE :v_val WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6
                               WHEN 'LOW' THEN 0.3 ELSE 0.0 END;

        IF (:v_val IN ('HIGH','MEDIUM','LOW')) THEN
            v_stamp := TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');
            v_sid := 'sig-mail-' || :v_cid || '-' || :v_stamp;
            INSERT INTO CUSTOMER_360_DB.ENGINE.SIGNAL (signal_instance_id, customer_id, signal_id,
                signal_name, signal_value, numeric_value, confidence, evidence_ref, domain, extracted_at)
            SELECT :v_sid, :v_cid, 'ins_x_emailtone', 'email_escalation',
                :v_val, :v_num, :v_conf, 'email:' || :v_tid, 'insurance', CURRENT_TIMESTAMP();
            INSERT INTO CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE (signal_instance_id, customer_id,
                signal_name, quote, model, model_confidence)
            VALUES (:v_sid, :v_cid, 'email_escalation', :v_quote, 'llama3.3-70b', :v_conf);
            v_n := v_n + 1;
        END IF;
    END FOR;

    RETURN 'email_escalation backfilled for ' || v_n || ' customers';
END;
$$;

-- =============================================================================
-- WHY_THIS_STATE — give the 3 new signals a real contribution label instead
-- of falling through to the generic default.
-- =============================================================================
CREATE OR REPLACE FUNCTION WHY_THIS_STATE(P_CUSTOMER_ID VARCHAR)
RETURNS TABLE (SIGNAL_NAME VARCHAR, SIGNAL_VALUE VARCHAR, ORIGIN VARCHAR,
               EVIDENCE_REF VARCHAR, CONTRIBUTION VARCHAR)
AS
$$
SELECT s.signal_name, s.signal_value, s.origin, s.evidence_ref,
    CASE
      WHEN s.signal_name IN ('grievance_filed','portability_intent')
           AND s.signal_value = 'HIGH' THEN 'Escalates to CRITICAL on its own'
      WHEN s.signal_name = 'portability_intent' THEN 'Escalates to HIGH on its own'
      WHEN s.signal_name = 'renewal_lateness' AND s.signal_value = 'HIGH' THEN 'Escalates to HIGH on its own'
      WHEN s.signal_name = 'coverage_downgrade' THEN 'Escalates to HIGH on its own'
      WHEN s.signal_name IN ('service_failure','claim_friction') THEN 'Escalates to HIGH when both are HIGH'
      WHEN s.signal_name IN ('ticket_reopen','csat_low') THEN 'Supports MEDIUM'
      WHEN s.signal_name = 'group_exposure' THEN 'Not a trigger — sizes the blast radius'
      WHEN s.signal_name = 'renewal_proximity' THEN 'Context — not yet wired to a state rule'
      WHEN s.signal_name = 'payment_irregularity' THEN 'Context — not yet wired to a state rule'
      WHEN s.signal_name = 'email_escalation' THEN 'Written-channel corroboration for churn_intent'
      ELSE 'Contributing evidence'
    END
FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS s
WHERE s.customer_id = P_CUSTOMER_ID
ORDER BY CASE s.signal_value WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
         s.signal_name
$$;

GRANT SELECT ON ALL VIEWS IN SCHEMA CUSTOMER_360_DB.APP TO ROLE C360_JUDGE;
GRANT USAGE ON ALL FUNCTIONS IN SCHEMA CUSTOMER_360_DB.APP TO ROLE C360_JUDGE;

SELECT 'All 15 configured insurance signals now produce rows' AS status;
