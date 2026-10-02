import streamlit as st
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils.snowflake_queries import get_session
from utils.persona import render_decision_flow

st.title("Agent Chat")
render_decision_flow("UNDERSTAND")
st.caption("Chat with the Customer 360 Agent to explore data, get recommendations, and execute actions.")

session = get_session()

if "chat_history" not in st.session_state:
    st.session_state.chat_history = []

for msg in st.session_state.chat_history:
    with st.chat_message(msg["role"]):
        st.write(msg["content"])

prompt = st.chat_input("Ask the agent...")

if prompt:
    st.session_state.chat_history.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.write(prompt)

    with st.chat_message("assistant"):
        with st.spinner("Thinking..."):
            try:
                if "ins-1001" in prompt.lower() or "rajesh" in prompt.lower():
                    result = session.sql("CALL APP.SUMMARIZE_CUSTOMER('INS-1001')").collect()
                    response = result[0][0]
                elif "ins-1002" in prompt.lower() or "priya" in prompt.lower():
                    result = session.sql("CALL APP.SUMMARIZE_CUSTOMER('INS-1002')").collect()
                    response = result[0][0]
                elif "queue" in prompt.lower() or "pending" in prompt.lower():
                    df = session.sql("CALL APP.GET_DECISION_QUEUE(NULL, 'PENDING')").to_pandas()
                    response = f"There are {len(df)} pending items in the decision queue:\n" + df.to_string(index=False)
                elif "recommend" in prompt.lower():
                    cid = "INS-1001"
                    for c in ["INS-1001", "INS-1002", "INS-1005", "LND-2001", "LND-2005"]:
                        if c.lower() in prompt.lower():
                            cid = c
                            break
                    df = session.sql(f"CALL APP.RECOMMEND_ACTION('{cid}', 'default')").to_pandas()
                    response = f"Recommendations for {cid}:\n" + df[["ACTION_NAME", "SCORE", "EFFECTIVENESS_RATE", "POLICY_STATUS"]].to_string(index=False)
                elif "high" in prompt.lower() and ("churn" in prompt.lower() or "risk" in prompt.lower()):
                    df = session.sql("""
                        SELECT c.customer_id, c.full_name, cs.state_name, cs.severity
                        FROM ENGINE.CUSTOMER_360 c JOIN ENGINE.CUSTOMER_STATE cs ON c.customer_id = cs.customer_id AND c.domain = cs.domain
                        WHERE cs.is_current = TRUE AND cs.severity >= 3 ORDER BY cs.severity DESC
                    """).to_pandas()
                    response = f"High-risk customers:\n" + df.to_string(index=False)
                else:
                    response = "I can help with customer lookups (mention a customer ID like INS-1001), decision queue status, action recommendations, and risk analysis. Try asking about specific customers or the pending queue."
            except Exception as e:
                response = f"Error: {str(e)}"

            st.write(response)
    st.session_state.chat_history.append({"role": "assistant", "content": response})
