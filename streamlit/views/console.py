"""
Operations Console — the persona-scoped product the procedures sit behind.

Studio proves the machinery; this proves it is a product rather than a demo script.
All reads are live.
"""
import altair as alt
import pandas as pd
import streamlit as st

from utils import fmt, sf


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

    q = sf.queue(row["DATA_SCOPE_TYPE"], persona, "team_alpha")
    if not len(q):
        st.info("Nothing in scope needs attention.")
        if unowned and row["DATA_SCOPE_TYPE"] != "ALL":
            st.warning(f"**{unowned} of {int(gap['TOTAL'])} customers have no owner** in "
                       "CONFIG.CUSTOMER_ASSIGNMENT, so they appear in no RM or Team Lead "
                       "queue at all. Switch to Team Lead for the whole book.")
        return

    k = st.columns(4)
    k[0].metric("Open", len(q))
    k[1].metric("High or worse", int((q.SEVERITY >= 3).sum()))
    k[2].metric("Relationship at risk", fmt.lakh(q.RELATIONSHIP_VALUE.sum()))
    k[3].metric("Critical", int((q.SEVERITY >= 4).sum()))

    tf = sf.trust_flags().set_index("CUSTOMER_ID")
    view = q.copy()
    view["flag"] = [tf.loc[c, "FLAG"] if c in tf.index else "" for c in view.CUSTOMER_ID]
    view["value"] = view.RELATIONSHIP_VALUE.apply(fmt.lakh)
    st.dataframe(
        view[["CUSTOMER_ID", "FULL_NAME", "SEGMENT", "STATE_NAME", "value", "flag",
              "ASSIGNED_USER"]],
        hide_index=True, use_container_width=True,
        column_config={"CUSTOMER_ID": "ID", "FULL_NAME": "Customer",
                       "SEGMENT": "Segment", "STATE_NAME": "State",
                       "value": "Relationship", "flag": "Trust flag",
                       "ASSIGNED_USER": "Owner"})

    flagged = [c for c in view.CUSTOMER_ID if c in tf.index]
    if flagged:
        st.caption("**Trust flags are not decoration — computed from APP.V_TRUST_FLAGS for "
                   "every customer, not a hand-picked few.** They mark where the engine's "
                   "answer is least reliable:")
        for c in flagged:
            st.caption(f"· `{c}` — {tf.loc[c, 'DETAIL']}")

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

    pending = sf.pending_approvals(row["DATA_SCOPE_TYPE"], persona, persona, "team_alpha")
    if not len(pending):
        st.success("Nothing is waiting for approval in your scope.")
        return
    st.caption("Computed server-side by APP.PENDING_APPROVALS — one Snowpark call scores "
               "every customer in scope and keeps the top candidate that needs sign-off.")

    for _, p in pending.iterrows():
        with st.container(border=True):
            auth = sf.authority(p["ACTION_ID"], persona, 0)
            head, badge = st.columns([3, 1])
            head.markdown(f"**{p['ACTION_NAME']}** — {p['FULL_NAME']} (`{p['CUSTOMER_ID']}`)")
            badge.markdown(fmt.policy_chip("PASS" if auth.get("authorised") else "BLOCK"),
                           unsafe_allow_html=True)
            st.markdown(fmt.state_badge(p["STATE_NAME"], p["SEVERITY"]), unsafe_allow_html=True)
            m = st.columns(4)
            m[0].metric("Relationship", fmt.lakh(p["RELATIONSHIP_VALUE"]))
            m[1].metric("Track record", fmt.pct(p["EFFECTIVENESS_RATE"]))
            m[2].metric("Needs authority", fmt.inr(auth.get("needed")))
            m[3].metric("Your ceiling", fmt.inr(auth.get("persona_limit")))
            if not auth.get("authorised"):
                st.error("Above your authority — escalate to Team Lead.")
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
    p = sf.profile(cid)
    if p is None:
        st.warning("No profile for this customer.")
        return

    st.markdown(f"### {p['FULL_NAME']}")
    st.markdown(fmt.state_badge(p["STATE_NAME"], p["SEVERITY"]), unsafe_allow_html=True)
    st.caption(f"{fmt.opt_str(p['SEGMENT'])} · {fmt.opt_str(p['REGION'])} · {p['DOMAIN']} · `{cid}` · "
               f"customer since {p['CUSTOMER_SINCE']} ({fmt.opt_int(p['TENURE_YEARS'])} years)")

    k = st.columns(5)
    k[0].metric("Relationship", fmt.lakh(p["RELATIONSHIP_VALUE"]))
    k[1].metric("Renewals", fmt.opt_int(p["TENURE_RENEWALS"]) or "—",
                help="Policy versions on the longest-held policy")
    k[2].metric("Open tickets", fmt.opt_int(p["TICKETS_OPEN"]) or "0")
    k[3].metric("SLA breaches 90d", fmt.opt_int(p["SLA_BREACHES_90D"]) or "0")
    k[4].metric("CSAT", f"{p['CSAT_AVG']:.1f}" if not fmt.missing(p["CSAT_AVG"]) else "—")

    # the things that should stop a reader — shown before anything else
    alerts = []
    if not fmt.missing(p["GRIEVANCES_OPEN"]) and p["GRIEVANCES_OPEN"] > 0:
        alerts.append(("critical", f"**IRDAI grievance open** since {p['LAST_GRIEVANCE_DATE']}. "
                       "A regulatory filing is the strongest single churn predictor in this market."))
    if fmt.opt_str(p["PORTABILITY_STAGE"], "") not in ("", "—"):
        alerts.append(("critical" if p["PORTABILITY_STAGE"] in ("FORM_REQUESTED", "SUBMITTED") else "warn",
                       f"**Portability {str(p['PORTABILITY_STAGE']).replace('_',' ').lower()}** to "
                       f"{p['PORTABILITY_TARGET']} — quoted {fmt.inr(p['COMPETITOR_QUOTE'])} against our "
                       f"{fmt.inr(p['OUR_PREMIUM'])}, **{p['COMPETITOR_DISCOUNT_PCT']}% cheaper**."))
    if not fmt.missing(p["EMPLOYEE_COUNT"]) and p["MEMBER_ROLE"] == "HR_ADMIN":
        alerts.append(("warn", f"**Group decision-maker.** {p['HR_CONTACT_NAME']} administers "
                       f"{p['EMPLOYER_NAME']} — {int(p['EMPLOYEE_COUNT'])} employees, "
                       f"{fmt.lakh(p['GROUP_PREMIUM'])} annual premium, renews {p['GROUP_RENEWAL_DATE']}. "
                       "Losing this customer means losing the group."))
    if not fmt.missing(p["LAST_RENEWAL_DAYS_LATE"]) and p["LAST_RENEWAL_DAYS_LATE"] > 0:
        alerts.append(("warn", f"Last renewal was **{int(p['LAST_RENEWAL_DAYS_LATE'])} days late** "
                       f"({fmt.opt_int(p['LATE_RENEWALS'])} late renewals on record)."))
    for kind, msg in alerts:
        (st.error if kind == "critical" else st.warning)(msg)

    tabs = st.tabs(["Why this state", "Timeline", "Tickets", "Email", "Policy history",
                    "Regulatory", "Recommendation"])

    with tabs[0]:
        st.caption("Every signal behind the current state, and what each one contributes. "
                   "Eight of the nine new signals are plain SQL over observable facts — "
                   "a filing exists, a renewal was late, a ticket breached SLA.")
        why = sf.why_this_state(cid)
        if len(why):
            st.dataframe(why, hide_index=True, use_container_width=True,
                         column_config={"SIGNAL_NAME": "Signal", "SIGNAL_VALUE": "Value",
                                        "ORIGIN": "Origin", "EVIDENCE_REF": "Evidence",
                                        "CONTRIBUTION": "What it contributes"})
            der = int((why.ORIGIN == "DERIVED").sum())
            ext = int((why.ORIGIN == "EXTRACTED").sum())
            st.caption(f"{der} derived deterministically from source systems · "
                       f"{ext} extracted from unstructured text by Cortex.")
        else:
            st.info("No signals on file.")

    with tabs[1]:
        st.caption("Every dated record for this customer, one stream — policy versions, "
                   "tickets, emails, claims, grievances, portability, logged contacts.")
        tl = sf.timeline(cid)
        st.dataframe(tl, hide_index=True, use_container_width=True,
                     column_config={"WHEN_AT": "When", "SOURCE": "Source",
                                    "WHAT": "What", "DETAIL": "Detail"})

    with tabs[2]:
        t = sf.tickets(cid)
        if not len(t):
            st.info("No tickets.")
        else:
            c = st.columns(4)
            c[0].metric("Total", len(t))
            c[1].metric("Open", int((t.STATUS == "OPEN").sum()))
            c[2].metric("SLA breached", int(t.SLA_BREACHED.sum()))
            c[3].metric("Reopened", int(t.REOPEN_COUNT.sum()))
            st.dataframe(t, hide_index=True, use_container_width=True)
            st.caption("SLA breaches and reopens are failures we caused — distinct from the "
                       "customer being unhappy, and actionable in a different way.")

    with tabs[3]:
        em = sf.email_threads(cid)
        if not len(em):
            st.info("No email on file for this customer.")
        else:
            st.caption(f"{len(em)} messages across {em.TICKET_ID.nunique()} threads. "
                       "The written channel is where escalation language appears first.")
            for tid, grp in em.groupby("TICKET_ID", sort=False):
                grp = grp.sort_values("THREAD_POSITION")
                head = grp.iloc[0]
                with st.expander(f"{head['SUBJECT']} · {tid} · {len(grp)} messages"):
                    for _, m in grp.iterrows():
                        who = "Customer" if m["DIRECTION"] == "INBOUND" else "Us"
                        st.markdown(f"**{who}** · {m['SENT_AT']}")
                        st.text(m["BODY"])
                        st.divider()

    with tabs[4]:
        pv = sf.policy_versions(cid)
        if not len(pv):
            st.info("No policy history.")
        else:
            st.caption("How the product was actually used, year by year — premium drift, "
                       "cover changes, no-claim bonus, and whether each renewal was on time.")
            st.dataframe(pv, hide_index=True, use_container_width=True)
            first, cur = p["FIRST_PREMIUM"], p["CURRENT_PREMIUM"]
            if not fmt.missing(first) and not fmt.missing(cur) and first:
                st.caption(f"Premium across the relationship: {fmt.inr(first)} → {fmt.inr(cur)} "
                           f"({(cur/first - 1) * 100:.0f}% over {fmt.opt_int(p['TENURE_YEARS'])} years). "
                           f"No-claim bonus peaked at {fmt.opt_int(p['PEAK_NCB'])}% and now sits at "
                           f"{fmt.opt_int(p['CURRENT_NCB'])}%.")

    with tabs[5]:
        g, pr = sf.grievances(cid), sf.portability(cid)
        if not len(g) and not len(pr):
            st.success("No regulatory filing and no portability request on record.")
        if len(g):
            st.markdown("**IRDAI grievances**")
            st.dataframe(g, hide_index=True, use_container_width=True)
        if len(pr):
            st.markdown("**Portability requests**")
            st.dataframe(pr, hide_index=True, use_container_width=True)
            st.caption("Portability is a regulated process with forms and deadlines — so this "
                       "is an observed act, not an inference from tone.")

    with tabs[6]:
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
    ev = sf.effectiveness().copy()
    ev["SUCCESS_RATE"] = ev["SUCCESS_RATE"] * 100
    st.dataframe(
        ev[["ACTION_NAME", "STATE_NAME", "SUCCESS_RATE", "SUCCESS_COUNT", "TOTAL_COUNT",
            "AVG_UPLIFT", "CONFIDENCE", "IS_THIN_SAMPLE"]],
        hide_index=True, use_container_width=True,
        column_config={
            "ACTION_NAME": "Action", "STATE_NAME": "At state",
            "SUCCESS_RATE": st.column_config.ProgressColumn(
                "Success", min_value=0, max_value=100, format="%.1f%%"),
            "SUCCESS_COUNT": st.column_config.NumberColumn("wins", width="small"),
            "TOTAL_COUNT": st.column_config.NumberColumn("n", width="small"),
            "AVG_UPLIFT": st.column_config.NumberColumn("Uplift", format="%.2f"),
            "CONFIDENCE": st.column_config.NumberColumn("Conf", format="%.2f"),
            "IS_THIN_SAMPLE": st.column_config.CheckboxColumn("thin sample?"),
        })
    st.caption("Thin-sample is a real column on APP.V_ACTION_EFFECTIVENESS (confidence < "
               "0.70), not a threshold re-typed in the UI. The recommender discounts these "
               "rather than treating 14 cases like 112.")

    if len(act):
        st.markdown("##### Recent activity")
        st.dataframe(act, hide_index=True, use_container_width=True)
    else:
        st.info("No actions have been carried out yet. Run a scenario in the Studio and "
                "this fills up — ACTION_RECOMMENDATION, ACTION_EXECUTION, ACTION_OUTCOME, "
                "NOTIFICATION_LOG and INTERACTION_SUMMARY all populate from a real run.")


def ask(persona):
    st.markdown("### Ask the data")
    st.caption("Cortex Search over the current interaction corpus — every transcript and "
               "logged contact for the 30 customers in the book, including anything a "
               "scenario run just injected.")
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
    st.caption("These are read live by APP.RECOMMEND_ACTION. Personas without a row fall "
               "back to `default`, so every persona always gets a ranked recommendation.")

    st.markdown("##### Approval ceilings")
    p = sf.personas()
    pv = p.copy()
    pv["needs fixing"] = pv.CONFIG_LIMIT != pv.EFFECTIVE_LIMIT
    st.dataframe(pv[["PERSONA_NAME", "DATA_SCOPE_TYPE", "CONFIG_LIMIT", "EFFECTIVE_LIMIT",
                     "needs fixing", "NOTE"]],
                 hide_index=True, use_container_width=True)
    st.error("**CONFIG.USER_PERSONA still holds the unconverted value.** Policy gates are in "
             "rupees (₹4,15,000+) while Team Lead's ceiling is 100,000, so even the one "
             "approval tier can't approve anything. The app reads a corrected override "
             "table (APP.PERSONA_LIMIT) so approvals work today; the real fix is still this "
             "UPDATE statement against CONFIG directly:")
    st.code("UPDATE CONFIG.USER_PERSONA SET max_approval_value = 8300000 "
            "WHERE persona_id='team_lead';", language="sql")

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
    st.dataframe(defs[["SIGNAL_NAME", "EXTRACTION_METHOD", "WEIGHT", "SOURCE_TABLE"]],
                 hide_index=True, use_container_width=True)
    st.caption("All configured signals for this domain produce rows — extracted via Cortex "
               "or derived deterministically from source systems.")


CATEGORY_COLOR = {"RISK": "#B3251E", "SERVICE": "#C98A00", "OPPORTUNITY": "#2E7D52"}
CATEGORY_BLURB = {
    "RISK": "Predicts churn, default or attrition.",
    "SERVICE": "Operational friction we caused.",
    "OPPORTUNITY": "Relationship value or growth timing.",
}
PRIORITY_COLOR = {"HIGH": "#B3251E", "MEDIUM": "#C98A00", "LOW": "#5C6B70"}


def signal_discovery(persona):
    row = _scope(persona)
    st.markdown("### Signal discovery")
    st.caption("Runs once a day against RAW tables nothing has mined yet, and proposes "
               "candidates — structured columns scored deterministically, free text via "
               "Cortex. Nothing here activates on its own; every candidate waits for a human.")

    last = sf.discovery_latest_run()
    c1, c2 = st.columns([1, 3])
    with c1:
        if st.button("Run discovery now", use_container_width=True):
            with st.spinner("Scanning tables nothing has mined yet…"):
                sf.run_discovery()
            sf.clear_caches()
            st.rerun()
    with c2:
        if last is not None:
            st.caption(f"Last run **{last['RUN_AT']}** · scanned {last['TABLES_SCANNED']} · "
                       f"{int(last['CANDIDATES_FOUND'])} candidate(s) found")

    if last is not None:
        st.info(f"**What changed:** {last['AI_SUMMARY']}")

    cand = sf.discovery_candidates("NEW")
    if not len(cand):
        st.success("No pending candidates — everything discovered so far has been reviewed.")
    else:
        hi = cand[cand.PRIORITY.isin(["HIGH", "MEDIUM"])]
        lo = cand[cand.PRIORITY == "LOW"]

        if not row["CAN_CONFIGURE"]:
            st.caption(f"{row['PERSONA_NAME']} has read-only access here — switch to Analyst "
                       "in the sidebar to promote or dismiss.")

        if len(hi):
            st.markdown("##### New candidates — worth a look")
            for cat in ["RISK", "SERVICE", "OPPORTUNITY"]:
                sub = hi[hi.CATEGORY == cat]
                if not len(sub):
                    continue
                st.caption(f"**{cat}** · {CATEGORY_BLURB[cat]}")
                for _, c in sub.iterrows():
                    with st.container(border=True):
                        head, badge = st.columns([4, 1])
                        head.markdown(f"**{c['SIGNAL_NAME']}** — `{c['SOURCE_TABLE']}.{c['SOURCE_COLUMN']}`")
                        badge.markdown(fmt.chip(c["PRIORITY"], PRIORITY_COLOR[c["PRIORITY"]]),
                                       unsafe_allow_html=True)
                        st.caption(c["RATIONALE"])
                        if row["CAN_CONFIGURE"]:
                            b1, b2, _ = st.columns([1, 1, 4])
                            if b1.button("Promote", key=f"pr_{c['CANDIDATE_ID']}"):
                                sf.promote_candidate(c["CANDIDATE_ID"])
                                sf.clear_caches()
                                st.rerun()
                            if b2.button("Dismiss", key=f"di_{c['CANDIDATE_ID']}"):
                                sf.dismiss_candidate(c["CANDIDATE_ID"])
                                sf.clear_caches()
                                st.rerun()

        if len(lo):
            with st.expander(f"{len(lo)} low-priority candidate(s) — mostly static or "
                              "rarely-informative columns, collapsed so the real work stays visible"):
                st.dataframe(lo[["SIGNAL_NAME", "CATEGORY", "SOURCE_TABLE", "SOURCE_COLUMN", "RATIONALE"]],
                             hide_index=True, use_container_width=True,
                             column_config={"SIGNAL_NAME": "Signal", "CATEGORY": "Type",
                                            "SOURCE_TABLE": "Table", "SOURCE_COLUMN": "Column",
                                            "RATIONALE": "Why"})

    st.divider()
    st.markdown("##### Signals already live, same three types")
    live = sf.signals_by_category()
    for cat in ["RISK", "SERVICE", "OPPORTUNITY"]:
        sub = live[live.CATEGORY == cat]
        if not len(sub):
            continue
        st.caption(f"**{cat}** ({len(sub)}) · {CATEGORY_BLURB[cat]}")
        st.dataframe(
            sub[["SIGNAL_NAME", "DOMAIN_ID", "EXTRACTION_METHOD", "SOURCE_TABLE", "WEIGHT"]],
            hide_index=True, use_container_width=True,
            column_config={"SIGNAL_NAME": "Signal", "DOMAIN_ID": "Domain",
                           "EXTRACTION_METHOD": "Method", "SOURCE_TABLE": "Source",
                           "WEIGHT": "Weight"})


PAGES = {"queue": queue, "approvals": approvals, "c360": customer_360,
         "portfolio": portfolio, "agent": ask, "config": config,
         "discovery": signal_discovery}


def render(page, persona):
    PAGES.get(page, queue)(persona)
