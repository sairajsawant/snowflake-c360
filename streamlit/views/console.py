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


def feed(persona):
    row = _scope(persona)
    st.markdown("### My Feed")
    st.caption("Your worklist for today, most urgent first — customers at risk of leaving, "
               "then customers we owe something after a service failure, then genuine "
               "opportunities. Nobody is ever offered a product while we still owe them a fix.")

    if st.button("Refresh"):
        # The signal layer is refreshed on demand rather than on a timer, so this
        # button brings it up to date before re-ranking.
        with st.spinner("Bringing signals up to date…"):
            sf.refresh_signal_snapshot()
        sf.unified_feed.clear()
        st.rerun()

    with st.spinner("Ranking your customers…"):
        f = sf.unified_feed(row["DATA_SCOPE_TYPE"], persona, persona, "team_alpha")

    if not len(f):
        st.info("Nothing needs your attention right now.")
        return

    retention = f[f.FEED_TYPE == "RETENTION"]
    service = f[f.FEED_TYPE == "SERVICE"]
    opportunity = f[f.FEED_TYPE == "OPPORTUNITY"]
    k = st.columns(4)
    k[0].metric("On your list", len(f))
    k[1].metric("At risk", len(retention))
    k[2].metric("We owe them", len(service),
                help="Something went wrong on our side — a stuck claim, a repeat "
                     "ticket, or poor satisfaction. Put right before anything is sold.")
    k[3].metric("Opportunities", len(opportunity))

    total = int(f["ELIGIBLE_TOTAL"].iloc[0]) if "ELIGIBLE_TOTAL" in f.columns else len(f)
    if total > len(f):
        st.caption(f"Showing the top {len(f)} of {total} customers who need something today — "
                   "work down the list and refresh for the rest.")

    for _, r in f.iterrows():
        with st.container(border=True):
            head, badge = st.columns([4, 1])
            head.markdown(f"**{r['HEADLINE']}** — {r['FULL_NAME']} (`{r['CUSTOMER_ID']}`)")
            label, colour = {
                "RETENTION":   ("At risk",     "#B3251E"),
                "SERVICE":     ("We owe them", "#C98A00"),
                "OPPORTUNITY": ("Opportunity", "#2E7D52"),
            }.get(r["FEED_TYPE"], (r["FEED_TYPE"], "#5C6B70"))
            badge.markdown(fmt.chip(label, colour), unsafe_allow_html=True)
            st.markdown(fmt.state_badge(r["STATE_NAME"], r["SEVERITY"]), unsafe_allow_html=True)
            m = st.columns(3)
            m[0].metric("Relationship", fmt.lakh(r["RELATIONSHIP_VALUE"]))
            m[1].metric("Fit score", f"{r['SCORE']:.2f}",
                        help="How strongly this customer's situation matches this "
                             "recommendation. Higher is a better fit.")
            m[2].caption("Why: " + str(r["DETAIL"]).replace("_", " "))
            if st.button("Open full profile", key=f"feed_{r['CUSTOMER_ID']}"):
                st.session_state["cid"] = r["CUSTOMER_ID"]
                st.session_state["page"] = "c360"
                st.rerun()


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
        st.info("Nothing in your scope needs attention.")
        if unowned and row["DATA_SCOPE_TYPE"] != "ALL":
            st.info(f"{unowned} of {int(gap['TOTAL'])} customers aren't assigned to anyone yet, "
                    "so they don't appear in any individual queue. Switch to VP Executive in "
                    "the sidebar to see the whole book.")
        return

    k = st.columns(4)
    k[0].metric("Open", len(q))
    k[1].metric("High or worse", int((q.SEVERITY >= 3).sum()))
    k[2].metric("Relationship at risk", fmt.lakh(q.RELATIONSHIP_VALUE.sum()))
    k[3].metric("Critical", int((q.SEVERITY >= 4).sum()))
    st.caption("Ordered by how severe the situation is, then by how much the relationship is "
               "worth — so the biggest exposure surfaces first.")

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
        with st.expander(f"⚠ {len(flagged)} customer(s) where the evidence is weaker than usual"):
            st.caption("Treat these recommendations with more care — either the evidence "
                       "disagrees with itself, or we've seen too few similar cases to be "
                       "confident. Worth a human read before acting.")
            for c in flagged:
                st.caption(f"· `{c}` — {tf.loc[c, 'DETAIL']}")

    ins = q[q.DOMAIN == "insurance"]
    if len(ins) and ins.SEVERITY.max() >= 4:
        top_crit = ins[ins.SEVERITY >= 4].RELATIONSHIP_VALUE.max()
        top_any = q.RELATIONSHIP_VALUE.max()
        if pd.notna(top_crit) and pd.notna(top_any) and top_crit < top_any:
            st.info("Your most urgent customers aren't your most valuable ones right now — "
                    "worth reading severity and relationship value together when you decide "
                    "what to work first.")

    if unowned and row["DATA_SCOPE_TYPE"] != "ALL":
        st.caption(f"{unowned} of {int(gap['TOTAL'])} customers aren't assigned to anyone yet, so "
                   f"this queue shows the {int(gap['OWNED'])} that are. VP Executive sees the "
                   "whole book.")

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
        st.success("Nothing is waiting for your approval.")
        return
    st.caption("Recommended actions that cost more than a relationship manager can authorise "
               "on their own, so they need your sign-off before they can go ahead.")

    done = sf.executions()
    done_keys = {(r.CUSTOMER_ID, r.ACTION_ID) for r in done.itertuples()}
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
            key = (p["CUSTOMER_ID"], p["ACTION_ID"])
            if key in done_keys:
                note = st.session_state.get(f"approved_{key}", "")
                st.success(f"**Approved and carried out.** {note}".strip())
            elif not auth.get("authorised"):
                st.error("This is above your approval limit — escalate to a VP Executive.")
            elif st.button("Approve", key=f"approve_{p['CUSTOMER_ID']}_{p['ACTION_ID']}",
                           type="primary"):
                with st.spinner("Approving and carrying it out…"):
                    run_id = sf.start_run(p["CUSTOMER_ID"], persona, "approval")
                    ex = sf.execute_action(p["CUSTOMER_ID"], p["ACTION_ID"], persona, 0,
                                           "Approved from the Approvals queue", run_id)
                if ex.get("status") == "EXECUTED":
                    se = ex.get("side_effect")
                    st.session_state[f"approved_{key}"] = (
                        f"{se[0].upper()}{se[1:]}." if se and se != "none" else "")
                    st.rerun()
                else:
                    st.error(f"{ex.get('status')} — {ex.get('reason')}")


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

    next_best(cid, persona, p)

    tabs = st.tabs(["Why this state", "Timeline", "Tickets", "Email", "Policy history",
                    "Regulatory"])

    with tabs[0]:
        st.caption("Everything that put this customer in their current state, and how much "
                   "each one counted. Most are observable facts — a filing exists, a renewal "
                   "was late, a ticket missed its deadline.")
        why = sf.why_this_state(cid)
        if len(why):
            st.dataframe(why, hide_index=True, use_container_width=True,
                         column_config={"SIGNAL_NAME": "Signal", "SIGNAL_VALUE": "Value",
                                        "ORIGIN": "Origin", "EVIDENCE_REF": "Evidence",
                                        "CONTRIBUTION": "What it contributes"})
            der = int((why.ORIGIN == "DERIVED").sum())
            ext = int((why.ORIGIN == "EXTRACTED").sum())
            st.caption(f"{der} read from source systems · {ext} picked out of what the "
                       f"customer said on calls and in emails.")
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


def _reasons(text):
    """'product_interest=super_topup_cover, tenure_segment=MATURE' -> plain words."""
    out = []
    for part in str(text or "").split(","):
        if "=" in part:
            k, v = [x.strip() for x in part.split("=", 1)]
            out.append(f"{k.replace('_', ' ')}: {v.replace('_', ' ').lower()}")
    return out


def next_best(cid, persona, prof):
    """
    The decision, readable at a glance and actionable in place: the top retention
    action (with a button to carry it out, within the role's authority) beside the
    best-fit product for first buy or renewal (or why it's being held back).
    """
    st.markdown("#### Next best action")
    left, right = st.columns(2)

    # ── keep the customer: retention / servicing action ─────────────────────
    with left:
        with st.container(border=True):
            st.markdown(fmt.chip("Keep", "#B3251E"), unsafe_allow_html=True)
            recs = sf.recommend(cid, persona, 0)
            done = None
            ex = sf.executions(cid)
            if len(ex):
                e = ex.iloc[0]
                names = dict(zip(sf.personas()["PERSONA_ID"], sf.personas()["PERSONA_NAME"]))
                who = names.get(e["APPROVED_BY"] or e["EXECUTED_BY"], e["APPROVED_BY"] or e["EXECUTED_BY"])
                sess = st.session_state.get(f"c360_done_{cid}") or {}
                done = {"action": e["ACTION_NAME"], "action_id": e["ACTION_ID"],
                        "by": (f"Approved by {who}" if e["EXECUTION_TYPE"] == "APPROVED"
                               else f"Carried out by {who}"),
                        "side_effect": sess.get("side_effect", ""),
                        "message": sess.get("message")}
            if not len(recs):
                st.markdown("**No intervention needed**")
                st.caption("Nothing in their situation matches an approved action, so the "
                           "platform recommends nothing rather than inventing one.")
            elif done:
                st.markdown(f"### {done['action']}")
                st.success(f"**{done['by']}** and carried out. {done.get('side_effect') or ''}".strip())
                if done.get("message"):
                    st.caption("Customer notified: " + done["message"])
                if st.button("Write my call brief", key=f"brief_{cid}"):
                    with st.spinner("Writing the brief from this customer's own evidence…"):
                        st.session_state[f"c360_brief_{cid}"] = sf.call_brief(cid, done["action_id"], 0)
                if st.session_state.get(f"c360_brief_{cid}"):
                    with st.expander("Call brief", expanded=True):
                        st.markdown(st.session_state[f"c360_brief_{cid}"])
            else:
                top = recs.iloc[0]
                auth = sf.authority(top["ACTION_ID"], persona, 0)
                st.markdown(f"### {top['ACTION_NAME']}")
                st.caption(f"Worked for **{fmt.pct(top['EFFECTIVENESS_RATE'])}** of similar "
                           f"customers ({int(top['SAMPLE_SIZE'])} cases).")
                m = st.columns(2)
                m[0].metric("Expected value", fmt.inr(top["EXPECTED_VALUE"]))
                m[1].metric("Cost", fmt.inr(top["TOTAL_COST"]))
                needs = bool(auth.get("requires_approval"))
                allowed = (not needs) or bool(auth.get("authorised"))
                if needs and not allowed:
                    st.warning("Needs Team Lead sign-off — it's waiting in their Approvals.")
                elif needs:
                    st.caption("Needs approval, and you have the authority.")
                else:
                    st.caption("Within your authority — you can act now.")
                label = "Approve and carry out" if needs else "Carry it out"
                if st.button(label, key=f"act_{cid}", type="primary", disabled=not allowed):
                    with st.spinner("Carrying it out and notifying the customer…"):
                        run_id = sf.start_run(cid, persona, "console")
                        ex = sf.execute_action(cid, top["ACTION_ID"], persona, 0,
                                               "Actioned from Customer 360", run_id)
                    if ex.get("status") == "EXECUTED":
                        st.session_state[f"c360_done_{cid}"] = {
                            "action": top["ACTION_NAME"], "action_id": top["ACTION_ID"],
                            "side_effect": (f"{ex['side_effect'][0].upper()}{ex['side_effect'][1:]}."
                                            if ex.get("side_effect") and ex["side_effect"] != "none" else ""),
                            "message": ex.get("message")}
                        sf.clear_caches()
                        st.rerun()
                    else:
                        st.error(f"{ex.get('status')} — {ex.get('reason')}")
                if len(recs) > 1:
                    others = ", ".join(recs["ACTION_NAME"].iloc[1:3])
                    st.caption(f"Also considered: {others}")

    # ── grow the customer: best product for first buy / renewal ─────────────
    with right:
        with st.container(border=True):
            st.markdown(fmt.chip("Grow", "#2E7D52"), unsafe_allow_html=True)
            prods = sf.recommend_product(cid)
            if not len(prods):
                st.markdown("**No product fits yet**")
                st.caption("None of the catalogue matches what we know about this customer.")
            else:
                pr = prods.iloc[0]
                if bool(pr["SUPPRESSED"]):
                    st.markdown(f"**Hold the upsell** · {pr['PRODUCT_NAME']}")
                    st.caption("This customer is at risk, so retention comes before any offer. "
                               "The product will be suggested once they're stable.")
                else:
                    st.markdown(f"### {pr['PRODUCT_NAME']}")
                    st.caption(f"{pr['PRODUCT_TYPE']} · best fit for first buy or renewal")
                    why = _reasons(pr["MATCH_REASONS"])
                    if why:
                        st.markdown("**Why it fits**")
                        for w in why:
                            st.markdown(f"- {w}")
                    st.caption(f"Accepted by {fmt.pct(pr['ACCEPTANCE_RATE'])} of customers it "
                               f"was offered to.")
    st.write("")


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
    st.caption("How much relationship value sits in each state — the tall bars in the worst "
               "states are where the money is at risk.")

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
    st.caption("Every action's real track record, learned from recorded outcomes. Anything "
               "flagged thin sample hasn't been tried often enough to trust yet — the engine "
               "already discounts those rather than treating 14 cases like 112.")

    if len(act):
        st.markdown("##### Recent activity")
        st.dataframe(act, hide_index=True, use_container_width=True)
    else:
        st.info("No actions have been carried out yet. Run a scenario in Scenario Studio and "
                "what happened, and what it led to, will show up here.")


TOOL_LABEL = {
    'get_customer_360': 'Looked up their profile',
    'summarize_customer': 'Summarised their history from past calls and emails',
    'recommend_action': 'Ran the retention engine',
    'recommend_product': 'Ran the product recommendation engine',
    'recommend_service': 'Ran the service recovery engine',
    'search_products': 'Searched product documentation',
    'interaction_search': 'Searched past calls, tickets and emails',
    'get_decision_queue': 'Checked who needs attention',
}

CHAT_EXAMPLES = [
    "Show me the profile for INS-1011",
    "Summarise customer INS-1005 for me",
    "What should we do about INS-1005?",
    "What product should we offer Arun Mehta at renewal?",
    "We let INS-1001 down — what should we do to make it right?",
    "What does the Super Top-up Health Cover include?",
    "Find calls about customers threatening to switch insurers",
]


def ask(persona):
    st.markdown("### Ask the data")
    st.caption("Ask in your own words. Every question goes to the one capability that answers "
               "it — a profile, a summary of their history, a retention action, a product fit, "
               "or a search across past conversations — and the answer only ever uses what came "
               "back. You can keep talking: follow-ups remember who you were asking about.")

    with st.expander("Try one of these"):
        for ex in CHAT_EXAMPLES:
            if st.button(ex, key=f"ex_{ex}", use_container_width=True):
                st.session_state["chat_pending"] = ex
                st.rerun()

    st.session_state.setdefault("chat_history", [])

    for turn in st.session_state["chat_history"]:
        with st.chat_message(turn["role"]):
            st.markdown(turn["content"])
            if turn.get("tool"):
                line = TOOL_LABEL.get(turn["tool"], turn["tool"])
                if turn.get("customer_id"):
                    line += f" · `{turn['customer_id']}`"
                if turn.get("carried_context"):
                    line += " · carried over from your last question"
                st.caption(line)
            if turn.get("data") is not None:
                with st.expander("See the data behind this"):
                    if isinstance(turn["data"], list) and turn["data"]:
                        st.dataframe(turn["data"], hide_index=True, use_container_width=True)
                    else:
                        st.json(turn["data"])

    pending = st.session_state.pop("chat_pending", None)
    typed = st.chat_input("Ask about a customer, a product, or who needs attention…")
    q = pending or typed
    if q:
        # Pass the conversation so far so follow-ups ("what about his renewal?")
        # resolve against whoever we were already discussing. The history is read
        # before this turn is appended, so the model never sees the live question twice.
        history = list(st.session_state["chat_history"])
        st.session_state["chat_history"].append({"role": "user", "content": q})
        with st.chat_message("user"):
            st.markdown(q)
        with st.chat_message("assistant"):
            with st.spinner("Working on it…"):
                result = sf.run_chat(q, persona, history)
        st.session_state["chat_history"].append({
            "role": "assistant", "content": result["answer"], "tool": result["tool"],
            "customer_id": result["customer_id"], "data": result["data"],
            "carried_context": result.get("carried_context", False),
        })
        st.rerun()

    if st.session_state["chat_history"] and st.button("Start a new conversation"):
        st.session_state["chat_history"] = []
        st.rerun()


def config(persona):
    row = _scope(persona)
    st.markdown("### Change behaviour without shipping code")
    if not row["CAN_CONFIGURE"]:
        st.info(f"{row['PERSONA_NAME']} has read-only access to configuration. "
                "Switch to Analyst / Domain Expert in the sidebar.")

    st.markdown("##### How recommendations are weighted")
    st.dataframe(sf.scoring_weights(), hide_index=True, use_container_width=True)
    st.caption("Each role weighs a recommendation differently — a relationship manager leans on "
               "how well an action works, an executive leans on what the relationship is worth "
               "and what the action costs. Change these and the ranking changes immediately, "
               "with no release needed. Roles without their own row use the default.")

    st.markdown("##### Approval limits")
    p = sf.personas()
    st.dataframe(p[["PERSONA_NAME", "DATA_SCOPE_TYPE", "EFFECTIVE_LIMIT"]],
                 hide_index=True, use_container_width=True,
                 column_config={"PERSONA_NAME": "Role", "DATA_SCOPE_TYPE": "Sees",
                                "EFFECTIVE_LIMIT": st.column_config.NumberColumn(
                                    "Can approve up to", format="₹%d")})
    st.caption("Anything above a role's limit is held for the next tier instead of going ahead.")

    st.markdown("##### When a customer counts as at-risk")
    dom = st.selectbox("Business line", ["insurance", "lending"])
    st.dataframe(sf.state_rules(dom), hide_index=True, use_container_width=True)
    st.caption("The ladder is evaluated top down and the first rule that matches decides the "
               "customer's state. Switching a rule off or reordering it takes effect on the "
               "next run.")

    st.markdown("##### What we watch for")
    defs = sf.signal_definitions(dom)
    st.dataframe(defs[["SIGNAL_NAME", "EXTRACTION_METHOD", "WEIGHT"]],
                 hide_index=True, use_container_width=True,
                 column_config={"SIGNAL_NAME": "Signal", "EXTRACTION_METHOD": "Found by",
                                "WEIGHT": "Weight"})
    st.caption("Some signals are read straight from the source systems; others are picked out "
               "of what customers actually said on calls and in emails.")


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
    st.caption("Once a day the platform looks through data nothing is using yet and proposes "
               "new things worth watching. Nothing is switched on automatically — every "
               "suggestion waits for someone to approve it.")

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
            st.caption(f"{row['PERSONA_NAME']} has read-only access here — switch to Analyst / Domain Expert "
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
            with st.expander(f"{len(lo)} lower-priority suggestion(s) — mostly fields that "
                              "rarely change or rarely tell us anything"):
                st.dataframe(lo[["SIGNAL_NAME", "CATEGORY", "SOURCE_TABLE", "SOURCE_COLUMN", "RATIONALE"]],
                             hide_index=True, use_container_width=True,
                             column_config={"SIGNAL_NAME": "Signal", "CATEGORY": "Type",
                                            "SOURCE_TABLE": "Table", "SOURCE_COLUMN": "Column",
                                            "RATIONALE": "Why"})

    st.divider()
    st.markdown("##### Already in use")
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


PAGES = {"feed": feed, "queue": queue, "approvals": approvals, "c360": customer_360,
         "portfolio": portfolio, "agent": ask, "config": config,
         "discovery": signal_discovery}


def render(page, persona):
    PAGES.get(page, feed)(persona)
