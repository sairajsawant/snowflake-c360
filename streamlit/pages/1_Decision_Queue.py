import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session, get_decision_queue, get_queue_kpis, get_value_at_risk, simulate_event
from utils.persona import render_decision_flow, get_persona_config

st.title("Decision Queue")
render_decision_flow("DETECT")
st.caption("Stage: DETECT - Monitor customer risk transitions and prioritize responses.")

session = get_session()
domain = st.session_state.get("domain", "insurance")
persona_cfg = get_persona_config()

kpis = get_queue_kpis(session, domain)
var_df = get_value_at_risk(session, domain)

c1, c2, c3, c4 = st.columns(4)
with c1:
    st.metric("Total Items", int(kpis["TOTAL"].iloc[0]) if not kpis.empty else 0)
with c2:
    st.metric("Critical/High", int(kpis["CRITICAL"].iloc[0]) if not kpis.empty else 0)
with c3:
    st.metric("Pending", int(kpis["PENDING"].iloc[0]) if not kpis.empty else 0)
with c4:
    val = float(var_df["VALUE_AT_RISK"].iloc[0]) if not var_df.empty else 0
    st.metric("Value at Risk", f"₹{val:,.0f}")

st.markdown("---")

col_filter, col_sim = st.columns([3, 1])
with col_filter:
    urgency_filter = st.selectbox("Filter by Urgency", ["All", "CRITICAL", "HIGH", "MEDIUM", "LOW"])
with col_sim:
    st.markdown("<br>", unsafe_allow_html=True)
    if st.button("Simulate New Event"):
        result = simulate_event(session, "INS-1005" if domain == "insurance" else "LND-2003")
        st.toast(result)
        st.rerun()

queue_df = get_decision_queue(session, domain)
if urgency_filter != "All":
    queue_df = queue_df[queue_df["URGENCY"] == urgency_filter]

if not queue_df.empty:
    st.dataframe(queue_df, use_container_width=True, hide_index=True)

    selected = st.selectbox("Select customer to view 360:", queue_df["CUSTOMER_ID"].tolist())
    if st.button("View Customer 360"):
        st.session_state["selected_customer"] = selected
        st.switch_page("pages/2_Customer_360.py")
else:
    st.info("No items in decision queue.")
