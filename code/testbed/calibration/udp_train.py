#!/usr/bin/env python3
"""udp_train.py -- back-to-back UDP packet-train sender/receiver used to
infer a path's capacity via packet dispersion: capacity ~= packet_bits /
inter_arrival_gap, measured at the receiver.

Sender (--mode sender):
    Fires `count` equal-size UDP datagrams at the destination back-to-back,
    in as tight a loop as CPython allows, with NO sleeping and NO pacing.
    Any deliberate pacing would make the measurement reflect our own timer
    instead of the emulated path's bottleneck -- so payloads are
    precomputed before the timing-critical loop starts, and the loop body
    is nothing but socket.send().

Receiver (--mode receiver):
    Uses KERNEL receive timestamps via SO_TIMESTAMPNS / SCM_TIMESTAMPNS
    (setsockopt + recvmsg ancillary data), taken by the kernel at the
    moment each packet is received. This is deliberate and non-negotiable:
    userspace timestamps (e.g. time.perf_counter() called right after
    recv()) are polluted by scheduler jitter -- measured on this host,
    100us sleeps actually take 148-384us -- which would corrupt every gap
    measurement downstream. If SO_TIMESTAMPNS cannot be enabled, or a
    received packet is missing its SCM_TIMESTAMPNS control message, this
    script fails loudly (nonzero exit + stderr message) rather than
    silently falling back to a userspace clock.

Receiver output (JSON, written to --out):
    packets_sent, packets_received, per_packet [{seq, timestamp_ns}, ...],
    gaps_ns (inter-arrival gaps in nanoseconds, chronological order),
    per_gap_rate_bps (b_i = wire_bits / gap_seconds for each gap; null
    where the gap rounded to 0ns and a rate is undefined), and a `summary`
    block with the median rate (primary estimator), the asymptotic
    dispersion rate (n-1)*wire_bits/(t_last-t_first), and IQR / IQR-over-
    median of the b_i distribution as a robust coefficient of variation.

--discard-leading N (receiver only, default 0):
    Excludes the first N inter-arrival gaps (chronological order) from the
    median/IQR/asymptotic statistics in `summary`. Motivation: a tbf burst
    of B bytes lets floor(B / wire_bytes) packets through at line rate
    before the token bucket empties, which contaminates that many LEADING
    gaps with fictitious multi-Gbit/s readings. With a long train (e.g. 20
    packets) a couple of contaminated leading gaps are a small fraction of
    the total and a median absorbs them; with a short train (e.g. 5
    packets, only 4 gaps) the same contamination can be half the data and
    breaks the median outright. This flag lets the sweep quantify exactly
    how many leading gaps must be discarded to recover an accurate estimate.
    The discarded gaps are NEVER removed from the raw gaps_ns /
    per_gap_rate_bps arrays -- they are always recorded in full -- only
    flagged per-gap in `gap_discarded_leading`, and excluded from the
    summary statistics. Default 0 discards nothing, so existing behaviour
    (and existing consumers' output) is unchanged.
"""
import argparse
import json
import socket
import statistics
import struct
import sys
import time

SEQ_STRUCT = struct.Struct("!Q")        # 8-byte big-endian sequence number, prefixed to every payload
TIMESPEC_STRUCT = struct.Struct("@ll")  # struct timespec { long tv_sec; long tv_nsec; } -- 16B on x86_64

# Python's socket module does not expose SO_TIMESTAMPNS as a named constant
# (verified: Python 3.12 on this host has no socket.SO_TIMESTAMPNS attribute),
# so we use the raw Linux value. Confirmed against this system's own headers
# (/usr/include/x86_64-linux-gnu/bits/socket-constants.h): for a 64-bit
# userspace with a 64-bit time_t (true for x86_64 Ubuntu 24.04, the Phase-0
# target), SO_TIMESTAMPNS == SO_TIMESTAMPNS_OLD == 35, and SCM_TIMESTAMPNS is
# defined to the same value. This was also confirmed empirically: a loopback
# smoke test observed ancillary data with level=SOL_SOCKET, type=35, and a
# 16-byte payload that decodes to a plausible wall-clock-relative timestamp.
SO_TIMESTAMPNS = getattr(socket, "SO_TIMESTAMPNS", 35)
SCM_TIMESTAMPNS = SO_TIMESTAMPNS

UDP_HEADER_BYTES = 8
IP_HEADER_BYTES = 20
ETH_HEADER_BYTES = 14

RECV_TIMEOUT_S = 3.0  # per-recv timeout: bounds how long the receiver waits when packets are lost


def build_payload(seq: int, size: int) -> bytes:
    if size < SEQ_STRUCT.size:
        raise ValueError(f"--size must be >= {SEQ_STRUCT.size} bytes to hold the sequence number, got {size}")
    filler = bytes(size - SEQ_STRUCT.size)
    return SEQ_STRUCT.pack(seq) + filler


def run_sender(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((args.dst, args.port))

    # Precompute every payload OUTSIDE the timing-critical loop so the send
    # loop itself is nothing but back-to-back send() calls.
    payloads = [build_payload(seq, args.size) for seq in range(args.count)]

    t0 = time.perf_counter()
    for pkt in payloads:
        sock.send(pkt)
    elapsed = time.perf_counter() - t0

    sock.close()
    print(
        f"[sender] sent {args.count} packets of {args.size}B payload to {args.dst}:{args.port} "
        f"in {elapsed * 1e3:.3f} ms wall-clock (informational only -- the receiver's kernel "
        f"timestamps are what matters, not this sender-side figure)",
        file=sys.stderr,
    )


def run_receiver(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))

    try:
        sock.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS, 1)
    except OSError as e:
        print(
            f"[receiver][FATAL] setsockopt(SO_TIMESTAMPNS) failed: {e}. Refusing to fall back "
            f"to a userspace clock -- userspace timestamps are polluted by scheduler jitter and "
            f"would invalidate every downstream capacity measurement.",
            file=sys.stderr,
        )
        sys.exit(2)

    readback = sock.getsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS)
    if not readback:
        print(
            f"[receiver][FATAL] setsockopt(SO_TIMESTAMPNS) appeared to succeed but getsockopt "
            f"reads back {readback!r} (falsy). Refusing to proceed with unverified timestamping.",
            file=sys.stderr,
        )
        sys.exit(2)

    sock.settimeout(RECV_TIMEOUT_S)

    bufsize = 65535
    ancbufsize = socket.CMSG_SPACE(TIMESPEC_STRUCT.size)

    packets = []  # [{"seq": int, "timestamp_ns": int, "payload_len": int}, ...]

    while len(packets) < args.count:
        try:
            data, ancdata, flags, addr = sock.recvmsg(bufsize, ancbufsize)
        except socket.timeout:
            print(
                f"[receiver] timed out after {RECV_TIMEOUT_S}s waiting for more packets -- "
                f"received {len(packets)}/{args.count} (remainder presumed lost)",
                file=sys.stderr,
            )
            break

        if len(data) < SEQ_STRUCT.size:
            print(f"[receiver][WARN] dropping runt datagram of {len(data)} bytes (too small for seq)", file=sys.stderr)
            continue

        seq = SEQ_STRUCT.unpack(data[: SEQ_STRUCT.size])[0]

        timestamp_ns = None
        for cmsg_level, cmsg_type, cmsg_data in ancdata:
            if cmsg_level == socket.SOL_SOCKET and cmsg_type == SCM_TIMESTAMPNS:
                tv_sec, tv_nsec = TIMESPEC_STRUCT.unpack(cmsg_data[: TIMESPEC_STRUCT.size])
                timestamp_ns = tv_sec * 1_000_000_000 + tv_nsec
                break

        if timestamp_ns is None:
            print(
                f"[receiver][FATAL] packet seq={seq} arrived with no SCM_TIMESTAMPNS control "
                f"message even though SO_TIMESTAMPNS is enabled on this socket (saw "
                f"{[(lvl, typ, len(d)) for lvl, typ, d in ancdata]}). Refusing to silently "
                f"substitute a userspace clock for this packet.",
                file=sys.stderr,
            )
            sys.exit(2)

        packets.append({"seq": seq, "timestamp_ns": timestamp_ns, "payload_len": len(data)})

    result = compute_stats(packets, args.count, args.discard_leading)

    with open(args.out, "w") as f:
        json.dump(result, f, indent=2)

    print(f"[receiver] received {len(packets)}/{args.count} packets; wrote {args.out}", file=sys.stderr)
    if result["summary"] is not None:
        s = result["summary"]
        med = s["median_rate_bps"]
        asy = s["asymptotic_rate_bps"]
        iom = s["iqr_over_median"]
        disc = s["discard_leading_applied"]
        # med/asy/iom can legitimately be None (e.g. discard_leading consumed
        # every gap, or every gap rounded to 0ns) -- format defensively
        # rather than crashing on `None:.0f`.
        med_s = f"{med:.0f}" if med is not None else "n/a"
        asy_s = f"{asy:.0f}" if asy is not None else "n/a"
        iom_s = f"{iom:.4f}" if iom is not None else "n/a"
        print(
            f"[receiver] discard_leading={disc} median_rate_bps={med_s} "
            f"asymptotic_rate_bps={asy_s} iqr_over_median={iom_s}",
            file=sys.stderr,
        )


def compute_stats(packets, sent_count, discard_leading=0):
    """Compute inter-arrival gaps and per-gap dispersion-rate estimates.

    Packets are ordered chronologically by kernel receive timestamp (not by
    sequence number) before differencing, so an out-of-order arrival cannot
    produce a nonsensical negative gap.

    `discard_leading` (default 0) excludes the first N gaps -- chronological
    order, i.e. the earliest arrivals -- from the median/IQR/asymptotic-rate
    statistics computed below. This models discarding the leading packets a
    tbf burst let through at line rate before its bucket emptied. The
    discarded gaps are NOT removed from gaps_ns / per_gap_rate_bps -- every
    gap is always recorded there -- they are only excluded from `summary`,
    and flagged per-gap in the returned `gap_discarded_leading` list. At the
    default N=0, "kept" == "all gaps", so every summary field is numerically
    identical to the pre-discard-leading implementation.
    """
    packets_sorted = sorted(packets, key=lambda p: p["timestamp_ns"])

    per_packet = [{"seq": p["seq"], "timestamp_ns": p["timestamp_ns"]} for p in packets_sorted]

    gaps_ns = []
    rates_bps = []
    gap_discarded_leading = []
    summary = None

    if len(packets_sorted) >= 2:
        # All payloads in one train are the same size by construction (a
        # single --size value on the sender); use the size actually observed
        # on the wire rather than hardcoding it here.
        payload_len = packets_sorted[0]["payload_len"]
        wire_bits = (payload_len + UDP_HEADER_BYTES + IP_HEADER_BYTES + ETH_HEADER_BYTES) * 8

        n_gaps = len(packets_sorted) - 1
        # Clamp so a discard_leading >= n_gaps just means "everything
        # discarded" (median/IQR/asymptotic all become None) rather than
        # indexing past the end of the gap list below.
        discard_applied = max(0, min(discard_leading, n_gaps))

        for i in range(1, len(packets_sorted)):
            gap_ns = packets_sorted[i]["timestamp_ns"] - packets_sorted[i - 1]["timestamp_ns"]
            gaps_ns.append(gap_ns)
            gap_discarded_leading.append((i - 1) < discard_applied)
            if gap_ns > 0:
                rates_bps.append(wire_bits / (gap_ns / 1e9))
            else:
                # Two packets landed in the same kernel timestamp tick (gap
                # rounds to 0ns). The instantaneous rate is undefined
                # (would be infinite) -- record null rather than fabricate
                # a number; the gap itself is still kept in gaps_ns.
                rates_bps.append(None)

        kept_rates = rates_bps[discard_applied:]
        valid_rates = [r for r in kept_rates if r is not None]

        # Asymptotic estimator over the KEPT span only: from the packet
        # immediately after the last discarded gap, to the final packet.
        n_kept_gaps = n_gaps - discard_applied
        t_first_kept = packets_sorted[discard_applied]["timestamp_ns"]
        t_last = packets_sorted[-1]["timestamp_ns"]
        total_s = (t_last - t_first_kept) / 1e9

        median_rate = statistics.median(valid_rates) if valid_rates else None
        asymptotic_rate = (n_kept_gaps * wire_bits / total_s) if (total_s > 0 and n_kept_gaps > 0) else None

        if len(valid_rates) >= 2:
            q1, _q2, q3 = statistics.quantiles(valid_rates, n=4)  # method="exclusive" (statistics module default)
            iqr = q3 - q1
        elif len(valid_rates) == 1:
            q1 = q3 = valid_rates[0]
            iqr = 0.0
        else:
            q1 = q3 = iqr = None

        summary = {
            "payload_len_bytes": payload_len,
            "wire_bits_per_packet": wire_bits,
            "discard_leading_requested": discard_leading,
            "discard_leading_applied": discard_applied,
            "n_gaps": len(gaps_ns),          # total gaps observed (all, including discarded)
            "n_gaps_kept": n_kept_gaps,        # gaps actually used for the stats below
            "n_valid_rate_estimates": len(valid_rates),  # non-null rate estimates among the KEPT gaps
            "median_rate_bps": median_rate,
            "asymptotic_rate_bps": asymptotic_rate,
            "q1_rate_bps": q1,
            "q3_rate_bps": q3,
            "iqr_rate_bps": iqr,
            "iqr_over_median": (iqr / median_rate) if (iqr is not None and median_rate) else None,
        }

    return {
        "packets_sent": sent_count,
        "packets_received": len(packets_sorted),
        "discard_leading": discard_leading,
        "per_packet": per_packet,
        "gaps_ns": gaps_ns,
        "per_gap_rate_bps": rates_bps,
        "gap_discarded_leading": gap_discarded_leading,
        "summary": summary,
    }


def main():
    parser = argparse.ArgumentParser(description="Back-to-back UDP packet-train sender/receiver for packet-dispersion capacity calibration.")
    parser.add_argument("--mode", required=True, choices=["sender", "receiver"])
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--count", type=int, required=True)
    # sender-only
    parser.add_argument("--dst", help="sender: destination IP address")
    parser.add_argument("--size", type=int, help="sender: UDP payload size in bytes (>=8)")
    # receiver-only
    parser.add_argument("--bind", help="receiver: local IP address to bind")
    parser.add_argument("--out", help="receiver: path to write the JSON results")
    parser.add_argument(
        "--discard-leading",
        type=int,
        default=0,
        help="receiver: exclude the first N inter-arrival gaps from median/IQR/asymptotic "
        "stats (still recorded raw and flagged in gap_discarded_leading). Default 0 = no change.",
    )

    args = parser.parse_args()

    if args.count <= 0:
        parser.error("--count must be a positive integer")

    if args.discard_leading < 0:
        parser.error("--discard-leading must be >= 0")

    if args.mode == "sender":
        if not args.dst or args.size is None:
            parser.error("--mode sender requires --dst and --size")
        if args.size < SEQ_STRUCT.size:
            parser.error(f"--size must be >= {SEQ_STRUCT.size} (bytes needed for the sequence number)")
        run_sender(args)
    else:
        if not args.bind or not args.out:
            parser.error("--mode receiver requires --bind and --out")
        run_receiver(args)


if __name__ == "__main__":
    main()
