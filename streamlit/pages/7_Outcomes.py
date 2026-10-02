import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session, record_outcome, get_recent_outcomes, get_effectiveness_data, get_recent_executions
from utils.persona import render_decision_flow

st.title("Outcomes & Learning")
render_decision_flow("LEARN")
st.caption("Stage: LEARN - Record outcomes, track effectiveness changes, and close the feedback loop.")

session = get_session()
domain = st.session_state.get("domain", "insurance")

st.subheader("Record New Outcome")
with st.form("outcome_form"):
    oc1, oc2, oc3 = st.columns(3)
    with oc1:
        customer_id = st.text_input("Customer ID", "INS-1001")
    with oc2:
        action_name = st.selectbox("Action", ["Claim Escalation", "Retention Call", "Retention Offer", "Policy Review", "Manager Escalation",
            "Payment Plan", "Hardship Program", "Collection Call", "Rate Modification", "Early Intervention"])
    with oc3:
        outcome = st.selectbox("Outcome", ["renewed", "cancelled", "retained", "churned", "engaged", "disengaged",
            "payment_resumed", "defaulted", "restructured", "enrolled"])
    submitted = st.form_submit_button("Record Outcome")
    if submitted:
        result = record_outcome(session, customer_id, action_name, outcome)
        st.toast(result)
        st.rerun()

st.markdown("---")

st.subheader("Recent Outcomes")
outcomes = get_recent_outcomes(session, domain)
if not outcomes.empty:
    st.dataframe(outcomes, use_container_width=True, hide_index=True)
else:
    st.info("No outcomes recorded yet.")

st.markdown("---")

st.subheader("Effectiveness Tracker")
eff_df = get_effectiveness_data(session, domain)
if not eff_df.empty:
    for _, row in eff_df.iterrows():
        st.metric(
            f"{row['ACTION_NAME']} ({row['STATE_NAME']})",
            f"{row['SUCCESS_RATE']:.1%}",
            delta=f"+{row['AVG_UPLIFT']*100:.1f}pp uplift (n={int(row['TOTAL_COUNT'])})"
        )
