import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session, get_config_table
from utils.persona import render_decision_flow, get_persona_config

st.title("Platform Configuration")
render_decision_flow("LEARN")
st.caption("Configure signals, states, actions, policies, and notifications for each domain.")

session = get_session()
domain = st.session_state.get("domain", "insurance")
persona_cfg = get_persona_config()

if not persona_cfg["can_configure"]:
    st.warning(f"Persona '{st.session_state.get('persona', '')}' has read-only access to configuration. Switch to 'analyst' persona to edit.")

tab_names = ["Signals", "States", "Actions", "Policies", "Notifications"]
tabs = st.tabs(tab_names)

config_tables = {
    "Signals": "SIGNAL_DEFINITION",
    "States": "STATE_DEFINITION",
    "Actions": "ACTION_DEFINITION",
    "Policies": "POLICY_RULE",
    "Notifications": "NOTIFICATION_RULE",
}

for tab, tab_name in zip(tabs, tab_names):
    with tab:
        table_name = config_tables[tab_name]
        try:
            df = get_config_table(session, table_name, domain)
            if not df.empty:
                if persona_cfg["can_configure"]:
                    edited = st.data_editor(df, use_container_width=True, num_rows="dynamic")
                    if st.button(f"Save {tab_name}", key=f"save_{tab_name}"):
                        st.toast(f"Saved {tab_name} changes (write-back not implemented in demo)")
                else:
                    st.dataframe(df, use_container_width=True, hide_index=True)
            else:
                st.info(f"No {tab_name.lower()} configured for {domain}.")
        except Exception as e:
            st.error(f"Error loading {table_name}: {e}")
