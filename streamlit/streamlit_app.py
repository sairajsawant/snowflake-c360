"""
Customer 360 Decisioning Platform.

Two modes. Scenario Studio walks the DETECT → UNDERSTAND → DECIDE → ACT → LEARN
loop on any of the 30 real customers, driving the real APP procedures, real
Cortex AI and the real ENGINE tables. Operations Console is the persona-scoped
product those procedures sit behind.

Nothing on screen is mocked. Every figure is read back from Snowflake after the
write that produced it.
"""
import streamlit as st

from utils import fmt, sf
from views import console

st.set_page_config(page_title="Customer 360 Decisioning Platform",
                   page_icon="🛡️", layout="wide")

SCENARIOS = {
    "A": dict(cid="INS-1011", title="Save the corporate account",
              proves="The whole loop end to end, plus contradictory evidence resolved correctly.",
              why=("₹15.8 L relationship. Pre-authorisation for Monday's spinal surgery is still "
                   "unapproved with three days to go, and HR is ready to move a 200-employee group "
                   "policy. Two of his calls disagree about whether he intends to leave."),
              situation=("his pre-authorisation for Monday spinal surgery is still unapproved with "
                         "three days left, and HR is ready to move the 200-employee group policy"),
              action="ins_claim_escalation", offer=0),
    "B": dict(cid="INS-1005", title="When the machine must ask",
              proves="Policy limits that actually block, and a human approving with a modification.",
              why=("Already at CRITICAL. The strongest action is a retention offer, which is gated "
                   "above ₹4,15,000 — so the engine is not allowed to act on its own."),
              situation=("the 30 percent premium revision on his family floater is still unexplained "
                         "and he has a competitor quote at 38,000 against your 62,400"),
              action="ins_retention_offer", offer=50000),
    "C": dict(cid="LND-2010", title="Same engine, different industry",
              proves="Domain portability. Not one line of engine code differs — only CONFIG rows.",
              why=("₹26 L home loan plus ₹5.2 L vehicle loan, ₹46,700 going out monthly, "
                   "27 days delinquent, credit score 690."),
              situation=("she has missed an EMI after a salary delay and wants to know what "
                         "restructuring is possible before it becomes a default"),
              action="lend_payment_plan", offer=0),
    "D": dict(cid="INS-1007", title="A customer we barely know",
              proves="Honest restraint — one weak signal is not grounds for an intervention.",
              why=("₹12.5 L Corporate Group customer whose entire history is a single call reading "
                   "LOW churn intent. No action is mapped to LOW, so nothing is recommended."),
              situation="he is calling to ask a routine question about his renewal date",
              action=None, offer=0),
}

STEPS = ["Stage event", "Detect", "Understand", "Decide", "Act", "Learn"]

DEFAULTS = dict(mode="studio", persona="rm1", page="queue",
                scenario="A", step=0, cid="INS-1011", offer=0, run_id=None,
                compose="sample", situation="", draft="", transcript_id=None,
                extracted=None, state_result=None, chosen=None, exec_result=None,
                brief=None, sim=None, outcome_result=None, ranks_before=None,
                ranks_after=None, summary_text=None)


def init():
    for k, v in DEFAULTS.items():
        st.session_state.setdefault(k, v)


def reset_run(keep_scenario=True):
    for k in ("run_id", "transcript_id", "extracted", "state_result", "chosen",
              "exec_result", "brief", "sim", "outcome_result", "ranks_before",
              "ranks_after", "summary_text", "draft"):
        st.session_state[k] = DEFAULTS[k]
    st.session_state["step"] = 0
    if not keep_scenario:
        st.session_state["scenario"] = "A"


# ─────────────────────────────────────────────────────────────── sidebar ──────
def sidebar():
    with st.sidebar:
        st.markdown("#### Customer 360 Decisioning Platform")
        st.caption("wired to live Snowflake")

        mode = st.radio("Mode", ["Scenario Studio", "Operations Console"],
                        index=0 if st.session_state["mode"] == "studio" else 1,
                        label_visibility="collapsed")
        st.session_state["mode"] = "studio" if mode == "Scenario Studio" else "console"

        st.divider()
        pdf = sf.personas()
        opts = list(pdf["PERSONA_ID"])
        labels = dict(zip(pdf["PERSONA_ID"], pdf["PERSONA_NAME"]))
        st.session_state["persona"] = st.selectbox(
            "Acting as", opts, index=opts.index(st.session_state["persona"]),
            format_func=lambda p: labels.get(p, p))

        prow = pdf[pdf["PERSONA_ID"] == st.session_state["persona"]].iloc[0]
        lim = float(prow["EFFECTIVE_LIMIT"])
        st.caption(f"{prow['DATA_SCOPE_TYPE']} scope · "
                   + (f"may approve {fmt.inr(lim)}" if lim else "cannot approve")
                   + (" · may configure" if prow["CAN_CONFIGURE"] else ""))
        if float(prow["CONFIG_LIMIT"]) != lim:
            st.caption(f"⚠ CONFIG holds {fmt.inr(prow['CONFIG_LIMIT'])} — "
                       "never converted to rupees. Using the corrected ceiling.")

        if st.session_state["mode"] == "console":
            st.divider()
            pages = {"queue": "Decision Queue", "approvals": "Approvals",
                     "c360": "Customer 360", "portfolio": "Portfolio & Learning",
                     "agent": "Ask the data", "config": "Config Studio"}
            st.session_state["page"] = st.radio(
                "View", list(pages), format_func=lambda k: pages[k],
                index=list(pages).index(st.session_state["page"]),
                label_visibility="collapsed")

        st.divider()
        h = sf.pipeline_health()
        st.caption(f"**{h['scored']} / {h['total']}** customers scored")
        runs = sf.open_runs()
        if len(runs):
            st.caption(f"{len(runs)} open run(s)")
            if st.button("Undo all open runs", use_container_width=True):
                with st.spinner("Reversing…"):
                    for r in runs["RUN_ID"]:
                        sf.undo_run(r)
                sf.clear_caches()
                reset_run()
                st.success("Baseline restored.")
                st.rerun()
        if st.button("Start over", use_container_width=True):
            reset_run()
            st.rerun()


# ──────────────────────────────────────────────────────────────── studio ──────
def scenario_picker():
    st.markdown("##### Choose a situation")
    cols = st.columns(4)
    for col, (k, s) in zip(cols, SCENARIOS.items()):
        c = sf.customer(s["cid"])
        with col:
            selected = st.session_state["scenario"] == k
            if st.button(f"**{k} · {s['title']}**", key=f"scen_{k}",
                         use_container_width=True,
                         type="primary" if selected else "secondary"):
                st.session_state["scenario"] = k
                st.session_state["cid"] = s["cid"]
                st.session_state["offer"] = s["offer"]
                st.session_state["situation"] = s["situation"]
                reset_run()
                st.rerun()
            if c is not None:
                st.markdown(fmt.state_badge(c["STATE_NAME"], c["SEVERITY"]), unsafe_allow_html=True)
                st.caption(f"{c['FULL_NAME']} · {fmt.lakh(c['RELATIONSHIP_VALUE'])}")
            st.caption(s["proves"])


def stepper():
    done = st.session_state["step"]
    cols = st.columns(len(STEPS))
    for i, (col, name) in enumerate(zip(cols, STEPS)):
        with col:
            mark = "✓" if i < done else ("▸" if i == done else "·")
            if i == done:
                st.markdown(f"**:blue[{mark} {name}]**")
            elif i < done:
                st.markdown(f":green[{mark} {name}]")
            else:
                st.caption(f"{mark} {name}")


def nav(next_label=None, can_advance=True):
    c1, c2, _ = st.columns([1, 2, 4])
    with c1:
        if st.session_state["step"] > 0 and st.button("← Back"):
            st.session_state["step"] -= 1
            st.rerun()
    with c2:
        if st.session_state["step"] < len(STEPS) - 1:
            if st.button(next_label or f"Continue to {STEPS[st.session_state['step'] + 1]} →",
                         type="primary", disabled=not can_advance):
                st.session_state["step"] += 1
                st.rerun()
        else:
            if st.button("Run another scenario", type="primary"):
                reset_run()
                st.rerun()


def proves(text):
    with st.expander("What this demonstrates"):
        st.caption(text)


# step 0 ─────────────────────────────────────────────────────────────────────
def step_stage():
    s = SCENARIOS[st.session_state["scenario"]]
    st.info("**You are here:** choosing who this is about and what just happened to "
            "them. In the real product this event arrives from a contact centre; here "
            "you supply it.")

    left, right = st.columns([1, 1])
    with left:
        st.markdown("##### Who")
        cdf = sf.customers()
        ids = list(cdf["CUSTOMER_ID"])
        cid = st.selectbox("Customer — any of the 30", ids,
                           index=ids.index(st.session_state["cid"]),
                           format_func=lambda i: f"{i} — "
                           f"{cdf[cdf.CUSTOMER_ID == i].iloc[0]['FULL_NAME']}")
        if cid != st.session_state["cid"]:
            st.session_state["cid"] = cid
            reset_run()
            st.rerun()

        c = sf.customer(cid)
        st.markdown(f"### {c['FULL_NAME']}")
        st.markdown(fmt.state_badge(c["STATE_NAME"], c["SEVERITY"]), unsafe_allow_html=True)
        st.caption(f"{c['SEGMENT']} · {c['REGION']} · {c['DOMAIN']}"
                   + fmt.opt_int(c["CREDIT_SCORE"], prefix=" · credit "))

        k1, k2, k3 = st.columns(3)
        k1.metric("Relationship", fmt.lakh(c["RELATIONSHIP_VALUE"]))
        sig = sf.signals(cid)
        k2.metric("Signals held", len(sig))
        cl = sf.claims(cid) if c["DOMAIN"] == "insurance" else None
        k3.metric("Open claims", 0 if cl is None else int((cl.CLAIM_STATUS == "PENDING").sum()))

        prod = sf.products(cid, c["DOMAIN"])
        if len(prod):
            st.dataframe(prod, hide_index=True, use_container_width=True)
        if cl is not None and len(cl):
            st.dataframe(cl, hide_index=True, use_container_width=True)
        if not len(sig):
            st.warning("No signals on file — nothing has been said or logged that the "
                       "engine could reason from.")

    with right:
        st.markdown("##### What just happened")
        tabs = st.tabs(["Describe it", "Pick a past call", "Paste your own"])

        with tabs[0]:
            st.caption("Say it in your own words. The system writes a realistic transcript "
                       "grounded in **this** customer's real policy numbers, claim ids and premium.")
            sit = st.text_area("Situation", value=st.session_state["situation"] or s["situation"],
                               height=90, key="sit_in")
            c1, c2 = st.columns(2)
            intensity = c1.selectbox("Intensity", ["Mild", "Moderate", "Severe"], index=2)
            channel = c2.selectbox("Channel", ["Call", "Chat", "Email"])
            if st.button("Generate transcript", type="primary"):
                with st.spinner("AI_COMPLETE is writing a grounded transcript…"):
                    st.session_state["situation"] = sit
                    st.session_state["draft"] = sf.generate_transcript(
                        st.session_state["cid"], sit, intensity, channel)
                st.rerun()

        with tabs[1]:
            tdf = sf.transcripts(st.session_state["cid"], sf.customer(st.session_state["cid"])["DOMAIN"])
            if len(tdf):
                pick = st.selectbox("Existing transcript", list(tdf["TRANSCRIPT_ID"]))
                row = tdf[tdf.TRANSCRIPT_ID == pick].iloc[0]
                st.caption(str(row["CALL_DATE"]))
                if st.button("Use this one"):
                    st.session_state["draft"] = row["TRANSCRIPT_TEXT"]
                    st.rerun()
                st.code(row["TRANSCRIPT_TEXT"][:700], language=None)
            else:
                st.caption("No transcripts on file for this customer.")

        with tabs[2]:
            st.caption("Paste anything. Be adversarial if you like — it goes through "
                       "exactly the same pipeline.")
            pasted = st.text_area("Transcript", height=180, key="paste_in")
            if st.button("Use this text") and pasted.strip():
                st.session_state["draft"] = pasted
                st.rerun()

        if st.session_state["draft"]:
            st.markdown("##### Event to be injected — editable")
            st.session_state["draft"] = st.text_area(
                "Final transcript", value=st.session_state["draft"], height=240,
                label_visibility="collapsed")

    proves("Reads CANONICAL.CUSTOMER for the before-state. The Describe-it path calls "
           "APP.GENERATE_TRANSCRIPT, which puts this customer's real policy ids, premiums "
           "and claim amounts into the AI_COMPLETE prompt, so the generated call references "
           "POL-5015 and CLM-3009 rather than placeholders.")
    nav(can_advance=bool(st.session_state["draft"]))


# step 1 ─────────────────────────────────────────────────────────────────────
def step_detect():
    st.info("**You are here:** the event lands, the pipeline picks it up, and the AI "
            "pulls meaning out of plain language.")
    cid = st.session_state["cid"]
    c = sf.customer(cid)

    if st.session_state["extracted"] is None:
        if st.button("Inject into the pipeline", type="primary"):
            with st.status("Running the real pipeline…", expanded=True) as status:
                st.write("Opening a run…")
                st.session_state["run_id"] = sf.start_run(
                    cid, st.session_state["persona"], st.session_state["scenario"])

                st.write("Writing to RAW and refreshing the Dynamic Tables…")
                st.session_state["transcript_id"] = sf.inject_event(
                    cid, st.session_state["draft"], st.session_state["run_id"])
                st.write(f"→ `{st.session_state['transcript_id']}`")

                st.write("Extracting signals with AI_COMPLETE and AI_SENTIMENT…")
                st.session_state["extracted"] = sf.extract_signals(
                    cid, st.session_state["transcript_id"], st.session_state["run_id"])

                st.write("Summarising the conversation history with AI_SUMMARIZE…")
                st.session_state["summary_text"] = sf.summarize(cid, st.session_state["run_id"])
                status.update(label="Pipeline complete", state="complete", expanded=False)
            sf.clear_caches()
            st.rerun()
        st.caption("This writes a real row to RAW, forces a synchronous Dynamic Table "
                   "refresh so you are not waiting on the one-minute lag, and calls Cortex.")
        nav(can_advance=False)
        return

    st.success(f"Run `{st.session_state['run_id']}` · transcript "
               f"`{st.session_state['transcript_id']}`")

    st.markdown("##### Signals extracted from this call")
    ex = st.session_state["extracted"]
    for _, r in ex.iterrows():
        with st.container(border=True):
            a, b = st.columns([2, 3])
            with a:
                st.markdown(f"**`{r['SIGNAL_NAME']}`** &nbsp; "
                            + fmt.chip(r["METHOD"], "#0B6E6E"), unsafe_allow_html=True)
                st.metric("Value", r["SIGNAL_VALUE"],
                          help=f"numeric {r['NUMERIC_VALUE']}")
                st.caption(f"model confidence {float(r['CONFIDENCE']):.2f}")
            with b:
                st.caption("Evidence — the sentence that produced this signal")
                st.markdown(f"> {r['QUOTE']}" if r["QUOTE"] else "> _none captured_")

    st.markdown("##### Every signal this domain is configured to look for")
    defs = sf.signal_definitions(c["DOMAIN"])
    st.dataframe(
        defs[["SIGNAL_NAME", "EXTRACTION_METHOD", "WEIGHT", "SOURCE_TABLE"]],
        hide_index=True, use_container_width=True,
        column_config={"SIGNAL_NAME": "Signal", "EXTRACTION_METHOD": "Method",
                       "WEIGHT": "Weight", "SOURCE_TABLE": "Source"})
    st.caption("These signals exist because of rows in CONFIG.SIGNAL_DEFINITION — including "
               "the extraction prompt itself. Adding one is an INSERT, not a deploy.")
    with st.expander("The prompt that classified intent, read from config"):
        p = defs[defs.EXTRACTION_METHOD == "INTENT"]
        st.code(p.iloc[0]["EXTRACTION_PROMPT"] if len(p) else "—", language=None)

    proves("APP.INJECT_EVENT writes to RAW.*_CALL_TRANSCRIPTS then issues ALTER DYNAMIC "
           "TABLE … REFRESH. APP.EXTRACT_SIGNALS_FOR calls AI_COMPLETE with a JSON "
           "response_format — which returns the value, the supporting quote and the model's "
           "own confidence — plus AI_SENTIMENT for the sentiment label. All six writes are "
           "in one transaction.")
    nav()


# step 2 ─────────────────────────────────────────────────────────────────────
def step_understand():
    st.info("**You are here:** scattered signals become one labelled state, by rules you "
            "can read. No model decides this — the rules do.")
    cid = st.session_state["cid"]
    c = sf.customer(cid)

    if st.session_state["state_result"] is None:
        with st.spinner("Evaluating CONFIG.STATE_RULE…"):
            st.session_state["state_result"] = sf.compute_state(cid, st.session_state["run_id"])
        sf.clear_caches()
        st.rerun()

    res = st.session_state["state_result"]
    a, b, cc = st.columns([2, 2, 3])
    with a:
        st.caption("Before")
        st.markdown(fmt.state_badge(res["previous"], res["previous_severity"]), unsafe_allow_html=True)
    with b:
        st.caption("After")
        st.markdown(fmt.state_badge(res["new"], res["severity"]), unsafe_allow_html=True)
    with cc:
        st.caption("Changed?")
        st.markdown("**Yes — SCD2 row closed and reopened**" if res["changed"]
                    else "**No — state held, so nothing was written**")
        if not res["changed"]:
            st.caption("That restraint is the fix for the row-churn defect: the old pipeline "
                       "rewrote history every 60 seconds whether or not anything changed.")

    st.markdown("##### Signals, after conflict resolution")
    allsig = sf.signals(cid)
    res_sig = sf.signals(cid, resolved_only=True)
    # match on the evidence reference, not the value — two rows can share a value
    winners = set(zip(res_sig["SIGNAL_NAME"], res_sig["EVIDENCE_REF"]))
    dupes = allsig.groupby("SIGNAL_NAME")["SIGNAL_VALUE"].nunique()
    conflicted = [k for k, v in dupes.items() if v > 1]
    if conflicted:
        st.warning(f"**The evidence disagrees with itself on:** {', '.join(conflicted)}. "
                   "Resolved by severity rank, then recency — not alphabetically, which is "
                   "what used to demote a HIGH reading to LOW.")
    view = allsig.assign(used=[("✓ used" if (n, e) in winners else "")
                               for n, e in zip(allsig.SIGNAL_NAME, allsig.EVIDENCE_REF)])
    st.dataframe(view[["used", "SIGNAL_NAME", "SIGNAL_VALUE", "NUMERIC_VALUE",
                       "CONFIDENCE", "EVIDENCE_REF", "QUOTE"]],
                 hide_index=True, use_container_width=True)

    st.markdown("##### Rules evaluated, highest priority first")
    rules = sf.state_rules(c["DOMAIN"])
    wide = sf.resolved_wide(cid)
    st.caption("Values the rules were tested against:")
    if len(wide):
        st.dataframe(wide.drop(columns=["CUSTOMER_ID", "DOMAIN"]),
                     hide_index=True, use_container_width=True)
    rv = rules.copy()
    rv["outcome"] = ["← this one won" if sf.customer(cid)["STATE_ID"] == t else ""
                     for t in rules["TARGET_STATE_ID"]]
    st.dataframe(rv[["PRIORITY", "RULE_ID", "TARGET_STATE_ID", "RULE_EXPRESSION", "outcome"]],
                 hide_index=True, use_container_width=True)
    st.warning("**Half of this is genuinely config-driven now.** COMPUTE_STATES joins "
               "CONFIG.STATE_RULE and honours each row's priority and active flag, so "
               "switching a rule off or reordering the ladder works. The predicates are "
               "still hardcoded in SQL keyed on domain and priority — so editing a "
               "threshold in Config Studio still has no effect, and a third domain would "
               "produce no state at all.")

    st.markdown("##### The evidence behind this state")
    why = sf.why_this_state(cid)
    if len(why):
        der = int((why.ORIGIN == "DERIVED").sum())
        ext = int((why.ORIGIN == "EXTRACTED").sum())
        st.caption(f"{ext} signals read out of unstructured text by Cortex, "
                   f"{der} derived deterministically from source systems — tickets, policy "
                   f"versions, grievances, portability requests, the employer record. "
                   f"They are independent evidence, not one fact restated.")
        st.dataframe(why, hide_index=True, use_container_width=True,
                     column_config={"SIGNAL_NAME": "Signal", "SIGNAL_VALUE": "Value",
                                    "ORIGIN": "Origin", "EVIDENCE_REF": "Evidence",
                                    "CONTRIBUTION": "What it contributes"})

    prof = sf.profile(cid)
    if prof is not None:
        flags = []
        if not fmt.missing(prof["GRIEVANCES_OPEN"]) and prof["GRIEVANCES_OPEN"] > 0:
            flags.append(f"IRDAI grievance open since {prof['LAST_GRIEVANCE_DATE']}")
        if fmt.opt_str(prof["PORTABILITY_STAGE"], "") not in ("", "—"):
            flags.append(f"portability {str(prof['PORTABILITY_STAGE']).replace('_',' ').lower()} "
                         f"to {prof['PORTABILITY_TARGET']} at {prof['COMPETITOR_DISCOUNT_PCT']}% less")
        if not fmt.missing(prof["SLA_BREACHES_90D"]) and prof["SLA_BREACHES_90D"] > 0:
            flags.append(f"{int(prof['SLA_BREACHES_90D'])} SLA breaches in 90 days")
        if not fmt.missing(prof["LAST_RENEWAL_DAYS_LATE"]) and prof["LAST_RENEWAL_DAYS_LATE"] > 0:
            flags.append(f"last renewal {int(prof['LAST_RENEWAL_DAYS_LATE'])} days late")
        if not fmt.missing(prof["EMPLOYEE_COUNT"]) and prof["MEMBER_ROLE"] == "HR_ADMIN":
            flags.append(f"administers {prof['EMPLOYER_NAME']} — {int(prof['EMPLOYEE_COUNT'])} employees "
                         f"on {fmt.lakh(prof['GROUP_PREMIUM'])} of group premium")
        if flags:
            st.warning("**What the profile adds that this call does not:** " + "; ".join(flags) + ".")

    st.markdown("##### The 360 the state was computed from")
    g1, g2 = st.columns(2)
    with g1:
        st.caption("From systems of record")
        prod = sf.products(cid, c["DOMAIN"])
        if len(prod):
            st.dataframe(prod, hide_index=True, use_container_width=True)
        if c["DOMAIN"] == "insurance":
            cl = sf.claims(cid)
            if len(cl):
                st.dataframe(cl, hide_index=True, use_container_width=True)
                if cl["AGE_DAYS"].max() > 400:
                    st.caption(f"⚠ Claim ages run to {int(cl['AGE_DAYS'].max())} days — the "
                               "seed data is time-shifted about two years, so every "
                               "time-based signal is unusable.")
    with g2:
        st.caption("From what the customer said — AI_SUMMARIZE")
        st.markdown(st.session_state["summary_text"] or sf.summary(cid) or "_none yet_")

    proves("APP.COMPUTE_STATE_FOR resolves conflicting signals by severity rank with a "
           "recency tie-break, evaluates CONFIG.STATE_RULE in priority order, writes an SCD2 "
           "row only when the state actually changed, then calls the platform's own "
           "ENGINE.DETECT_TRANSITIONS to raise the transition and queue entry.")
    nav()


# step 3 ─────────────────────────────────────────────────────────────────────
def step_decide():
    st.info("**You are here:** ranking what could be done, and checking whether you are "
            "allowed to do it. Every number below is arithmetic you can follow.")
    cid = st.session_state["cid"]
    persona = st.session_state["persona"]

    if any(sf.recommend(cid, persona, 0)["REQUIRES_APPROVAL"]):
        st.session_state["offer"] = st.number_input(
            "Offer amount on the approval-gated action (₹)",
            value=int(st.session_state["offer"]), step=10000, min_value=0,
            help="Feeds cost, the policy gate and the authority check. Try 20,000 then 2,00,000.")

    recs = sf.recommend(cid, persona, st.session_state["offer"])
    if st.session_state["ranks_before"] is None:
        st.session_state["ranks_before"] = recs.copy()

    if not len(recs):
        st.warning(f"**Nothing is recommended.** CONFIG.ACTION_STATE_MAPPING has no rows for "
                   f"`{sf.customer(cid)['STATE_ID']}`, so a customer in this state needs "
                   "nothing done. The engine says so rather than inventing an intervention.")
        proves("An empty candidate set is a real outcome, not an error. Silence is a valid "
               "recommendation — and for a customer with one weak signal it is the honest one.")
        nav()
        return

    st.markdown("##### Candidates")
    show = recs[["RANKING", "ACTION_NAME", "POLICY_STATUS", "EFFECTIVENESS_RATE",
                 "SAMPLE_SIZE", "EXPECTED_UPLIFT", "CONFIDENCE", "EXPECTED_VALUE",
                 "TOTAL_COST", "SCORE"]].copy()
    show["EFFECTIVENESS_RATE"] = show["EFFECTIVENESS_RATE"] * 100
    st.dataframe(
        show, hide_index=True, use_container_width=True,
        column_config={
            "RANKING": st.column_config.NumberColumn("#", width="small"),
            "ACTION_NAME": "Action",
            "POLICY_STATUS": "Route",
            "EFFECTIVENESS_RATE": st.column_config.ProgressColumn(
                "Track record", min_value=0, max_value=100, format="%.1f%%"),
            "SAMPLE_SIZE": st.column_config.NumberColumn("n", width="small"),
            "EXPECTED_UPLIFT": st.column_config.NumberColumn("Uplift", format="%.2f"),
            "CONFIDENCE": st.column_config.NumberColumn("Conf", format="%.2f"),
            "EXPECTED_VALUE": st.column_config.NumberColumn("Expected value", format="₹%d"),
            "TOTAL_COST": st.column_config.NumberColumn("Cost", format="₹%d"),
            "SCORE": st.column_config.NumberColumn("Score", format="%.4f"),
        })

    top = recs.iloc[0]
    with st.expander(f"How {top['ACTION_NAME']} scored {top['SCORE']:.4f}"):
        st.code(
            f"score = {top['W_UPLIFT']}·uplift_n + {top['W_VALUE']}·value_n "
            f"+ ({top['W_COST']})·cost_n + {top['W_CONF']}·confidence\n\n"
            f"  uplift      {top['PART_UPLIFT']:+.4f}\n"
            f"  value       {top['PART_VALUE']:+.4f}\n"
            f"  cost        {top['PART_COST']:+.4f}\n"
            f"  confidence  {top['PART_CONF']:+.4f}\n"
            f"  {'':-<22}\n"
            f"  score       {top['SCORE']:.4f}\n\n"
            f"cost_n is cost ÷ {fmt.inr(top['COST_CEILING'])}, the highest action cost "
            f"configured for this domain — a fixed ceiling, so a larger offer genuinely "
            f"moves the ranking instead of normalising away.\n"
            f"Relationship value used for expected value: {fmt.inr(top['RELATIONSHIP_VALUE'])}.",
            language=None)

    # persona comparison — the same facts, two mandates
    st.markdown("##### Who is asking changes the answer")
    labels = dict(zip(sf.personas()["PERSONA_ID"], sf.personas()["PERSONA_NAME"]))
    pa, pb = st.columns(2)
    for col, p in ((pa, "rm1"), (pb, "team_lead")):
        r = sf.recommend(cid, p, st.session_state["offer"])
        with col:
            st.caption(f"**{labels.get(p, p)}** · weights "
                       f"{r.iloc[0]['W_UPLIFT']}/{r.iloc[0]['W_VALUE']}/"
                       f"{r.iloc[0]['W_COST']}/{r.iloc[0]['W_CONF']}")
            for _, x in r.iterrows():
                st.write(f"{int(x['RANKING'])}. {x['ACTION_NAME']} — `{x['SCORE']:.4f}`")
    rm_top = sf.recommend(cid, "rm1", st.session_state["offer"]).iloc[0]
    tl_top = sf.recommend(cid, "team_lead", st.session_state["offer"]).iloc[0]
    if rm_top["ACTION_ID"] != tl_top["ACTION_ID"]:
        st.info(f"**They disagree right now.** Relationship Manager 1 would "
                f"{rm_top['ACTION_NAME'].lower()}; the Team Lead, who is three times more "
                f"cost-sensitive, would {tl_top['ACTION_NAME'].lower()} instead. Same "
                "customer, same evidence, same instant — different mandate.")
    else:
        st.caption(f"Both roles currently agree on **{rm_top['ACTION_NAME']}**. "
                   "Change the offer amount above and they diverge.")

    # choose + policy
    st.markdown("##### Choose an action")
    names = {r["ACTION_ID"]: f"{r['ACTION_NAME']} ({r['POLICY_STATUS'].replace('_', ' ')})"
             for _, r in recs.iterrows()}
    default = st.session_state["chosen"] or recs.iloc[0]["ACTION_ID"]
    st.session_state["chosen"] = st.radio(
        "Action", list(names), index=list(names).index(default)
        if default in names else 0, format_func=lambda a: names[a],
        label_visibility="collapsed")

    chosen = st.session_state["chosen"]
    st.markdown("##### May we actually do it?")
    pol = sf.policy_eval(cid, chosen, persona, st.session_state["offer"])
    pv = pol.copy()
    pv["VERDICT"] = pv["VERDICT"].apply(lambda v: v.replace("_", " "))
    st.dataframe(pv[["POLICY_NAME", "RULE_EXPRESSION", "SUBSTITUTED", "VERDICT"]],
                 hide_index=True, use_container_width=True)

    auth = sf.authority(chosen, persona, st.session_state["offer"])
    if not auth.get("requires_approval"):
        st.success(f"**Cleared to run now.** This action is autonomous and costs under the "
                   f"₹8,300 auto-execute ceiling.")
    elif auth.get("authorised"):
        st.warning(f"**Needs a human, and you are one.** Needs authority of "
                   f"{fmt.inr(auth['needed'])}; your ceiling is "
                   f"{fmt.inr(auth['persona_limit'])}.")
    else:
        st.error(f"**Above your authority.** Needs {fmt.inr(auth['needed'])} but "
                 f"{persona.replace('_', ' ')} may approve only "
                 f"{fmt.inr(auth['persona_limit'])}. Switch role in the sidebar.")
    if auth.get("requires_approval") and not auth.get("authorised_under_config"):
        st.caption(f"⚠ Under the CONFIG value ({fmt.inr(auth['config_limit'])}) this would be "
                   "unapprovable by everyone, including the VP — the ceilings were never "
                   "converted to rupees. The figures above use the corrected limits.")

    auto = recs[~recs["REQUIRES_APPROVAL"]]
    if len(auto) and recs.iloc[0]["REQUIRES_APPROVAL"]:
        b = auto.iloc[0]
        st.caption(f"Best option needing nobody: **{b['ACTION_NAME']}** at "
                   f"{fmt.pct(b['EFFECTIVENESS_RATE'])} (score {b['SCORE']:.4f}). Act now at "
                   "slightly lower odds, or wait for approval on the stronger play.")

    proves("APP.RECOMMEND_ACTION joins ACTION_STATE_MAPPING to ACTION_EFFECTIVENESS and "
           "weights by SCORING_CONFIG for the calling persona, falling back to the domain "
           "default. APP.POLICY_EVAL evaluates every POLICY_RULE row with substituted "
           "values, and AUTHORITY_CHECK compares the requirement against the persona ceiling.")
    nav()


# step 4 ─────────────────────────────────────────────────────────────────────
def step_act():
    st.info("**You are here:** doing the thing — and if a person must sign off, being "
            "that person.")
    cid, persona = st.session_state["cid"], st.session_state["persona"]
    chosen = st.session_state["chosen"]

    if not chosen:
        st.caption("Nothing was recommended, so there is nothing to carry out.")
        nav()
        return

    auth = sf.authority(chosen, persona, st.session_state["offer"])

    if st.session_state["exec_result"] is None:
        if auth.get("requires_approval") and not auth.get("authorised"):
            st.error(f"This needs authority of {fmt.inr(auth['needed'])}. Switch to a role "
                     "that can approve it in the sidebar, then come back.")
            nav(can_advance=False)
            return
        label = "Approve and execute" if auth.get("requires_approval") else "Execute"
        notes = st.text_input("Notes", value="Carried out from the scenario studio")
        if st.button(label, type="primary"):
            with st.spinner("Writing the recommendation, the execution and the notification…"):
                st.session_state["exec_result"] = sf.execute_action(
                    cid, chosen, persona, st.session_state["offer"], notes,
                    st.session_state["run_id"])
            sf.clear_caches()
            st.rerun()
        nav(can_advance=False)
        return

    ex = st.session_state["exec_result"]
    if ex.get("status") != "EXECUTED":
        st.error(f"{ex.get('status')} — {ex.get('reason')}")
        nav(can_advance=False)
        return

    st.success("Executed and recorded.")
    c1, c2 = st.columns(2)
    with c1:
        st.caption("Rows written")
        st.code(f"ENGINE.ACTION_RECOMMENDATION  {ex['recommendation_id']}\n"
                f"ENGINE.ACTION_EXECUTION       {ex['execution_id']}\n"
                f"ENGINE.NOTIFICATION_LOG       {ex['notification_id']}", language=None)
        if ex.get("side_effect") and ex["side_effect"] != "none":
            st.info(f"**Real side effect in the system of record:** {ex['side_effect']}. "
                    "Not a toast — an UPDATE the pipeline can see.")
    with c2:
        st.caption("Notification, rendered from the configured template")
        st.markdown(f"> {ex.get('message') or '—'}")
        st.caption("Email goes out through the Snowflake notification integration. "
                   "Slack is rendered but not posted — no webhook is configured.")

    st.markdown("##### Call brief for the person making the call")
    if st.session_state["brief"] is None:
        if st.button("Generate brief"):
            with st.spinner("AI_COMPLETE, grounded on the signals and evidence quotes…"):
                st.session_state["brief"] = sf.call_brief(
                    cid, chosen, st.session_state["offer"])
            st.rerun()
    else:
        st.markdown(st.session_state["brief"])

    st.markdown("##### The call")
    if st.session_state["sim"] is None:
        tone = st.text_input(
            "How should the call go?",
            value="The remedy landed and the customer is reassured but still wary")
        if st.button("Simulate the call", type="primary"):
            with st.spinner("Role-playing the customer against the brief…"):
                st.session_state["sim"] = sf.simulate_call(
                    cid, chosen, st.session_state["offer"], tone)
            st.rerun()
        st.caption("The result is written back as a new transcript and re-enters the same "
                   "pipeline, so the conversation becomes new evidence.")
    else:
        sim = st.session_state["sim"]
        st.code(sim["transcript"], language=None)
        a, b, c = st.columns(3)
        a.metric("Disposition", sim["disposition"])
        b.metric("Intent remaining", sim["resolved_intent"])
        c.metric("Counts as", "success" if sim["success"] else "failure")
        st.caption(sim.get("rationale", ""))

        if st.button("Feed this call back into the pipeline"):
            with st.status("Re-entering the loop…", expanded=True) as s:
                st.write("Injecting the follow-up transcript…")
                tid2 = sf.inject_event(cid, sim["transcript"], st.session_state["run_id"])
                st.write("Re-extracting signals…")
                sf.extract_signals(cid, tid2, st.session_state["run_id"])
                st.write("Recomputing state from the new evidence…")
                res = sf.compute_state(cid, st.session_state["run_id"])
                st.session_state["state_result"] = res
                s.update(label="The loop closed", state="complete")
            sf.clear_caches()
            st.success(f"State is now **{res['new']}** — recomputed from the "
                       "call the system told us to have. That is the loop as a circle, "
                       "not a line.")

    proves("APP.EXECUTE_ACTION writes the recommendation, the execution and the "
           "notification, and performs a real UPDATE in RAW. CALL_BRIEF and SIMULATE_CALL are "
           "AI_COMPLETE grounded on this customer's signals and captured evidence quotes. The "
           "simulated call is injected back through INJECT_EVENT, so it is indistinguishable "
           "from a real one.")
    nav()


# step 5 ─────────────────────────────────────────────────────────────────────
def step_learn():
    st.info("**You are here:** the part most systems skip. What happened gets written "
            "back, and the next recommendation changes because of it.")
    cid, persona = st.session_state["cid"], st.session_state["persona"]
    chosen = st.session_state["chosen"]

    if not chosen or st.session_state["exec_result"] is None:
        st.caption("No action was carried out, so no effectiveness row moves. What is worth "
                   "recording is that this state produced no candidate — which is how you "
                   "find gaps in the action catalogue before an audit does.")
        nav()
        return

    if st.session_state["outcome_result"] is None:
        sim = st.session_state["sim"]
        default = sim["disposition"] if sim else "renewed"
        opts = ["renewed", "engaged", "no_contact", "cancelled"]
        pick = st.selectbox("Outcome", opts, index=opts.index(default)
                            if default in opts else 0)
        if sim:
            st.caption(f"The simulated call closed as **{sim['disposition']}** — override "
                       "if you disagree.")
        if st.button("Record outcome", type="primary"):
            with st.spinner("Writing ACTION_OUTCOME and recomputing effectiveness…"):
                st.session_state["outcome_result"] = sf.record_outcome(
                    cid, chosen, pick, sf.customer(cid)["STATE_ID"],
                    st.session_state["run_id"])
                st.session_state["ranks_after"] = sf.recommend(
                    cid, persona, st.session_state["offer"])
            sf.clear_caches()
            st.rerun()
        nav(can_advance=False)
        return

    out = st.session_state["outcome_result"]
    if out.get("status") != "RECORDED":
        st.error(f"{out.get('status')} — {out.get('reason')}")
        nav()
        return

    before, after = out["before"], out["after"]
    st.markdown("##### What the system learned")
    k1, k2, k3 = st.columns(3)
    k1.metric("Success rate", fmt.pct(after["success_rate"]),
              delta=f"{(after['success_rate'] - before['success_rate']) * 100:+.2f}pp")
    k2.metric("Sample size", int(after["total_count"]),
              delta=int(after["total_count"]) - int(before["total_count"]))
    k3.metric("Confidence", f"{after['confidence']:.3f}",
              delta=f"{after['confidence'] - before['confidence']:+.3f}")

    st.markdown("##### Would we decide differently now?")
    rb, ra = st.session_state["ranks_before"], st.session_state["ranks_after"]
    cols = st.columns(2)
    with cols[0]:
        st.caption("Before this outcome")
        for _, x in rb.iterrows():
            st.write(f"{int(x['RANKING'])}. {x['ACTION_NAME']} — `{x['SCORE']:.4f}`")
    with cols[1]:
        st.caption("After")
        bmap = dict(zip(rb["ACTION_ID"], rb["SCORE"]))
        for _, x in ra.iterrows():
            d = float(x["SCORE"]) - float(bmap.get(x["ACTION_ID"], x["SCORE"]))
            st.write(f"{int(x['RANKING'])}. {x['ACTION_NAME']} — `{x['SCORE']:.4f}` "
                     f"({d:+.4f})")
    if rb.iloc[0]["ACTION_ID"] != ra.iloc[0]["ACTION_ID"]:
        st.success(f"**The recommendation changed.** {rb.iloc[0]['ACTION_NAME']} has been "
                   f"displaced by {ra.iloc[0]['ACTION_NAME']}. One recorded outcome moved it.")
    else:
        st.caption(f"The order held — {ra.iloc[0]['ACTION_NAME']} stays first, now at "
                   f"{ra.iloc[0]['SCORE']:.4f}. This is the honest test of a feedback loop: "
                   "not that a number moved, but whether the decision would.")

    st.markdown("##### The round trip")
    arts = sf.run_artifacts(st.session_state["run_id"])
    st.dataframe(arts, hide_index=True, use_container_width=True)
    st.caption("Every row this run wrote, in order. `Undo all open runs` in the sidebar "
               "reverses exactly this list, which is what lets one judge follow another.")

    proves("APP.RECORD_OUTCOME writes ENGINE.ACTION_OUTCOME and recomputes "
           "ENGINE.ACTION_EFFECTIVENESS — the same table RECOMMEND_ACTION reads. That shared "
           "table is the feedback loop; the re-ranking above is a second real call to the "
           "recommender, not a recalculation in the UI.")
    nav()


STUDIO_STEPS = [step_stage, step_detect, step_understand, step_decide, step_act, step_learn]


def studio():
    st.markdown("### Drive the decision loop yourself")
    st.caption("Pick a situation, give the system something new to react to, then walk the "
               "five stages it runs. Every figure is read back from Snowflake after the "
               "write that produced it.")
    scenario_picker()
    s = SCENARIOS[st.session_state["scenario"]]
    st.caption(f"**Why this one:** {s['why']}")
    st.divider()
    stepper()
    st.divider()
    STUDIO_STEPS[st.session_state["step"]]()


def main():
    init()
    sidebar()
    if st.session_state["mode"] == "studio":
        studio()
    else:
        console.render(st.session_state["page"], st.session_state["persona"])


main()
