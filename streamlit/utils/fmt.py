"""Formatting helpers. Indian number conventions throughout — the book is in rupees.

Every helper treats NaN like None. Snowflake nullable columns arrive as NaN via
pandas, and NaN is truthy in Python, so `if value:` is never a safe null guard.
"""
import math


def missing(v) -> bool:
    """True for None or NaN. The only null check these helpers trust."""
    if v is None:
        return True
    try:
        return math.isnan(float(v))
    except (TypeError, ValueError):
        return False

SEV_LABEL = {1: "LOW", 2: "MEDIUM", 3: "HIGH", 4: "CRITICAL"}
# Semantic status colours, validated for contrast in both Streamlit themes.
SEV_COLOR = {1: "#2E7D52", 2: "#C98A00", 3: "#B3251E", 4: "#6B3FA0"}


def inr(n) -> str:
    """Rupees with Indian digit grouping."""
    if missing(n):
        return "—"
    n = float(n)
    neg = n < 0
    s = f"{abs(n):.0f}"
    if len(s) > 3:
        head, tail = s[:-3], s[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        s = ",".join(parts) + "," + tail
    return ("-" if neg else "") + "₹" + s


def lakh(n) -> str:
    """Compact rupees: crore above 1e7, lakh above 1e5."""
    if missing(n):
        return "—"
    n = float(n)
    if abs(n) >= 1e7:
        return f"₹{n / 1e7:.2f} Cr"
    if abs(n) >= 1e5:
        return f"₹{n / 1e5:.2f} L"
    return inr(n)


def pct(x, places: int = 1) -> str:
    return "—" if missing(x) else f"{float(x) * 100:.{places}f}%"


def opt_int(v, prefix: str = "", suffix: str = "") -> str:
    """Render an integer that may be absent, without tripping over NaN."""
    return "" if missing(v) else f"{prefix}{int(v)}{suffix}"


def opt_str(v, default: str = "—") -> str:
    return default if missing(v) or v == "" else str(v)


def state_badge(state_name, severity) -> str:
    """
    Coloured pill. Always carries the text label, so colour is never the only cue.

    Severity must be passed in from the row that already has it (ENGINE.CUSTOMER_STATE
    computes it authoritatively) rather than re-derived here by string-matching the
    state name — a name that doesn't contain "HIGH"/"CRITICAL"/etc would have silently
    fallen back to the wrong colour.
    """
    if missing(state_name) or not state_name:
        return (
            "<span style='font:600 11px ui-monospace,monospace;padding:3px 8px;"
            "border-radius:4px;border:1px solid #888;color:#888'>NO STATE</span>"
        )
    sev = int(severity) if not missing(severity) else 1
    c = SEV_COLOR.get(sev, SEV_COLOR[1])
    return (
        f"<span style='font:600 11px ui-monospace,monospace;padding:3px 8px;"
        f"border-radius:4px;border:1px solid {c};color:{c};background:{c}14'>{state_name}</span>"
    )


def chip(text: str, color: str = "#5C6B70") -> str:
    return (
        f"<span style='font:600 11px ui-monospace,monospace;padding:3px 8px;"
        f"border-radius:4px;border:1px solid {color};color:{color};background:{color}14'>{text}</span>"
    )


def policy_chip(status: str) -> str:
    colors = {
        "AUTONOMOUS": "#2E7D52",
        "AUTONOMOUS_REVIEW": "#C98A00",
        "REQUIRES_APPROVAL": "#C98A00",
        "BLOCK": "#B3251E",
        "PASS": "#2E7D52",
        "ALLOW": "#2E7D52",
        "REQUIRE_APPROVAL": "#C98A00",
        "SKIP": "#5C6B70",
    }
    return chip(status.replace("_", " "), colors.get(status, "#5C6B70"))
