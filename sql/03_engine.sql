-- =============================================================================
-- 03_engine.sql — Decisioning Engine Stored Procedures
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

-- =============================================================================
-- 1. RECOMMEND_ACTION — Returns ranked action candidates for a customer
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.RECOMMEND_ACTION(P_CUSTOMER_ID VARCHAR, P_PERSONA VARCHAR DEFAULT 'default')
RETURNS TABLE(action_id VARCHAR, action_name VARCHAR, action_type VARCHAR, score FLOAT, effectiveness_rate FLOAT, expected_uplift FLOAT, expected_value FLOAT, action_cost FLOAT, confidence FLOAT, ranking INT, requires_approval BOOLEAN, policy_status VARCHAR)
LANGUAGE SQL
AS
$$
DECLARE
    v_domain VARCHAR;
    v_state_id VARCHAR;
    v_lifetime_value FLOAT;
BEGIN
    SELECT cs.domain, cs.state_id INTO :v_domain, :v_state_id
    FROM ENGINE.CUSTOMER_STATE cs WHERE cs.customer_id = :P_CUSTOMER_ID AND cs.is_current = TRUE LIMIT 1;

    SELECT COALESCE(c360.total_relationship_value, c360.lifetime_value, 10000) INTO :v_lifetime_value
    FROM ENGINE.CUSTOMER_360 c360 WHERE c360.customer_id = :P_CUSTOMER_ID LIMIT 1;

    LET rs RESULTSET := (
        WITH candidates AS (
            SELECT ad.action_id, ad.action_name, ad.action_type, ad.default_cost, ad.requires_approval, ad.approval_threshold,
                COALESCE(ae.success_rate, 0.5) AS effectiveness_rate,
                COALESCE(ae.avg_uplift, 0.05) AS expected_uplift,
                COALESCE(ae.confidence, 0.5) AS confidence
            FROM CONFIG.ACTION_DEFINITION ad
            JOIN CONFIG.ACTION_STATE_MAPPING asm ON ad.action_id = asm.action_id AND asm.state_id = :v_state_id AND asm.domain_id = :v_domain
            LEFT JOIN ENGINE.ACTION_EFFECTIVENESS ae ON ad.action_id = ae.action_id AND ae.state_id = :v_state_id AND ae.domain_id = :v_domain
            WHERE ad.active = TRUE AND asm.active = TRUE
        ),
        scored AS (
            SELECT c.*,
                c.expected_uplift * :v_lifetime_value AS expected_value,
                (COALESCE(sc_u.weight, 0.4) * c.expected_uplift +
                 COALESCE(sc_v.weight, 0.3) * (c.expected_uplift * :v_lifetime_value / NULLIF(:v_lifetime_value, 0)) +
                 COALESCE(sc_c.weight, -0.1) * (c.default_cost / NULLIF(:v_lifetime_value, 0)) +
                 COALESCE(sc_f.weight, 0.2) * c.confidence) AS score
            FROM candidates c
            LEFT JOIN CONFIG.SCORING_CONFIG sc_u ON sc_u.domain_id = :v_domain AND sc_u.persona = :P_PERSONA AND sc_u.factor_name = 'effectiveness_uplift' AND sc_u.active = TRUE
            LEFT JOIN CONFIG.SCORING_CONFIG sc_v ON sc_v.domain_id = :v_domain AND sc_v.persona = :P_PERSONA AND sc_v.factor_name = 'business_value' AND sc_v.active = TRUE
            LEFT JOIN CONFIG.SCORING_CONFIG sc_c ON sc_c.domain_id = :v_domain AND sc_c.persona = :P_PERSONA AND sc_c.factor_name = 'action_cost' AND sc_c.active = TRUE
            LEFT JOIN CONFIG.SCORING_CONFIG sc_f ON sc_f.domain_id = :v_domain AND sc_f.persona = :P_PERSONA AND sc_f.factor_name = 'confidence' AND sc_f.active = TRUE
        )
        SELECT action_id, action_name, action_type, score, effectiveness_rate, expected_uplift,
            expected_value, default_cost AS action_cost, confidence,
            ROW_NUMBER() OVER (ORDER BY score DESC) AS ranking,
            requires_approval,
            CASE WHEN requires_approval THEN 'REQUIRES_APPROVAL' WHEN action_type = 'AUTONOMOUS' THEN 'AUTONOMOUS' ELSE 'MANUAL' END AS policy_status
        FROM scored ORDER BY score DESC
    );
    RETURN TABLE(rs);
END;
$$;

-- =============================================================================
-- 2. EXECUTE_ACTION — Executes an action for a customer
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.EXECUTE_ACTION(P_CUSTOMER_ID VARCHAR, P_ACTION_NAME VARCHAR, P_PERSONA VARCHAR DEFAULT 'default', P_MODIFIED_AMOUNT FLOAT DEFAULT NULL, P_NOTES VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_action_id VARCHAR;
    v_action_type VARCHAR;
    v_requires_approval BOOLEAN;
    v_domain VARCHAR;
    v_exec_id VARCHAR DEFAULT '';
BEGIN
    SELECT ad.action_id, ad.action_type, ad.requires_approval
    INTO :v_action_id, :v_action_type, :v_requires_approval
    FROM CONFIG.ACTION_DEFINITION ad WHERE ad.action_name = :P_ACTION_NAME AND ad.active = TRUE LIMIT 1;

    SELECT cs.domain INTO :v_domain
    FROM ENGINE.CUSTOMER_STATE cs WHERE cs.customer_id = :P_CUSTOMER_ID AND cs.is_current = TRUE LIMIT 1;

    IF (:v_requires_approval AND :P_PERSONA = 'relationship_manager') THEN
        RETURN 'BLOCKED: Action requires approval. RM cannot approve.';
    END IF;

    v_exec_id := 'exec-' || :P_CUSTOMER_ID || '-' || :v_action_id || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3');

    INSERT INTO ENGINE.ACTION_EXECUTION (execution_id, customer_id, action_id, action_name, domain, execution_type, executed_by, execution_notes, status, executed_at)
    VALUES (:v_exec_id, :P_CUSTOMER_ID, :v_action_id, :P_ACTION_NAME, :v_domain,
        CASE WHEN :v_requires_approval THEN 'APPROVED' ELSE 'AUTONOMOUS' END,
        :P_PERSONA, :P_NOTES, 'EXECUTED', CURRENT_TIMESTAMP());

    UPDATE ENGINE.DECISION_QUEUE SET status = 'RESOLVED', resolved_at = CURRENT_TIMESTAMP()
    WHERE customer_id = :P_CUSTOMER_ID AND status = 'PENDING';

    RETURN 'SUCCESS: ' || :P_ACTION_NAME || ' executed for ' || :P_CUSTOMER_ID || '. ID: ' || :v_exec_id;
END;
$$;

-- =============================================================================
-- 3. RECORD_OUTCOME — Records outcome and updates effectiveness
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.RECORD_OUTCOME(P_CUSTOMER_ID VARCHAR, P_ACTION_NAME VARCHAR, P_OUTCOME VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_exec_id VARCHAR;
    v_action_id VARCHAR;
    v_domain VARCHAR;
    v_state_id VARCHAR;
    v_state_before VARCHAR;
    v_success BOOLEAN DEFAULT FALSE;
BEGIN
    SELECT ae.execution_id, ae.action_id, ae.domain
    INTO :v_exec_id, :v_action_id, :v_domain
    FROM ENGINE.ACTION_EXECUTION ae
    WHERE ae.customer_id = :P_CUSTOMER_ID AND ae.action_name = :P_ACTION_NAME
    ORDER BY ae.executed_at DESC LIMIT 1;

    IF (EXISTS (SELECT 1 FROM ENGINE.ACTION_OUTCOME ao WHERE ao.execution_id = :v_exec_id)) THEN
        RETURN 'SKIPPED: Outcome already recorded for execution ' || :v_exec_id;
    END IF;

    SELECT cs.state_id, cs.state_name INTO :v_state_id, :v_state_before
    FROM ENGINE.CUSTOMER_STATE cs WHERE cs.customer_id = :P_CUSTOMER_ID AND cs.is_current = TRUE LIMIT 1;

    v_success := (:P_OUTCOME IN ('renewed', 'retained', 'engaged', 'payment_resumed', 'restructured', 'enrolled'));

    INSERT INTO ENGINE.ACTION_OUTCOME (outcome_id, execution_id, customer_id, action_id, domain, outcome_type, state_before, state_after, success, notes, recorded_at)
    VALUES ('outcome-' || :v_exec_id, :v_exec_id, :P_CUSTOMER_ID, :v_action_id, :v_domain,
        :P_OUTCOME, :v_state_before, :P_OUTCOME, :v_success, NULL, CURRENT_TIMESTAMP());

    MERGE INTO ENGINE.ACTION_EFFECTIVENESS tgt
    USING (SELECT :v_action_id AS action_id, :v_state_id AS state_id, :v_domain AS domain_id) src
    ON tgt.action_id = src.action_id AND tgt.state_id = src.state_id AND tgt.domain_id = src.domain_id
    WHEN MATCHED THEN UPDATE SET
        total_count = tgt.total_count + 1,
        success_count = tgt.success_count + CASE WHEN :v_success THEN 1 ELSE 0 END,
        success_rate = (tgt.success_count + CASE WHEN :v_success THEN 1 ELSE 0 END)::FLOAT / (tgt.total_count + 1),
        last_updated = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (effectiveness_id, action_id, state_id, domain_id, success_count, total_count, success_rate, avg_uplift, confidence, last_updated)
        VALUES ('eff-new-' || :v_action_id || '-' || :v_state_id, :v_action_id, :v_state_id, :v_domain,
            CASE WHEN :v_success THEN 1 ELSE 0 END, 1, CASE WHEN :v_success THEN 1.0 ELSE 0.0 END, 0.05, 0.3, CURRENT_TIMESTAMP());

    RETURN 'SUCCESS: Outcome ' || :P_OUTCOME || ' recorded. Effectiveness updated.';
END;
$$;

-- =============================================================================
-- 4. POLICY_CHECK — Deterministic policy check for an action
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.POLICY_CHECK(P_CUSTOMER_ID VARCHAR, P_ACTION_NAME VARCHAR, P_PERSONA VARCHAR DEFAULT 'default')
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_action_type VARCHAR;
    v_requires_approval BOOLEAN;
    v_approval_threshold FLOAT;
    v_max_approval FLOAT;
    v_can_approve BOOLEAN;
BEGIN
    SELECT ad.action_type, ad.requires_approval, ad.approval_threshold
    INTO :v_action_type, :v_requires_approval, :v_approval_threshold
    FROM CONFIG.ACTION_DEFINITION ad WHERE ad.action_name = :P_ACTION_NAME AND ad.active = TRUE LIMIT 1;

    SELECT up.can_approve, up.max_approval_value
    INTO :v_can_approve, :v_max_approval
    FROM CONFIG.USER_PERSONA up WHERE up.persona_id = :P_PERSONA LIMIT 1;

    IF (NOT :v_requires_approval AND :v_action_type = 'AUTONOMOUS') THEN
        RETURN 'AUTONOMOUS: Action can be executed automatically.';
    ELSEIF (:v_requires_approval AND :v_can_approve AND :v_approval_threshold <= :v_max_approval) THEN
        RETURN 'REQUIRES_APPROVAL: Persona ' || :P_PERSONA || ' can approve up to ₹' || :v_max_approval::VARCHAR || '.';
    ELSEIF (:v_requires_approval AND NOT :v_can_approve) THEN
        RETURN 'BLOCKED: Persona ' || :P_PERSONA || ' cannot approve actions. Escalate to team_lead or vp_executive.';
    ELSEIF (:v_requires_approval AND :v_approval_threshold > :v_max_approval) THEN
        RETURN 'BLOCKED: Threshold ₹' || :v_approval_threshold::VARCHAR || ' exceeds limit ₹' || :v_max_approval::VARCHAR || '.';
    ELSE
        RETURN 'MANUAL: Action requires manual execution.';
    END IF;
END;
$$;

-- =============================================================================
-- 5. DISPATCH_NOTIFICATION — Logs notifications for a transition
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.DISPATCH_NOTIFICATION(P_TRANSITION_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_customer_id VARCHAR;
    v_customer_name VARCHAR;
    v_old_state VARCHAR;
    v_new_state VARCHAR;
    v_domain VARCHAR;
    v_count INT DEFAULT 0;
BEGIN
    SELECT t.customer_id, t.previous_state_name, t.new_state_name, t.domain
    INTO :v_customer_id, :v_old_state, :v_new_state, :v_domain
    FROM ENGINE.STATE_TRANSITION t WHERE t.transition_id = :P_TRANSITION_ID;

    SELECT c.full_name INTO :v_customer_name
    FROM CANONICAL.CUSTOMER c WHERE c.customer_id = :v_customer_id AND c.domain = :v_domain LIMIT 1;

    INSERT INTO ENGINE.NOTIFICATION_LOG (log_id, channel_id, channel_type, event_type, customer_id, domain, message, status, sent_at)
    SELECT
        'notif-' || nr.rule_id || '-' || :P_TRANSITION_ID,
        nr.channel_id, nc.channel_type, nr.trigger_event, :v_customer_id, :v_domain,
        REPLACE(REPLACE(REPLACE(REPLACE(nr.message_template,
            '{{customer_name}}', :v_customer_name), '{{customer_id}}', :v_customer_id),
            '{{old_state}}', COALESCE(:v_old_state, 'NONE')), '{{new_state}}', :v_new_state),
        'LOGGED', CURRENT_TIMESTAMP()
    FROM CONFIG.NOTIFICATION_RULE nr
    JOIN CONFIG.NOTIFICATION_CHANNEL nc ON nr.channel_id = nc.channel_id
    WHERE nr.domain_id = :v_domain AND nr.active = TRUE AND nc.active = TRUE;

    SELECT COUNT(*) INTO :v_count FROM ENGINE.NOTIFICATION_LOG WHERE log_id LIKE 'notif-%-' || :P_TRANSITION_ID;
    RETURN 'Dispatched ' || :v_count || ' notifications for transition ' || :P_TRANSITION_ID;
END;
$$;

-- =============================================================================
-- 6. SIMULATE_NEW_EVENT — Insert synthetic event for demo
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.SIMULATE_NEW_EVENT(P_CUSTOMER_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_domain VARCHAR;
    v_transcript_id VARCHAR DEFAULT '';
    v_interaction_id VARCHAR DEFAULT '';
BEGIN
    SELECT c.domain INTO :v_domain FROM CANONICAL.CUSTOMER c WHERE c.customer_id = :P_CUSTOMER_ID LIMIT 1;

    v_interaction_id := 'INT-SIM-' || :P_CUSTOMER_ID || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3');
    v_transcript_id := 'TRN-SIM-' || :P_CUSTOMER_ID || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3');

    IF (:v_domain = 'insurance') THEN
        INSERT INTO RAW.INSURANCE_INTERACTIONS VALUES
            (:v_interaction_id, :P_CUSTOMER_ID, 'PHONE', 'complaint', 'Urgent follow-up call', -0.85, 420, 'AGT-101', CURRENT_TIMESTAMP(), 'Customer extremely frustrated. Threatening to cancel.', CURRENT_TIMESTAMP());
        INSERT INTO RAW.INSURANCE_CALL_TRANSCRIPTS VALUES
            (:v_transcript_id, :v_interaction_id, :P_CUSTOMER_ID,
            'Agent: Thank you for calling.\nCustomer: I am done waiting. I want to cancel everything.\nAgent: I understand. Let me look into this.\nCustomer: I have quotes from other companies. Unless you resolve this today, I am switching.\nAgent: Let me escalate immediately.\nCustomer: You have until end of day.',
            CURRENT_TIMESTAMP(), 420, 'AGT-101', CURRENT_TIMESTAMP());
    ELSE
        INSERT INTO RAW.LENDING_INTERACTIONS VALUES
            (:v_interaction_id, :P_CUSTOMER_ID, 'PHONE', 'complaint', 'Payment hardship call', -0.80, 360, 'AGT-201', CURRENT_TIMESTAMP(), 'Customer in financial distress.', CURRENT_TIMESTAMP());
        INSERT INTO RAW.LENDING_CALL_TRANSCRIPTS VALUES
            (:v_transcript_id, :v_interaction_id, :P_CUSTOMER_ID,
            'Agent: How can I help?\nCustomer: I lost my job and can not make payments.\nAgent: We have hardship programs.\nCustomer: I am struggling to pay for basic needs right now.',
            CURRENT_TIMESTAMP(), 360, 'AGT-201', CURRENT_TIMESTAMP());
    END IF;

    RETURN 'Simulated event for ' || :P_CUSTOMER_ID || ' (' || :v_domain || '). Interaction: ' || :v_interaction_id;
END;
$$;
