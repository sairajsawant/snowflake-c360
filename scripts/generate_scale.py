#!/usr/bin/env python3
"""
Scale the insurance book from 20 to 500 customers.

Same approach as generate_sources.py: content is authored here, not by a model,
so it is deterministic (same seed, same rows). The existing data is the
reference — same tables, same id shapes, same value ranges, and the ticket and
email threads reuse generate_sources.py's templates verbatim.

Every new customer is given one latent SCENARIO, and that one story drives all
of their records consistently: a delayed claim produces the PENDING claim, the
claim-status tickets that breach SLA, the hardening email thread, the angry call
and the negative interaction notes. Scenarios are chosen so that, between them,
every signal in CONFIG.SIGNAL_DEFINITION fires somewhere in the book, from
different sources, so the engines see independent evidence rather than one fact
restated.

New customers belong to three new teams (12 relationship managers). The
original 30 customers, their RMs and team_alpha are untouched, so the existing
demo behaves exactly as before; the Analyst / Domain Expert sees the whole book.

Usage:  python3 scripts/generate_scale.py > sql/app/24_scale_data.sql
"""
import random
from datetime import date, datetime, timedelta

import generate_sources as gs

SEED = 20261005
R = random.Random(SEED)
TODAY = date(2026, 10, 5)
N_CUSTOMERS = 480
row, q = gs.row, gs.q

# ── reference vocabularies (drawn from the existing book) ────────────────────
MALE = ["Rajesh", "Amit", "Suresh", "Vikram", "Arjun", "Rohan", "Karthik", "Sanjay", "Manoj",
        "Anil", "Deepak", "Rahul", "Nikhil", "Pradeep", "Harish", "Gaurav", "Siddharth",
        "Venkatesh", "Mohan", "Ashok", "Imran", "Farhan", "Joseph", "Thomas", "Gurpreet",
        "Harpreet", "Abhishek", "Kunal", "Naveen", "Prakash", "Ramesh", "Sunil", "Tarun",
        "Varun", "Yash", "Aditya", "Balaji", "Dinesh", "Ganesh", "Jayant"]
FEMALE = ["Priya", "Anjali", "Sunita", "Kavita", "Meera", "Lakshmi", "Pooja", "Neha",
          "Divya", "Shreya", "Ananya", "Deepa", "Rekha", "Swati", "Nandini", "Asha",
          "Fatima", "Ayesha", "Mary", "Simran", "Harleen", "Revathi", "Padma", "Geeta",
          "Usha", "Radha", "Ishita", "Kritika", "Sneha", "Tanvi", "Vidya", "Bhavna",
          "Jyoti", "Madhuri", "Nisha", "Pallavi", "Rashmi", "Sapna", "Shalini", "Uma"]
LAST = ["Sharma", "Verma", "Gupta", "Iyer", "Nair", "Reddy", "Rao", "Patel", "Shah",
        "Mehta", "Desai", "Joshi", "Kulkarni", "Deshpande", "Banerjee", "Chatterjee",
        "Mukherjee", "Das", "Bose", "Sen", "Singh", "Kaur", "Gill", "Malhotra", "Kapoor",
        "Khanna", "Chopra", "Agarwal", "Jain", "Bansal", "Mishra", "Pandey", "Tiwari",
        "Yadav", "Pillai", "Menon", "Krishnan", "Subramanian", "Naidu", "Chowdhury",
        "Khan", "Qureshi", "Ansari", "D'Souza", "Fernandes", "Pinto", "Hegde", "Shetty",
        "Bhat", "Saxena"]
CITIES = ["Mumbai", "Delhi", "Bengaluru", "Chennai", "Hyderabad", "Pune", "Kolkata",
          "Ahmedabad", "Jaipur", "Lucknow", "Kochi", "Chandigarh", "Indore", "Nagpur",
          "Coimbatore", "Bhubaneswar", "Surat", "Vadodara", "Mysuru", "Thiruvananthapuram"]
HOSPITALS = {
    "Mumbai": ["Lilavati Hospital", "Kokilaben Hospital", "Hinduja Hospital"],
    "Delhi": ["Max Saket", "Fortis Vasant Kunj", "Sir Ganga Ram Hospital"],
    "Bengaluru": ["Manipal Hospital", "Narayana Health", "Sakra World Hospital"],
    "Chennai": ["Apollo Greams Road", "MIOT International", "Kauvery Hospital"],
    "Hyderabad": ["Yashoda Hospital", "KIMS", "Care Hospital Banjara Hills"],
    "Pune": ["Ruby Hall Clinic", "Jehangir Hospital", "Sahyadri Hospital"],
    "Kolkata": ["AMRI Hospital", "Peerless Hospital", "Medica Superspecialty"],
}
DEFAULT_HOSP = ["Apollo Hospital", "Fortis Hospital", "Manipal Hospital", "Max Hospital"]
RIVALS = ["Star Health", "HDFC Ergo", "Niva Bupa", "Care Health", "ICICI Lombard",
          "Aditya Birla Health", "Tata AIG"]
AGENTS = [f"AGT-{n}" for n in range(106, 121)]
RMS = {f"rm{i}": t for i, t in
       [(3, "team_north"), (4, "team_north"), (5, "team_north"), (6, "team_north"),
        (7, "team_south"), (8, "team_south"), (9, "team_south"), (10, "team_south"),
        (11, "team_west"), (12, "team_west"), (13, "team_west"), (14, "team_west")]}

SEGMENT = {  # premium range, cover options, LTV range, age range
    "Individual":      ((12000, 30000), (500000, 1000000), (50000, 220000), (24, 55)),
    "Family Floater":  ((25000, 55000), (1000000, 1500000, 2500000), (150000, 520000), (28, 52)),
    "Senior Citizen":  ((40000, 78000), (500000, 1000000), (300000, 900000), (60, 76)),
    "Corporate Group": ((60000, 120000), (1500000, 2500000), (800000, 2500000), (35, 58)),
}
SIDE_POLICIES = [("Term Life", (15000, 45000), (5000000, 10000000)),
                 ("Motor Insurance", (8000, 18000), (600000, 1200000)),
                 ("Critical Illness Cover", (12000, 30000), (1000000, 2500000)),
                 ("Travel Insurance", (2500, 6000), (250000, 500000)),
                 ("Home Insurance", (6000, 12000), (3000000, 8000000))]

# scenario: (count, transcript probability, preferred segments or None)
SCENARIOS = {
    "steady":                (147, 0.08, None),
    "renewal_due":           (45, 0.30, None),
    "premium_shock":         (40, 0.85, None),
    "claim_delay":           (40, 0.70, None),
    "claim_rejected":        (20, 0.80, None),
    "cashless_escalation":   (18, 1.00, None),
    "mis_selling":           (10, 1.00, ["Family Floater", "Individual"]),
    "network_delisted":      (20, 0.50, None),
    "payment_trouble":       (30, 0.45, None),
    "affordability":         (15, 0.70, ["Senior Citizen"]),
    "service_failure":       (25, 0.35, None),
    "group_renewal_risk":    (7, 1.00, ["Corporate Group"]),
    "interest_maternity":    (14, 1.00, ["Family Floater"]),
    "interest_senior":       (12, 1.00, ["Senior Citizen"]),
    "interest_critical":     (12, 1.00, ["Individual"]),
    "interest_opd":          (10, 1.00, ["Family Floater", "Individual"]),
    "interest_topup":        (10, 1.00, ["Individual", "Family Floater"]),
    "interest_corporate":    (5, 1.00, ["Corporate Group"]),
}
assert sum(v[0] for v in SCENARIOS.values()) == N_CUSTOMERS
GROWTH = {s for s in SCENARIOS if s.startswith("interest_")}
# Names already in the book. Every generated name is unique, so a customer can
# always be found by name (the chat resolves customers that way).
TAKEN = {n.lower() for n in (
    "Rajesh Kumar;Priya Sharma;Amit Patel;Deepika Singh;Suresh Reddy;Ananya Gupta;Vikram Malhotra;"
    "Sunita Iyer;Rohit Joshi;Meena Nair;Arun Mehta;Kavita Desai;Sanjay Verma;Pooja Kapoor;Manoj Tiwari;"
    "Neha Agarwal;Ravi Chandra;Lakshmi Rao;Kiran Bhat;Divya Menon;Arjun Nair;Sneha Pillai;Vijay Krishnan;"
    "Asha Devi;Prakash Sinha;Nandini Iyengar;Gaurav Saxena;Pallavi Jain;Sudhir Bhatt;Rekha Acharya").split(";")}
HINGLISH_SHARE = 0.3

customers, policies, claims, payments, interactions, transcripts = [], [], [], [], [], []
versions, tickets, grievances, ports, employers, members, assignments = [], [], [], [], [], [], []
_seq = {"POL": 60000, "CLM": 40000, "PAY": 900000, "INT": 70000, "TRN": 80000}


def nid(kind):
    _seq[kind] += 1
    return f"{kind}-{_seq[kind]}"


def money(x):
    return f"{int(round(x)):,}"


def lakh(x):
    v = x / 100000
    return f"{v:.0f} lakh" if v == int(v) else f"{v:.1f} lakh"


def ts(dt):
    return dt.isoformat(sep=" ") if isinstance(dt, datetime) else dt.isoformat()


def at(d, hour):
    return datetime.combine(d, datetime.min.time()) + timedelta(hours=hour, minutes=R.randint(0, 59))


# ── transcripts: authored per scenario, English and Hinglish ─────────────────
# Each is a list of lines; {placeholders} are filled from the customer's own
# records, so the policy, claim, amount and hospital quoted are the real ones.
T = {
"steady": [
"""Customer: Hi, I just wanted to say the claim for my day-care procedure at {hosp} was settled very quickly. Thank you.
Agent: That is great to hear, {hon} {last}. Is there anything else I can help you with on policy {pid}?
Customer: No, everything is fine. I will renew as usual. Please just send me the 80D certificate for this year.
Agent: Certainly, I will email it to {email} today.
Customer: Perfect, thanks. Your app is very easy to use.""",
"""Customer: Namaste, mujhe bas apna premium certificate chahiye tha tax ke liye.
Agent: Namaste {hon} {last}. Policy {pid} ka 80D certificate main abhi email kar deta hoon.
Customer: Thank you. Aur haan, pichhle saal ka claim bahut smoothly hua tha, koi problem nahi hui.
Agent: Sunke accha laga. Renewal ke time pe hum aapko reminder bhej denge.
Customer: Theek hai, renewal toh karna hi hai. Bahut shukriya.""",
],
"renewal_due": [
"""Customer: Hello, my renewal for policy {pid} is coming up in about {days} days. I wanted to check the new premium.
Agent: Good afternoon {hon} {last}. Your renewal premium is INR {new_prem}, with your no-claim bonus applied.
Customer: That is reasonable. Can I pay by UPI this time instead of net banking?
Agent: Yes, I will send you a payment link closer to the date.
Customer: Great, please do. I want to renew on time.""",
"""Customer: Mera renewal {days} din mein aa raha hai. Premium kitna hoga is baar?
Agent: {hon} {last}, policy {pid} ka renewal premium INR {new_prem} hai, no-claim bonus ke saath.
Customer: Theek hai, yeh chalega. Link bhej dijiye, main time pe pay kar dunga.
Agent: Zaroor, renewal se ek hafta pehle link aa jayega.""",
],
"premium_shock": [
"""Customer: I received the renewal notice for policy {pid}. The premium has gone from INR {prem} to INR {new_prem}. That is a {hike}% increase.
Agent: {hon} {last}, I understand. The revision reflects medical inflation and the age band change.
Customer: I have been with you for {tenure} years. {rival} has quoted me INR {quote} for the same {cover} cover.
Agent: Let me check if a loyalty discount can be applied before your renewal.
Customer: Please do it quickly. If you cannot match something close to that, I will port my policy before the renewal date.""",
"""Customer: This renewal premium of INR {new_prem} is not acceptable. Last year it was INR {prem}.
Agent: I apologise for the surprise, {hon} {last}. Let me explain the calculation.
Customer: I do not need the calculation. I need a fair price. I have not made a single claim in {tenure} years.
Agent: Your no-claim bonus is already applied, but I can raise a retention request.
Customer: Raise it. I am already comparing plans on PolicyBazaar and {rival} looks much cheaper. I am considering switching.""",
"""Customer: Renewal notice dekha maine. INR {prem} se seedha INR {new_prem}? Yeh {hike}% badh gaya hai.
Agent: {hon} {last} ji, main samajh sakta hoon. Yeh medical inflation ki wajah se hai.
Customer: {tenure} saal se aapke saath hoon, ek bhi claim nahi kiya. {rival} wale INR {quote} mein de rahe hain.
Agent: Main loyalty discount ke liye request daal deta hoon.
Customer: Jaldi kijiye. Agar kuch nahi hua toh main port kar lunga, renewal se pehle hi.""",
],
"claim_delay": [
"""Customer: My claim {cid} for the hospitalisation at {hosp} has been pending for {age} days. Every time I call, I hear the same thing.
Agent: I am very sorry, {hon} {last}. I can see the claim for INR {amt} is under review with the TPA.
Customer: Under review for {age} days? I submitted every document twice. I paid the hospital from my savings.
Agent: I will escalate it to a senior claims officer today.
Customer: This is the last time I am asking nicely. If it is not settled this week, I will file a complaint with IRDAI and move my policy elsewhere.""",
"""Customer: I am calling again about claim {cid}. INR {amt}. It is more than a month now.
Agent: {hon} {last}, I see a deficiency was raised for the final bill.
Customer: I uploaded the final bill on the day of discharge. This is the second deficiency letter for the same document.
Agent: I understand your frustration. Let me reconcile the documents with the TPA.
Customer: I am frustrated, yes. I am not happy paying INR {prem} a year for this kind of service.""",
"""Customer: Claim {cid} ka kya hua? {age} din ho gaye hain. {hosp} ka bill maine apni jeb se bhara hai.
Agent: {hon} {last} ji, maaf kijiye. Claim abhi TPA ke paas review mein hai.
Customer: Har baar yahi sunta hoon. Saare documents do baar bhej chuka hoon.
Agent: Main isko aaj hi senior officer ko escalate karta hoon.
Customer: Is hafte settle nahi hua toh main IRDAI mein complaint karunga aur policy port kar dunga.""",
],
"claim_rejected": [
"""Customer: Why was my claim {cid} rejected? The letter says pre-existing condition, but I was never diagnosed before buying policy {pid}.
Agent: {hon} {last}, the rejection was based on the treating doctor's history notes.
Customer: The doctor wrote 'history of mild hypertension' because I mentioned it once. That is not a pre-existing disease.
Agent: You can request a review with additional medical records.
Customer: I will, but this feels unfair. INR {amt} is a lot of money. I am considering taking this to the ombudsman.""",
"""Customer: Mera claim {cid} reject kar diya, waiting period bolke. Mujhe agent ne bola tha ki koi waiting period nahi hai.
Agent: {hon} {last} ji, policy terms mein do saal ka waiting period likha hai.
Customer: Toh agent ne galat bataya. INR {amt} ka bill hai. Main review chahta hoon.
Agent: Main review request daal deta hoon, aapko 15 din mein reply milega.
Customer: Dekhte hain. Agar yeh reject hi raha toh main yeh policy cancel karke kahin aur le lunga.""",
],
"cashless_escalation": [
"""Customer: I am at {hosp} right now. The cashless pre-authorisation for claim {cid} has not come through and they want me to pay INR {amt} upfront.
Agent: {hon} {last}, I can see the request. The TPA has asked for one more document.
Customer: Which document? The hospital sent everything yesterday. My father is in the ICU.
Agent: I will mark it urgent and call the TPA directly.
Customer: I have already filed a grievance on the IRDAI portal. I have also asked {rival} for portability forms. I am done waiting.""",
"""Customer: This is my fourth call today about the cashless approval for claim {cid}. Nobody calls back.
Agent: I am very sorry, {hon} {last}. Your case is with the senior claims team.
Customer: The hospital is threatening to discharge my wife against medical advice unless I pay. I have paid INR {prem} every year for this policy.
Agent: I understand. I am escalating it as a priority right now.
Customer: I have filed a formal complaint with IRDAI. Once this is over, I am porting to {rival}.""",
"""Customer: {hosp} mein hoon, cashless approval abhi tak nahi aaya. Claim {cid}. Hospital INR {amt} advance maang raha hai.
Agent: {hon} {last} ji, TPA ne ek aur document maanga hai.
Customer: Kaunsa document? Hospital ne kal sab bhej diya tha. Meri maa ICU mein hai.
Agent: Main abhi urgent mark karke TPA ko call karta hoon.
Customer: Maine IRDAI portal pe grievance daal diya hai. {rival} se porting form bhi mangwa liya hai. Bas, ab bahut ho gaya.""",
],
"mis_selling": [
"""Customer: I was sold policy {pid} by your agent who told me it covers maternity from day one. Now claim {cid} for my delivery is rejected because of a waiting period.
Agent: {hon} {last}, I understand. Do you have anything in writing from the agent?
Customer: Yes, I have his WhatsApp messages. I chose your company over {rival} because of that promise.
Agent: Then we can register it as a mis-selling complaint and investigate.
Customer: I have already escalated it to the insurance ombudsman. I want a full refund of premiums or the claim paid. Otherwise I am taking legal action.""",
"""Customer: Aapke agent ne bola tha ki OPD covered hai. Ab claim {cid} reject ho gaya, bol rahe ho OPD covered hi nahi hai.
Agent: {hon} {last} ji, policy document mein OPD cover nahi hai.
Customer: Toh agent ne jhooth bola. Mere paas uske messages hain. Yeh mis-selling hai.
Agent: Main mis-selling complaint register kar deta hoon.
Customer: Maine ombudsman ko already likh diya hai. Premium wapas chahiye, warna main yeh policy cancel kar raha hoon.""",
],
"network_delisted": [
"""Customer: {hosp} is no longer in your cashless network. That is the only big hospital near my house.
Agent: {hon} {last}, network hospitals are reviewed periodically. I can share alternatives.
Customer: The alternatives are 40 minutes away. In an emergency that matters. I bought policy {pid} because of that hospital.
Agent: You can still claim reimbursement at {hosp}.
Customer: Reimbursement means paying lakhs upfront. I am not happy about this. I will see what other insurers cover it.""",
"""Customer: {hosp} aapke network se hata diya gaya hai? Mere ghar ke paas wahi ek accha hospital hai.
Agent: {hon} {last} ji, haan, network review hua tha. Main aapko dusre hospitals ki list bhejta hoon.
Customer: Woh sab bahut door hain. Maine policy isi hospital ki wajah se li thi.
Agent: Aap reimbursement claim kar sakte hain.
Customer: Reimbursement matlab pehle paise khud bharo. Yeh theek nahi hai. Main dusri companies check karunga.""",
],
"payment_trouble": [
"""Customer: The auto-debit for policy {pid} failed again. I had the money in my account.
Agent: {hon} {last}, I can see two failed attempts this month. The bank returned it as a mandate issue.
Customer: I changed my bank last month. Can I pay in instalments instead? INR {new_prem} at once is difficult right now.
Agent: We offer quarterly payment for this plan. I can switch you.
Customer: Please do. I do not want the policy to lapse, but things are tight after my job change.""",
"""Customer: Is mahine premium nahi kat paaya. Auto-debit fail ho gaya.
Agent: {hon} {last} ji, do baar try hua, dono baar fail hua.
Customer: Thoda paisa tight chal raha hai. Kya main EMI mein premium de sakta hoon? INR {new_prem} ek saath mushkil hai.
Agent: Haan, quarterly option hai. Main aapke liye change kar deta hoon.
Customer: Kar dijiye please. Policy lapse nahi honi chahiye, family ka cover hai.""",
],
"affordability": [
"""Customer: The renewal premium of INR {new_prem} on policy {pid} is too much on my pension. I may have to reduce my cover.
Agent: {hon} {last}, we can lower the sum insured to bring the premium down.
Customer: I do not want to, at my age the cover matters most. But I cannot pay this every year.
Agent: Let me check if a co-payment option reduces it.
Customer: Please check. If nothing works, I will have to take the lower cover or look at other companies.""",
"""Customer: Pension pe hoon, INR {new_prem} premium bharna mushkil hai. Cover kam karna padega shayad.
Agent: {hon} {last} ji, sum insured kam karke premium kam ho sakta hai.
Customer: Is umar mein cover hi toh chahiye. Par har saal itna nahi de sakti.
Agent: Main co-payment option check karta hoon.
Customer: Dekhiye kya ho sakta hai. Warna kam cover lena padega ya kahin aur dekhna padega.""",
],
"service_failure": [
"""Customer: I have raised the same request three times. Ticket after ticket gets closed without anything being done.
Agent: I apologise, {hon} {last}. I can see the tickets on policy {pid}.
Customer: Each time someone closes it and I get a survey asking how satisfied I am. I am not satisfied.
Agent: I will keep this one open until it is actually resolved.
Customer: I am frustrated with the service. I expected better after {tenure} years.""",
"""Customer: Teen baar complaint kar chuka hoon. Har baar ticket close ho jata hai bina kuch kiye.
Agent: {hon} {last} ji, maaf kijiye. Main tickets dekh raha hoon.
Customer: Har baar survey aata hai ki kitna satisfied ho. Bilkul satisfied nahi hoon.
Agent: Is baar main ise tab tak open rakhunga jab tak solve na ho.
Customer: Bahut frustrated hoon. {tenure} saal se customer hoon, yeh expect nahi kiya tha.""",
],
"group_renewal_risk": [
"""Customer: This is {first} from HR at {employer}. Our group policy for {headcount} employees renews in {days} days.
Agent: Good morning {hon} {last}. How can I help with the renewal?
Customer: Our broker has a quote from {rival} that is about 15% lower, with better maternity limits for employees.
Agent: We value the relationship. Let me get our corporate team to review the terms.
Customer: Please do it this week. Management is considering switching the entire group if the renewal terms do not improve.""",
],
"interest_maternity": [
"""Customer: Hi, we got married last year and are planning a baby. Does my family floater {pid} cover maternity?
Agent: Congratulations, {hon} {last}. Your current plan does not include maternity, but we have a maternity add-on.
Customer: What is the waiting period? We want to plan this properly.
Agent: The add-on has a nine-month waiting period and covers delivery and newborn care.
Customer: That sounds good. Please send me the details of the maternity cover and the premium.""",
"""Customer: Hamari shaadi pichhle saal hui hai, baby plan kar rahe hain. Kya meri policy {pid} mein maternity cover hai?
Agent: Congratulations {hon} {last} ji. Abhi maternity included nahi hai, par maternity add-on available hai.
Customer: Waiting period kitna hai? Hum pehle se plan karna chahte hain.
Agent: Nau mahine ka waiting period hai, delivery aur newborn care dono cover hote hain.
Customer: Accha hai. Maternity cover ki details aur premium bhej dijiye.""",
],
"interest_senior": [
"""Customer: My parents are both above seventy now. Is there a plan with health check-ups and home care for seniors?
Agent: Yes, {hon} {last}, our senior wellness plan includes annual check-ups and domiciliary care.
Customer: My mother has diabetes. Would that be covered?
Agent: Pre-existing conditions are covered after the waiting period, with a co-pay option to lower the premium.
Customer: That is helpful. Please share the senior wellness plan details for both of them.""",
"""Customer: Meri umar 68 hai. Kya koi plan hai jismein regular health check-up aur ghar pe care mile?
Agent: {hon} {last} ji, hamara senior wellness plan hai, annual check-up aur home care ke saath.
Customer: Mujhe BP ki problem hai, woh cover hogi?
Agent: Waiting period ke baad cover hogi, co-pay lene se premium kam hoga.
Customer: Theek hai, senior wellness plan ki details bhej dijiye.""",
],
"interest_critical": [
"""Customer: My father had a heart attack at fifty-two, and I am forty-four now. I am worried about critical illness.
Agent: I understand, {hon} {last}. A critical illness cover pays a lump sum on diagnosis, separate from hospital bills.
Customer: How much cover would make sense with my current {cover} policy?
Agent: Many customers in your situation take 20 to 25 lakh.
Customer: Please send me a critical illness quote for 25 lakh. I want to sort this out this month.""",
],
"interest_opd": [
"""Customer: We spend a lot on doctor visits and medicines for the kids. Does my policy {pid} cover OPD?
Agent: {hon} {last}, OPD is not included, but we have an OPD cover add-on.
Customer: What does it include?
Agent: Consultations, diagnostics and pharmacy bills up to an annual limit.
Customer: That would help a lot. Please share the OPD cover options.""",
"""Customer: Bachchon ke doctor visits aur dawaiyon pe bahut kharcha hota hai. Kya OPD cover milta hai?
Agent: {hon} {last} ji, OPD add-on available hai, consultation aur medicines dono cover hote hain.
Customer: Yeh toh bahut kaam ka hai. Details bhej dijiye OPD cover ki.""",
],
"interest_topup": [
"""Customer: My cover is {cover}, and hospital bills in {city} are getting expensive. Is there a way to increase it without a big premium?
Agent: Yes, {hon} {last}. A super top-up adds cover above a deductible at a much lower premium.
Customer: How much would a 20 lakh super top-up cost?
Agent: For your age it is roughly INR 4,000 to 6,000 a year.
Customer: That is very reasonable. Please send me the super top-up cover details.""",
],
"interest_corporate": [
"""Customer: This is {first} from HR at {employer}. Several employees want to cover their parents, which our group policy does not include.
Agent: {hon} {last}, we offer a voluntary corporate top-up that employees can buy for parents.
Customer: Can it be deducted from salary?
Agent: Yes, through payroll deduction, with group rates.
Customer: Please send me the corporate top-up proposal for about {headcount} employees.""",
],
}
INTERACTION_SUBJECT = {
    "steady": ("Feedback", "Positive feedback on claim experience", (0.4, 0.8)),
    "renewal_due": ("Inquiry", "Renewal premium enquiry", (0.1, 0.5)),
    "premium_shock": ("Complaint", "Renewal premium increase dispute", (-0.85, -0.45)),
    "claim_delay": ("Complaint", "Claim settlement delay", (-0.9, -0.55)),
    "claim_rejected": ("Complaint", "Claim rejection dispute", (-0.85, -0.5)),
    "cashless_escalation": ("Escalation", "Cashless pre-authorisation delay at hospital", (-0.95, -0.7)),
    "mis_selling": ("Escalation", "Mis-selling complaint", (-0.95, -0.75)),
    "network_delisted": ("Complaint", "Network hospital delisted", (-0.6, -0.3)),
    "payment_trouble": ("Service", "Auto-debit failure and payment options", (-0.4, -0.1)),
    "affordability": ("Inquiry", "Renewal affordability on pension", (-0.5, -0.2)),
    "service_failure": ("Complaint", "Repeated unresolved service requests", (-0.75, -0.45)),
    "group_renewal_risk": ("Inquiry", "Group policy renewal terms", (-0.4, -0.1)),
    "interest_maternity": ("Inquiry", "Maternity cover enquiry", (0.3, 0.7)),
    "interest_senior": ("Inquiry", "Senior wellness plan enquiry", (0.2, 0.6)),
    "interest_critical": ("Inquiry", "Critical illness cover enquiry", (0.1, 0.5)),
    "interest_opd": ("Inquiry", "OPD cover enquiry", (0.3, 0.7)),
    "interest_topup": ("Inquiry", "Super top-up enquiry", (0.3, 0.7)),
    "interest_corporate": ("Inquiry", "Corporate top-up for employees' parents", (0.2, 0.6)),
}
CLAIM_DESC = {
    "Hospitalization": "Admitted to {hosp} for {why}. {n}-day stay.",
    "Day Care": "Day care procedure at {hosp} for {why} under cashless facility.",
    "Maternity": "Delivery at {hosp}. Claim filed for maternity expenses.",
    "Critical Illness": "Diagnosed with {why} at {hosp}. Lump-sum benefit claimed.",
}
WHY = {"Hospitalization": ["dengue fever", "appendectomy", "pneumonia", "knee replacement",
                           "cardiac evaluation and angioplasty", "kidney stone removal",
                           "typhoid with complications", "spinal surgery"],
       "Day Care": ["cataract surgery", "chemotherapy cycle", "dialysis", "lithotripsy"],
       "Critical Illness": ["early-stage cancer", "stroke"], "Maternity": [""]}


def pick_segment(prefs):
    if prefs:
        return R.choice(prefs)
    return R.choices(list(SEGMENT), weights=[40, 35, 20, 5])[0]


def make_claim(cust, pol, ctype, status, filed, amount, resolved=None):
    cid = nid("CLM")
    why = R.choice(WHY[ctype]) if WHY.get(ctype) else ""
    desc = CLAIM_DESC[ctype].format(hosp=cust["hosp"], why=why, n=R.randint(2, 7))
    if status == "REJECTED":
        desc += " " + R.choice(["Rejected: pre-existing disease exclusion.",
                                "Rejected: within waiting period.",
                                "Rejected: treatment not covered under policy terms."])
    claims.append(row([cid, pol["id"], cust["id"], ctype, status, round(amount, -2),
                       filed.isoformat(), resolved.isoformat() if resolved else None, desc,
                       ts(at(filed, 9)), ts(at(resolved or TODAY, 9))]))
    return {"id": cid, "type": ctype, "status": status, "amount": round(amount, -2),
            "filed": filed.isoformat()}


# ── one customer, end to end ─────────────────────────────────────────────────
def build(i, scenario):
    rng = R
    cid = f"INS-{2001 + i}"
    count, p_call, prefs = SCENARIOS[scenario]
    seg = pick_segment(prefs)
    prem_rng, covers, ltv_rng, age_rng = SEGMENT[seg]
    female = rng.random() < 0.48
    first = rng.choice(FEMALE if female else MALE)
    last = rng.choice(LAST)
    alt = random.Random(f"{SEED}-{cid}")   # separate stream: the rest of the book is unchanged
    while f"{first} {last}".lower() in TAKEN:
        last = alt.choice(LAST)
    TAKEN.add(f"{first} {last}".lower())
    city = rng.choice(CITIES)
    hosp = rng.choice(HOSPITALS.get(city, DEFAULT_HOSP))
    age = rng.randint(*age_rng)
    dob = date(TODAY.year - age, rng.randint(1, 12), rng.randint(1, 28))
    tenure = {"interest_maternity": (1, 4)}.get(scenario, (1, 12))
    tenure = rng.randint(*tenure)
    since = date(TODAY.year - tenure, rng.randint(1, 12), rng.randint(1, 28))
    if since > TODAY - timedelta(days=200):
        since = TODAY - timedelta(days=400)
    email = f"{first}.{last}{rng.randint(1, 99)}@{rng.choice(['gmail.com', 'yahoo.co.in', 'outlook.com', 'rediffmail.com'])}".lower().replace("'", "")
    phone = f"+91-{rng.choice('6789')}{rng.randint(100000000, 999999999)}"
    ltv = round(rng.uniform(*ltv_rng), -3)
    customers.append(row([cid, first, last, email, phone, dob.isoformat(), since.isoformat(),
                          seg, ltv, city, ts(at(since, 10)), ts(at(TODAY, 8))]))
    rm = list(RMS)[i % len(RMS)]
    assignments.append(row([cid, rm, RMS[rm], "insurance"]))

    cust = {"id": cid, "first": first, "last": last, "hon": "Ms." if female else "Mr.",
            "email": email, "phone": phone, "city": city, "hosp": hosp, "seg": seg,
            "since": since, "tenure": max(1, TODAY.year - since.year), "scenario": scenario}

    # policies — anniversary sets the renewal; the scenario sets how close it is
    days_to_renewal = {"renewal_due": (8, 55), "premium_shock": (10, 40),
                       "affordability": (12, 45), "payment_trouble": (20, 90),
                       "group_renewal_risk": (30, 75)}.get(scenario, (65, 360))
    renew = TODAY + timedelta(days=rng.randint(*days_to_renewal))
    start = date(renew.year - 1, renew.month, min(renew.day, 28))
    prem = round(rng.uniform(*prem_rng), -2)
    cover = rng.choice(covers)
    pol = {"id": nid("POL"), "type": "Health Insurance", "premium": prem, "cover": cover,
           "renewal": renew, "start": start}
    pols = [pol]
    if rng.random() < 0.3 and scenario not in ("affordability",):
        ptype, prng, crng = rng.choice(SIDE_POLICIES)
        r2 = TODAY + timedelta(days=rng.randint(30, 360))
        pols.append({"id": nid("POL"), "type": ptype, "premium": round(rng.uniform(*prng), -2),
                     "cover": round(rng.uniform(*crng), -5), "renewal": r2,
                     "start": date(r2.year - 1, r2.month, min(r2.day, 28))})
    for p in pols:
        policies.append(row([p["id"], cid, p["type"], "ACTIVE", p["premium"], p["cover"],
                             p["start"].isoformat(), (p["renewal"] - timedelta(days=1)).isoformat(),
                             p["renewal"].isoformat(), ts(at(since, 11)), ts(at(TODAY, 8))]))
    hike = {"premium_shock": rng.randint(24, 38), "affordability": rng.randint(18, 30)}.get(scenario, rng.randint(6, 11))
    new_prem = round(prem * (1 + hike / 100), -2)

    # claims
    cl = []
    if scenario in ("steady", "renewal_due") or scenario in GROWTH:
        if rng.random() < 0.35:
            f = TODAY - timedelta(days=rng.randint(200, 900))
            cl.append(make_claim(cust, pol, rng.choice(["Day Care", "Hospitalization"]), "APPROVED",
                                 f, rng.uniform(30000, 180000), f + timedelta(days=rng.randint(5, 15))))
    elif scenario == "claim_delay":
        f = TODAY - timedelta(days=rng.randint(33, 80))
        cl.append(make_claim(cust, pol, "Hospitalization", "PENDING", f, rng.uniform(120000, 600000)))
    elif scenario == "claim_rejected":
        f = TODAY - timedelta(days=rng.randint(20, 60))
        cl.append(make_claim(cust, pol, "Hospitalization", "REJECTED", f, rng.uniform(80000, 450000),
                             f + timedelta(days=rng.randint(10, 18))))
    elif scenario == "cashless_escalation":
        f = TODAY - timedelta(days=rng.randint(3, 12))
        cl.append(make_claim(cust, pol, "Hospitalization", "PENDING", f, rng.uniform(250000, 900000)))
    elif scenario == "mis_selling":
        f = TODAY - timedelta(days=rng.randint(25, 70))
        cl.append(make_claim(cust, pol, rng.choice(["Maternity", "Day Care"]), "REJECTED", f,
                             rng.uniform(60000, 160000), f + timedelta(days=12)))
    elif scenario == "service_failure" and rng.random() < 0.5:
        f = TODAY - timedelta(days=rng.randint(10, 25))
        cl.append(make_claim(cust, pol, "Day Care", "PENDING", f, rng.uniform(40000, 120000)))
    open_claim = next((c for c in cl if c["status"] in ("PENDING", "REJECTED")), None)

    # payments — one per policy-year, most recent three years
    for p in pols:
        for yr in range(min(3, cust["tenure"])):
            pd = date(p["start"].year - yr, p["start"].month, p["start"].day) - timedelta(days=rng.randint(0, 6))
            payments.append(row([nid("PAY"), cid, p["id"], round(p["premium"] / (1.08 ** yr), -2),
                                 pd.isoformat(), rng.choice(["UPI", "Net Banking", "Credit Card", "Auto Debit"])
                                 if seg != "Corporate Group" else "Corporate Deduction",
                                 "COMPLETED", ts(at(pd, 12))]))
    if scenario == "payment_trouble":
        for k, st in enumerate(["FAILED", "FAILED", "PENDING"][: rng.choice([2, 3])]):
            pd = TODAY - timedelta(days=20 - k * 6)
            payments.append(row([nid("PAY"), cid, pol["id"], round(new_prem / 4, -2), pd.isoformat(),
                                 "Auto Debit", st, ts(at(pd, 6))]))
    elif scenario in ("affordability", "premium_shock") and rng.random() < 0.3:
        pd = TODAY - timedelta(days=rng.randint(3, 15))
        payments.append(row([nid("PAY"), cid, pol["id"], new_prem, pd.isoformat(), "UPI", "PENDING", ts(at(pd, 19))]))

    # policy versions — year-on-year usage history back to acquisition
    first_yr = max(since.year, 2015)
    n_years = max(1, pol["start"].year - first_yr + 1)
    base_prem = prem / (1.08 ** (n_years - 1))
    cov, ncb = cover, 0.0
    if scenario == "affordability":
        cov = cover / 0.75
    for v in range(n_years):
        eff = date(first_yr + v, pol["start"].month, pol["start"].day)
        is_new, is_last = v == 0, v == n_years - 1
        ctype = "NEW" if is_new else "RENEWAL"
        if not is_new and v == 2 and (scenario in GROWTH or scenario == "steady") and rng.random() < 0.4:
            ctype, cov = "UPGRADE", cov * 1.5
        if is_last and not is_new and scenario == "affordability":
            ctype, cov = "DOWNGRADE", cover
        if is_new:
            rstat, late = "NA", 0
        elif scenario == "payment_trouble" and v >= n_years - 2:
            rstat, late = ("LATE", rng.randint(16, 32)) if is_last else ("LATE", rng.randint(3, 9))
        elif scenario in ("claim_delay", "premium_shock") and is_last and rng.random() < 0.3:
            rstat, late = "LATE", rng.randint(2, 8)
        else:
            rstat, late = "ON_TIME", 0
        claimed = any(gs.d(c["filed"]).year == eff.year for c in cl)
        ncb = 0.0 if claimed else min(50.0, ncb + 10.0)
        riders = []
        if ctype == "UPGRADE":
            riders.append("Critical Illness Rider")
        if seg == "Senior Citizen":
            riders.append("Domiciliary Cover")
        versions.append(row([f"PV-{cid}-{pol['id']}-{v + 1}", pol["id"], cid, v + 1, eff.isoformat(),
                             (date(eff.year + 1, eff.month, eff.day) - timedelta(days=1)).isoformat(),
                             round(cov), round(base_prem * (1.08 ** v), -2), ctype, rstat, late, ncb,
                             ", ".join(riders) or None]))

    # tickets + email threads (templates from generate_sources.py)
    plan = []  # (kind, days_ago, priority, breached, reopens, csat)
    for k in range(rng.randint(1, 3)):
        plan.append((["policy_doc", "add_member", "policy_doc"][k], rng.randint(120, 1400), "LOW", False, 0,
                     rng.choice([4, 5, 5])))
    if scenario == "claim_delay":
        plan += [("claim_status", rng.randint(25, 30), "HIGH", True, 1, None),
                 ("claim_deficiency", rng.randint(8, 15), "HIGH", True, rng.randint(1, 2), None)]
    elif scenario == "claim_rejected":
        plan += [("claim_status", rng.randint(10, 20), "HIGH", False, 1, rng.choice([1, 2]))]
    elif scenario == "cashless_escalation":
        plan += [("preauth", rng.randint(2, 6), "URGENT", True, 2, None),
                 ("claim_deficiency", rng.randint(1, 3), "HIGH", True, 1, None),
                 ("portability_query", 1, "URGENT", False, 0, None)]
    elif scenario == "mis_selling":
        plan += [("claim_status", rng.randint(15, 30), "HIGH", True, 1, None),
                 ("refund", rng.randint(5, 12), "HIGH", True, 1, None)]
    elif scenario == "premium_shock":
        plan += [("premium_hike", rng.randint(6, 20), "HIGH", rng.random() < 0.6, 0, None)]
        if rng.random() < 0.4:
            plan.append(("portability_query", rng.randint(2, 6), "HIGH", False, 0, None))
    elif scenario == "affordability":
        plan += [("premium_hike", rng.randint(10, 25), "MEDIUM", False, 0, 3)]
    elif scenario == "network_delisted":
        plan += [("network_hospital", rng.randint(10, 40), "MEDIUM", False, rng.choice([0, 1]), rng.choice([1, 2, 3]))]
    elif scenario == "payment_trouble":
        plan += [("nach", rng.randint(8, 18), "HIGH", rng.random() < 0.5, rng.choice([0, 1]), None)]
    elif scenario == "service_failure":
        for k in range(3):
            plan.append((["add_member", "policy_doc", "claim_status"][k], rng.randint(10, 80), "MEDIUM",
                         k < 2, rng.randint(1, 3), rng.choice([1, 2])))
    elif scenario == "group_renewal_risk":
        plan += [("premium_hike", rng.randint(5, 15), "HIGH", False, 0, None)]
    elif scenario == "interest_maternity":
        plan += [("add_member", rng.randint(60, 200), "LOW", False, 0, 5)]
    elif scenario == "renewal_due":
        plan += [("policy_doc", rng.randint(3, 20), "LOW", False, 0, 5)]
    for k, (kind, ago, prio, breached, reopens, csat) in enumerate(plan):
        subj, cat, sla = gs.TICKET_LIB[kind]
        od = TODAY - timedelta(days=ago)
        tid = f"TKT-{cid}-{od.strftime('%Y%m%d')}-{k}"
        opened = datetime.combine(od, datetime.min.time()) + timedelta(hours=9 + k)
        channel = "EMAIL" if kind in ("premium_hike", "claim_deficiency", "portability_query", "policy_doc",
                                      "nach", "network_hospital", "preauth") else "PHONE"
        first_resp = opened + timedelta(hours=rng.randint(30, 70) if breached else rng.randint(2, 20))
        if breached:
            resolved, status = None, "OPEN"
        else:
            resolved, status = opened + timedelta(hours=rng.randint(6, sla - 2)), "RESOLVED"
            csat = csat or rng.choice([3, 4, 5])
        tickets.append(row([tid, cid, email, phone, "insurance", channel, cat, prio, subj, pol["id"],
                            open_claim["id"] if (open_claim and cat == "Claims") else None,
                            ts(opened), ts(first_resp), ts(resolved) if resolved else None,
                            sla, breached, reopens, status, csat if not breached else None,
                            rng.choice(AGENTS)]))
        if channel == "EMAIL":
            gs.email_thread({"CUSTOMER_ID": cid, "FULL_NAME": f"{first} {last}", "EMAIL": email},
                            kind, tid, subj, opened, pol, open_claim, breached, 0)

    # grievances — IRDAI IGMS, only where the story warrants it
    if scenario in ("cashless_escalation", "mis_selling") or (scenario == "claim_rejected" and rng.random() < 0.5):
        fd = TODAY - timedelta(days=rng.randint(1, 10))
        cat, txt = {
            "cashless_escalation": ("Cashless authorisation delay",
                                    "Policyholder reports cashless pre-authorisation pending while the insured is admitted; "
                                    "hospital demanding upfront payment."),
            "mis_selling": ("Mis-selling",
                            "Policyholder alleges the intermediary misrepresented coverage at sale; claim later "
                            "rejected under the terms that were misrepresented."),
            "claim_rejected": ("Claim repudiation",
                               "Policyholder disputes repudiation of claim on pre-existing disease / waiting period "
                               "grounds and requests review."),
        }[scenario]
        grievances.append(row([f"GRV-{cid}-{fd.strftime('%Y%m%d')}", cid, email, pol["id"],
                               f"IGMS-{rng.randint(100000, 999999)}", fd.isoformat(), cat, txt,
                               "UNDER_REVIEW", None, scenario == "mis_selling" and rng.random() < 0.6]))

    # portability — the observable competitive act
    port_stage = None
    if scenario == "cashless_escalation" and rng.random() < 0.6:
        port_stage = "FORM_REQUESTED"
    elif scenario == "premium_shock":
        port_stage = rng.choices(["ENQUIRY", "FORM_REQUESTED", None], weights=[55, 15, 30])[0]
    elif scenario in ("claim_rejected", "affordability", "group_renewal_risk") and rng.random() < 0.35:
        port_stage = "ENQUIRY"
    rival = rng.choice(RIVALS)
    quote = round(new_prem * rng.uniform(0.7, 0.85), -2)
    if port_stage:
        rd = TODAY - timedelta(days=rng.randint(2, 20))
        ports.append(row([f"PORT-{cid}-{rd.strftime('%Y%m%d')}", cid, email, pol["id"], rd.isoformat(), rival,
                          new_prem, quote, port_stage, "ACTIVE",
                          f"Customer requested portability documentation. Quoted premium is "
                          f"{round((1 - quote / new_prem) * 100)}% below current renewal."]))

    # employer — corporate customers run an HR group
    emp = None
    if seg == "Corporate Group":
        emp = {"name": f"{rng.choice(['Apex', 'Vertex', 'Sahyadri', 'Kaveri', 'Indus', 'Ganga', 'Orion', 'Zenith', 'Lotus', 'Nilgiri'])} "
                       f"{rng.choice(['Technologies', 'Pharma', 'Textiles', 'Logistics', 'Engineering', 'Foods', 'Retail', 'Finserv'])} "
                       f"{rng.choice(['Pvt Ltd', 'Ltd', 'India Pvt Ltd'])}",
               "headcount": rng.randint(40, 450)}
        eid = f"EMP-{len(employers) + 4:03d}"
        employers.append(row([eid, emp["name"], emp["name"].split()[1], city, pol["id"], emp["headcount"],
                              f"{first} {last}", email, phone,
                              round(prem * emp["headcount"] * 0.9, -3), since.isoformat(),
                              (TODAY + timedelta(days=(renew - TODAY).days)).isoformat(),
                              rng.choice(["Anand Broking Services", "Keystone Insurance Brokers",
                                          "Prudent Insurance Brokers", "Marsh India"])]))
        members.append(row([eid, cid, "HR_ADMIN", since.isoformat()]))
        cust["emp_id"] = eid

    # interactions + call transcripts
    subj_type, subject, (s_lo, s_hi) = INTERACTION_SUBJECT[scenario]
    n_calls = 0
    if rng.random() < p_call:
        n_calls = 2 if scenario in ("cashless_escalation", "claim_delay", "premium_shock") and rng.random() < 0.3 else 1
    for k in range(n_calls):
        hing = rng.random() < HINGLISH_SHARE
        opts = T[scenario]
        hi = [t for t in opts if "Customer: " in t and any(w in t for w in (" hai", " hoon", " kijiye"))]
        en = [t for t in opts if t not in hi] or opts
        tpl = rng.choice(hi if (hing and hi) else en)
        call_d = TODAY - timedelta(days=rng.randint(1, 30) + k * 9)
        ctx = dict(first=first, last=last, hon=cust["hon"], pid=pol["id"], prem=money(prem),
                   new_prem=money(new_prem), hike=hike, cover=f"INR {lakh(cover)}", quote=money(quote),
                   rival=rival, tenure=cust["tenure"], days=(renew - TODAY).days, hosp=hosp, city=city,
                   email=email, cid=open_claim["id"] if open_claim else "—",
                   amt=money(open_claim["amount"]) if open_claim else "—",
                   age=(TODAY - gs.d(open_claim["filed"])).days if open_claim else 0,
                   employer=emp["name"] if emp else "our company",
                   headcount=emp["headcount"] if emp else 100)
        text = tpl.format(**ctx)
        iid, tid = nid("INT"), nid("TRN")
        dt = at(call_d, rng.randint(9, 18))
        dur = rng.randint(180, 900)
        agent = rng.choice(AGENTS)
        sent = round(rng.uniform(s_lo, s_hi), 2)
        interactions.append(row([iid, cid, "Phone", subj_type, subject, sent, dur, agent, ts(dt),
                                 f"{subject}. Call transcript {tid}.", ts(dt)]))
        transcripts.append(row([tid, iid, cid, text, ts(dt), dur, agent, ts(dt)]))
    # a non-call touchpoint or two, same tone as the story
    for k in range(rng.randint(0, 2)):
        dd = TODAY - timedelta(days=rng.randint(5, 300) if scenario in ("steady",) or scenario in GROWTH
                               else rng.randint(5, 85))
        dt = at(dd, rng.randint(9, 20))
        ch = rng.choice(["Chat", "Email"])
        interactions.append(row([nid("INT"), cid, ch, subj_type, subject,
                                 round(rng.uniform(s_lo, s_hi), 2), None, rng.choice(AGENTS), ts(dt),
                                 f"{ch} contact: {subject.lower()}.", ts(dt)]))
    return cust


def main():
    order = [s for s, (n, _, _) in SCENARIOS.items() for _ in range(n)]
    R.shuffle(order)
    book = [build(i, s) for i, s in enumerate(order)]

    # covered employees: a few customers in each new employer's city, so a group
    # decision has visible blast radius
    emp_rows = [(c["emp_id"], c["city"]) for c in book if c.get("emp_id")]
    pool = [c for c in book if c["seg"] in ("Individual", "Family Floater")]
    for eid, city in emp_rows:
        local = [c for c in pool if c["city"] == city][:R.randint(2, 5)]
        for c in local:
            members.append(row([eid, c["id"], "EMPLOYEE", c["since"].isoformat()]))
            pool.remove(c)

    def emit(table, cols, rows, chunk=100):
        if not rows:
            return
        print(f"\n-- {table}: {len(rows)} rows")
        for k in range(0, len(rows), chunk):
            print(f"INSERT INTO {table} ({cols}) VALUES")
            print(",\n".join(rows[k:k + chunk]) + ";")

    print("-- Generated by scripts/generate_scale.py — deterministic, seed", SEED)
    print(f"-- {N_CUSTOMERS} insurance customers (INS-2001..INS-{2000 + N_CUSTOMERS}), scenario-driven.")
    print("-- Idempotent: removes only rows belonging to the generated customers first.")
    print("USE DATABASE CUSTOMER_360_DB;")
    new = "customer_id LIKE 'INS-2%'"
    for t in ["RAW.INSURANCE_CALL_TRANSCRIPTS", "RAW.INSURANCE_INTERACTIONS", "RAW.INSURANCE_PAYMENTS",
              "RAW.INSURANCE_CLAIMS", "RAW.INSURANCE_POLICIES", "RAW.POLICY_VERSION", "RAW.EMAIL_MESSAGE",
              "RAW.SUPPORT_TICKET", "RAW.GRIEVANCE", "RAW.PORTABILITY_REQUEST", "RAW.EMPLOYER_MEMBER",
              "CONFIG.CUSTOMER_ASSIGNMENT", "RAW.INSURANCE_CUSTOMERS"]:
        print(f"DELETE FROM {t} WHERE {new};")
    print("DELETE FROM RAW.EMPLOYER WHERE employer_id >= 'EMP-004';")

    emit("RAW.INSURANCE_CUSTOMERS", "customer_id, first_name, last_name, email, phone, date_of_birth, "
         "customer_since, segment, lifetime_value, address_state, created_at, updated_at", customers)
    emit("RAW.INSURANCE_POLICIES", "policy_id, customer_id, policy_type, policy_status, premium_amount, "
         "coverage_amount, start_date, end_date, renewal_date, created_at, updated_at", policies)
    emit("RAW.INSURANCE_CLAIMS", "claim_id, policy_id, customer_id, claim_type, claim_status, claim_amount, "
         "filed_date, resolved_date, description, created_at, updated_at", claims)
    emit("RAW.INSURANCE_PAYMENTS", "payment_id, customer_id, policy_id, payment_amount, payment_date, "
         "payment_method, payment_status, created_at", payments)
    emit("RAW.INSURANCE_INTERACTIONS", "interaction_id, customer_id, channel, interaction_type, subject, "
         "sentiment_score, duration_seconds, agent_id, interaction_date, notes, created_at", interactions)
    emit("RAW.INSURANCE_CALL_TRANSCRIPTS", "transcript_id, interaction_id, customer_id, transcript_text, "
         "call_date, duration_seconds, agent_id, created_at", transcripts, chunk=50)
    emit("RAW.POLICY_VERSION", "version_id, policy_id, customer_id, version_no, effective_from, effective_to, "
         "sum_insured, premium, change_type, renewal_status, days_late, no_claim_bonus_pct, riders", versions)
    emit("RAW.SUPPORT_TICKET", "ticket_id, customer_id, customer_email, customer_phone, domain, channel, "
         "category, priority, subject, linked_policy_id, linked_claim_id, opened_at, first_response_at, "
         "resolved_at, sla_target_hours, sla_breached, reopen_count, status, csat_score, agent_id", tickets)
    emit("RAW.EMAIL_MESSAGE", "message_id, ticket_id, customer_id, customer_email, direction, from_address, "
         "to_address, subject, body, thread_position, sent_at", gs.emails, chunk=40)
    emit("RAW.GRIEVANCE", "grievance_id, customer_id, customer_email, policy_id, igms_token, filed_date, "
         "category, description, status, resolution_date, escalated_to_ombudsman", grievances)
    emit("RAW.PORTABILITY_REQUEST", "request_id, customer_id, customer_email, policy_id, requested_date, "
         "target_insurer, current_premium, quoted_premium, stage, status, notes", ports)
    emit("RAW.EMPLOYER", "employer_id, employer_name, industry, city, group_policy_id, employee_count, "
         "hr_contact_name, hr_contact_email, hr_contact_phone, annual_premium, relationship_since, "
         "renewal_date, broker_name", employers)
    emit("RAW.EMPLOYER_MEMBER", "employer_id, customer_id, member_role, joined_date", members)
    emit("CONFIG.CUSTOMER_ASSIGNMENT", "customer_id, assigned_user, assigned_team, domain", assignments)

    import sys
    print(f"\nSELECT 'Scaled book loaded' AS status;", file=sys.stdout)
    summary = {"customers": len(customers), "policies": len(policies), "claims": len(claims),
               "payments": len(payments), "interactions": len(interactions),
               "transcripts": len(transcripts), "policy_versions": len(versions),
               "tickets": len(tickets), "emails": len(gs.emails), "grievances": len(grievances),
               "portability": len(ports), "employers": len(employers), "members": len(members)}
    print("-- " + ", ".join(f"{k}={v}" for k, v in summary.items()))
    print(summary, file=sys.stderr)


if __name__ == "__main__":
    main()
