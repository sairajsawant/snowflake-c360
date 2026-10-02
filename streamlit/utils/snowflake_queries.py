from snowflake.snowpark.context import get_active_session

def get_session():
    return get_active_session()

def get_decision_queue(session, domain):
    return session.sql(f"""
        SELECT q.customer_id, q.customer_name, q.state_name, q.urgency, q.severity, q.domain, q.status, q.created_at
        FROM ENGINE.DECISION_QUEUE q
        WHERE q.status = 'PENDING' AND q.domain = '{domain}'
        ORDER BY q.severity DESC, q.created_at ASC
    """).to_pandas()

def get_queue_kpis(session, domain):
    return session.sql(f"""
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN urgency IN ('CRITICAL','HIGH') THEN 1 ELSE 0 END) AS critical,
            SUM(CASE WHEN status = 'PENDING' THEN 1 ELSE 0 END) AS pending
        FROM ENGINE.DECISION_QUEUE WHERE domain = '{domain}'
    """).to_pandas()

def get_value_at_risk(session, domain):
    return session.sql(f"""
        SELECT COALESCE(SUM(c.total_relationship_value), 0) AS value_at_risk
        FROM ENGINE.CUSTOMER_360 c
        JOIN ENGINE.CUSTOMER_STATE cs ON c.customer_id = cs.customer_id AND c.domain = cs.domain
        WHERE cs.is_current = TRUE AND cs.severity >= 3 AND c.domain = '{domain}'
    """).to_pandas()

def get_customer_360(session, customer_id):
    return session.sql(f"CALL APP.GET_CUSTOMER_360('{customer_id}')").to_pandas()

def get_customer_signals(session, customer_id):
    return session.sql(f"""
        SELECT signal_name, signal_value, numeric_value, confidence, evidence_ref, extracted_at
        FROM ENGINE.SIGNAL WHERE customer_id = '{customer_id}'
        ORDER BY extracted_at DESC
    """).to_pandas()

def get_customer_interactions(session, customer_id):
    return session.sql(f"""
        SELECT interaction_id, channel, interaction_type, subject, sentiment_score, interaction_date
        FROM CANONICAL.INTERACTION WHERE customer_id = '{customer_id}'
        ORDER BY interaction_date DESC LIMIT 20
    """).to_pandas()

def get_customer_state_history(session, customer_id):
    return session.sql(f"""
        SELECT state_name, severity, computed_score, effective_from, effective_to, is_current
        FROM ENGINE.CUSTOMER_STATE WHERE customer_id = '{customer_id}'
        ORDER BY effective_from DESC
    """).to_pandas()

def get_customer_transcripts(session, customer_id):
    return session.sql(f"""
        SELECT e.event_id, e.event_data, e.event_date, e.duration_seconds
        FROM CANONICAL.EVENT e WHERE e.customer_id = '{customer_id}'
        ORDER BY e.event_date DESC
    """).to_pandas()

def get_interaction_summary(session, customer_id):
    return session.sql(f"""
        SELECT summary_text FROM ENGINE.INTERACTION_SUMMARY WHERE customer_id = '{customer_id}' LIMIT 1
    """).to_pandas()

def recommend_actions(session, customer_id, persona):
    return session.sql(f"CALL APP.RECOMMEND_ACTION('{customer_id}', '{persona}')").to_pandas()

def execute_action(session, customer_id, action_name, persona, notes=""):
    result = session.sql(f"CALL APP.EXECUTE_ACTION('{customer_id}', '{action_name}', '{persona}', NULL, '{notes}')").collect()
    return result[0][0]

def record_outcome(session, customer_id, action_name, outcome):
    result = session.sql(f"CALL APP.RECORD_OUTCOME('{customer_id}', '{action_name}', '{outcome}')").collect()
    return result[0][0]

def policy_check(session, customer_id, action_name, persona):
    result = session.sql(f"CALL APP.POLICY_CHECK('{customer_id}', '{action_name}', '{persona}')").collect()
    return result[0][0]

def get_effectiveness_data(session, domain):
    return session.sql(f"""
        SELECT ae.action_id, ad.action_name, ae.state_id, sd.state_name, ae.domain_id,
            ae.success_rate, ae.avg_uplift, ae.total_count, ae.confidence
        FROM ENGINE.ACTION_EFFECTIVENESS ae
        JOIN CONFIG.ACTION_DEFINITION ad ON ae.action_id = ad.action_id
        JOIN CONFIG.STATE_DEFINITION sd ON ae.state_id = sd.state_id
        WHERE ae.domain_id = '{domain}'
        ORDER BY ae.success_rate DESC
    """).to_pandas()

def get_portfolio_risk(session, domain):
    return session.sql(f"""
        SELECT cs.state_name, cs.severity, COUNT(*) AS customer_count,
            SUM(c.total_relationship_value) AS total_value
        FROM ENGINE.CUSTOMER_360 c
        JOIN ENGINE.CUSTOMER_STATE cs ON c.customer_id = cs.customer_id AND c.domain = cs.domain
        WHERE cs.is_current = TRUE AND c.domain = '{domain}'
        GROUP BY cs.state_name, cs.severity ORDER BY cs.severity DESC
    """).to_pandas()

def get_recent_outcomes(session, domain):
    return session.sql(f"""
        SELECT ao.customer_id, c.full_name, ao.outcome_type, ao.state_before, ao.state_after,
            ao.success, ad.action_name, ao.recorded_at
        FROM ENGINE.ACTION_OUTCOME ao
        JOIN ENGINE.ACTION_EXECUTION ae ON ao.execution_id = ae.execution_id
        JOIN CONFIG.ACTION_DEFINITION ad ON ao.action_id = ad.action_id
        JOIN CANONICAL.CUSTOMER c ON ao.customer_id = c.customer_id AND ao.domain = c.domain
        WHERE ao.domain = '{domain}'
        ORDER BY ao.recorded_at DESC LIMIT 20
    """).to_pandas()

def get_config_table(session, table_name, domain):
    return session.sql(f"SELECT * FROM CONFIG.{table_name} WHERE domain_id = '{domain}' OR domain = '{domain}'").to_pandas()

def simulate_event(session, customer_id):
    result = session.sql(f"CALL APP.SIMULATE_NEW_EVENT('{customer_id}')").collect()
    return result[0][0]

def get_recent_executions(session, customer_id):
    return session.sql(f"""
        SELECT action_name, execution_type, executed_by, status, executed_at
        FROM ENGINE.ACTION_EXECUTION WHERE customer_id = '{customer_id}'
        ORDER BY executed_at DESC LIMIT 10
    """).to_pandas()
