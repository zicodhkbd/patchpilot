#!/usr/bin/env bash
# Builds the proof-of-concept report from everything the test scripts recorded,
# then zips the evidence folder so you can download it from CloudShell.
# shellcheck source=poc_lib.sh
PHASE=report source "$(dirname "$0")/poc_lib.sh"

python3 - "$EVID_DIR" <<'PY'
import csv, html, os, sys, datetime
d = sys.argv[1]
rows = list(csv.DictReader(open(os.path.join(d, "results.csv"))))
latest = {}
for r in rows:                      # keep the latest result of each test
    latest[(r["phase"], r["test_id"])] = r
items = sorted(latest.values(), key=lambda r: r["timestamp"])
phases = []
for r in items:
    if r["phase"] not in phases:
        phases.append(r["phase"])
names = {"preflight": "Preflight", "sprint1": "Sprint 1 - network, servers, Systems Manager",
         "sprint2": "Sprint 2 - backup and patch automation",
         "sprint3_rollback": "Sprint 3 - fault injection and automatic rollback",
         "sprint3": "Sprint 3 - dashboard, schedule and monitoring"}
passed = sum(r["result"] == "PASS" for r in items)
failed = len(items) - passed
files = sorted(f for f in os.listdir(d) if f.endswith(".txt"))
gen = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

parts = [f"""<!doctype html><html><head><meta charset="utf-8"><title>PatchPilot PoC Report</title>
<style>body{{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#1b2430}}h1{{color:#16324f;margin-bottom:4px}}
.sum{{display:flex;gap:16px;margin:16px 0 24px}}.tile{{border:1px solid #dde3ea;border-radius:8px;padding:12px 18px}}
.n{{font-size:28px;font-weight:700}}table{{border-collapse:collapse;width:100%;margin-bottom:24px;font-size:14px}}
th,td{{border:1px solid #dde3ea;padding:6px 8px;text-align:left;vertical-align:top}}th{{background:#16324f;color:#fff}}
.PASS{{color:#1f8a4c;font-weight:700}}.FAIL{{color:#c0392b;font-weight:700}}h2{{color:#1d4e79}}</style></head><body>
<h1>PatchPilot - Proof of Concept Test Report</h1>
<div>Md Alamgir | DEVP-600-T01 | Generated {gen}</div>
<div class="sum"><div class="tile"><div class="n">{len(items)}</div>tests</div>
<div class="tile"><div class="n PASS">{passed}</div>passed</div><div class="tile"><div class="n FAIL">{failed}</div>failed</div></div>"""]
md = [f"# PatchPilot - Proof of Concept Test Report\n\nGenerated {gen}\n\n**{len(items)} tests: {passed} passed, {failed} failed**\n"]
for ph in phases:
    title = names.get(ph, ph)
    parts.append(f"<h2>{html.escape(title)}</h2><table><tr><th>Test</th><th>Description</th><th>Result</th><th>Detail</th><th>Time (UTC)</th></tr>")
    md.append(f"\n## {title}\n\n| Test | Description | Result | Detail |\n|---|---|---|---|")
    for r in (x for x in items if x["phase"] == ph):
        parts.append("<tr>" + "".join(f"<td>{html.escape(v)}</td>" for v in (r["test_id"], r["description"])) +
                     f'<td class="{r["result"]}">{r["result"]}</td><td>{html.escape(r["detail"])}</td><td>{r["timestamp"]}</td></tr>')
        md.append(f'| {r["test_id"]} | {r["description"]} | {r["result"]} | {r["detail"]} |')
    parts.append("</table>")
parts.append("<h2>Evidence files</h2><ul>" + "".join(f"<li>{html.escape(f)}</li>" for f in files) + "</ul></body></html>")
md.append("\n## Evidence files\n\n" + "\n".join(f"- {f}" for f in files))
open(os.path.join(d, "poc-report.html"), "w").write("".join(parts))
open(os.path.join(d, "poc-report.md"), "w").write("\n".join(md) + "\n")
print(f"Report: {len(items)} tests, {passed} passed, {failed} failed")
PY

cd "$(dirname "$EVID_DIR")" || exit 1
zipname="patchpilot-poc-$(date -u +%Y%m%d-%H%M).zip"
if command -v zip >/dev/null; then zip -qr "$zipname" "$(basename "$EVID_DIR")"
else zipname="${zipname%.zip}.tar.gz"; tar -czf "$zipname" "$(basename "$EVID_DIR")"; fi
echo "Report:   $EVID_DIR/poc-report.html"
echo "Download: CloudShell > Actions > Download file > $(pwd)/$zipname"
