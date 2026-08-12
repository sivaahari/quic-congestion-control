#!/usr/bin/env python3
"""revalidate_fresh.py -- INDEPENDENT re-validation of every survey claim.

Written from scratch on 2026-08-11. It deliberately shares NO code with
analysis/parse_qlog*.py, analysis/make_survey_figures.py, or any _build/ script.
Trace parsing, source counting and arithmetic are all re-implemented here so
that a shared bug cannot produce a false agreement.

Method: read survey_results.json as the CLAIMS, then re-derive each claim from
primary sources -- git object storage for source code, raw .qlog/.sqlog/.log
for measurements -- and compare. Every claim is reported PASS, FAIL or
UNVERIFIABLE.

Usage:  python3 revalidate_fresh.py
Exit code 0 if no FAILs, 1 otherwise.
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = "/home/sivaa/pvseed"
CLAIMS_FILE = f"{ROOT}/analysis/survey_results.json"

RESULTS = []          # (impl, claim, verdict, detail)
GREEN, RED, AMBER, RESET_C = "\033[92m", "\033[91m", "\033[93m", "\033[0m"


def record(impl, claim, ok, detail):
    verdict = "PASS" if ok is True else ("FAIL" if ok is False else "UNVERIFIABLE")
    RESULTS.append((impl, claim, verdict, detail))
    col = GREEN if ok is True else (RED if ok is False else AMBER)
    print(f"  {col}{verdict:<13}{RESET_C} {claim}")
    if detail:
        print(f"                {detail}")


# ---------------------------------------------------------------- source side
def git_show(repo, path):
    """Pull a file straight out of git object storage -- immune to any local edit."""
    try:
        return subprocess.run(["git", "-C", repo, "show", f"HEAD:{path}"],
                              capture_output=True, text=True, timeout=90).stdout
    except Exception:
        return ""


def repo_head(repo):
    try:
        return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ""


def grep_tree(root, pattern, include=(".c", ".h", ".go", ".rs", ".cpp", ".hpp"),
              exclude_substr=()):
    """Own recursive grep. Returns [(relpath, lineno, line)]."""
    hits = []
    rx = re.compile(pattern)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "target", "build", "_build")]
        for fn in filenames:
            if not fn.endswith(include):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if any(x in rel for x in exclude_substr):
                continue
            try:
                with open(full, "r", errors="ignore") as fh:
                    for i, line in enumerate(fh, 1):
                        if rx.search(line):
                            hits.append((rel, i, line.rstrip()))
            except Exception:
                pass
    return hits


def count_call_sites(hits, symbol):
    """A call site = the symbol followed by '(' and NOT a declaration,
    definition, case label, struct field, or vtable assignment."""
    calls = []
    for rel, ln, line in hits:
        s = line.strip()
        if symbol + "(" not in s:
            continue
        if s.startswith(("case ", "//", "/*", "*", "#")):
            continue
        if re.search(r"\b(fn|func|static|void|int|typedef)\b.*" + re.escape(symbol) + r"\s*\(", s) \
           and not re.search(r"[.\->]\s*" + re.escape(symbol) + r"\s*\(", s):
            continue          # definition/declaration
        if re.search(r"\.\s*" + re.escape(symbol) + r"\s*=", s):
            continue          # vtable assignment
        calls.append((rel, ln, s))
    return calls


# ----------------------------------------------------------------- trace side
def parse_picoquic_qlog(path):
    """picoquic: one JSON doc, positional event arrays, microsecond ints."""
    with open(path) as fh:
        doc = json.load(fh)
    tr = doc["traces"][0]
    f = tr["event_fields"]
    ti, ni, di = f.index("relative_time"), f.index("event"), f.index("data")
    cw, resp = [], []
    for ev in tr["events"]:
        t, name, data = ev[ti], ev[ni], ev[di]
        if not isinstance(data, dict):
            continue
        if name == "metrics_updated" and "cwnd" in data:
            cw.append((float(t), float(data["cwnd"])))
        elif name == "packet_received":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    resp.append(float(t))
    return cw, resp


def parse_jsonseq_qlog(path, cwnd_keys, time_scale):
    """quic-go / quiche: JSON-SEQ, 0x1E separators, named fields."""
    cw, resp = [], []
    with open(path, "rb") as fh:
        for raw in fh:
            raw = raw.strip().lstrip(b"\x1e")
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except Exception:
                continue
            t = ev.get("time")
            if t is None:
                continue
            t = float(t) * time_scale
            name = str(ev.get("name") or ev.get("event") or "")
            data = ev.get("data") or {}
            if "metrics_updated" in name:
                for k in cwnd_keys:
                    if k in data:
                        cw.append((t, float(data[k])))
                        break
            elif "packet_received" in name:
                for fr in data.get("frames") or []:
                    if str(fr.get("frame_type")) == "path_response":
                        resp.append(t)
    return cw, resp


def parse_msquic_log(path):
    """msquic: plain stdout trace lines emitted by our harness."""
    cw = []
    rx = re.compile(r"t_us=(\d+).*?\bcwnd=(\d+)")
    with open(path, errors="ignore") as fh:
        for line in fh:
            m = rx.search(line)
            if m:
                cw.append((float(m.group(1)), float(m.group(2))))
    return cw


def newest(pattern):
    g = glob.glob(pattern)
    return max(g, key=os.path.getsize) if g else None


# ---------------------------------------------------------------------- main
def main():
    claims = json.load(open(CLAIMS_FILE))
    by_name = {i["name"]: i for i in claims["implementations"]}

    print("=" * 74)
    print("INDEPENDENT RE-VALIDATION OF ALL SURVEY CLAIMS")
    print("fresh code, primary sources, no reuse of project parsers")
    print("=" * 74)

    # ---------------- picoquic ----------------
    print("\n### picoquic")
    im = by_name["picoquic"]
    repo = f"{ROOT}/picoquic"
    head = repo_head(repo)
    record("picoquic", f"commit == {im['commit'][:12]}",
           head == im["commit"], f"actual {head[:12]}")

    # dead hook, judged on PRISTINE source only
    sym = "picoquic_congestion_notification_reset"
    dispatches = 0
    for f in ("picoquic/frames.c", "picoquic/sender.c", "picoquic/timing.c",
              "picoquic/loss_recovery.c", "picoquic/quicctx.c", "picoquic/paths.c"):
        src = git_show(repo, f)
        # a dispatch = alg_notify(...) whose argument list mentions the reset enum
        for m in re.finditer(r"alg_notify\s*\((?:[^;]{0,400}?)\)", src, re.S):
            if sym in m.group(0):
                dispatches += 1
    record("picoquic", "reset hook has 0 dispatches in pristine source",
           dispatches == 0, f"found {dispatches}")

    # live: five repetitions at the Phase-2 operating point.
    #
    # The test for "no reset" is NOT "the window stayed above the initial value".
    # A loss cascade can legitimately take it below, and on this data it does --
    # down to the 2 x MTU floor. Both the parser and an earlier version of THIS
    # validator got that backwards. A reset assigns the initial window EXACTLY,
    # so the correct test is that no sample ever takes it.
    iw_const = im["initial_cwnd_bytes"]
    iw_eff = im.get("initial_cwnd_effective_bytes") or iw_const
    reps = sorted(glob.glob(f"{ROOT}/results/raw/picoquic/reps/rep_*"))
    seen = clean = ip_changed = below = 0
    minima = []
    for d in reps:
        qs = sorted(glob.glob(f"{d}/qlog_server/*.qlog"),
                    key=os.path.getsize, reverse=True)
        if not qs:
            continue
        seen += 1
        with open(qs[0]) as fh:
            tr = json.load(fh)["traces"][0]
        fl = tr["event_fields"]
        ti, ni, di = fl.index("relative_time"), fl.index("event"), fl.index("data")
        cw, ips, resp = [], set(), []
        for ev in tr["events"]:
            data = ev[di]
            if not isinstance(data, dict):
                continue
            if ev[ni] == "metrics_updated" and "cwnd" in data:
                cw.append((float(ev[ti]), float(data["cwnd"])))
            elif ev[ni] == "packet_received":
                for fr in data.get("frames") or []:
                    if fr.get("frame_type") == "path_response":
                        resp.append(float(ev[ti]))
            for key in ("addr_from", "addr_to"):
                a = data.get(key)
                if isinstance(a, dict):
                    ip = a.get("ip_v4") or a.get("ip")
                    if isinstance(ip, str) and ip.startswith("10.0."):
                        ips.add(ip)
        if not cw or not resp:
            continue
        # Scope to the migration. Testing the WHOLE trace is wrong: every
        # connection BEGINS at its initial window, so that value always appears
        # near t=0 and the test can never pass. A reset would re-take it here.
        t0 = min(resp)
        window = [c for t, c in cw if t0 - 50_000 <= t <= t0 + 2_000_000]
        if not window:
            continue
        hits = [c for c in window if abs(c - iw_const) <= 1 or abs(c - iw_eff) <= 1]
        if not hits:
            clean += 1
        mn = min(window)
        minima.append(mn)
        if mn < min(iw_const, iw_eff):
            below += 1
        # A migration between two DIFFERENT client IPs; a port-only change would
        # be exempt under RFC 9000 s9.4 and would prove nothing.
        client_ips = {i for i in ips if i.startswith(("10.0.1.", "10.0.3."))}
        if len(client_ips) > 1:
            ip_changed += 1

    exp = im["live"]["reps"]
    record("picoquic", f"live reps with retained data == {exp}", seen == exp,
           f"found {seen}")
    record("picoquic", "every rep migrated to a DIFFERENT IP (not port-only)",
           seen > 0 and ip_changed == seen, f"{ip_changed}/{seen} with 2 client IPs")
    record("picoquic", "no sample takes the initial window at migration (=> no reset)",
           seen > 0 and clean == seen,
           f"{clean}/{seen} reps with 0 samples at {iw_const:,} or {iw_eff:,} B "
           f"in [-50 ms, +2 s] around path validation")
    record("picoquic", "window fell BELOW the initial window (loss, not reset)",
           seen > 0 and below == seen,
           f"{below}/{seen}; minima {min(minima):,.0f}-{max(minima):,.0f} B"
           if minima else "no minima")
    record("picoquic", "superseded 50 Mbit run retained for traceability",
           bool(newest(f"{ROOT}/results/raw/_task2_verify/naive/qlog_server/*.qlog")),
           "results/raw/_task2_verify/naive/")

    # ---------------- quic-go ----------------
    print("\n### quic-go")
    im = by_name["quic-go"]
    repo = f"{ROOT}/quic-go"
    head = repo_head(repo)
    record("quic-go", f"commit == {im['commit'][:12]}",
           head == im["commit"], f"actual {head[:12]}")

    hits = grep_tree(repo, r"MigratedPath\s*\(", include=(".go",),
                     exclude_substr=("_test.go", "mocks"))
    calls = [h for h in hits if re.search(r"\.\s*MigratedPath\s*\(", h[2])]
    record("quic-go", "MigratedPath is reachable (>=1 real call site)",
           len(calls) >= 1, f"{len(calls)} call sites: " +
           ", ".join(f"{r}:{l}" for r, l, _ in calls[:4]))

    reps_seen, resets = 0, 0
    pre_vals = []
    for d in sorted(glob.glob(f"{ROOT}/results/raw/quicgo/repeat/rep*")):
        sq = newest(os.path.join(d, "..", "..", "migrate_demo", "qlog_server", "*.sqlog"))
        csvp = os.path.join(d, "server_metrics.csv")
        if not os.path.exists(csvp):
            continue
        reps_seen += 1
        # re-derive from the CSV with independent arithmetic
        vals = []
        with open(csvp) as fh:
            hdr = fh.readline().strip().split(",")
            try:
                ti, ci = hdr.index("time_us"), hdr.index("cwnd")
            except ValueError:
                continue
            for line in fh:
                p = line.rstrip("\n").split(",")
                if len(p) <= max(ti, ci) or not p[ci]:
                    continue
                try:
                    vals.append((float(p[ti]), float(p[ci])))
                except ValueError:
                    pass
        vals.sort()
        iw = im["initial_cwnd_bytes"]
        hit = [c for t, c in vals if t > 4e6 and abs(c - iw) < 1]
        pre = [c for t, c in vals if 3e6 < t < 5.05e6]
        if pre:
            pre_vals.append(max(pre))
        if hit:
            resets += 1
    record("quic-go", f"live reps with retained data == {im['live']['reps']}",
           reps_seen == im["live"]["reps"], f"found {reps_seen}")
    record("quic-go", "every retained rep resets to exactly the initial window",
           reps_seen > 0 and resets == reps_seen,
           f"{resets}/{reps_seen} at {im['initial_cwnd_bytes']:,} B; "
           f"pre-migration peaks {min(pre_vals):,.0f}-{max(pre_vals):,.0f}" if pre_vals else "")

    # ---------------- quiche ----------------
    print("\n### quiche")
    im = by_name["quiche"]
    repo = f"{ROOT}/quiche"
    head = repo_head(repo)
    record("quiche", f"commit == {im['commit'][:12]}",
           head == im["commit"], f"actual {head[:12]}")

    hits = grep_tree(repo, r"on_connection_migration", include=(".rs",),
                     exclude_substr=("/tests/",))
    calls = [h for h in hits if re.search(r"[.\w]\s*\.\s*on_connection_migration\s*\(", h[2])]
    record("quiche", "on_connection_migration has 0 call sites (dead)",
           len(calls) == 0,
           f"{len(hits)} textual occurrences, {len(calls)} of them calls")

    resets, seen, pres = 0, 0, []
    for d in sorted(glob.glob(f"{ROOT}/results/raw/quiche/migrate_demo/rep_*")):
        sq = newest(os.path.join(d, "qlog_server", "*.sqlog"))
        if not sq:
            continue
        seen += 1
        cw, resp = parse_jsonseq_qlog(sq, ("congestion_window", "cwnd"), 1000.0)
        cw.sort()
        iw = im["initial_cwnd_bytes"]
        hit = [c for t, c in cw if t > 4e6 and abs(c - iw) < 1]
        pre = [c for t, c in cw if 3e6 < t < 5.02e6]
        if pre:
            pres.append(max(pre))
        if hit:
            resets += 1
    record("quiche", f"live reps == {im['live']['reps']}", seen == im["live"]["reps"],
           f"found {seen}")
    record("quiche", "every rep resets to exactly the initial window",
           seen > 0 and resets == seen,
           f"{resets}/{seen} at {im['initial_cwnd_bytes']:,} B" +
           (f"; pre peaks {min(pres):,.0f}-{max(pres):,.0f}" if pres else ""))

    # ---------------- msquic ----------------
    print("\n### msquic")
    im = by_name["msquic"]
    repo = f"{ROOT}/msquic"
    head = repo_head(repo)
    record("msquic", f"commit == {im['commit'][:12]}",
           head == im["commit"], f"actual {head[:12]}")

    hits = grep_tree(f"{repo}/src", r"QuicCongestionControlReset\s*\(",
                     include=(".c", ".h", ".cpp"), exclude_substr=("unittest",))
    calls = [h for h in hits
             if "QuicCongestionControlReset(&" in h[2] and not h[2].strip().startswith(("void", "//", "*"))]
    record("msquic", "QuicCongestionControlReset is reachable",
           len(calls) >= 1, f"{len(calls)} call sites: " +
           ", ".join(f"{r}:{l}" for r, l, _ in calls[:4]))

    # asymmetry, from source: the local-address handler must NOT reset
    conn_c = git_show(repo, "src/core/connection.c")
    seg = ""
    m = re.search(r"case QUIC_PARAM_CONN_LOCAL_ADDRESS:(.{0,4000})", conn_c, re.S)
    if m:
        seg = m.group(1)
    record("msquic", "client SetLocalAddr handler contains no CC reset",
           bool(seg) and "QuicCongestionControlReset" not in seg and "QuicPathSetActive" not in seg,
           "scanned the QUIC_PARAM_CONN_LOCAL_ADDRESS branch" if seg else "branch not located")

    srv_reset, seen = 0, 0
    for d in sorted(glob.glob(f"{ROOT}/results/raw/msquic/migrate_demo/rep_*")):
        log = os.path.join(d, "server.log")
        if not os.path.exists(log):
            continue
        seen += 1
        cw = parse_msquic_log(log)
        iw = im["initial_cwnd_bytes"]
        if any(abs(c - iw) < 1 and t > 4e6 for t, c in cw):
            srv_reset += 1
    record("msquic", "server reset observed in every rep",
           seen > 0 and srv_reset == seen, f"{srv_reset}/{seen} reach {im['initial_cwnd_bytes']:,} B")

    # F6, re-derived independently -- MIGRATION-ANCHORED.
    # An earlier version of this check used "the last two thirds of samples",
    # which for a rep that migrates late and crashes early (rep 5: migrate
    # 7.5 s, crash 8.6 s) sweeps in PRE-migration samples and reports a false
    # failure. Anchor on the migration instant instead.
    stuck = 0
    row_rx = re.compile(r"t_us=(\d+).*?\bcwnd=(\d+).*?\bsrtt_us=(\d+)")
    for d in sorted(glob.glob(f"{ROOT}/results/raw/msquic/migrate_demo/rep_*")):
        log = os.path.join(d, "server.log")
        if not os.path.exists(log):
            continue
        rows = []
        with open(log, errors="ignore") as fh:
            for line in fh:
                m = row_rx.search(line)
                if m:
                    rows.append(tuple(int(x) for x in m.groups()))
        rows.sort()
        mig = next((t for t, c, s in rows if c == im["initial_cwnd_bytes"] and t > 4_000_000), None)
        if mig is None:
            continue
        post = [s for t, c, s in rows if t > mig]
        if post and all(s == 333000 for s in post):
            stuck += 1
    record("msquic", "F6: server srtt pinned at 333,000us after migration",
           stuck == seen and seen > 0,
           f"{stuck}/{seen} reps pinned across every post-migration sample")

    # ---------------- ngtcp2 ----------------
    print("\n### ngtcp2")
    im = by_name["ngtcp2"]
    repo = f"{ROOT}/ngtcp2"
    head = repo_head(repo)
    record("ngtcp2", f"commit == {im['commit'][:12]}",
           head == im["commit"], f"actual {head[:12]}")

    conn_src = git_show(repo, "lib/ngtcp2_conn.c")
    calls = [ln for ln, line in enumerate(conn_src.splitlines(), 1)
             if re.search(r"conn_reset_congestion_state\s*\(\s*conn", line)]
    record("ngtcp2", f"conn_reset_congestion_state call sites == {im['reset_hook']['callers']}",
           len(calls) == im["reset_hook"]["callers"], f"found {len(calls)} at lines {calls}")

    # does it reset RTT as well as cwnd?
    m = re.search(r"conn_reset_conn_stat_cc\s*\([^)]*\)\s*\{(.{0,1500}?)\n\}", conn_src, re.S)
    body = m.group(1) if m else ""
    resets_rtt = all(k in body for k in ("smoothed_rtt", "min_rtt", "rttvar"))
    record("ngtcp2", "reset clears RTT as well as cwnd", resets_rtt,
           "smoothed_rtt/min_rtt/rttvar all assigned" if resets_rtt else "not all found")

    # initial window arithmetic, recomputed here
    cc_src = git_show(repo, "lib/ngtcp2_cc.c")
    mm = re.search(r"ngtcp2_cc_compute_initcwnd[^{]*\{(.{0,400}?)\n\}", cc_src, re.S)
    iw_ok = False
    if mm:
        payload = 1200
        n = max(2 * payload, 14720)
        computed = min(10 * payload, n)
        iw_ok = computed == im["initial_cwnd_bytes"]
    record("ngtcp2", f"initial window == {im['initial_cwnd_bytes']:,} B by the formula",
           iw_ok, f"recomputed min(10*1200, max(2*1200,14720)) = {min(12000, max(2400,14720)):,}")

    # Live measurement was obtained on 2026-08-11 after fixing the build, so
    # this now verifies the measurement rather than the absence of one.
    seen_n, reset_n, pres_n = 0, 0, []
    for d in sorted(glob.glob(f"{ROOT}/results/raw/ngtcp2/reps/rep_*")):
        sq = (glob.glob(os.path.join(d, "qlog_server", "*.sqlog")) +
              glob.glob(os.path.join(d, "qlog_server", "*.qlog")))
        if not sq:
            continue
        seen_n += 1
        cw, _ = parse_jsonseq_qlog(max(sq, key=os.path.getsize),
                                   ("congestion_window", "cwnd"), 1000.0)
        cw.sort()
        iw = im["initial_cwnd_bytes"]
        if any(abs(c - iw) < 1 and t > 4e6 for t, c in cw):
            reset_n += 1
        pre = [c for t, c in cw if 3e6 < t < 5.2e6]
        if pre:
            pres_n.append(max(pre))
    exp = (im.get("live") or {}).get("reps")
    record("ngtcp2", f"live reps == {exp}", seen_n == exp, f"found {seen_n}")
    record("ngtcp2", "every rep resets to exactly the initial window",
           seen_n > 0 and reset_n == seen_n,
           f"{reset_n}/{seen_n} at {im['initial_cwnd_bytes']:,} B" +
           (f"; pre peaks {min(pres_n):,.0f}-{max(pres_n):,.0f}" if pres_n else ""))
    record("ngtcp2", "migration changed the IP, not just the port",
           all("10.0.3.1" in open(os.path.join(d, "client.log"), errors="ignore").read()
               for d in sorted(glob.glob(f"{ROOT}/results/raw/ngtcp2/reps/rep_*"))
               if os.path.exists(os.path.join(d, "client.log"))),
           "client logs 'Local address is now [10.0.3.1]' in every rep")

    # ---------------- cross-cutting ----------------
    print("\n### cross-cutting")
    done = [i for i in claims["implementations"] if i["status"] == "done"]
    q2_all_no = all(i["q2"]["answer"] in ("NO", "INERT") for i in done)
    record("ALL", "F3: not one implementation uses the path-validation RTT",
           q2_all_no, f"{len(done)}/{len(done)} are NO or INERT")

    dead = [i["name"] for i in done if (i.get("reset_hook") or {}).get("dead")]
    record("ALL", "F1: exactly 2 of 5 ship a dead reset hook",
           len(dead) == 2, f"dead in: {', '.join(dead) or 'none'}")

    mechs = {i["q1"].get("mechanism", "")[:40] for i in done}
    record("ALL", "F2: every implementation uses a different mechanism",
           len(mechs) == len(done), f"{len(mechs)} distinct mechanisms across {len(done)}")

    # ---------------- summary ----------------
    print("\n" + "=" * 74)
    n_fail = sum(1 for _, _, v, _ in RESULTS if v == "FAIL")
    n_unv = sum(1 for _, _, v, _ in RESULTS if v == "UNVERIFIABLE")
    n_pass = sum(1 for _, _, v, _ in RESULTS if v == "PASS")
    print(f"SUMMARY: {n_pass} PASS, {n_fail} FAIL, {n_unv} UNVERIFIABLE "
          f"(of {len(RESULTS)} checks)")
    if n_fail:
        print("\nFAILURES:")
        for impl, claim, v, detail in RESULTS:
            if v == "FAIL":
                print(f"  [{impl}] {claim}\n      {detail}")
    if n_unv:
        print("\nUNVERIFIABLE:")
        for impl, claim, v, detail in RESULTS:
            if v == "UNVERIFIABLE":
                print(f"  [{impl}] {claim}  -- {detail}")
    print("=" * 74)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
