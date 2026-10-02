import altair as alt
import pandas as pd

def risk_distribution_chart(df):
    color_map = {
        "LOW_CHURN_RISK": "#4CAF50", "MEDIUM_CHURN_RISK": "#FF9800",
        "HIGH_CHURN_RISK": "#F44336", "CRITICAL_CHURN_RISK": "#9C27B0",
        "LOW_PAYMENT_RISK": "#4CAF50", "MEDIUM_PAYMENT_RISK": "#FF9800",
        "HIGH_PAYMENT_RISK": "#F44336", "HARDSHIP": "#9C27B0"
    }
    states = list(color_map.keys())
    colors = list(color_map.values())
    chart = alt.Chart(df).mark_bar().encode(
        x=alt.X("STATE_NAME:N", title="", sort="-y"),
        y=alt.Y("CUSTOMER_COUNT:Q", title="Customers"),
        color=alt.Color("STATE_NAME:N", scale=alt.Scale(domain=states, range=colors), legend=None),
        tooltip=["STATE_NAME", "CUSTOMER_COUNT"]
    ).properties(title="Customers by Risk Level", height=350)
    return chart

def value_at_risk_chart(df):
    chart = alt.Chart(df).mark_bar().encode(
        x=alt.X("STATE_NAME:N", title="", sort="-y"),
        y=alt.Y("TOTAL_VALUE:Q", title="Value (INR)"),
        color=alt.Color("STATE_NAME:N", legend=None),
        tooltip=["STATE_NAME", "TOTAL_VALUE"]
    ).properties(title="Value at Risk by State", height=350)
    return chart

def effectiveness_chart(df):
    chart = alt.Chart(df).mark_circle().encode(
        x=alt.X("TOTAL_COUNT:Q", title="Sample Size"),
        y=alt.Y("SUCCESS_RATE:Q", title="Success Rate"),
        size=alt.Size("CONFIDENCE:Q", legend=None),
        color=alt.Color("ACTION_NAME:N"),
        tooltip=["ACTION_NAME", "STATE_NAME", "SUCCESS_RATE", "AVG_UPLIFT", "TOTAL_COUNT"]
    ).properties(title="Action Effectiveness", height=400)
    return chart

def state_timeline_chart(df):
    if df.empty:
        return alt.Chart(pd.DataFrame()).mark_point()
    severity_map = {
        "LOW_CHURN_RISK": 1, "MEDIUM_CHURN_RISK": 2, "HIGH_CHURN_RISK": 3, "CRITICAL_CHURN_RISK": 4,
        "LOW_PAYMENT_RISK": 1, "MEDIUM_PAYMENT_RISK": 2, "HIGH_PAYMENT_RISK": 3, "HARDSHIP": 4
    }
    df = df.copy()
    df["SEVERITY_NUM"] = df["STATE_NAME"].map(severity_map).fillna(0)
    chart = alt.Chart(df).mark_circle(size=100).encode(
        x=alt.X("EFFECTIVE_FROM:T", title="Date"),
        y=alt.Y("SEVERITY_NUM:Q", title="Severity"),
        color=alt.Color("STATE_NAME:N"),
        tooltip=["STATE_NAME", "EFFECTIVE_FROM", "SEVERITY_NUM"]
    ).properties(title="State History Timeline", height=300)
    return chart
