-- =============================================================================
-- 05_evaluation.sql — Test Cases, Demo Script, Evaluation Framework
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

-- =============================================================================
-- EVAL.TEST_CASES — 10 test classes
-- =============================================================================

CREATE OR REPLACE TABLE EVAL.TEST_CASES (
    test_id INT PRIMARY KEY,
    test_class VARCHAR(50) NOT NULL,
    customer_id VARCHAR(50),
    question VARCHAR(500),
    expected_tools VARCHAR(500),
    expected_action VARCHAR(200),
    expected_state VARCHAR(100),
    expected_policy VARCHAR(100)
);

INSERT INTO EVAL.TEST_CASES VALUES
    (1, 'NORMAL_CASE', 'C1023', 'What actions for Sarah Chen?', 'recommend_action,get_customer_360', 'Claim Escalation', 'HIGH_CHURN_RISK', 'AUTONOMOUS'),
    (2, 'HIGH_RISK', 'C1067', 'Maria wants to cancel.', 'recommend_action,policy_check', 'Retention Offer', 'HIGH_CHURN_RISK', 'REQUIRES_APPROVAL'),
    (3, 'INSUFFICIENT_EVIDENCE', 'C1012', 'Nicole Clark risk level?', 'get_customer_360', NULL, 'LOW_CHURN_RISK', NULL),
    (4, 'STALE_DATA', 'C1002', 'Emily Johnson recent activity?', 'get_customer_360', NULL, 'LOW_CHURN_RISK', NULL),
    (5, 'COLD_START', 'C2015', 'Tom Nguyen hardship.', 'recommend_action', 'Hardship Program', 'HIGH_PAYMENT_RISK', 'REQUIRES_APPROVAL'),
    (6, 'DUPLICATE_EVENT', 'C1023', 'Sarah called again.', 'extract_signals', 'Claim Escalation', 'HIGH_CHURN_RISK', 'AUTONOMOUS'),
    (7, 'POLICY_VIOLATION', 'C1067', 'Can RM approve offer?', 'policy_check', 'Retention Offer', 'HIGH_CHURN_RISK', 'BLOCKED'),
    (8, 'AMBIGUOUS_CASE', 'C1089', 'James has mixed signals.', 'summarize_customer', NULL, 'MEDIUM_CHURN_RISK', NULL),
    (9, 'HUMAN_APPROVAL', 'C1067', 'Team lead approves offer.', 'execute_action', 'Retention Offer', 'HIGH_CHURN_RISK', 'REQUIRES_APPROVAL'),
    (10, 'DOMAIN_PORTABILITY', 'C2001', 'Priya at payment risk.', 'recommend_action', 'Collection Call', 'HIGH_PAYMENT_RISK', 'AUTONOMOUS');

-- =============================================================================
-- APP.RUN_DEMO — 12-act closed-loop demo
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.RUN_DEMO()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_result VARCHAR DEFAULT '';
    v_step VARCHAR DEFAULT '';
BEGIN
    v_step := 'Act 1: Simulate new event';
    CALL APP.SIMULATE_NEW_EVENT('C1023');
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 2: Extract signals';
    CALL ENGINE.EXTRACT_SIGNALS();
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 3: Verify signals';
    LET signal_count INT := (SELECT COUNT(*) FROM ENGINE.SIGNAL WHERE customer_id = 'C1023');
    v_result := :v_result || :v_step || ' - ' || :signal_count::VARCHAR || ' signals\n';

    v_step := 'Act 4: Compute states';
    CALL ENGINE.COMPUTE_STATES();
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 5: Detect transitions';
    CALL ENGINE.DETECT_TRANSITIONS();
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 6: Verify state';
    LET current_state VARCHAR := (SELECT state_name FROM ENGINE.CUSTOMER_STATE WHERE customer_id = 'C1023' AND is_current = TRUE LIMIT 1);
    v_result := :v_result || :v_step || ' - ' || :current_state || '\n';

    v_step := 'Act 7: Decision queue';
    LET queue_count INT := (SELECT COUNT(*) FROM ENGINE.DECISION_QUEUE WHERE customer_id = 'C1023' AND status = 'PENDING');
    v_result := :v_result || :v_step || ' - ' || :queue_count::VARCHAR || ' pending\n';

    v_step := 'Act 8: Notifications';
    LET trans_id VARCHAR := (SELECT transition_id FROM ENGINE.STATE_TRANSITION WHERE customer_id = 'C1023' ORDER BY transition_date DESC LIMIT 1);
    IF (:trans_id IS NOT NULL) THEN
        CALL APP.DISPATCH_NOTIFICATION(:trans_id);
    END IF;
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 9: Recommend actions';
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 10: Execute action';
    CALL APP.EXECUTE_ACTION('C1023', 'Claim Escalation', 'relationship_manager', NULL, 'Demo');
    v_result := :v_result || :v_step || ' - DONE\n';

    v_step := 'Act 11: Record outcome';
    CALL APP.RECORD_OUTCOME('C1023', 'Claim Escalation', 'renewed');
    v_result := :v_result || :v_step || ' - renewed\n';

    v_step := 'Act 12: Verify effectiveness';
    LET eff_rate FLOAT := (SELECT success_rate FROM ENGINE.ACTION_EFFECTIVENESS WHERE action_id = 'ins_claim_escalation' AND state_id = 'ins_high_churn');
    LET eff_count INT := (SELECT total_count FROM ENGINE.ACTION_EFFECTIVENESS WHERE action_id = 'ins_claim_escalation' AND state_id = 'ins_high_churn');
    v_result := :v_result || :v_step || ' - Rate: ' || ROUND(:eff_rate, 4)::VARCHAR || ', n=' || :eff_count::VARCHAR || '\n';

    v_result := :v_result || '\nDEMO COMPLETE';
    RETURN :v_result;
END;
$$;
