import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session, get_customer_360, get_customer_signals, get_customer_interactions, get_customer_state_history, get_customer_transcripts, get_interaction_summary
from utils.persona import render_decision_flow
from utils.charts import state_timeline_chart

st.title("Customer 360")
render_decision_flow("UNDERSTAND")
st.caption("Stage: UNDERSTAND - Deep dive into customer context, signals, and history.")

session = get_session()
customer_id = st.session_state.get("selected_customer", None)

if not customer_id:
    customer_id = st.text_input("Enter Customer ID:", "INS-1001")

if customer_id:
    c360 = get_customer_360(session, customer_id)
    if c360.empty:
        st.error(f"Customer {customer_id} not found.")
        st.stop()

    row = c360.iloc[0]
    st.markdown(f"### {row['FULL_NAME']} ({customer_id})")

    badge_colors = {"HIGH_CHURN_RISK": "red", "CRITICAL_CHURN_RISK": "red", "MEDIUM_CHURN_RISK": "orange", "LOW_CHURN_RISK": "green",
                    "HIGH_PAYMENT_RISK": "red", "HARDSHIP": "red", "MEDIUM_PAYMENT_RISK": "orange", "LOW_PAYMENT_RISK": "green"}
    state = row.get("STATE_NAME", "UNKNOWN")
    st.markdown(f"**State:** :{badge_colors.get(state, 'gray')}[{state}] | **Domain:** {row['DOMAIN']} | **Segment:** {row.get('SEGMENT', 'N/A')}")

    mc1, mc2, mc3, mc4 = st.columns(4)
    with mc1:
        st.metric("Lifetime Value", f"₹{row['LIFETIME_VALUE']:,.0f}" if row['LIFETIME_VALUE'] else "N/A")
    with mc2:
        st.metric("Relationships", int(row['RELATIONSHIP_COUNT']))
    with mc3:
        st.metric("Open Issues", int(row['OPEN_ISSUES']))
    with mc4:
        st.metric("Avg Sentiment", f"{row['AVG_SENTIMENT']:.2f}" if row['AVG_SENTIMENT'] else "N/A")

    tab1, tab2, tab3, tab4, tab5 = st.tabs(["Profile", "Signals", "History", "Evidence", "Actions"])

    with tab1:
        st.dataframe(c360.T.rename(columns={0: "Value"}), use_container_width=True)

    with tab2:
        signals = get_customer_signals(session, customer_id)
        if not signals.empty:
            st.dataframe(signals, use_container_width=True, hide_index=True)
        else:
            st.info("No signals extracted yet.")

    with tab3:
        history = get_customer_state_history(session, customer_id)
        if not history.empty:
            st.altair_chart(state_timeline_chart(history), use_container_width=True)
            st.dataframe(history, use_container_width=True, hide_index=True)

    with tab4:
        summary = get_interaction_summary(session, customer_id)
        if not summary.empty and summary.iloc[0]["SUMMARY_TEXT"]:
            st.markdown("**AI Summary:**")
            st.info(summary.iloc[0]["SUMMARY_TEXT"])

        transcripts = get_customer_transcripts(session, customer_id)
        if not transcripts.empty:
            for _, t in transcripts.iterrows():
                with st.expander(f"Transcript: {t['EVENT_ID']} ({t['EVENT_DATE']})"):
                    st.text(t["EVENT_DATA"])

    with tab5:
        interactions = get_customer_interactions(session, customer_id)
        if not interactions.empty:
            st.dataframe(interactions, use_container_width=True, hide_index=True)

    st.markdown("---")
    if st.button("Open Decision Workspace"):
        st.session_state["selected_customer"] = customer_id
        st.switch_page("pages/3_Decision_Workspace.py")
