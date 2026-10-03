-- =============================================================================
-- APP — AI-assisted human execution, outcome recording and run reversal.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- ─────────────────────────────────────────────────────────────────────────────
-- CALL_BRIEF — grounded prep for the person who actually makes the call.
-- Built from this customer's resolved signals, the evidence quotes captured at
-- extraction, their real products and claims, and the approved action.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE CALL_BRIEF(
    P_CUSTOMER_ID VARCHAR, P_ACTION_ID VARCHAR, P_OFFER_AMOUNT FLOAT)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_name VARCHAR; v_dom VARCHAR; v_state VARCHAR; v_action VARCHAR;
    v_signals VARCHAR; v_quotes VARCHAR; v_products VARCHAR; v_out VARCHAR;
BEGIN
    v_name   := (SELECT full_name FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id=:P_CUSTOMER_ID LIMIT 1);
    v_dom    := (SELECT domain    FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id=:P_CUSTOMER_ID LIMIT 1);
    v_state  := (SELECT state_name FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
                 WHERE customer_id=:P_CUSTOMER_ID AND is_current=TRUE LIMIT 1);
    v_action := (SELECT action_name || ' — ' || COALESCE(description,'')
                 FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION WHERE action_id=:P_ACTION_ID);

    v_signals := (SELECT LISTAGG(signal_name || '=' || signal_value, ', ')
                  FROM CUSTOMER_360_DB.APP.V_SIGNAL_RESOLVED WHERE customer_id=:P_CUSTOMER_ID);

    v_quotes := (SELECT COALESCE(LISTAGG('"' || quote || '"', ' / '),'none captured')
                 FROM CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE WHERE customer_id=:P_CUSTOMER_ID);

    IF (v_dom = 'insurance') THEN
        v_products := (SELECT COALESCE(LISTAGG(policy_id || ' ' || policy_type
                || ' premium INR ' || TO_VARCHAR(premium_amount), '; '),'none')
            FROM CUSTOMER_360_DB.RAW.INSURANCE_POLICIES WHERE customer_id=:P_CUSTOMER_ID);
    ELSE
        v_products := (SELECT COALESCE(LISTAGG(loan_id || ' ' || loan_type
                || ' EMI INR ' || TO_VARCHAR(monthly_payment), '; '),'none')
            FROM CUSTOMER_360_DB.RAW.LENDING_LOANS WHERE customer_id=:P_CUSTOMER_ID);
    END IF;

    v_out := (SELECT AI_COMPLETE('llama3.3-70b',
        'You brief an Indian ' || :v_dom || ' relationship manager before a retention call.

CUSTOMER: ' || :v_name || '
CURRENT RISK STATE: ' || :v_state || '
SIGNALS ON FILE: ' || COALESCE(:v_signals,'none') || '
WHAT THEY ACTUALLY SAID: ' || :v_quotes || '
THEIR PRODUCTS: ' || :v_products || '
APPROVED ACTION: ' || :v_action || '
AUTHORISED OFFER CEILING: INR ' || TO_VARCHAR(COALESCE(:P_OFFER_AMOUNT,0)) || '

Produce a brief with exactly these five markdown sections and nothing else:

## Open with
One sentence the RM should actually say first.

## Acknowledge, in this order
Three bullets, each a specific fact from the data above. Reference real ids and amounts.

## Offer
What is authorised, with the ceiling stated plainly.

## If they push back
Two bullets: the likely objection, and how to answer it without disparaging a competitor.

## Do not say
Four bullets of compliance guardrails appropriate to Indian insurance or lending regulation
(IRDAI or RBI as relevant). Include not promising settlement dates and not exceeding the
authorised ceiling. Be specific, not generic.'));

    RETURN v_out;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- SIMULATE_CALL — role-plays the customer against the brief, then returns a
-- transcript AND a disposition. The caller re-injects the transcript so the
-- outcome of the conversation re-enters the same pipeline: the loop is a circle.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE SIMULATE_CALL(
    P_CUSTOMER_ID VARCHAR, P_ACTION_ID VARCHAR, P_OFFER_AMOUNT FLOAT, P_TONE VARCHAR)
RETURNS OBJECT LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_name VARCHAR; v_dom VARCHAR; v_state VARCHAR; v_action VARCHAR;
    v_quotes VARCHAR; v_json VARIANT;
BEGIN
    v_name   := (SELECT full_name FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id=:P_CUSTOMER_ID LIMIT 1);
    v_dom    := (SELECT domain    FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id=:P_CUSTOMER_ID LIMIT 1);
    v_state  := (SELECT state_name FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
                 WHERE customer_id=:P_CUSTOMER_ID AND is_current=TRUE LIMIT 1);
    v_action := (SELECT action_name FROM CUSTOMER_360_DB.CONFIG.ACTION_DEFINITION WHERE action_id=:P_ACTION_ID);
    v_quotes := (SELECT COALESCE(LISTAGG('"' || quote || '"', ' / '),'none')
                 FROM CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE WHERE customer_id=:P_CUSTOMER_ID);

    v_json := (SELECT AI_COMPLETE(
        model => 'llama3.3-70b',
        prompt => 'Role-play the FOLLOW-UP call that happens after an Indian ' || :v_dom
            || ' company carried out "' || :v_action || '" for this customer.

CUSTOMER: ' || :v_name || ' — currently ' || :v_state || '
WHAT THEY SAID ON THE EARLIER CALL: ' || :v_quotes || '
REMEDY DELIVERED: ' || :v_action
            || CASE WHEN COALESCE(:P_OFFER_AMOUNT,0) > 0
                    THEN ' with an offer of INR ' || TO_VARCHAR(:P_OFFER_AMOUNT) ELSE '' END || '
HOW THE CALL SHOULD GO: ' || :P_TONE || '

Write a 6 to 8 turn transcript, each line starting exactly "Agent:" or "Customer:", alternating,
starting with the Agent. Keep it consistent with what the customer said before — they should not
suddenly forget their grievance. Light Hinglish is fine.

Then judge the result. disposition must be exactly one of: renewed, engaged, no_contact, cancelled.
resolved_intent must be exactly one of: NONE, LOW, MEDIUM, HIGH — the customer''s remaining intent
to leave after this call.',
        response_format => {'type':'json','schema':{'type':'object','properties':{
            'transcript':{'type':'string'},
            'disposition':{'type':'string'},
            'resolved_intent':{'type':'string'},
            'rationale':{'type':'string'}},
            'required':['transcript','disposition','resolved_intent','rationale']}}));

    RETURN OBJECT_CONSTRUCT(
        'transcript',      v_json:transcript::VARCHAR,
        'disposition',     LOWER(TRIM(v_json:disposition::VARCHAR)),
        'resolved_intent', UPPER(TRIM(v_json:resolved_intent::VARCHAR)),
        'rationale',       v_json:rationale::VARCHAR,
        'success',         CASE WHEN LOWER(TRIM(v_json:disposition::VARCHAR)) IN ('renewed','engaged')
                                THEN TRUE ELSE FALSE END);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RECORD_OUTCOME — writes ACTION_OUTCOME and recomputes ACTION_EFFECTIVENESS,
-- the same table RECOMMEND_ACTION reads. That shared table IS the feedback loop.
-- Returns before/after so the UI can show the delta honestly.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE RECORD_OUTCOME(
    P_CUSTOMER_ID VARCHAR, P_ACTION_ID VARCHAR, P_OUTCOME VARCHAR,
    P_STATE_AFTER VARCHAR, P_RUN_ID VARCHAR)
RETURNS OBJECT LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_state VARCHAR; v_exec VARCHAR; v_stamp VARCHAR; v_out_id VARCHAR;
    v_success BOOLEAN; v_eff_id VARCHAR;
    v_s0 NUMBER; v_t0 NUMBER; v_r0 FLOAT; v_c0 FLOAT;
    v_s1 NUMBER; v_t1 NUMBER; v_r1 FLOAT; v_c1 FLOAT;
BEGIN
    v_stamp := TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');
    v_dom   := (SELECT domain   FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
                WHERE customer_id=:P_CUSTOMER_ID AND is_current=TRUE LIMIT 1);
    v_state := (SELECT state_id FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
                WHERE customer_id=:P_CUSTOMER_ID AND is_current=TRUE LIMIT 1);
    v_exec  := (SELECT execution_id FROM CUSTOMER_360_DB.ENGINE.ACTION_EXECUTION
                WHERE customer_id=:P_CUSTOMER_ID AND action_id=:P_ACTION_ID
                ORDER BY executed_at DESC LIMIT 1);
    v_success := (:P_OUTCOME IN ('renewed','engaged'));

    IF (v_exec IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status','NO_EXECUTION',
            'reason','No ACTION_EXECUTION row for this customer and action — execute it first.');
    END IF;

    v_out_id := 'out-x-' || :P_CUSTOMER_ID || '-' || :v_stamp;
    INSERT INTO CUSTOMER_360_DB.ENGINE.ACTION_OUTCOME (outcome_id, execution_id, customer_id,
        action_id, domain, outcome_type, state_before, state_after, success, notes, recorded_at)
    VALUES (:v_out_id, :v_exec, :P_CUSTOMER_ID, :P_ACTION_ID, :v_dom, :P_OUTCOME,
        :v_state, COALESCE(:P_STATE_AFTER, :v_state), :v_success,
        'Recorded by APP run ' || COALESCE(:P_RUN_ID,'(none)'), CURRENT_TIMESTAMP());

    -- effectiveness before
    v_s0 := (SELECT success_count FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);
    v_t0 := (SELECT total_count   FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);
    v_r0 := (SELECT success_rate  FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);
    v_c0 := (SELECT confidence    FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);

    IF (v_t0 IS NULL) THEN
        -- cold start: open a new effectiveness row rather than silently doing nothing
        v_eff_id := 'eff-x-' || :P_ACTION_ID || '-' || :v_state;
        INSERT INTO CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS (effectiveness_id, action_id, state_id,
            domain_id, success_count, total_count, success_rate, avg_uplift, confidence, last_updated)
        VALUES (:v_eff_id, :P_ACTION_ID, :v_state, :v_dom,
            IFF(:v_success,1,0), 1, IFF(:v_success,1.0,0.0), 0.05, 0.10, CURRENT_TIMESTAMP());
        INSERT INTO CUSTOMER_360_DB.APP.RUN_ARTIFACT (run_id, object_type, object_id, detail)
        VALUES (:P_RUN_ID,'EFFECTIVENESS_NEW', :v_eff_id, 'cold start row created');
        v_s0 := 0; v_t0 := 0; v_r0 := 0; v_c0 := 0;
    ELSE
        UPDATE CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
           SET success_count = success_count + IFF(:v_success,1,0),
               total_count   = total_count + 1,
               success_rate  = (success_count + IFF(:v_success,1,0)) / (total_count + 1),
               confidence    = LEAST(0.99, 1 - 1.0/SQRT(total_count + 1)),
               last_updated  = CURRENT_TIMESTAMP()
         WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom;
    END IF;

    v_s1 := (SELECT success_count FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);
    v_t1 := (SELECT total_count   FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);
    v_r1 := (SELECT success_rate  FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);
    v_c1 := (SELECT confidence    FROM CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
             WHERE action_id=:P_ACTION_ID AND state_id=:v_state AND domain_id=:v_dom);

    INSERT INTO CUSTOMER_360_DB.APP.RUN_ARTIFACT (run_id, object_type, object_id, detail)
    VALUES (:P_RUN_ID,'OUTCOME', :v_out_id, :P_OUTCOME);
    INSERT INTO CUSTOMER_360_DB.APP.RUN_ARTIFACT (run_id, object_type, object_id, detail)
    SELECT :P_RUN_ID,'EFFECTIVENESS', :P_ACTION_ID || '|' || :v_state,
           'rate ' || TO_VARCHAR(:v_r0) || ' -> ' || TO_VARCHAR(:v_r1);

    RETURN OBJECT_CONSTRUCT('status','RECORDED','outcome_id',:v_out_id,'success',:v_success,
        'state_id',:v_state,
        'before', OBJECT_CONSTRUCT('success_count',:v_s0,'total_count',:v_t0,'success_rate',:v_r0,'confidence',:v_c0),
        'after',  OBJECT_CONSTRUCT('success_count',:v_s1,'total_count',:v_t1,'success_rate',:v_r1,'confidence',:v_c1));
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- SUMMARIZE_CUSTOMER — real AI_SUMMARIZE over the customer's interactions,
-- persisted to ENGINE.INTERACTION_SUMMARY (a table that has never held a row).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE SUMMARIZE_CUSTOMER(P_CUSTOMER_ID VARCHAR, P_RUN_ID VARCHAR)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_corpus VARCHAR; v_sum VARCHAR; v_id VARCHAR;
BEGIN
    v_dom := (SELECT domain FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id=:P_CUSTOMER_ID LIMIT 1);

    IF (v_dom = 'insurance') THEN
        v_corpus := (SELECT LISTAGG(transcript_text, '

') WITHIN GROUP (ORDER BY call_date DESC)
            FROM CUSTOMER_360_DB.RAW.INSURANCE_CALL_TRANSCRIPTS WHERE customer_id=:P_CUSTOMER_ID);
    ELSE
        v_corpus := (SELECT LISTAGG(transcript_text, '

') WITHIN GROUP (ORDER BY call_date DESC)
            FROM CUSTOMER_360_DB.RAW.LENDING_CALL_TRANSCRIPTS WHERE customer_id=:P_CUSTOMER_ID);
    END IF;

    IF (v_corpus IS NULL) THEN
        RETURN 'No conversations on file for this customer.';
    END IF;

    v_sum := (SELECT SNOWFLAKE.CORTEX.SUMMARIZE(:v_corpus));
    v_id  := 'sum-x-' || :P_CUSTOMER_ID || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');

    INSERT INTO CUSTOMER_360_DB.ENGINE.INTERACTION_SUMMARY
        (summary_id, customer_id, domain, summary_text, source_interactions, generated_at)
    SELECT :v_id, :P_CUSTOMER_ID, :v_dom, :v_sum, NULL, CURRENT_TIMESTAMP();

    INSERT INTO CUSTOMER_360_DB.APP.RUN_ARTIFACT (run_id, object_type, object_id, detail)
    VALUES (:P_RUN_ID,'SUMMARY', :v_id, NULL);

    RETURN v_sum;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- UNDO_RUN — reverses exactly one scenario run, so back-to-back judges always
-- start from the same state.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE UNDO_RUN(P_RUN_ID VARCHAR)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_cust VARCHAR; v_n NUMBER;
BEGIN
    v_cust := (SELECT customer_id FROM CUSTOMER_360_DB.APP.RUN_LOG WHERE run_id=:P_RUN_ID);

    -- reverse effectiveness increments recorded by this run
    UPDATE CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS ae
       SET success_count = GREATEST(0, ae.success_count
             - (SELECT COUNT(*) FROM CUSTOMER_360_DB.ENGINE.ACTION_OUTCOME o
                JOIN CUSTOMER_360_DB.APP.RUN_ARTIFACT ra
                  ON ra.object_id = o.outcome_id AND ra.object_type='OUTCOME' AND ra.run_id=:P_RUN_ID
                WHERE o.action_id = ae.action_id AND o.success = TRUE)),
           total_count = GREATEST(0, ae.total_count
             - (SELECT COUNT(*) FROM CUSTOMER_360_DB.ENGINE.ACTION_OUTCOME o
                JOIN CUSTOMER_360_DB.APP.RUN_ARTIFACT ra
                  ON ra.object_id = o.outcome_id AND ra.object_type='OUTCOME' AND ra.run_id=:P_RUN_ID
                WHERE o.action_id = ae.action_id)),
           last_updated = CURRENT_TIMESTAMP()
     WHERE ae.action_id IN (SELECT o.action_id FROM CUSTOMER_360_DB.ENGINE.ACTION_OUTCOME o
            JOIN CUSTOMER_360_DB.APP.RUN_ARTIFACT ra
              ON ra.object_id=o.outcome_id AND ra.object_type='OUTCOME' AND ra.run_id=:P_RUN_ID);

    UPDATE CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
       SET success_rate = IFF(total_count=0, 0, success_count/total_count)
     WHERE total_count >= 0;

    -- restore claim statuses this run changed
    UPDATE CUSTOMER_360_DB.RAW.INSURANCE_CLAIMS
       SET claim_status='PENDING', updated_at=CURRENT_TIMESTAMP()
     WHERE claim_id IN (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT
                        WHERE run_id=:P_RUN_ID AND object_type='CLAIM_STATUS');

    DELETE FROM CUSTOMER_360_DB.ENGINE.ACTION_OUTCOME WHERE outcome_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='OUTCOME');
    DELETE FROM CUSTOMER_360_DB.ENGINE.ACTION_EXECUTION WHERE execution_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='EXECUTION');
    DELETE FROM CUSTOMER_360_DB.ENGINE.ACTION_RECOMMENDATION WHERE recommendation_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='RECOMMENDATION');
    DELETE FROM CUSTOMER_360_DB.ENGINE.NOTIFICATION_LOG WHERE log_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='NOTIFICATION');
    DELETE FROM CUSTOMER_360_DB.ENGINE.INTERACTION_SUMMARY WHERE summary_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='SUMMARY');
    DELETE FROM CUSTOMER_360_DB.APP.SIGNAL_EVIDENCE WHERE signal_instance_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='SIGNAL');
    DELETE FROM CUSTOMER_360_DB.ENGINE.SIGNAL WHERE signal_instance_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='SIGNAL');

    -- remove the state row this run opened and reinstate the one it closed
    DELETE FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE WHERE state_instance_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='STATE');
    UPDATE CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
       SET is_current=TRUE, effective_to='9999-12-31'::TIMESTAMP_NTZ
     WHERE customer_id=:v_cust
       AND state_instance_id = (SELECT state_instance_id FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
            WHERE customer_id=:v_cust AND is_current=FALSE ORDER BY effective_to DESC LIMIT 1)
       AND NOT EXISTS (SELECT 1 FROM CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE
            WHERE customer_id=:v_cust AND is_current=TRUE);

    -- queue + transitions created during this run's window
    DELETE FROM CUSTOMER_360_DB.ENGINE.DECISION_QUEUE
     WHERE customer_id=:v_cust AND created_at >=
       (SELECT started_at FROM CUSTOMER_360_DB.APP.RUN_LOG WHERE run_id=:P_RUN_ID);
    DELETE FROM CUSTOMER_360_DB.ENGINE.STATE_TRANSITION
     WHERE customer_id=:v_cust AND transition_date >=
       (SELECT started_at FROM CUSTOMER_360_DB.APP.RUN_LOG WHERE run_id=:P_RUN_ID);

    -- the injected event itself
    DELETE FROM CUSTOMER_360_DB.RAW.INSURANCE_CALL_TRANSCRIPTS WHERE transcript_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='TRANSCRIPT');
    DELETE FROM CUSTOMER_360_DB.RAW.LENDING_CALL_TRANSCRIPTS WHERE transcript_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='TRANSCRIPT');
    DELETE FROM CUSTOMER_360_DB.RAW.INSURANCE_INTERACTIONS WHERE interaction_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='INTERACTION');
    DELETE FROM CUSTOMER_360_DB.RAW.LENDING_INTERACTIONS WHERE interaction_id IN
        (SELECT object_id FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID AND object_type='INTERACTION');

    ALTER DYNAMIC TABLE CUSTOMER_360_DB.CANONICAL.INTERACTION REFRESH;
    ALTER DYNAMIC TABLE CUSTOMER_360_DB.CANONICAL.EVENT REFRESH;

    v_n := (SELECT COUNT(*) FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID);
    DELETE FROM CUSTOMER_360_DB.APP.RUN_ARTIFACT WHERE run_id=:P_RUN_ID;
    UPDATE CUSTOMER_360_DB.APP.RUN_LOG SET status='UNDONE' WHERE run_id=:P_RUN_ID;

    RETURN 'Reversed run ' || :P_RUN_ID || ' — ' || TO_VARCHAR(:v_n) || ' artefacts removed.';
END;
$$;

SELECT 'APP AI and learning procedures created' AS status;
