#!/usr/bin/env python3
"""
PreToolUse hook: no agent writes to production directly.

Any SQL that writes (INSERT / UPDATE / DELETE / MERGE / TRUNCATE / CREATE /
ALTER / DROP / GRANT / REVOKE) must target the run sandbox, the STUDIO schema.
Production configuration changes only through CALL STUDIO.RELEASE_RUN, which
itself refuses unless the current draft was simulated and approved.

Reads the hook JSON on stdin; exit 0 = allow, exit 2 = block (reason on stderr
and in the JSON decision). Applies to the SQL tool and to shell commands that
run SQL (snow sql / cortex). Reads and CALLs are never blocked.
"""
import json
import re
import sys

WRITE = re.compile(
    r"""\b(?:
        insert\s+(?:overwrite\s+)?into\s+(?P<ins>[\w$."]+)
      | update\s+(?P<upd>[\w$."]+)\s+set\b
      | delete\s+from\s+(?P<del>[\w$."]+)
      | merge\s+into\s+(?P<mrg>[\w$."]+)
      | truncate\s+(?:table\s+)?(?:if\s+exists\s+)?(?P<trn>[\w$."]+)
      | create\s+(?:or\s+replace\s+)?(?P<tmp>(?:local\s+|global\s+)?(?:temporary|temp|volatile)\s+)?
            (?:secure\s+|transient\s+|recursive\s+|materialized\s+|dynamic\s+|external\s+|hybrid\s+|iceberg\s+)*
            (?P<ckind>table|view|function|procedure|schema|database|task|stage|stream|pipe|sequence|
                      alert|tag|role|user|warehouse|streamlit|service|cortex\s+search\s+service|semantic\s+view|agent)
            \s+(?:if\s+not\s+exists\s+)?(?P<cre>[\w$."]+)
      | alter\s+(?P<akind>[a-z ]+?)\s+(?:if\s+exists\s+)?(?P<alt>[\w$."]+)\s
      | drop\s+(?P<dkind>[a-z ]+?)\s+(?:if\s+exists\s+)?(?P<drp>[\w$."]+)
      | (?P<grant>grant|revoke)\s
    )""",
    re.I | re.X,
)
ALLOWED_SCHEMA = re.compile(r'^(?:"?customer_360_db"?\.)?"?studio"?\.', re.I)


def strip_sql(sql):
    """Remove comments and string literals so text inside them can't trigger."""
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)
    return sql


def violations(sql):
    out = []
    for m in WRITE.finditer(strip_sql(sql)):
        if m.group("grant"):
            out.append(f"{m.group('grant').upper()} is not allowed from an agent session")
            continue
        if m.group("tmp"):
            continue  # temporary objects die with the session
        target = next(m.group(g) for g in ("ins", "upd", "del", "mrg", "trn", "cre", "alt", "drp") if m.group(g))
        kind = (m.group("ckind") or m.group("akind") or m.group("dkind") or "").strip().lower()
        if kind in ("session",):
            continue
        if not ALLOWED_SCHEMA.match(target):
            out.append(f"write to {target} (only CUSTOMER_360_DB.STUDIO.* is writable; "
                       f"production changes go through CALL CUSTOMER_360_DB.STUDIO.RELEASE_RUN)")
    return out


def sql_from_input(tool_name, tool_input):
    if not isinstance(tool_input, dict):
        return ""
    if tool_name.lower() == "bash":
        cmd = str(tool_input.get("command", ""))
        return cmd if re.search(r"\b(snow\s+sql|cortex|snowsql)\b", cmd) else ""
    return "\n".join(str(v) for v in tool_input.values() if isinstance(v, str))


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    found = violations(sql_from_input(event.get("tool_name", ""), event.get("tool_input", {})))
    if not found:
        sys.exit(0)
    reason = "Blocked by guard_prod: " + "; ".join(dict.fromkeys(found))
    print(json.dumps({"decision": "block", "reason": reason}))
    print(reason, file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
