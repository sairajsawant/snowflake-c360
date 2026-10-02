-- =============================================================================
-- 04_intelligence.sql — Cortex Search, Semantic View, Cortex Agent, Tool SPs
-- NOTE: Cortex Search requires non-trial account for AI embedding.
--       Semantic View DDL may require account feature enablement.
--       Cortex Agent DDL may require specific Snowflake version.
--       Tool SPs work on all accounts.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CUSTOMER_360_DB;

-- =============================================================================
-- SEARCH.INTERACTION_DOCUMENTS — Source table for Cortex Search
-- =============================================================================

CREATE OR REPLACE TABLE SEARCH.INTERACTION_DOCUMENTS AS
SELECT
    i.interaction_id AS doc_id, i.customer_id, c.full_name AS customer_name,
    i.domain, i.channel, i.interaction_type, i.subject,
    COALESCE(e.event_data, i.notes, '') AS content,
    COALESCE(summ.summary_text, '') AS summary,
    i.sentiment_score, i.interaction_date, i.agent_id
FROM CANONICAL.INTERACTION i
JOIN CANONICAL.CUSTOMER c ON i.customer_id = c.customer_id AND i.domain = c.domain
LEFT JOIN CANONICAL.EVENT e ON i.interaction_id = e.interaction_id
LEFT JOIN ENGINE.INTERACTION_SUMMARY summ ON i.customer_id = summ.customer_id AND i.domain = summ.domain;

-- =============================================================================
-- CORTEX SEARCH SERVICE (requires non-trial account)
-- =============================================================================

-- CREATE OR REPLACE CORTEX SEARCH SERVICE SEARCH.CUSTOMER_INTERACTION_SEARCH
--   ON content
--   ATTRIBUTES customer_id, customer_name, domain, channel, interaction_type, subject
--   WAREHOUSE = COMPUTE_WH
--   TARGET_LAG = '1 hour'
--   EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
--   AS (
--     SELECT doc_id, customer_id, customer_name, domain, channel, interaction_type, subject, content, sentiment_score, interaction_date
--     FROM SEARCH.INTERACTION_DOCUMENTS
--   );

-- =============================================================================
-- STAGES
-- =============================================================================

CREATE STAGE IF NOT EXISTS APP.SEMANTIC_STAGE;
CREATE STAGE IF NOT EXISTS APP.STREAMLIT_STAGE;

-- Upload 04_semantic_view.yaml to @APP.SEMANTIC_STAGE/ before creating semantic view
-- PUT file://sql/04_semantic_view.yaml @APP.SEMANTIC_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- =============================================================================
-- TOOL STORED PROCEDURES (work on all accounts)
-- =============================================================================

CREATE OR REPLACE PROCEDURE APP.GET_CUSTOMER_360(P_CUSTOMER_ID VARCHAR)
RETURNS TABLE(customer_id VARCHAR, full_name VARCHAR, domain VARCHAR, segment VARCHAR, lifetime_value FLOAT, relationship_count NUMBER, total_relationship_value FLOAT, open_issues NUMBER, avg_sentiment FLOAT, state_name VARCHAR, severity INT)
LANGUAGE SQL
AS
$$
BEGIN
    LET rs RESULTSET := (
        SELECT c.customer_id, c.full_name, c.domain, c.segment, c.lifetime_value,
            c.relationship_count, c.total_relationship_value, c.open_issues, c.avg_sentiment,
            cs.state_name, cs.severity
        FROM ENGINE.CUSTOMER_360 c
        LEFT JOIN ENGINE.CUSTOMER_STATE cs ON c.customer_id = cs.customer_id AND c.domain = cs.domain AND cs.is_current = TRUE
        WHERE c.customer_id = :P_CUSTOMER_ID
    );
    RETURN TABLE(rs);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.GET_DECISION_QUEUE(P_DOMAIN VARCHAR DEFAULT NULL, P_STATUS VARCHAR DEFAULT 'PENDING')
RETURNS TABLE(customer_id VARCHAR, customer_name VARCHAR, state_name VARCHAR, urgency VARCHAR, severity INT, domain VARCHAR, status VARCHAR, created_at TIMESTAMP_NTZ)
LANGUAGE SQL
AS
$$
BEGIN
    LET rs RESULTSET := (
        SELECT q.customer_id, q.customer_name, q.state_name, q.urgency, q.severity, q.domain, q.status, q.created_at
        FROM ENGINE.DECISION_QUEUE q
        WHERE q.status = :P_STATUS AND (q.domain = :P_DOMAIN OR :P_DOMAIN IS NULL)
        ORDER BY q.severity DESC, q.created_at ASC
    );
    RETURN TABLE(rs);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SUMMARIZE_CUSTOMER(P_CUSTOMER_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_name VARCHAR; v_domain VARCHAR; v_state VARCHAR; v_severity INT;
    v_ltv FLOAT; v_rel_count NUMBER; v_open_issues NUMBER;
    v_signals VARCHAR DEFAULT ''; v_summary VARCHAR;
BEGIN
    SELECT c.full_name, c.domain, cs.state_name, cs.severity, c.lifetime_value, c.relationship_count, c.open_issues
    INTO :v_name, :v_domain, :v_state, :v_severity, :v_ltv, :v_rel_count, :v_open_issues
    FROM ENGINE.CUSTOMER_360 c
    LEFT JOIN ENGINE.CUSTOMER_STATE cs ON c.customer_id = cs.customer_id AND c.domain = cs.domain AND cs.is_current = TRUE
    WHERE c.customer_id = :P_CUSTOMER_ID LIMIT 1;

    SELECT LISTAGG(s.signal_name || '=' || s.signal_value, ', ') WITHIN GROUP (ORDER BY s.signal_name)
    INTO :v_signals FROM ENGINE.SIGNAL s WHERE s.customer_id = :P_CUSTOMER_ID;

    v_summary := :v_name || ' (' || :P_CUSTOMER_ID || ') | Domain: ' || :v_domain ||
        ' | State: ' || :v_state || ' (severity ' || :v_severity::VARCHAR || ')' ||
        ' | LTV: $' || ROUND(:v_ltv, 0)::VARCHAR || ' | Relationships: ' || :v_rel_count::VARCHAR ||
        ' | Open Issues: ' || :v_open_issues::VARCHAR || ' | Signals: ' || :v_signals;
    RETURN :v_summary;
END;
$$;

-- =============================================================================
-- CORTEX AGENT DDL (requires account support)
-- =============================================================================

-- CREATE OR REPLACE CORTEX AGENT APP.CUSTOMER_360_AGENT
--   ORCHESTRATION_MODEL = 'auto'
--   TOOLS = (
--     cortex_analyst(semantic_view => 'APP.CUSTOMER_DECISIONING_VIEW'),
--     -- cortex_search(search_service => 'SEARCH.CUSTOMER_INTERACTION_SEARCH'),
--     sql_exec(tool_description => 'Execute SQL queries against the customer database'),
--     data_to_chart(tool_description => 'Create charts from query results')
--   )
--   SYSTEM_PROMPT = 'You are the Customer 360 Decisioning Agent. You help users understand customer risk states, recommend actions, and manage the customer decision pipeline. Available stored procedures: APP.GET_CUSTOMER_360(customer_id), APP.GET_DECISION_QUEUE(domain, status), APP.RECOMMEND_ACTION(customer_id, persona), APP.EXECUTE_ACTION(customer_id, action_name, persona, amount, notes), APP.RECORD_OUTCOME(customer_id, action_name, outcome), APP.POLICY_CHECK(customer_id, action_name, persona), APP.SUMMARIZE_CUSTOMER(customer_id), APP.DISPATCH_NOTIFICATION(transition_id), APP.SIMULATE_NEW_EVENT(customer_id).';
