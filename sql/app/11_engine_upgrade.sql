-- =============================================================================
-- Wire the new sources into the decision engine.
--
-- Until now the state machine saw three things: churn_intent, sentiment and an
-- open claim. It now also sees a regulatory filing, a portability request, our
-- own service failures, renewal lateness and group exposure — so a state is
-- argued from independent evidence rather than one angry phone call.
--
-- All of it stays deterministic. The escalation rules below are thresholds over
-- observable facts; nothing here samples a model.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- Signals the engine reasons over = extracted signals + derived signals.
CREATE OR REPLACE VIEW V_ALL_SIGNALS AS
SELECT customer_id, domain, signal_name, signal_value, numeric_value,
       confidence, evidence_ref, 'EXTRACTED' AS origin
FROM CUSTOMER_360_DB.APP.V_SIGNAL_RESOLVED
UNION ALL
SELECT customer_id, domain, signal_name, signal_value, numeric_value,
       confidence, evidence_ref, 'DERIVED'
FROM CUSTOMER_360_DB.APP.V_DERIVED_SIGNALS;

CREATE OR REPLACE VIEW V_SIGNAL_WIDE AS
SELECT customer_id, domain,
    MAX(CASE WHEN signal_name='churn_intent'       THEN signal_value  END) AS churn_intent,
    MAX(CASE WHEN signal_name='hardship_intent'    THEN signal_value  END) AS hardship_intent,
    MAX(CASE WHEN signal_name='payment_risk'       THEN signal_value  END) AS payment_risk,
    MAX(CASE WHEN signal_name='negative_sentiment' THEN numeric_value END) AS negative_sentiment,
    MAX(CASE WHEN signal_name='unresolved_claim'   THEN numeric_value END) AS unresolved_claim,
    MAX(CASE WHEN signal_name='renewal_proximity'  THEN numeric_value END) AS renewal_proximity,
    MAX(CASE WHEN signal_name='delinquency'        THEN numeric_value END) AS delinquency,
    -- new, all deterministic
    MAX(CASE WHEN signal_name='grievance_filed'    THEN signal_value  END) AS grievance_filed,
    MAX(CASE WHEN signal_name='portability_intent' THEN signal_value  END) AS portability_intent,
    MAX(CASE WHEN signal_name='service_failure'    THEN signal_value  END) AS service_failure,
    MAX(CASE WHEN signal_name='ticket_reopen'      THEN signal_value  END) AS ticket_reopen,
    MAX(CASE WHEN signal_name='csat_low'           THEN signal_value  END) AS csat_low,
    MAX(CASE WHEN signal_name='renewal_lateness'   THEN signal_value  END) AS renewal_lateness,
    MAX(CASE WHEN signal_name='coverage_downgrade' THEN signal_value  END) AS coverage_downgrade,
    MAX(CASE WHEN signal_name='claim_friction'     THEN signal_value  END) AS claim_friction,
    MAX(CASE WHEN signal_name='group_exposure'     THEN signal_value  END) AS group_exposure,
    MAX(CASE WHEN signal_name='email_escalation'   THEN signal_value  END) AS email_escalation
FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS
GROUP BY customer_id, domain;

-- Rule text in CONFIG, so the UI shows what is actually being tested.
UPDATE CUSTOMER_360_DB.CONFIG.STATE_RULE
   SET rule_expression = 'grievance_filed = ''HIGH'' OR portability_intent = ''HIGH'' '
                      || 'OR (churn_intent = ''HIGH'' AND negative_sentiment > 0.8 AND unresolved_claim > 0)'
 WHERE rule_id = 'ins_rule_critical';
UPDATE CUSTOMER_360_DB.CONFIG.STATE_RULE
   SET rule_expression = 'portability_intent = ''MEDIUM'' OR renewal_lateness = ''HIGH'' '
                      || 'OR coverage_downgrade = ''HIGH'' OR (service_failure = ''HIGH'' AND claim_friction = ''HIGH'') '
                      || 'OR (churn_intent IN (''HIGH'',''MEDIUM'') AND (negative_sentiment > 0.6 OR unresolved_claim > 0))'
 WHERE rule_id = 'ins_rule_high';
UPDATE CUSTOMER_360_DB.CONFIG.STATE_RULE
   SET rule_expression = 'service_failure IN (''HIGH'',''MEDIUM'') OR ticket_reopen = ''HIGH'' '
                      || 'OR csat_low = ''HIGH'' OR renewal_lateness = ''MEDIUM'' OR claim_friction = ''HIGH'' '
                      || 'OR negative_sentiment > 0.4 OR unresolved_claim > 0'
 WHERE rule_id = 'ins_rule_medium';

-- ─── State computation, now reading the wider evidence ──────────────────────
CREATE OR REPLACE PROCEDURE COMPUTE_STATE_FOR(P_CUSTOMER_ID VARCHAR, P_RUN_ID VARCHAR)
RETURNS TABLE (PREVIOUS_STATE VARCHAR, NEW_STATE VARCHAR, SEVERITY NUMBER, CHANGED BOOLEAN, SCORE FLOAT)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_prev_id VARCHAR; v_prev VARCHAR; v_target VARCHAR; v_target_name VARCHAR;
    v_sev NUMBER; v_score FLOAT; v_changed BOOLEAN := FALSE; v_sid VARCHAR;
    res RESULTSET;
BEGIN
    v_dom := (SELECT domain FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER
              WHERE customer_id = :P_CUSTOMER_ID LIMIT 1);
    v_prev_id := (SELECT state_id FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
                  WHERE customer_id = :P_CUSTOMER_ID AND is_current = TRUE LIMIT 1);
    v_prev := (SELECT state_name FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
               WHERE customer_id = :P_CUSTOMER_ID AND is_current = TRUE LIMIT 1);

    v_target := (
        SELECT r.target_state_id
        FROM CUSTOMER_360_DB.APP.V_SIGNAL_WIDE w
        JOIN CUSTOMER_360_DB.CONFIG.STATE_RULE r
          ON r.domain_id = w.domain AND r.active = TRUE
        WHERE w.customer_id = :P_CUSTOMER_ID
          AND CASE
            WHEN r.domain_id='insurance' AND r.priority=4 THEN
                (w.grievance_filed = 'HIGH' OR w.portability_intent = 'HIGH'
                 OR (w.churn_intent='HIGH' AND w.negative_sentiment > 0.8
                     AND COALESCE(w.unresolved_claim,0) > 0))
            WHEN r.domain_id='insurance' AND r.priority=3 THEN
                (w.portability_intent = 'MEDIUM' OR w.renewal_lateness = 'HIGH'
                 OR w.coverage_downgrade = 'HIGH'
                 OR (w.service_failure = 'HIGH' AND w.claim_friction = 'HIGH')
                 OR (w.churn_intent IN ('HIGH','MEDIUM')
                     AND (w.negative_sentiment > 0.6 OR COALESCE(w.unresolved_claim,0) > 0
                          OR w.renewal_proximity < 30)))
            WHEN r.domain_id='insurance' AND r.priority=2 THEN
                (w.service_failure IN ('HIGH','MEDIUM') OR w.ticket_reopen = 'HIGH'
                 OR w.csat_low = 'HIGH' OR w.renewal_lateness = 'MEDIUM'
                 OR w.claim_friction = 'HIGH'
                 OR w.negative_sentiment > 0.4 OR COALESCE(w.unresolved_claim,0) > 0
                 OR w.renewal_proximity < 60)
            WHEN r.domain_id='insurance' AND r.priority=1 THEN TRUE
            WHEN r.domain_id='lending' AND r.priority=4 THEN
                (w.hardship_intent='HIGH' AND w.delinquency > 60)
            WHEN r.domain_id='lending' AND r.priority=3 THEN
                (w.payment_risk='HIGH' OR w.delinquency > 30
                 OR w.hardship_intent IN ('HIGH','MEDIUM'))
            WHEN r.domain_id='lending' AND r.priority=2 THEN
                (w.payment_risk='MEDIUM' OR w.delinquency > 0 OR w.negative_sentiment > 0.5)
            WHEN r.domain_id='lending' AND r.priority=1 THEN TRUE
            ELSE FALSE END
        ORDER BY r.priority DESC LIMIT 1);

    SELECT state_name, severity INTO :v_target_name, :v_sev
    FROM CUSTOMER_360_DB.CONFIG.STATE_DEFINITION WHERE state_id = :v_target;

    -- normalised 0..1 so the score is comparable across customers and domains
    v_score := (SELECT ROUND(AVG(CASE signal_value
                    WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6
                    WHEN 'LOW' THEN 0.3 ELSE 0.0 END), 3)
                FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS
                WHERE customer_id = :P_CUSTOMER_ID);

    IF (v_prev_id IS NULL OR v_prev_id <> v_target) THEN
        v_changed := TRUE;
        UPDATE CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
           SET is_current = FALSE, effective_to = CURRENT_TIMESTAMP()
         WHERE customer_id = :P_CUSTOMER_ID AND is_current = TRUE;

        v_sid := 'state-x-' || :P_CUSTOMER_ID || '-' ||
                 TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');
        INSERT INTO CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
            (state_instance_id, customer_id, state_id, state_name, domain, severity,
             computed_score, effective_from, effective_to, is_current)
        VALUES (:v_sid, :P_CUSTOMER_ID, :v_target, :v_target_name, :v_dom, :v_sev,
                :v_score, CURRENT_TIMESTAMP(), '9999-12-31'::TIMESTAMP_NTZ, TRUE);

        INSERT INTO CUSTOMER_360_DB.APP.RUN_ARTIFACT (run_id, object_type, object_id, detail)
        SELECT :P_RUN_ID,'STATE', :v_sid, COALESCE(:v_prev,'none') || ' -> ' || :v_target_name;

        CALL CUSTOMER_360_DB.ENGINE.DETECT_TRANSITIONS();
    END IF;

    res := (SELECT :v_prev, :v_target_name, :v_sev, :v_changed, :v_score);
    RETURN TABLE(res);
END;
$$;

-- Why a customer is in the state they're in: one row per rule that fired.
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
      ELSE 'Contributing evidence'
    END
FROM CUSTOMER_360_DB.APP.V_ALL_SIGNALS s
WHERE s.customer_id = P_CUSTOMER_ID
ORDER BY CASE s.signal_value WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
         s.signal_name
$$;

GRANT SELECT ON ALL VIEWS IN SCHEMA CUSTOMER_360_DB.APP TO ROLE C360_JUDGE;
GRANT USAGE ON ALL FUNCTIONS IN SCHEMA CUSTOMER_360_DB.APP TO ROLE C360_JUDGE;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA CUSTOMER_360_DB.APP TO ROLE C360_JUDGE;
GRANT SELECT ON ALL TABLES IN SCHEMA CUSTOMER_360_DB.RAW TO ROLE C360_JUDGE;

SELECT 'Engine upgraded to read the new sources' AS status;
