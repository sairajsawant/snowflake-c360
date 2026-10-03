-- =============================================================================
-- Semantic View + Cortex Agent, rebuilt clean under APP.
--
-- The agent previously pointed at four broken or stale things:
--   get_customer_360      -> APP.GET_CUSTOMER_360        (dropped, v1)
--   get_decision_queue    -> APP.GET_DECISION_QUEUE       (dropped, v1)
--   recommend_action      -> APP.RECOMMEND_ACTION          (dropped — the
--                             broken one, selected sc.effectiveness_weight
--                             which does not exist)
--   summarize_customer    -> APP.SUMMARIZE_CUSTOMER        (dropped, v1)
--   interaction_search    -> SEARCH.CUSTOMER_INTERACTION_SEARCH (dropped —
--                             60 pre-migration documents, wrong customers)
--
-- The compatibility procedures below give the agent the same four call
-- signatures, correctly implemented against the real data. interaction_search
-- and customer_decisioning_analyst are repointed to the objects created above.
-- =============================================================================
USE DATABASE CUSTOMER_360_DB;
USE SCHEMA APP;

-- ─── agent-facing compatibility wrappers ─────────────────────────────────────
CREATE OR REPLACE PROCEDURE GET_CUSTOMER_360(CUSTOMER_ID VARCHAR)
RETURNS TABLE (CUSTOMER_ID VARCHAR, FULL_NAME VARCHAR, DOMAIN VARCHAR, SEGMENT VARCHAR,
    REGION VARCHAR, RELATIONSHIP_VALUE FLOAT, STATE_NAME VARCHAR, SEVERITY NUMBER,
    TENURE_YEARS NUMBER, TICKETS_OPEN NUMBER, SLA_BREACHES_90D NUMBER,
    GRIEVANCES_OPEN NUMBER, PORTABILITY_STAGE VARCHAR, EMPLOYER_NAME VARCHAR,
    EMPLOYEE_COUNT NUMBER, CLAIMS_OPEN NUMBER)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE res RESULTSET;
BEGIN
    res := (
        SELECT customer_id, full_name, domain, segment, region, relationship_value,
            state_name, severity, tenure_years, tickets_open, sla_breaches_90d,
            grievances_open, portability_stage, employer_name, employee_count, claims_open
        FROM CUSTOMER_360_DB.APP.V_CUSTOMER_PROFILE WHERE customer_id = :CUSTOMER_ID
    );
    RETURN TABLE(res);
END;
$$;

CREATE OR REPLACE PROCEDURE GET_DECISION_QUEUE(DOMAIN VARCHAR, STATUS VARCHAR)
RETURNS TABLE (CUSTOMER_ID VARCHAR, CUSTOMER_NAME VARCHAR, STATE_NAME VARCHAR,
    DOMAIN VARCHAR, URGENCY VARCHAR, SEVERITY NUMBER, STATUS VARCHAR, CREATED_AT TIMESTAMP_NTZ)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE res RESULTSET;
BEGIN
    res := (
        SELECT customer_id, customer_name, state_name, domain, urgency, severity, status, created_at
        FROM CUSTOMER_360_DB.ENGINE.DECISION_QUEUE
        WHERE (:DOMAIN IS NULL OR domain = :DOMAIN)
          AND (:STATUS IS NULL OR status = :STATUS)
        ORDER BY severity DESC, created_at DESC
    );
    RETURN TABLE(res);
END;
$$;

-- Two-argument form matching the agent's tool_spec (customer_id, domain). The
-- three-argument persona-aware procedure of the same name already exists —
-- Snowflake resolves by argument count, so both coexist without conflict.
CREATE OR REPLACE PROCEDURE RECOMMEND_ACTION(CUSTOMER_ID VARCHAR, DOMAIN VARCHAR)
RETURNS TABLE (ACTION_ID VARCHAR, ACTION_NAME VARCHAR, RANKING NUMBER, SCORE FLOAT,
    EFFECTIVENESS_RATE FLOAT, SAMPLE_SIZE NUMBER, EXPECTED_UPLIFT FLOAT,
    EXPECTED_VALUE FLOAT, TOTAL_COST FLOAT, REQUIRES_APPROVAL BOOLEAN, POLICY_STATUS VARCHAR)
LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE res RESULTSET;
BEGIN
    res := (
        SELECT action_id, action_name, ranking, score, effectiveness_rate, sample_size,
               expected_uplift, expected_value, total_cost, requires_approval, policy_status
        FROM TABLE(CUSTOMER_360_DB.APP.RECOMMEND(:CUSTOMER_ID, 'default', 0::FLOAT))
    );
    RETURN TABLE(res);
END;
$$;

-- One-argument form matching the agent (no run_id — this call does not
-- participate in a reversible scenario run, so nothing is written to
-- RUN_ARTIFACT; it only persists the summary, same as the run-scoped version).
CREATE OR REPLACE PROCEDURE SUMMARIZE_CUSTOMER(CUSTOMER_ID VARCHAR)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER
AS
$$
DECLARE
    v_dom VARCHAR; v_corpus VARCHAR; v_sum VARCHAR; v_id VARCHAR;
BEGIN
    v_dom := (SELECT domain FROM CUSTOMER_360_DB.CANONICAL.CUSTOMER WHERE customer_id=:CUSTOMER_ID LIMIT 1);
    IF (v_dom = 'insurance') THEN
        v_corpus := (SELECT LISTAGG(transcript_text, '

') WITHIN GROUP (ORDER BY call_date DESC)
            FROM CUSTOMER_360_DB.RAW.INSURANCE_CALL_TRANSCRIPTS WHERE customer_id=:CUSTOMER_ID);
    ELSE
        v_corpus := (SELECT LISTAGG(transcript_text, '

') WITHIN GROUP (ORDER BY call_date DESC)
            FROM CUSTOMER_360_DB.RAW.LENDING_CALL_TRANSCRIPTS WHERE customer_id=:CUSTOMER_ID);
    END IF;
    IF (v_corpus IS NULL) THEN
        RETURN 'No conversations on file for this customer.';
    END IF;
    v_sum := (SELECT SNOWFLAKE.CORTEX.SUMMARIZE(:v_corpus));
    v_id  := 'sum-agent-' || :CUSTOMER_ID || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISSFF3');
    INSERT INTO CUSTOMER_360_DB.ENGINE.INTERACTION_SUMMARY
        (summary_id, customer_id, domain, summary_text, source_interactions, generated_at)
    SELECT :v_id, :CUSTOMER_ID, :v_dom, :v_sum, NULL, CURRENT_TIMESTAMP();
    RETURN v_sum;
END;
$$;

-- ─── semantic view (self-contained SQL; identical to the original) ──────────
create or replace semantic view CUSTOMER_DECISIONING_VIEW
	tables (
		CUSTOMER_360_DB.ENGINE.CUSTOMER_360,
		CUSTOMER_360_DB.ENGINE.CUSTOMER_STATE,
		CUSTOMER_360_DB.ENGINE.DECISION_QUEUE,
		CUSTOMER_360_DB.ENGINE.ACTION_EFFECTIVENESS
	)
	dimensions (
		CUSTOMER_360.CUSTOMER_ID as CUSTOMER_ID comment='Unique customer identifier',
		CUSTOMER_360.FULL_NAME as FULL_NAME comment='Customer full name',
		CUSTOMER_360.EMAIL as EMAIL comment='Customer email address',
		CUSTOMER_360.DOMAIN as DOMAIN comment='Business domain (insurance or lending)',
		CUSTOMER_360.SEGMENT as SEGMENT comment='Customer segment classification',
		CUSTOMER_360.REGION as REGION comment='Customer geographic region/state',
		CUSTOMER_360.SOURCE_SYSTEM as SOURCE_SYSTEM comment='Source system identifier',
		CUSTOMER_360.CUSTOMER_SINCE as CUSTOMER_SINCE comment='Date customer relationship began',
		CUSTOMER_360.LAST_INTERACTION_DATE as LAST_INTERACTION_DATE comment='Most recent interaction timestamp',
		CUSTOMER_360.NEXT_RENEWAL_DATE as NEXT_RENEWAL_DATE comment='Next renewal date',
		CUSTOMER_STATE.STATE_CUSTOMER_ID as CUSTOMER_ID comment='Customer identifier for state',
		CUSTOMER_STATE.STATE_ID as STATE_ID comment='Current state identifier',
		CUSTOMER_STATE.STATE_NAME as STATE_NAME comment='Current state name',
		CUSTOMER_STATE.STATE_DOMAIN as DOMAIN comment='Domain for this state',
		CUSTOMER_STATE.IS_CURRENT as IS_CURRENT comment='Whether this is the current state',
		CUSTOMER_STATE.EFFECTIVE_FROM as EFFECTIVE_FROM comment='When this state became effective',
		DECISION_QUEUE.QUEUE_CUSTOMER_ID as CUSTOMER_ID comment='Customer in the decision queue',
		DECISION_QUEUE.QUEUE_CUSTOMER_NAME as CUSTOMER_NAME comment='Customer name in queue',
		DECISION_QUEUE.QUEUE_STATE_NAME as STATE_NAME comment='State that triggered the queue entry',
		DECISION_QUEUE.QUEUE_DOMAIN as DOMAIN comment='Domain for queue entry',
		DECISION_QUEUE.URGENCY as URGENCY comment='Urgency level',
		DECISION_QUEUE.QUEUE_STATUS as STATUS comment='Queue item status',
		DECISION_QUEUE.QUEUE_CREATED_AT as CREATED_AT comment='When the queue item was created',
		ACTION_EFFECTIVENESS.EFF_ACTION_ID as ACTION_ID comment='Action identifier',
		ACTION_EFFECTIVENESS.EFF_STATE_ID as STATE_ID comment='State identifier',
		ACTION_EFFECTIVENESS.EFF_DOMAIN_ID as DOMAIN_ID comment='Domain for effectiveness'
	)
	with extension (CA='{"tables":[{"name":"CUSTOMER_360","dimensions":[{"name":"CUSTOMER_ID"},{"name":"FULL_NAME"},{"name":"EMAIL"},{"name":"DOMAIN"},{"name":"SEGMENT"},{"name":"REGION"},{"name":"SOURCE_SYSTEM"}],"time_dimensions":[{"name":"CUSTOMER_SINCE"},{"name":"LAST_INTERACTION_DATE"},{"name":"NEXT_RENEWAL_DATE"}],"measures":[{"name":"CUSTOMER_LIFETIME_VALUE","expr":"LIFETIME_VALUE","description":"Customer lifetime value in dollars","default_aggregation":"sum"},{"name":"RELATIONSHIP_COUNT","expr":"RELATIONSHIP_COUNT","description":"Number of active relationships","default_aggregation":"sum"},{"name":"TOTAL_RELATIONSHIP_VALUE","expr":"TOTAL_RELATIONSHIP_VALUE","description":"Total value across all relationships","default_aggregation":"sum"},{"name":"TOTAL_PERIODIC_AMOUNT","expr":"TOTAL_PERIODIC_AMOUNT","description":"Total recurring payment amount","default_aggregation":"sum"},{"name":"OPEN_ISSUES","expr":"OPEN_ISSUES","description":"Count of unresolved claims or issues","default_aggregation":"sum"},{"name":"AVG_SENTIMENT","expr":"AVG_SENTIMENT","description":"Average sentiment score","default_aggregation":"avg"},{"name":"INTERACTION_COUNT","expr":"INTERACTION_COUNT","description":"Total number of customer interactions","default_aggregation":"sum"}]},{"name":"CUSTOMER_STATE","dimensions":[{"name":"STATE_CUSTOMER_ID"},{"name":"STATE_ID"},{"name":"STATE_NAME"},{"name":"STATE_DOMAIN"},{"name":"IS_CURRENT"}],"time_dimensions":[{"name":"EFFECTIVE_FROM"}],"measures":[{"name":"SEVERITY","expr":"SEVERITY","description":"State severity level","default_aggregation":"max"},{"name":"COMPUTED_SCORE","expr":"COMPUTED_SCORE","description":"Computed risk score","default_aggregation":"avg"}]},{"name":"DECISION_QUEUE","dimensions":[{"name":"QUEUE_CUSTOMER_ID"},{"name":"QUEUE_CUSTOMER_NAME"},{"name":"QUEUE_STATE_NAME"},{"name":"QUEUE_DOMAIN"},{"name":"URGENCY"},{"name":"QUEUE_STATUS"}],"time_dimensions":[{"name":"QUEUE_CREATED_AT"}],"measures":[{"name":"QUEUE_SEVERITY","expr":"SEVERITY","description":"Severity of the queue item","default_aggregation":"max"}]},{"name":"ACTION_EFFECTIVENESS","dimensions":[{"name":"EFF_ACTION_ID"},{"name":"EFF_STATE_ID"},{"name":"EFF_DOMAIN_ID"}],"measures":[{"name":"SUCCESS_RATE","expr":"SUCCESS_RATE","description":"Action success rate","default_aggregation":"avg"},{"name":"SUCCESS_COUNT","expr":"SUCCESS_COUNT","description":"Number of successful outcomes","default_aggregation":"sum"},{"name":"TOTAL_COUNT","expr":"TOTAL_COUNT","description":"Total action attempts","default_aggregation":"sum"},{"name":"AVG_UPLIFT","expr":"AVG_UPLIFT","description":"Average uplift from action","default_aggregation":"avg"},{"name":"CONFIDENCE","expr":"CONFIDENCE","description":"Statistical confidence level","default_aggregation":"avg"}]}]}');

SELECT 'Compatibility procedures + semantic view ready' AS status;
