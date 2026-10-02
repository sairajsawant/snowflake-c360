import streamlit as st

def get_persona_config():
    persona = st.session_state.get("persona", "relationship_manager")
    configs = {
        "relationship_manager": {"name": "Relationship Manager", "scope": "ASSIGNED", "can_approve": False, "can_configure": False, "max_approval": 0, "default_view": "Decision Queue"},
        "team_lead": {"name": "Team Lead", "scope": "TEAM", "can_approve": True, "can_configure": False, "max_approval": 2000000, "default_view": "Decision Queue"},
        "vp_executive": {"name": "VP Executive", "scope": "ALL", "can_approve": True, "can_configure": False, "max_approval": 8300000, "default_view": "Reports"},
        "analyst": {"name": "Analyst", "scope": "ALL", "can_approve": False, "can_configure": True, "max_approval": 0, "default_view": "Reports"},
    }
    return configs.get(persona, configs["relationship_manager"])

def get_scope_filter(session):
    persona = get_persona_config()
    if persona["scope"] == "ALL":
        return ""
    elif persona["scope"] == "TEAM":
        return "AND ca.assigned_team = 'team_alpha'"
    else:
        return "AND ca.assigned_user = 'agent_rm_1'"

DECISION_FLOW_STEPS = ["DETECT", "UNDERSTAND", "DECIDE", "ACT", "LEARN"]

def render_decision_flow(current_step):
    cols = st.columns(len(DECISION_FLOW_STEPS))
    for i, (col, step) in enumerate(zip(cols, DECISION_FLOW_STEPS)):
        with col:
            if step == current_step:
                st.markdown(f"**:blue[{step}]**")
            elif DECISION_FLOW_STEPS.index(step) < DECISION_FLOW_STEPS.index(current_step):
                st.markdown(f"~~{step}~~")
            else:
                st.markdown(f"{step}")
