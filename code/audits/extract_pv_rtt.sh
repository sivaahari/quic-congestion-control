#!/usr/bin/env bash
# THE POTENTIAL BLOCK-D SHORTCUT.
#
# The project's thesis is that PATH_CHALLENGE -> PATH_RESPONSE yields a CLEAN,
# new-path-only RTT measurement -- uncontaminated by in-flight old-path packets,
# because the challenge is sent on the new path and answered on the new path.
#
# If, in the SAME trace where the congestion controller's smoothed_rtt is
# poisoned to ~20 ms by old-path ACKs, the path-validation exchange measured the
# new path's true ~60 ms, then the clean measurement demonstrably EXISTED and the
# stack discarded it. That is the entire thesis in one slide -- and it needs no
# ORACLE arm, no new code, and no new experiment.
set -uo pipefail

python3 - <<'PYEOF'
import json, glob, os

def analyse(qlog, tag, true_rtt_ms):
    if not qlog or not os.path.exists(qlog):
        print(f"  [{tag}] MISSING"); return
    d = json.load(open(qlog))
    tr = d["traces"][0]
    f = tr["event_fields"]
    ti, ci, ei, di = (f.index(x) for x in ("relative_time","category","event","data"))

    sent_ch, recv_resp, metrics = [], [], []
    for ev in tr["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict): continue
        if name == "packet_sent":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_challenge":
                    sent_ch.append(t)
        elif name == "packet_received":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    recv_resp.append(t)
        elif name == "metrics_updated" and "cwnd" in data:
            metrics.append((t, data.get("cwnd"), data.get("smoothed_rtt")))

    print(f"\n  ===== {tag} =====")
    print(f"  new path TRUE RTT (configured): {true_rtt_ms} ms")
    if not sent_ch or not recv_resp:
        print(f"  no complete challenge/response pair (sent={len(sent_ch)} resp={len(recv_resp)})")
        return

    # Pair each response with the most recent preceding challenge.
    pairs = []
    for r in recv_resp:
        prior = [s for s in sent_ch if s <= r]
        if prior:
            pairs.append((max(prior), r, r - max(prior)))
    if not pairs:
        print("  no pairable challenge/response"); return

    print(f"  PATH_CHALLENGE -> PATH_RESPONSE measurements ({len(pairs)}):")
    for s, r, dt in pairs[:5]:
        print(f"     sent t={s:<10} resp t={r:<10}  delta = {dt:>8} us  = {dt/1000:6.1f} ms")
    best = min(p[2] for p in pairs)
    print(f"  --> CLEAN new-path RTT from path validation: {best} us = {best/1000:.1f} ms")

    # What did the congestion controller believe instead?
    t_mig = max(r for _, r, _ in pairs)
    after = [m for m in metrics if t_mig < m[0] <= t_mig + 200_000 and m[2]]
    if after:
        poisoned = after[0][2]
        print(f"  --> what the CC's smoothed_rtt actually held: {poisoned} us = {poisoned/1000:.1f} ms")
        err = abs(poisoned - best) / best * 100
        print(f"  --> discrepancy: {err:.0f}%  ({'CC UNDERESTIMATES -> paces too fast' if poisoned < best else 'CC overestimates -> paces too slow'})")
        print(f"  --> path validation was {abs(best-true_rtt_ms*1000)/1000:.1f} ms from the true value; "
              f"the CC estimate was {abs(poisoned-true_rtt_ms*1000)/1000:.1f} ms off.")

base = "/home/sivaa/pvseed/results/raw/baseline"
def pick(p):
    g = glob.glob(p)
    return max(g, key=os.path.getsize) if g else None

print("=" * 66)
print("BLOCK D EVIDENCE: was a clean new-path RTT available and ignored?")
print("=" * 66)

print("\n### STEP-DOWN (new path B = 20 Mbit / 60 ms) ###")
analyse(pick(f"{base}/step_down/specreset/rep1/final/qlog_server/*.qlog"),
        "STEP-DOWN / SPEC_RESET", 60)
analyse(pick(f"{base}/step_down/naive/rep1/final/qlog_server/*.qlog"),
        "STEP-DOWN / NAIVE", 60)

print("\n\n### STEP-UP (new path B = 100 Mbit / 20 ms) ###")
analyse(pick(f"{base}/step_up/naive/rep1/final/qlog_server/*.qlog"),
        "STEP-UP / NAIVE", 20)
PYEOF

echo
echo "=============== v2 data state ==============="
ls -la /home/sivaa/pvseed/results/processed/ 2>/dev/null
echo
echo "--- v2 raw dirs ---"
ls -d /home/sivaa/pvseed/results/raw/baseline_v2/*/*/ 2>/dev/null | head -12 || echo "  (no baseline_v2 tree)"
echo
echo "DONE"
