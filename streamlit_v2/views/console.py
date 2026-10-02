"""
Operations Console — the persona-scoped product the procedures sit behind.

Studio proves the machinery; this proves it is a product rather than a demo script.
All reads are live.
"""
import altair as alt
import pandas as pd
import streamlit as st

from utils import fmt, sf

# Customers whose evidence is least trustworthy, surfaced rather than buried.
# Each is a real, verifiable condition in the data, not a label.
FLAGS = {
    "INS-1011": ("CONFLICTING EVIDENCE",
                 "churn_intent arrived both HIGH and LOW from two different calls"),
    "INS-1003": ("CONFLICTING EVIDENCE",
                 "churn_intent arrived both HIGH and LOW from two different calls"),
    "LND-2010": ("THIN SAMPLE",
                 "best lending action has n=38; the runner-up has n=45 at half the rate"),
    "LND-2003": ("THIN SAMPLE",
                 "hardship actions carry n=20 and n=14 — confidence 0.70 and 0.62"),
}


def _scope(persona):
    p = sf.personas()
    row = p[p.PERSONA_ID == persona].iloc[0]
    return row


def queue(persona):
    row = _scope(persona)
    st.markdown("### What needs attention")
    st.caption(f"Scope is **{row['DATA_SCOPE_TYPE']}** for {row['PERSONA_NAME']} — "
               + {"ALL": "the whole book", "TEAM": "your team's customers",
                  "ASSIGNED": "only your own customers"}[row["DATA_SCOPE_TYPE"]])

    gap = sf.ownership_gap()
    unowned = int(gap["TOTAL"]) - int(gap["OWNED"])

    q = sf.queue(row["DATA_SCOPE_TYPE"])
    if not len(q):
        st.info("Nothing in scope needs attention.")
        if unowned and row["DATA_SCOPE_TYPE"] != "ALL":
            st.warning(f"**{unowned} of {int(gap['TOTAL'])} customers have no owner** in "
                       "CONFIG.CUSTOMER_ASSIGNMENT, so they appear in no Relationship Manager "
                       "or Team Lead queue at all. Switch to VP Executive for the whole book.")
        return

    k = st.columns(4)
    k[0].metric("Open", len(q))
    k[1].metric("High or worse", int((q.SEVERITY >= 3).sum()))
    k[2].metric("Relationship at risk", fmt.lakh(q.RELATIONSHIP_VALUE.sum()))
    k[3].metric("Critical", int((q.SEVERITY >= 4).sum()))

    view = q.copy()
    view["flag"] = [FLAGS.get(c, ("", ""))[0] for c in view.CUSTOMER_ID]
    view["value"] = view.RELATIONSHIP_VALUE.apply(fmt.lakh)
    st.dataframe(
        view[["CUSTOMER_ID", "FULL_NAME", "SEGMENT", "STATE_NAME", "value", "flag",
              "ASSIGNED_USER"]],
        hide_index=True, use_container_width=True,
        column_config={"CUSTOMER_ID": "ID", "FULL_NAME": "Customer",
                       "SEGMENT": "Segment", "STATE_NAME": "State",
                       "value": "Relationship", "flag": "Trust flag",
                       "ASSIGNED_USER": "Owner"})

    flagged = [c for c in view.CUSTOMER_ID if c in FLAGS]
    if flagged:
        st.caption("**Trust flags are not decoration.** They mark where the engine's answer "
                   "is least reliable:")
        for c in flagged:
            st.caption(f"· `{c}` — {FLAGS[c][1]}")

    ins = q[q.DOMAIN == "insurance"]
    if len(ins) and ins.SEVERITY.max() >= 4:
        top_crit = ins[ins.SEVERITY >= 4].RELATIONSHIP_VALUE.max()
        top_any = q.RELATIONSHIP_VALUE.max()
        if pd.notna(top_crit) and pd.notna(top_any) and top_crit < top_any:
            st.warning("**Risk does not track value here.** The most severe customers are not "
                       "the most valuable ones. The rules are behaving correctly on the "
                       "evidence available, but it means severity has to be read alongside "
                       "relationship value, never on its own.")

    if unowned and row["DATA_SCOPE_TYPE"] != "ALL":
        st.warning(f"**{unowned} of {int(gap['TOTAL'])} customers have no owner** in "
                   f"CONFIG.CUSTOMER_ASSIGNMENT, so this queue can only ever show the "
                   f"{int(gap['OWNED'])} that do. Scoping works correctly — the assignment "
                   "table was simply never backfilled past the original demo set. VP "
                   "Executive sees everything.")

    pick = st.selectbox("Open a customer", ["—"] + list(q.CUSTOMER_ID))
    if pick != "—":
        st.session_state["cid"] = pick
        st.session_state["page"] = "c360"
        st.rerun()


def approvals(persona):
    row = _scope(persona)
    st.markdown("### Waiting on you")
    if not row["CAN_APPROVE"]:
        st.info(f"{row['PERSONA_NAME']} cannot approve actions. Switch role in the sidebar.")
        return
    lim = float(row["EFFECTIVE_LIMIT"])
    st.caption(f"Your ceiling is **{fmt.inr(lim)}**.")

    q = sf.queue(row["DATA_SCOPE_TYPE"])
    pending = []
    for _, c in q.iterrows():
        recs = sf.recommend(c.CUSTOMER_ID, persona, 0)
        need = recs[recs.REQUIRES_APPROVAL]
        if len(need):
            a = need.iloc[0]
            pending.append(dict(cid=c.CUSTOMER_ID, name=c.FULL_NAME,
                                state=c.STATE_NAME, value=c.RELATIONSHIP_VALUE,
                                action=a.ACTION_NAME, action_id=a.ACTION_ID,
                                score=a.SCORE, eff=a.EFFECTIVENESS_RATE))
    if not pending:
        st.success("Nothing is waiting for approval in your scope.")
        return

    for p in pending:
        with st.container(border=True):
            auth = sf.authority(p["action_id"], persona, 0)
            head, badge = st.columns([3, 1])
            head.markdown(f"**{p['action']}** — {p['name']} (`{p['cid']}`)")
            badge.markdown(fmt.policy_chip("PASS" if auth.get("authorised") else "BLOCK"),
                           unsafe_allow_html=True)
            st.markdown(fmt.state_badge(p["state"]), unsafe_allow_html=True)
            m = st.columns(4)
            m[0].metric("Relationship", fmt.lakh(p["value"]))
            m[1].metric("Track record", fmt.pct(p["eff"]))
            m[2].metric("Needs authority", fmt.inr(auth.get("needed")))
            m[3].metric("Your ceiling", fmt.inr(auth.get("persona_limit")))
            if not auth.get("authorised"):
                st.error("Above your authority — escalate to VP Executive.")
            if not auth.get("authorised_under_config"):
                st.caption("⚠ Under the raw CONFIG ceiling this is unapprovable by every "
                           "persona including the VP. Using the corrected rupee limits.")
            st.caption("Approving from here is deliberately not wired — approval belongs to a "
                       "scenario run so it is reversible. Use Scenario Studio.")


def customer_360(persona):
    cdf = sf.customers()
    ids = list(cdf.CUSTOMER_ID)
    cid = st.selectbox("Customer", ids,
                       index=ids.index(st.session_state.get("cid", ids[0]))
                       if st.session_state.get("cid") in ids else 0,
                       format_func=lambda i: f"{i} — {cdf[cdf.CUSTOMER_ID == i].iloc[0]['FULL_NAME']}")
    st.session_state["cid"] = cid
    c = sf.customer(cid)

    st.markdown(f"### {c['FULL_NAME']}")
    st.markdown(fmt.state_badge(c["STATE_NAME"]), unsafe_allow_html=True)
    st.caption(f"{c['SEGMENT']} · {c['REGION']} · {c['DOMAIN']} · `{cid}`"
               + fmt.opt_int(c["CREDIT_SCORE"], prefix=" · credit "))

    k = st.columns(4)
    k[0].metric("Relationship", fmt.lakh(c["RELATIONSHIP_VALUE"]))
    sig = sf.signals(cid)
    k[1].metric("Signals", len(sig))
    k[2].metric("Computed score", f"{c['COMPUTED_SCORE']:.3f}"
                if pd.notna(c["COMPUTED_SCORE"]) else "—")
    k[3].metric("Owner", fmt.opt_str(c["ASSIGNED_USER"]))

    if cid in FLAGS:
        st.warning(f"**{FLAGS[cid][0]}** — {FLAGS[cid][1]}")

    tabs = st.tabs(["Signals", "Products", "History", "Conversations", "Recommendation"])

    with tabs[0]:
        resolved = sf.signals(cid, resolved_only=True)
        winners = set(zip(resolved.SIGNAL_NAME, resolved.EVIDENCE_REF))
        v = sig.assign(used=[("✓" if (n, e) in winners else "")
                             for n, e in zip(sig.SIGNAL_NAME, sig.EVIDENCE_REF)])
        st.dataframe(v[["used", "SIGNAL_NAME", "SIGNAL_VALUE", "NUMERIC_VALUE",
                        "CONFIDENCE", "EVIDENCE_REF", "QUOTE"]],
                     hide_index=True, use_container_width=True)
        st.caption("`✓` marks the reading that survived conflict resolution — most severe "
                   "label first, then recency. Quotes only exist for signals extracted by v2.")

    with tabs[1]:
        prod = sf.products(cid, c["DOMAIN"])
        st.dataframe(prod, hide_index=True, use_container_width=True) if len(prod) \
            else st.caption("No products on file.")
        if c["DOMAIN"] == "insurance":
            cl = sf.claims(cid)
            if len(cl):
                st.dataframe(cl, hide_index=True, use_container_width=True)
                if cl.AGE_DAYS.max() > 400:
                    st.caption(f"⚠ Oldest claim computes to {int(cl.AGE_DAYS.max())} days. "
                               "Seed dates sit in 2024 against a 2026 clock.")

    with tabs[2]:
        h = sf.state_history(cid)
        st.dataframe(h, hide_index=True, use_container_width=True)
        if len(h) <= 1:
            st.caption("Only one state row exists, so there is no before-and-after to show. "
                       "The row churn that used to fill this table is gone — but so is the "
                       "audit trail, until a scenario run produces a real transition.")

    with tabs[3]:
        tdf = sf.transcripts(cid, c["DOMAIN"])
        s = sf.summary(cid)
        if s:
            st.markdown("**AI_SUMMARIZE over the conversation history**")
            st.markdown(f"> {s}")
        for _, t in tdf.iterrows():
            with st.expander(f"{t.TRANSCRIPT_ID} · {t.CALL_DATE}"):
                st.code(t.TRANSCRIPT_TEXT, language=None)
        if not len(tdf):
            st.caption("No conversations on file.")

    with tabs[4]:
        recs = sf.recommend(cid, persona, 0)
        if len(recs):
            st.dataframe(recs[["RANKING", "ACTION_NAME", "POLICY_STATUS", "SCORE",
                               "EFFECTIVENESS_RATE", "SAMPLE_SIZE", "EXPECTED_VALUE"]],
                         hide_index=True, use_container_width=True)
            st.caption(f"Computed live for **{persona.replace('_', ' ')}**. Change role in "
                       "the sidebar and the order can change.")
        else:
            st.info("No action is mapped to this state — the engine recommends nothing "
                    "rather than inventing an intervention.")


def portfolio(persona):
    st.markdown("### Where the risk sits, and what works")
    p = sf.portfolio()
    k = st.columns(4)
    k[0].metric("Scored customers", int(p.CUSTOMERS.sum()))
    k[1].metric("Relationship value", fmt.lakh(p.TOTAL_VALUE.sum()))
    act = sf.recent_activity()
    k[2].metric("Actions carried out", len(act))
    k[3].metric("Outcomes recorded", int(act.OUTCOME_TYPE.notna().sum()) if len(act) else 0)

    st.markdown("##### Relationship value by state")
    for dom in sorted(p.DOMAIN.unique()):
        pv = p[p.DOMAIN == dom].copy()
        st.caption(dom.title())
        chart = (
            alt.Chart(pv)
            .mark_bar(cornerRadiusTopRight=4, cornerRadiusBottomRight=4)
            .encode(
                x=alt.X("TOTAL_VALUE:Q", title="Relationship value (₹)"),
                y=alt.Y("STATE_NAME:N", title=None, sort=alt.EncodingSortField(
                    field="SEVERITY", order="descending")),
                color=alt.Color("SEVERITY:O", legend=None,
                                scale=alt.Scale(domain=[1, 2, 3, 4],
                                                range=[fmt.SEV_COLOR[1], fmt.SEV_COLOR[2],
                                                       fmt.SEV_COLOR[3], fmt.SEV_COLOR[4]])),
                tooltip=["STATE_NAME", "CUSTOMERS", "TOTAL_VALUE"],
            ).properties(height=28 * max(len(pv), 1) + 20)
        )
        st.altair_chart(chart, use_container_width=True)
    st.caption("Bars are coloured by severity and every row is labelled, so colour never "
               "carries the meaning on its own.")

    st.markdown("##### What actually works")
    eff = sf.effectiveness()
    ev = eff.copy()
    ev["thin"] = ev.CONFIDENCE < 0.70
    ev["SUCCESS_RATE"] = ev["SUCCESS_RATE"] * 100
    st.dataframe(
        ev[["ACTION_NAME", "STATE_NAME", "SUCCESS_RATE", "SUCCESS_COUNT", "TOTAL_COUNT",
            "AVG_UPLIFT", "CONFIDENCE", "thin"]],
        hide_index=True, use_container_width=True,
        column_config={
            "ACTION_NAME": "Action", "STATE_NAME": "At state",
            "SUCCESS_RATE": st.column_config.ProgressColumn(
                "Success", min_value=0, max_value=100, format="%.1f%%"),
            "SUCCESS_COUNT": st.column_config.NumberColumn("wins", width="small"),
            "TOTAL_COUNT": st.column_config.NumberColumn("n", width="small"),
            "AVG_UPLIFT": st.column_config.NumberColumn("Uplift", format="%.2f"),
            "CONFIDENCE": st.column_config.NumberColumn("Conf", format="%.2f"),
            "thin": st.column_config.CheckboxColumn("thin sample?"),
        })
    st.caption("Rows under 0.70 confidence are flagged. The recommender discounts them "
               "rather than treating 14 cases like 112.")

    if len(act):
        st.markdown("##### Recent activity")
        st.dataframe(act, hide_index=True, use_container_width=True)
    else:
        st.info("No actions have been carried out yet. Run a scenario in the Studio and "
                "this fills up — those five ENGINE tables were empty until v2 wrote to them.")


def ask(persona):
    st.markdown("### Ask the data")
    st.caption("Cortex Search over the current interaction corpus — every transcript and "
               "logged contact for the 30 customers in the book, including anything a "
               "scenario run just injected.")
    st.caption("⚠ The original SEARCH.CUSTOMER_INTERACTION_SEARCH still indexes the 60 "
               "pre-migration documents, so it returns customers who no longer exist. v2 "
               "searches APP_V2.INTERACTION_SEARCH_V2, built from CANONICAL.INTERACTION.")
    q = st.text_input("Question", value="customers threatening to port to a competitor")
    if st.button("Search", type="primary") or q:
        with st.spinner("Cortex Search…"):
            res = sf.search_interactions(q, limit=5)
        if res and isinstance(res, list) and res[0].get("error"):
            st.error(f"Search unavailable: {res[0]['error']}")
            st.caption("The service exists and is ACTIVE; if this persists the warehouse may "
                       "be resuming.")
        else:
            for r in res:
                with st.container(border=True):
                    st.markdown(f"**{r.get('CUSTOMER_NAME','—')}** · {r.get('SUBJECT','—')}")
                    st.caption((r.get("CONTENT") or "")[:400])
    st.divider()
    st.caption("The Cortex Agent (`APP.CUSTOMER_360_AGENT`) is deployed and can orchestrate "
               "Analyst plus Search plus these procedures. Wiring its streaming REST endpoint "
               "into Streamlit is the one piece still outstanding.")


def config(persona):
    row = _scope(persona)
    st.markdown("### Change behaviour without shipping code")
    if not row["CAN_CONFIGURE"]:
        st.info(f"{row['PERSONA_NAME']} has read-only access to configuration. "
                "Switch to Analyst in the sidebar.")

    st.markdown("##### Scoring weights")
    st.dataframe(sf.scoring_weights(), hide_index=True, use_container_width=True)
    st.caption("These are read live by APP_V2.RECOMMEND_ACTION. Personas without a row fall "
               "back to `default` — the original APP.RECOMMEND_ACTION returns zero rows "
               "instead, which is why Team Lead and Analyst got no recommendations at all.")

    st.markdown("##### Approval ceilings")
    p = sf.personas()
    pv = p.copy()
    pv["needs fixing"] = pv.CONFIG_LIMIT != pv.EFFECTIVE_LIMIT
    st.dataframe(pv[["PERSONA_NAME", "DATA_SCOPE_TYPE", "CONFIG_LIMIT", "EFFECTIVE_LIMIT",
                     "needs fixing", "NOTE"]],
                 hide_index=True, use_container_width=True)
    st.error("**CONFIG.USER_PERSONA still holds the unconverted values.** Policy gates are in "
             "rupees (₹4,15,000+) while the ceilings are 25,000 and 100,000, so no persona — "
             "not even the VP — can approve anything. v2 reads a corrected override table. "
             "The real fix is two UPDATE statements:")
    st.code("UPDATE CONFIG.USER_PERSONA SET max_approval_value = 2075000 "
            "WHERE persona_id='team_lead';\n"
            "UPDATE CONFIG.USER_PERSONA SET max_approval_value = 8300000 "
            "WHERE persona_id='vp_executive';", language="sql")

    st.markdown("##### State rules")
    dom = st.selectbox("Domain", ["insurance", "lending"])
    st.dataframe(sf.state_rules(dom), hide_index=True, use_container_width=True)
    st.warning("Priority and the active flag **are** honoured — switching a rule off or "
               "reordering the ladder genuinely works. The predicates are still hardcoded in "
               "COMPUTE_STATES keyed on domain and priority, so editing a threshold here has "
               "no effect, and a third domain would produce no state at all. That is the "
               "remaining gap between the extensibility claim and the implementation.")

    st.markdown("##### Signals")
    defs = sf.signal_definitions(dom)
    live = sf.live_signal_names()
    dv = defs.copy()
    dv["producing rows?"] = ["yes" if s in live else "NO" for s in dv.SIGNAL_NAME]
    st.dataframe(dv[["SIGNAL_NAME", "EXTRACTION_METHOD", "WEIGHT", "SOURCE_TABLE",
                     "producing rows?"]], hide_index=True, use_container_width=True)


PAGES = {"queue": queue, "approvals": approvals, "c360": customer_360,
         "portfolio": portfolio, "agent": ask, "config": config}


def render(page, persona):
    PAGES.get(page, queue)(persona)
