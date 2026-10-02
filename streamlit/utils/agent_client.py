import json
import _snowflake

def call_agent(session, prompt, conversation_history=None):
    """Call Cortex Agent REST API (placeholder for when agent is available)."""
    try:
        result = session.sql(f"CALL APP.SUMMARIZE_CUSTOMER('{prompt}')").collect()
        return result[0][0]
    except Exception:
        return f"Agent not available. Try calling stored procedures directly: CALL APP.GET_CUSTOMER_360('{prompt}')"
