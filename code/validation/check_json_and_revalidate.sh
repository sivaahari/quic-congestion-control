#!/usr/bin/env bash
# Sanity-check survey_results.json after hand-editing, then re-run the
# independent validator. The JSON is the single source of truth: never leave it
# edited-but-unvalidated.
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

python3 - <<'PYEOF'
import json
d = json.load(open("analysis/survey_results.json"))
print(f"JSON OK - {len(d['implementations'])} implementations, "
      f"{len(d['cross_cutting_findings'])} findings")
for f in d["cross_cutting_findings"]:
    print(f"  {f['id']}  status: {f['status']}")
print()
print("per-implementation live rep counts:")
for i in d["implementations"]:
    lv = i.get("live") or {}
    print(f"  {i['name']:<10} q1={i['q1']['answer']:<10} q2={i['q2']['answer']:<6} "
          f"q3={i['q3']['answer']:<6} reps={lv.get('reps','-')}")
PYEOF

echo
echo "=== re-running the independent validator ==="
python3 _validation/revalidate_fresh.py 2>&1 | tail -12
