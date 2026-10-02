import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session, get_portfolio_risk, get_effectiveness_data
from utils.persona import render_decision_flow
from utils.charts import risk_distribution_chart, value_at_risk_chart, effectiveness_chart

st.title("Reports")
render_decision_flow("LEARN")
st.caption("Stage: LEARN - Analyze portfolio risk, action effectiveness, and trends.")

session = get_session()
domain = st.session_state.get("domain", "insurance")

tab1, tab2, tab3 = st.tabs(["Portfolio Risk", "Effectiveness", "SLA"])

with tab1:
    risk_df = get_portfolio_risk(session, domain)
    if not risk_df.empty:
        c1, c2 = st.columns(2)
        with c1:
            st.altair_chart(risk_distribution_chart(risk_df), use_container_width=True)
        with c2:
            st.altair_chart(value_at_risk_chart(risk_df), use_container_width=True)

        total_val = risk_df["TOTAL_VALUE"].sum()
        high_val = risk_df[risk_df["SEVERITY"] >= 3]["TOTAL_VALUE"].sum()
        st.metric("Total Portfolio Value", f"₹{total_val:,.0f}")
        st.metric("High-Risk Value", f"₹{high_val:,.0f}", delta=f"-{high_val/total_val*100:.1f}% at risk" if total_val > 0 else None, delta_color="inverse")
    else:
        st.info("No risk data available.")

with tab2:
    eff_df = get_effectiveness_data(session, domain)
    if not eff_df.empty:
        st.altair_chart(effectiveness_chart(eff_df), use_container_width=True)
        st.dataframe(eff_df, use_container_width=True, hide_index=True)
    else:
        st.info("No effectiveness data available.")

with tab3:
    st.markdown("### SLA Metrics")
    sla_data = session.sql(f"""
        SELECT
            AVG(DATEDIFF(minute, t.transition_date, COALESCE(q.resolved_at, CURRENT_TIMESTAMP()))) AS avg_response_minutes,
            COUNT(CASE WHEN ae.execution_type = 'AUTONOMOUS' THEN 1 END) AS auto_executed,
            COUNT(CASE WHEN ae.execution_type = 'APPROVED' THEN 1 END) AS hitl_executed,
            COUNT(*) AS total_executed
        FROM ENGINE.STATE_TRANSITION t
        LEFT JOIN ENGINE.DECISION_QUEUE q ON t.transition_id = q.transition_id
        LEFT JOIN ENGINE.ACTION_EXECUTION ae ON t.customer_id = ae.customer_id AND ae.domain = '{domain}'
        WHERE t.domain = '{domain}'
    """).to_pandas()

    if not sla_data.empty:
        sc1, sc2, sc3 = st.columns(3)
        with sc1:
            st.metric("Avg Response Time", f"{sla_data['AVG_RESPONSE_MINUTES'].iloc[0]:.0f} min")
        with sc2:
            st.metric("Auto-Executed", int(sla_data['AUTO_EXECUTED'].iloc[0]))
        with sc3:
            st.metric("HITL Actions", int(sla_data['HITL_EXECUTED'].iloc[0]))
