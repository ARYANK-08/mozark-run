#!/usr/bin/env python3
"""Render the GitHub job summary for an App Studio CI run from results/run.json and results/junit.xml."""
import json
import os
import sys
import xml.etree.ElementTree as ET

RESULT_BADGE = {"PASSED": "✅", "FAILED": "❌", "ERRORED": "⚠️"}
CASE_LABEL = {"pass": "✅ Pass", "failure": "❌ Fail", "error": "⚠️ Not run", "skipped": "⏭️ Skipped"}
REASON_LIMIT = 140
EXIT_CODES = "0 passed · 1 tests failed · 2 errored (auth, config, device or lab) · 3 timed out"


def cell(text):
    text = " ".join((text or "").split()).replace("|", "\\|")
    return text if len(text) <= REASON_LIMIT else text[: REASON_LIMIT - 1] + "…"


def cases(junit_path):
    try:
        root = ET.parse(junit_path).getroot()
    except (OSError, ET.ParseError):
        return []
    rows = []
    for case in root.iter("testcase"):
        outcome = next((child for child in case if child.tag in ("failure", "error", "skipped")), None)
        kind = outcome.tag if outcome is not None else "pass"
        reason = outcome.get("message", "") if outcome is not None else ""
        rows.append((CASE_LABEL[kind], case.get("name", ""), case.get("classname", ""), reason))
    return rows


def duration(seconds):
    minutes, rest = divmod(int(seconds), 60)
    return f"{minutes}m {rest:02d}s" if minutes else f"{rest}s"


def main(results_dir):
    run = json.load(open(os.path.join(results_dir, "run.json")))
    rows = cases(os.path.join(results_dir, "junit.xml"))
    env = os.environ
    result = run.get("result") or "ERRORED"
    failed = sum(1 for row in rows if not row[0].startswith("✅"))
    devices = len({row[2] for row in rows})
    app_url = env.get("MOZARK_APP_URL", "").rstrip("/")
    commit = env.get("COMMIT_SHA", "")[:7]
    branch = env.get("BRANCH", "")
    query = env.get("MOZARK_REPORT_QUERY", "")
    report_links = [(job["platform"], f"{app_url}{job['reportPath']}" + (f"?{query}" if query else "")) for job in run.get("jobs", [])]
    reports = " · ".join(f"[{platform} report]({link})" for platform, link in report_links)

    links = [f"**[Open the full report in App Studio →]({link})**" for _, link in report_links]
    out = [
        f"## {RESULT_BADGE.get(result, '⚠️')} App Studio suite · {result}",
        f"> {len(rows) - failed} of {len(rows)} tests passed on {devices} device(s) · {duration(env.get('MOZARK_ELAPSED', 0))}",
        "",
        *links,
        "",
        "| | |",
        "|---|---|",
        f"| **Report** | {reports or '—'} |",
        f"| **Suite** | `{env.get('MOZARK_SUITE_ID', '')}` |",
        f"| **Run** | `{run.get('id', '')}` |",
        f"| **Commit** | `{commit or '—'}`{f' on `{branch}`' if branch else ''} |",
        f"| **App version** | {env.get('MOZARK_APP_VERSION') or '—'} |",
        f"| **Build** | {env.get('MOZARK_BUILD_LABEL', 'the suite’s own build')} |",
        "",
    ]
    if rows:
        out += ["### Tests", "", "| Result | Test | Device | Reason |", "|---|---|---|---|"]
        out += [f"| {label} | {cell(name)} | `{device}` | {cell(reason)} |" for label, name, device, reason in rows]
        out.append("")
    for refused in run.get("refused", []):
        out.append(f"> ⚠️ **Not started:** {cell(refused.get('suiteName'))}: {cell(refused.get('error'))}")
    out += ["", f"<sub>Exit codes: {EXIT_CODES}</sub>", ""]
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])
