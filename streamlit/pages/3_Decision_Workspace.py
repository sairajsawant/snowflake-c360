import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session, recommend_actions, execute_action, policy_check, get_customer_360, get_customer_signals
from utils.persona import render_decision_flow, get_persona_config

st.title("Decision Workspace")
render_decision_flow("DECIDE")
st.caption("Stage: DECIDE & ACT - Review ranked actions, approve, and execute decisions.")

session = get_session()
customer_id = st.session_state.get("selected_customer", None)
persona = st.session_state.get("persona", "default")
persona_cfg = get_persona_config()

if not customer_id:
    customer_id = st.text_input("Enter Customer ID:", "INS-1001")

if customer_id:
    c360 = get_customer_360(session, customer_id)
    if not c360.empty:
        row = c360.iloc[0]
        st.markdown(f"### {row['FULL_NAME']} ({customer_id}) | State: {row.get('STATE_NAME', 'N/A')}")

    col_actions, col_evidence = st.columns(2)

    with col_actions:
        st.subheader("Ranked Actions")
        actions = recommend_actions(session, customer_id, persona)
        if not actions.empty:
            for idx, action in actions.iterrows():
                with st.container():
                    st.markdown(f"**#{action['RANKING']} {action['ACTION_NAME']}**")
                    eff_pct = action['EFFECTIVENESS_RATE'] * 100
                    st.progress(min(action['EFFECTIVENESS_RATE'], 1.0), text=f"{eff_pct:.0f}% effectiveness")
                    st.caption(f"Uplift: +{action['EXPECTED_UPLIFT']*100:.0f}pp | EV: ₹{action['EXPECTED_VALUE']:,.0f} | Cost: ₹{action['ACTION_COST']:,.0f} | Confidence: {action['CONFIDENCE']:.0%}")
                    st.caption(f"Policy: **{action['POLICY_STATUS']}**")

                    if action['POLICY_STATUS'] == 'AUTONOMOUS':
                        if st.button(f"Execute {action['ACTION_NAME']}", key=f"exec_{idx}"):
                            result = execute_action(session, customer_id, action['ACTION_NAME'], persona, "Executed from workspace")
                            st.toast(result)
                            st.rerun()
                    elif action['POLICY_STATUS'] == 'REQUIRES_APPROVAL':
                        if persona_cfg["can_approve"]:
                            if st.button(f"Approve {action['ACTION_NAME']}", key=f"approve_{idx}"):
                                st.session_state[f"show_approval_{idx}"] = True
                        else:
                            st.button(f"Request Approval", key=f"req_{idx}", disabled=True, help="Escalate to Team Lead or VP")

                    if st.session_state.get(f"show_approval_{idx}", False):
                        with st.expander(f"Approve: {action['ACTION_NAME']}", expanded=True):
                            st.write(f"**Action:** {action['ACTION_NAME']}")
                            st.write(f"**Customer:** {customer_id}")
                            modified_amount = st.number_input("Offer Amount (₹)", value=float(action['ACTION_COST']), min_value=0.0, key=f"amt_{idx}")
                            notes = st.text_area("Approval Notes", key=f"notes_{idx}")
                            ac1, ac2 = st.columns(2)
                            with ac1:
                                if st.button("Approve", type="primary", key=f"do_approve_{idx}"):
                                    result = execute_action(session, customer_id, action['ACTION_NAME'], persona, notes)
                                    st.toast(f"Approved: {result}")
                                    st.session_state[f"show_approval_{idx}"] = False
                                    st.rerun()
                            with ac2:
                                if st.button("Reject", key=f"do_reject_{idx}"):
                                    st.toast("Action rejected")
                                    st.session_state[f"show_approval_{idx}"] = False
                                    st.rerun()

                    st.markdown("---")
        else:
            st.info("No actions recommended for current state.")

    with col_evidence:
        st.subheader("Key Evidence")
        signals = get_customer_signals(session, customer_id)
        if not signals.empty:
            for _, sig in signals.head(8).iterrows():
                with st.expander(f"{sig['SIGNAL_NAME']}: {sig['SIGNAL_VALUE']}"):
                    st.caption(f"Source: {sig['EVIDENCE_REF']} | Confidence: {sig['CONFIDENCE']:.0%}")

        if not c360.empty:
            st.markdown("**Data Freshness:**")
            st.caption(f"Customer data: {row.get('LAST_INTERACTION_DATE', 'N/A')}")

        st.markdown("**Scoring Formula:**")
        st.code("score = w_uplift*uplift + w_value*EV - w_cost*cost + w_conf*confidence")
