import streamlit as st

st.set_page_config(page_title="Customer 360 Platform", page_icon="", layout="wide")

st.sidebar.title("Customer 360 Platform")
st.sidebar.markdown("---")

persona = st.sidebar.selectbox("Persona", ["relationship_manager", "team_lead", "vp_executive", "analyst"],
    format_func=lambda x: {"relationship_manager": "Relationship Manager", "team_lead": "Team Lead", "vp_executive": "VP Executive", "analyst": "Analyst"}[x])
domain = st.sidebar.selectbox("Domain", ["insurance", "lending"], format_func=str.title)

st.session_state["persona"] = persona
st.session_state["domain"] = domain

st.sidebar.markdown("---")
st.sidebar.caption(f"Role: {persona} | Domain: {domain.title()}")
st.sidebar.caption("Use the navigation above to explore pages.")

st.title("Enterprise Customer Decisioning Platform")
st.markdown("### Decision Flow: DETECT - UNDERSTAND - DECIDE - ACT - LEARN")
st.markdown("""
This platform provides a **closed-loop decisioning system** that:
1. **Detects** customer risk signals from interactions, claims, and payments
2. **Understands** customer context through 360-degree views and AI summaries
3. **Decides** on optimal actions using config-driven scoring and effectiveness data
4. **Acts** on decisions with policy-aware execution and approval workflows
5. **Learns** from outcomes to improve future recommendations

Navigate using the sidebar pages to explore each stage of the decision flow.
""")

st.markdown("---")
col1, col2, col3 = st.columns(3)
with col1:
    st.metric("Domain", domain.title())
with col2:
    st.metric("Persona", persona.replace("_", " ").title())
with col3:
    st.metric("Platform", "Active")
