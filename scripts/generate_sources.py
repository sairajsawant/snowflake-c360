#!/usr/bin/env python3
"""
Generate the new source data.

Content is authored here, not by a model, so it is deterministic and
reproducible: same inputs, same rows, every time. Everything is grounded in
each customer's real records — the policy ids, premiums, claim ids and amounts
come from what is actually in RAW, so a ticket about CLM-3009 refers to the
claim that genuinely exists.

Each source is written to surface a DIFFERENT signal, so the decision engine
gets independent evidence rather than one fact restated five ways:

  SUPPORT_TICKET      service quality      SLA breach, reopen count, CSAT
  EMAIL_MESSAGE       written escalation   tone hardening across a thread
  GRIEVANCE           regulatory risk      IRDAI filing, ombudsman escalation
  PORTABILITY_REQUEST competitive intent   a regulated act, not an inference
  POLICY_VERSION      product usage        renewal timeliness, upgrades, NCB
  EMPLOYER            group decision-maker HR owns the renewal, not the member

Usage:  python3 scripts/generate_sources.py > sql/v2/09_new_sources_data.sql
"""
import json
import random
from datetime import date, datetime, timedelta

SEED = 20261002
random.seed(SEED)

TODAY = date(2026, 10, 2)

INS = json.load(open("/tmp/ins_customers.json"))
LEND = json.load(open("/tmp/lend_customers.json"))


# ── helpers ──────────────────────────────────────────────────────────────────
def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def row(vals):
    return "(" + ", ".join(q(v) for v in vals) + ")"


def parse_policies(s):
    out = []
    for p in (s or "").split(";"):
        if not p:
            continue
        f = p.split("|")
        if len(f) >= 6:
            out.append(dict(id=f[0], type=f[1], premium=float(f[2]),
                            cover=float(f[3]),
                            renewal=f[4] or None, start=f[5]))
    return out


def parse_claims(s):
    out = []
    for c in (s or "").split(";"):
        if not c:
            continue
        f = c.split("|")
        if len(f) >= 5:
            out.append(dict(id=f[0], type=f[1], status=f[2],
                            amount=float(f[3]), filed=f[4]))
    return out


def d(s):
    return datetime.strptime(str(s)[:10], "%Y-%m-%d").date()


def sev(state):
    if not state:
        return 1
    s = state.upper()
    return 4 if ("CRITICAL" in s or "HARDSHIP" in s) else 3 if "HIGH" in s \
        else 2 if "MEDIUM" in s else 1


AGENTS = ["agent_rm_1", "agent_rm_2", "agent_rm_3", "agent_svc_1", "agent_svc_2"]
INSURERS = ["Star Health", "HDFC Ergo", "Niva Bupa", "Care Health", "ICICI Lombard"]
SUPPORT = "support@bharatsuraksha.co.in"
GRIEV = "grievance@bharatsuraksha.co.in"

tickets, emails, grievances, ports, versions = [], [], [], [], []
employers, members = [], []


# ── policy versions: the year-on-year product-usage record ───────────────────
# This is what closes the "purchase to date" hole. A policy bought in 2019 now
# has a row per renewal through to today, carrying premium drift, sum-insured
# upgrades, no-claim bonus and — critically — whether each renewal was on time.
def build_versions(cust, pols):
    cid = cust["CUSTOMER_ID"]
    since = d(cust["CUSTOMER_SINCE"])
    severity = sev(cust.get("STATE_NAME"))
    for pi, p in enumerate(pols):
        start = d(p["start"])
        # back-date the policy to acquisition so history is continuous
        first = date(max(since.year, 2015), start.month, start.day)
        n_years = max(1, TODAY.year - first.year)
        cover = p["cover"]
        prem = p["premium"]
        # work backwards: today's premium is the end of a drift
        base_prem = round(prem / (1.08 ** (n_years - 1)), -2) if n_years > 1 else prem
        base_cover = cover
        ncb = 0.0
        vno = 0
        for yr in range(n_years):
            eff = date(first.year + yr, first.month, first.day)
            if eff > TODAY:
                break
            vno += 1
            nxt = date(eff.year + 1, eff.month, eff.day)
            is_new = (vno == 1)
            # upgrades happen mid-life for healthier customers
            upgrade = (not is_new) and yr in (2, 4) and severity <= 2
            downgrade = (not is_new) and yr == n_years - 1 and severity >= 4
            if upgrade:
                base_cover = base_cover * 1.5
            if downgrade:
                base_cover = base_cover * 0.75
            # renewal timeliness degrades as risk rises
            if is_new:
                rstat, late = "NA", 0
            elif severity >= 4 and yr >= n_years - 2:
                rstat, late = "LATE", random.randint(12, 34)
            elif severity == 3 and yr == n_years - 1:
                rstat, late = "LATE", random.randint(4, 11)
            else:
                rstat, late = "ON_TIME", 0
            ncb = 0.0 if any(d(c["filed"]).year == eff.year for c in parse_claims(cust.get("CLAIMS"))) \
                else min(50.0, ncb + 10.0)
            ctype = "NEW" if is_new else "UPGRADE" if upgrade else \
                    "DOWNGRADE" if downgrade else "RENEWAL"
            riders = []
            if upgrade:
                riders.append("Critical Illness Rider")
            if cust.get("SEGMENT") == "Senior Citizen":
                riders.append("Domiciliary Cover")
            if cust.get("SEGMENT") == "Family Floater" and vno > 2:
                riders.append("Maternity Cover")
            versions.append(row([
                f"PV-{cid}-{p['id']}-{vno}", p["id"], cid, vno,
                eff.isoformat(), (nxt - timedelta(days=1)).isoformat(),
                round(base_cover), round(base_prem * (1.08 ** yr), -2),
                ctype, rstat, late, ncb, ", ".join(riders) or None,
            ]))


# ── support tickets + email threads ──────────────────────────────────────────
# Ticket mix is driven by the customer's actual situation: an open claim
# produces claim-status tickets, a high-risk customer produces SLA breaches and
# reopens, a calm customer produces routine admin tickets with good CSAT.
TICKET_LIB = {
    "claim_status": ("Claim status follow-up", "Claims", 48),
    "preauth": ("Cashless pre-authorisation delay", "Claims", 24),
    "claim_deficiency": ("Deficiency letter — documents already submitted", "Claims", 48),
    "premium_hike": ("Premium revision at renewal — justification requested", "Underwriting", 72),
    "network_hospital": ("Network hospital delisted", "Network", 72),
    "policy_doc": ("Policy document / 80D certificate request", "Policy Servicing", 72),
    "add_member": ("Addition of family member", "Policy Servicing", 72),
    "portability_query": ("Portability procedure enquiry", "Retention", 48),
    "refund": ("Refund not received after cancellation", "Finance", 72),
    "nach": ("Auto-debit mandate not honoured", "Finance", 48),
}


def ticket_plan(cust, pols, claims):
    """Which tickets this customer raised, and over what period."""
    severity = sev(cust.get("STATE_NAME"))
    since = d(cust["CUSTOMER_SINCE"])
    open_claims = [c for c in claims if c["status"] in ("PENDING", "PRIORITY")]
    plan = []
    # routine history, spread back over the relationship
    years_back = min(5, max(2, TODAY.year - since.year))
    for i in range(years_back):
        yr = TODAY.year - years_back + i
        kind = ["policy_doc", "add_member", "network_hospital"][i % 3]
        plan.append((kind, date(yr, 3 + (i % 7), 10 + (i % 15)), "LOW", False, 0))
    if open_claims:
        plan.append(("claim_status", TODAY - timedelta(days=52), "HIGH", severity >= 3, 1 if severity >= 3 else 0))
        if severity >= 3:
            plan.append(("preauth", TODAY - timedelta(days=21), "URGENT", True, 2))
            plan.append(("claim_deficiency", TODAY - timedelta(days=12), "HIGH", True, 1))
    if severity >= 3:
        plan.append(("premium_hike", TODAY - timedelta(days=34), "HIGH", True, 0))
    if severity >= 4:
        plan.append(("portability_query", TODAY - timedelta(days=6), "URGENT", False, 0))
        plan.append(("nach", TODAY - timedelta(days=15), "HIGH", True, 1))
    if severity == 2:
        plan.append(("claim_status", TODAY - timedelta(days=40), "MEDIUM", False, 0))
    return plan


# Email bodies. Written as real threads: the customer's tone hardens across
# messages, the company's replies stay procedural. This is the signal an
# AI extractor can read that a one-line note cannot carry.
def email_thread(cust, kind, tkt_id, subject, opened, pol, claim, breached, n):
    cid, name, email = cust["CUSTOMER_ID"], cust["FULL_NAME"], cust["EMAIL"]
    first = name.split()[0]
    pid = pol["id"] if pol else "—"
    prem = f"{int(pol['premium']):,}" if pol else "—"
    cid_claim = claim["id"] if claim else None
    camt = f"{int(claim['amount']):,}" if claim else None
    msgs = []

    def add(direction, body, offset_h, pos):
        msgs.append((direction, body, opened + timedelta(hours=offset_h), pos))

    if kind == "preauth":
        add("INBOUND", f"""Dear Sir/Madam,

I am writing with reference to policy {pid}. My cashless pre-authorisation request for claim {cid_claim} is still showing as "under review" on your portal.

The hospital has told me they cannot proceed on cashless basis without the approval letter. The estimated amount is INR {camt}. I have already submitted the discharge summary, the treating doctor's note and the pre-auth form through your TPA portal.

Please confirm when the approval will be issued.

Regards,
{name}
Policy {pid}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

Thank you for writing in. Your request has been registered under ticket {tkt_id}.

We have escalated the pre-authorisation to our TPA for review. The standard turnaround is 48 working hours from receipt of complete documentation.

Regards,
Customer Service
Bharat Suraksha Health Insurance""", 20, 2)
        if breached:
            add("INBOUND", f"""This is the third time I am writing.

It has now been well past the 48 hours you quoted. The hospital is asking me to settle in cash and claim reimbursement later, which defeats the entire purpose of a cashless policy that I have paid INR {prem} a year for.

I want a written explanation of the delay and the name of the officer handling this. If I do not receive the approval today I will be raising this with the IRDAI grievance cell.

{name}""", 76, 3)
            add("OUTBOUND", f"""Dear {first},

We acknowledge the delay and sincerely regret the inconvenience. Ticket {tkt_id} has been marked urgent and assigned to a senior claims officer.

We will revert within 24 hours.

Regards,
Customer Service""", 80, 4)

    elif kind == "premium_hike":
        add("INBOUND", f"""Dear Sir/Madam,

I have received the renewal notice for policy {pid}. The premium has been revised upward substantially from the previous year.

I would like a written explanation of how this revision has been calculated. As per IRDAI guidelines, premium revision must be based on the approved rate chart for the product and not on individual claims history alone.

Please share the basis of this revision.

Regards,
{name}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

Thank you for your mail, logged as ticket {tkt_id}.

Premium revisions are applied at the product level and reflect portfolio claims experience and medical inflation. We are arranging for an underwriter to walk you through the calculation.

Regards,
Customer Service""", 26, 2)
        if breached:
            add("INBOUND", f"""I have not received the written justification I asked for.

I have obtained a comparable quote from another insurer which is materially lower for the same sum insured. I have been with you for several years with a clean record.

Please treat this as a formal request for the justification. I am also enquiring about portability, since the renewal date is approaching.

{name}""", 120, 3)

    elif kind == "claim_deficiency":
        add("INBOUND", f"""Dear Sir/Madam,

I have received a deficiency letter on claim {cid_claim} asking for the same documents I have already uploaded twice — the discharge summary and the final bill.

This is the second deficiency letter on the same claim. Each time the clock appears to restart. Please confirm what is genuinely outstanding so I can close this once.

Regards,
{name}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

Ticket {tkt_id} refers. We have asked the TPA to reconcile the documents received against the deficiency raised and revert.

Regards,
Claims Support""", 30, 2)

    elif kind == "portability_query":
        add("INBOUND", f"""Dear Sir/Madam,

Please share the portability procedure and the required forms for policy {pid}.

I understand that under IRDAI portability regulations I need to apply at least 45 days before renewal, and that accrued continuity benefits and waiting periods carry over to the new insurer. Please confirm my accrued no-claim bonus and the waiting periods already served, as I will need these for the proposal.

Regards,
{name}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

We are sorry to see this request. Ticket {tkt_id} has been raised and routed to our retention desk, who will contact you before issuing the portability documentation.

Regards,
Customer Service""", 18, 2)

    elif kind == "nach":
        add("INBOUND", f"""Dear Sir/Madam,

The auto-debit for policy {pid} has not been presented this month. I have not cancelled the mandate from my side and my account has sufficient balance.

Please confirm the mandate is still active. I do not want the policy to lapse over a banking issue.

Regards,
{name}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

Ticket {tkt_id} refers. We are checking the NACH mandate status with our banking partner and will confirm within two working days.

Regards,
Finance Support""", 34, 2)

    elif kind == "network_hospital":
        add("INBOUND", f"""Dear Sir/Madam,

I note that a hospital near my residence has been removed from your cashless network list. This was the main hospital I relied on when taking policy {pid}.

Please confirm the current network in my area.

Regards,
{name}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

Thank you for writing in, logged as {tkt_id}. Network hospitals are reviewed periodically. We are sharing the updated list for your PIN code separately.

Regards,
Customer Service""", 22, 2)

    else:  # routine admin
        label = {"policy_doc": "the policy schedule and 80D premium certificate",
                 "add_member": "addition of a family member to the policy",
                 "claim_status": f"the current status of claim {cid_claim or ''}".strip(),
                 "refund": "the refund due after cancellation"}.get(kind, "my policy")
        add("INBOUND", f"""Dear Sir/Madam,

Please send {label} for policy {pid}.

Regards,
{name}""", 0, 1)
        add("OUTBOUND", f"""Dear {first},

Ticket {tkt_id} refers. The requested document has been sent to {email}.

Regards,
Customer Service""", 12, 2)

    for direction, body, ts, pos in msgs[:n] if n else msgs:
        mid = f"EM-{tkt_id}-{pos}"
        frm = email if direction == "INBOUND" else SUPPORT
        to = SUPPORT if direction == "INBOUND" else email
        emails.append(row([mid, tkt_id, cid, email, direction, frm, to,
                           subject, body, pos, ts.isoformat(sep=" ")]))


def build_tickets(cust, pols, claims):
    cid = cust["CUSTOMER_ID"]
    pol = pols[0] if pols else None
    open_claim = next((c for c in claims if c["status"] in ("PENDING", "PRIORITY")), None)
    for i, (kind, opened_d, prio, breached, reopens) in enumerate(ticket_plan(cust, pols, claims)):
        subj, cat, sla = TICKET_LIB[kind]
        tid = f"TKT-{cid}-{opened_d.strftime('%Y%m%d')}-{i}"
        opened = datetime.combine(opened_d, datetime.min.time()) + timedelta(hours=10 + i)
        # email for written categories, phone otherwise
        channel = "EMAIL" if kind in ("premium_hike", "claim_deficiency", "portability_query",
                                      "policy_doc", "nach", "network_hospital", "preauth") else "PHONE"
        first_resp = opened + timedelta(hours=random.randint(2, 20) if not breached else random.randint(30, 70))
        if breached:
            resolved, status = None, "OPEN"
            csat = None
        else:
            resolved = opened + timedelta(hours=random.randint(6, sla - 2))
            status, csat = "RESOLVED", random.choice([4, 5, 5, 3])
        tickets.append(row([
            tid, cid, cust["EMAIL"], cust["PHONE"], "insurance", channel, cat, prio,
            subj, pol["id"] if pol else None,
            open_claim["id"] if (open_claim and cat == "Claims") else None,
            opened.isoformat(sep=" "), first_resp.isoformat(sep=" "),
            resolved.isoformat(sep=" ") if resolved else None,
            sla, breached, reopens, status, csat, random.choice(AGENTS),
        ]))
        if channel == "EMAIL":
            email_thread(cust, kind, tid, subj, opened, pol, open_claim, breached, 0)


# ── grievances: only where the story genuinely warrants it ───────────────────
def build_grievance(cust, pols):
    severity = sev(cust.get("STATE_NAME"))
    if severity < 4:
        return
    cid = cust["CUSTOMER_ID"]
    pol = pols[0] if pols else None
    filed = TODAY - timedelta(days=9)
    grievances.append(row([
        f"GRV-{cid}-{filed.strftime('%Y%m%d')}", cid, cust["EMAIL"],
        pol["id"] if pol else None,
        f"IGMS-{random.randint(100000, 999999)}", filed.isoformat(),
        "Claim settlement delay / premium revision",
        "Policyholder has filed a grievance through the IRDAI Integrated Grievance "
        "Management System citing delay in claim settlement and an unexplained premium "
        "revision at renewal. Written justification was requested and not provided within "
        "the stipulated period.",
        "UNDER_REVIEW", None, False,
    ]))


# ── portability: the observable competitive act ──────────────────────────────
def build_portability(cust, pols):
    severity = sev(cust.get("STATE_NAME"))
    if severity < 3 or not pols:
        return
    cid = cust["CUSTOMER_ID"]
    pol = pols[0]
    req = TODAY - timedelta(days=5 if severity >= 4 else 18)
    quoted = round(pol["premium"] * (0.62 if severity >= 4 else 0.78), -2)
    stage = "FORM_REQUESTED" if severity >= 4 else "ENQUIRY"
    ports.append(row([
        f"PORT-{cid}-{req.strftime('%Y%m%d')}", cid, cust["EMAIL"], pol["id"],
        req.isoformat(), random.choice(INSURERS),
        pol["premium"], quoted, stage, "ACTIVE",
        f"Customer requested portability documentation. Quoted premium is "
        f"{round((1 - quoted / pol['premium']) * 100)}% below current renewal.",
    ]))


# ── employers: the corporate decision-maker ─────────────────────────────────
EMPLOYER_DEFS = [
    ("EMP-001", "Meridian Technologies Pvt Ltd", "Information Technology", "Mumbai",
     200, "Shalini Deshpande", "hr@meridiantech.co.in", "+91-22-4455-7788",
     "Anand Broking Services"),
    ("EMP-002", "Sterling Manufacturing Ltd", "Manufacturing", "Chennai",
     140, "Ganesh Subramanian", "people@sterlingmfg.co.in", "+91-44-2233-9900",
     "Anand Broking Services"),
    ("EMP-003", "Harbour Logistics India", "Logistics", "Delhi",
     85, "Farida Qureshi", "hradmin@harbourlogistics.in", "+91-11-4567-1200",
     "Keystone Insurance Brokers"),
]


# Which corporate customer runs which employer. Pinned, not positional, so the
# employer matches what that customer's own transcripts say about headcount.
EMPLOYER_OWNER = {"EMP-001": "INS-1011",   # Arun Mehta — "200-employee group policy"
                  "EMP-002": "INS-1017",
                  "EMP-003": "INS-1007"}


def build_employers(ins):
    corp = [c for c in ins if c.get("SEGMENT") == "Corporate Group"]
    by_id = {c["CUSTOMER_ID"]: c for c in corp}
    for i, (eid, nm, ind, city, headcount, hr, hrmail, hrphone, broker) in enumerate(EMPLOYER_DEFS):
        cust = by_id.get(EMPLOYER_OWNER.get(eid))
        pols = parse_policies(cust["POLICIES"]) if cust else []
        gp = pols[0]["id"] if pols else None
        renewal = (TODAY + timedelta(days=[74, 131, 198][i % 3])).isoformat()
        since = d(cust["CUSTOMER_SINCE"]) if cust else date(2016, 4, 1)
        employers.append(row([
            eid, nm, ind, city, gp, headcount, hr, hrmail, hrphone,
            round((pols[0]["premium"] if pols else 65000) * headcount * 0.9, -3),
            since.isoformat(), renewal, broker,
        ]))
        if cust:
            members.append(row([eid, cust["CUSTOMER_ID"], "HR_ADMIN",
                                since.isoformat()]))
    # give each group real depth: non-corporate customers in the same city are
    # modelled as covered employees, so a group decision has visible blast radius
    owners = set(EMPLOYER_OWNER.values())
    others = [c for c in ins if c["CUSTOMER_ID"] not in owners]
    for j, c in enumerate(others[:9]):
        eid = EMPLOYER_DEFS[j % len(EMPLOYER_DEFS)][0]
        members.append(row([eid, c["CUSTOMER_ID"], "EMPLOYEE",
                            d(c["CUSTOMER_SINCE"]).isoformat()]))


# ── lending: tickets only, keyed the same way ───────────────────────────────
LEND_TICKETS = [
    ("EMI debit failed — insufficient funds", "Collections", "HIGH", 48),
    ("Request for EMI date change", "Servicing", "LOW", 72),
    ("Foreclosure quote requested", "Retention", "HIGH", 48),
    ("Interest rate revision query", "Servicing", "MEDIUM", 72),
]


def build_lending(lend):
    for cust in lend:
        cid = cust["CUSTOMER_ID"]
        severity = sev(cust.get("STATE_NAME"))
        loans = (cust.get("LOANS") or "").split(";")
        lid = loans[0].split("|")[0] if loans and loans[0] else None
        picks = [0, 1] if severity <= 2 else [0, 2, 3]
        for i, pi in enumerate(picks):
            subj, cat, prio, sla = LEND_TICKETS[pi]
            opened_d = TODAY - timedelta(days=[70, 40, 11][i % 3])
            opened = datetime.combine(opened_d, datetime.min.time()) + timedelta(hours=11 + i)
            breached = severity >= 3 and i == len(picks) - 1
            tid = f"TKT-{cid}-{opened_d.strftime('%Y%m%d')}-{i}"
            resolved = None if breached else opened + timedelta(hours=random.randint(5, sla - 4))
            tickets.append(row([
                tid, cid, cust["EMAIL"], cust["PHONE"], "lending", "PHONE", cat, prio,
                subj, lid, None, opened.isoformat(sep=" "),
                (opened + timedelta(hours=random.randint(1, 12))).isoformat(sep=" "),
                resolved.isoformat(sep=" ") if resolved else None,
                sla, breached, 1 if breached else 0,
                "OPEN" if breached else "RESOLVED",
                None if breached else random.choice([3, 4, 5]),
                random.choice(AGENTS),
            ]))


# ── run ──────────────────────────────────────────────────────────────────────
for cust in INS:
    pols = parse_policies(cust.get("POLICIES"))
    claims = parse_claims(cust.get("CLAIMS"))
    build_versions(cust, pols)
    build_tickets(cust, pols, claims)
    build_grievance(cust, pols)
    build_portability(cust, pols)

build_employers(INS)
build_lending(LEND)


def emit(table, cols, rows, chunk=50):
    if not rows:
        return
    print(f"\n-- {table}: {len(rows)} rows")
    for i in range(0, len(rows), chunk):
        print(f"INSERT INTO RAW.{table} ({cols}) VALUES")
        print(",\n".join(rows[i:i + chunk]) + ";")


print("-- Generated by scripts/generate_sources.py — deterministic, seed", SEED)
print("-- Content authored in the generator, grounded in real policy/claim ids.")
print("USE DATABASE CUSTOMER_360_DB;\nUSE SCHEMA RAW;")
print("TRUNCATE TABLE IF EXISTS RAW.SUPPORT_TICKET;")
print("TRUNCATE TABLE IF EXISTS RAW.EMAIL_MESSAGE;")
print("TRUNCATE TABLE IF EXISTS RAW.GRIEVANCE;")
print("TRUNCATE TABLE IF EXISTS RAW.PORTABILITY_REQUEST;")
print("TRUNCATE TABLE IF EXISTS RAW.POLICY_VERSION;")
print("TRUNCATE TABLE IF EXISTS RAW.EMPLOYER;")
print("TRUNCATE TABLE IF EXISTS RAW.EMPLOYER_MEMBER;")

emit("SUPPORT_TICKET",
     "ticket_id, customer_id, customer_email, customer_phone, domain, channel, category, "
     "priority, subject, linked_policy_id, linked_claim_id, opened_at, first_response_at, "
     "resolved_at, sla_target_hours, sla_breached, reopen_count, status, csat_score, agent_id",
     tickets)
emit("EMAIL_MESSAGE",
     "message_id, ticket_id, customer_id, customer_email, direction, from_address, "
     "to_address, subject, body, thread_position, sent_at", emails, chunk=20)
emit("GRIEVANCE",
     "grievance_id, customer_id, customer_email, policy_id, igms_token, filed_date, "
     "category, description, status, resolution_date, escalated_to_ombudsman", grievances)
emit("PORTABILITY_REQUEST",
     "request_id, customer_id, customer_email, policy_id, requested_date, target_insurer, "
     "current_premium, quoted_premium, stage, status, notes", ports)
emit("POLICY_VERSION",
     "version_id, policy_id, customer_id, version_no, effective_from, effective_to, "
     "sum_insured, premium, change_type, renewal_status, days_late, no_claim_bonus_pct, riders",
     versions)
emit("EMPLOYER",
     "employer_id, employer_name, industry, city, group_policy_id, employee_count, "
     "hr_contact_name, hr_contact_email, hr_contact_phone, annual_premium, "
     "relationship_since, renewal_date, broker_name", employers)
emit("EMPLOYER_MEMBER", "employer_id, customer_id, member_role, joined_date", members)

print("\nSELECT 'Source data loaded' AS status;")
