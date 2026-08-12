# QUIC Congestion Control at Connection Migration: A Five-Implementation Survey

A measurement study of what QUIC implementations actually do to their congestion
controller and round-trip-time estimator when a connection moves to a new
network path, and how that compares with what RFC 9000 and RFC 9002 require.

Five independently developed implementations, three languages, three questions,
each answered twice: once by reading the source, once by measuring the running
program.

**Capstone research, Computer Networks (Semester 5).**
Author: sivaahari (`cb.sc.u4cys24055@cb.students.amrita.edu`)

---

## Abstract

When a mobile device changes network — Wi-Fi to cellular, or one cell to
another — a QUIC connection can survive the change by migrating to a new path.
RFC 9000 §9.4 states that on such a migration an endpoint **MUST** reset its
congestion controller and RTT estimator to initial values, and that packets sent
on the old path **MUST NOT** contribute to congestion control or RTT estimation
for the new path. RFC 9002 §6.2.2 additionally **MAY** permit reusing the
path-validation round trip, which every migration already performs, as the new
path's initial RTT.

We audited five implementations against these three requirements and measured
each one in a controlled two-path emulation testbed. The results are that no two
of the five behave identically; two of them ship a congestion-reset function
that nothing ever calls; the five that comply do so by five structurally
different mechanisms; not one of the five uses the free path-validation
measurement; one cannot be scored yes or no on either MUST; and in that same
implementation the sending endpoint never recovers a working RTT estimate after
migration at all.

A secondary result, established in Phase 1, is that partial compliance is worse
than none: implementing the §9.4 reset without the accompanying old-path
exclusion took transfer completion from 5/5 to 0/15 in our own patched build.

Every claim in this repository is re-derivable from primary sources by an
independent validator that shares no code with the analysis pipeline. It runs 27
checks; all 30 pass.

---

## 1. Motivation and research question

Connection migration is one of QUIC's headline capabilities over TCP: because a
connection is identified by a Connection ID rather than by the four-tuple, it can
survive a change of client address. The transport specification is unambiguous
about what must happen to the congestion state at that moment — the new path may
have entirely different capacity and delay, so estimates learned on the old path
are not merely stale, they are misleading.

What is not documented anywhere is whether implementations actually do this, or
what it costs when they do not. That is the gap this work addresses.

> **Research question.** When a QUIC connection migrates to a new network path,
> do widely used implementations reset their congestion and RTT state as
> RFC 9000 §9.4 requires; by what mechanism; and what does the resulting
> behaviour cost on a path whose characteristics differ from the old one?

---

## 2. Scope and status

| Item | Value |
|---|---|
| Implementations surveyed | 5 (picoquic, quic-go, quiche, msquic, ngtcp2) |
| Languages | C, Go, Rust |
| Source audits complete | 5 of 5 |
| Live measurement complete | 5 of 5 |
| Independent validation | 30 checks, 30 pass |
| Environment | Emulation only (Linux network namespaces under WSL2) |

This is an emulation study. There are no real handsets and no real cellular
networks in it. See [§10 Limitations](#10-limitations-and-claims-not-made) for
the full statement of what is and is not claimed.

---

## 3. The comparison metrics

Every implementation is scored on the same three questions. They are drawn
directly from the specifications, and each carries the requirement level the RFC
assigns it — which matters, because one of the three is an option rather than an
obligation and must not be reported as a violation.

### 3.1 Q1 — Does it reset congestion control on migration?

- **Source:** RFC 9000 §9.4, second paragraph
- **Requirement level:** MUST
- **Text:** an endpoint "MUST immediately reset the congestion controller and
  round-trip time estimator for the new path to initial values"

The new path is a different network. Its capacity is unknown. Continuing to send
at a rate learned elsewhere risks overwhelming it.

### 3.2 Q2 — Does it use the path-validation RTT as the new path's initial RTT?

- **Source:** RFC 9002 §6.2.2
- **Requirement level:** MAY
- **Text:** a connection "MAY use the delay between sending a PATH_CHALLENGE and
  receiving a PATH_RESPONSE to set the initial RTT for a new path"

Before an endpoint will send substantial data to a new address it must validate
the path: send a random challenge, require it echoed back. This is compulsory and
happens at every migration. It is also, by construction, a round-trip measurement
of the new path — obtained for free, before any data is sent. The specification
explicitly permits using it instead of a fixed default.

This is an option, not an obligation. An implementation that declines is not in
violation. It is nonetheless informative to know whether anybody takes it.

### 3.3 Q3 — Does it exclude old-path ACKs from new-path state?

- **Source:** RFC 9000 §9.4, first paragraph
- **Requirement level:** MUST
- **Text:** "Packets sent on the old path MUST NOT contribute to congestion
  control or RTT estimation for the new path"

At the instant of migration there are packets still in flight on the old path.
Their acknowledgements arrive after the switch. If they are fed into the new
path's estimators, they describe the wrong network.

This requirement is easy to overlook because it is stated separately from the
reset, one paragraph earlier. We overlooked it ourselves in Phase 1, with
measurable consequences — see [F4](#5-cross-cutting-findings).

### 3.4 Why these three

Q1 and Q3 are the two halves of a single obligation and are only meaningful
together: Q1 clears the state, Q3 keeps it clear. Q2 is the specification's own
suggestion for what to seed the cleared state with. Together they cover the
complete lifecycle of the congestion estimate across a migration event.

---

## 4. Results

### 4.1 Summary

| Implementation | Language | Vendor | Commit | Q1 (MUST) | Q2 (MAY) | Q3 (MUST) | Live reps |
|---|---|---|---|---|---|---|---|
| picoquic | C | private-octopus | `0dc8ba8b` | **NO** | present but inert | **NO** | 5 |
| quic-go | Go | quic-go | `2cfe6ee0` | YES | NO | YES | 5 |
| quiche | Rust | Cloudflare | `e97798e1` | YES | NO | YES | 5 |
| msquic | C | Microsoft | `4db8b398` | **ASYMMETRIC** | NO | **SPLIT** | 5 |
| ngtcp2 | C | ngtcp2 | `d7fb3ed0` | YES | NO | YES | 5 |

Three distinct answer patterns across five implementations. picoquic fails both
MUSTs outright; msquic fails both partially, in a way that a yes/no column cannot
express (see §4.4.4). The Q2 column is unanimous.

Full commit hashes are in [`data/upstream_commits.txt`](data/upstream_commits.txt).
No upstream source is vendored into this repository; the pinned commits are
sufficient to reconstruct exactly what was audited.

### 4.2 Measured congestion-window behaviour at the switch

| Implementation | Window before | Window after | Own initial window | Reset observed | Reps |
|---|---|---|---|---|---|
| picoquic | 86,904–89,352 B | 2,848–8,608 B (minimum) | 15,360 B / 14,240 B effective | **No** | 5 |
| quic-go | 274,025–280,414 B | **40,960 B** | 40,960 B | Yes, 5/5 | 5 |
| quiche | 654,900 B | **12,000 B** | 12,000 B | Yes, 5/5 | 5 |
| msquic (server) | 1,481,740–1,484,569 B | **12,200 B** | 12,200 B | Yes, 5/5 | 5 |
| ngtcp2 | 532,322–572,685 B | **12,000 B** | 12,000 B | Yes, 5/5 | 5 |

Where the window lands on exactly the implementation's own initial value, that
is a reset. The discriminator in [§6.2](#62-the-reset-versus-loss-discriminator)
establishes that no ordinary loss event could produce the same number.

Two clarifications that matter for honest reading of this table:

- **picoquic's row is the one case where the window ends up BELOW its own
  initial value, and that is still not a reset.** This is the discriminator's
  hardest case and it is worth stating precisely. A reset assigns the initial
  window *exactly* — 15,360 B by picoquic's constant, or 14,240 B from the
  negotiated 1424 B send size. Across five repetitions, **zero samples took
  either value** in the interval from 50 ms before path validation to two
  seconds after. What the window did instead was fall *past* both, reaching
  exactly 2,848 B (= 2 × 1424 = `PICOQUIC_CWIN_MINIMUM`, the floor) in two of
  five runs, roughly 110 ms after the migration and alongside 42–58 lost
  packets. A window below the initial value cannot have been produced *by* a
  reset. It is a loss cascade bottoming out.
- **msquic's client-side window is not decisive evidence.** It sat flat at
  96,290 B, but in a download the client is acknowledgement-only (it sent
  389,341 B in total, of which 16 were stream bytes), so its congestion window
  was never the binding constraint. The asymmetry finding rests on the source
  audit; the live trace only corroborates it.

### 4.3 RTT behaviour after migration

The two paths carry deliberately different delays so that the RTT alone reveals
which network an implementation is measuring after the switch.

| Implementation | First post-migration RTT | True RTT of new path | What it reflects |
|---|---|---|---|
| picoquic | 24.7–30.2 ms | 40 ms | **The old path**, converging over ~1 s |
| quic-go | 40.4–40.8 ms | 40 ms | The new path |
| quiche | path A 20.27–20.53 ms; path B 40.21–40.24 ms | 20 / 40 ms | Both, tracked separately |
| msquic (server) | 333.0 ms, unchanged for ~20 s | 40 ms | **Neither — stuck at its default** |
| ngtcp2 | new-path value | 40 ms | The new path |

picoquic's row is the Q3 failure made visible. Before migrating it reads
23.4–27.0 ms on the 20 ms path A. On the first sample after path validation it
still reads 24.7–30.2 ms — the old path — rather than the new path's 40 ms, and
only reaches 40.22–40.44 ms about a second later. A compliant implementation
would have cleared the estimator to picoquic's 250 ms initial RTT and re-measured
the new path from scratch.

The same failure was demonstrated more sharply in Phase 1's step-down scenario
(path B at 20 Mbit/60 ms), where our own *compliant* reset was re-seeded to
20.3 ms — the old path's RTT — just 1.8 ms after being cleared. That 60 ms figure
belongs to that experiment alone; the standard operating point used here has a
40 ms new path.

### 4.4 Per-implementation detail

#### 4.4.1 picoquic (C, private-octopus) — `0dc8ba8b`

**Answers: Q1 NO, Q2 present but inert, Q3 NO.**

*Architecture.* One path object per connection. Migrating attaches a new address
tuple to that same object. Congestion state belongs to the path, not to the
tuple, so it simply carries across.

*Q1.* The reset notification `picoquic_congestion_notification_reset` is
implemented as a handler by **all seven** of picoquic's congestion-control
algorithms, and is called by **nothing**. The code that runs at path validation
updates RTT, promotes the address and resets the maximum packet size; it never
touches congestion control. The window is re-initialised only in algorithm setup
and in new-path creation, neither of which runs during ordinary migration.

This was re-derived a second time against pristine upstream source pulled
directly out of git object storage, so that our own later modifications to the
tree could not contaminate the finding. Upstream dispatches ten distinct
congestion notifications; the reset is not among them.

*Q1, live.* Five repetitions, each verified from the server qlog's
`addr_from`/`addr_to` fields to be a genuine IP change (`10.0.1.1` →
`10.0.3.1`, port unchanged) rather than a port-only rebinding — the latter would
be exempt under §9.4 and would prove nothing. In none of the five did the window
ever take the initial value. See §4.2 for why falling *below* the initial window
is not a reset.

*Scope.* This holds for single-path operation, which is the default and what
standard migration uses. With multipath enabled, `picoquic_create_path()` does
produce genuinely fresh state.

*Q2.* Implemented at `frames.c:4943`, but gated on `!rtt_is_initialized`, which
is false for the primary path. The code exists and never fires.

*Q3.* No old/new attribution for ACK-derived samples. This is the specific defect
that broke our own compliant implementation — see [F4](#5-cross-cutting-findings).

#### 4.4.2 quic-go (Go) — `2cfe6ee0` (v0.61.0+8)

**Answers: Q1 YES, Q2 NO, Q3 YES.**

*Q1 — explicit reset.* `MigratedPath()` does not adjust the controller; it
**replaces** it with a new object, and resets RTT to a fixed 100 ms. Two live
call sites: `connection.go:915` (client) and `:1295` (server, reactive).

Note that `addrsEqual` compares IP **and** port, so quic-go resets on any address
change. It does not take the RFC's port-only leniency.

*Q3 — structural.* quic-go does not attempt to work out which packets belong to
which path. On migration it declares every in-flight packet lost, and the
function that does so sets the array slot to `nil` — actual removal. The
ACK-matching iterator skips `nil` entries, so a late acknowledgement from the old
path is permanently unmatchable. Aggressive, but unambiguously safe.

*Q2.* `initialRTT` is used only as PATH_CHALLENGE probe backoff;
`ResetForPathMigration` always seeds a fixed default. The client logs a measured
probe RTT of 40.7 ms and then seeds 100 ms — the measurement is taken and
discarded in consecutive log lines.

*Historical note.* The frequently repeated claim that quic-go does not support
connection migration is out of date. It was added in 2025 and has shipped in
stable releases since.

#### 4.4.3 quiche (Rust, Cloudflare) — `e97798e1`

**Answers: Q1 YES, Q2 NO, Q3 YES.**

*Q1 — compliant by construction.* quiche never resets anything. It keeps a
separate object per path, each with its own `Recovery`. Migrating creates a
**new** path, and `Path::new` builds a new `Recovery` at the initial window. The
naive reading — "quiche resets, therefore compliant" — is wrong in mechanism even
though right in outcome. That distinction is the point of this survey.

*The dead hook, again.* quiche contains `on_connection_migration()`, carrying the
comment *"Called when connection migrates and cwnd needs to be reset"*, with one
empty implementation and **zero call sites**. The hook that *is* called on a path
change only runs loss detection on the old path; it resets nothing.

*Q3 — the cleanest evidence in the survey.* Because state is per-path, each path
tracks its own RTT. Across five runs, path A measured 20.27–20.53 ms and path B
measured 40.21–40.24 ms against configured delays of 20 ms and 40 ms. Both
correct, both separate, no contamination.

*Methodological caveat.* quiche's qlog does **not** tag congestion metrics with a
path identifier — zero of 98,369 events carried one. Its time series is therefore
a union over both paths. The reliable per-path evidence is its own `path_stats`
output; the log is corroboration only.

*Untested edge case.* Migrating **back** to a previously used path reuses that
path object, which still holds its old congestion state. Arguably outside the
rule's wording, but against its intent.

#### 4.4.4 msquic (C, Microsoft) — `4db8b398` (v2.6.0)

**Answers: Q1 ASYMMETRIC, Q2 NO, Q3 SPLIT.**

msquic broke the survey's scoring. Neither MUST could be answered yes or no, and
two new categories had to be introduced.

*A fourth architecture.* Congestion control is **connection-wide**; RTT is
**per-path**. No other surveyed implementation splits them this way.

*Q1 is asymmetric — the answer depends on which endpoint you ask.*
`QuicPathSetActive` (`path.c:312`) does reset connection-wide congestion control,
and notably implements the RFC's port-only exemption deliberately, skipping the
reset when only the port changed (ordinary NAT rebinding rather than a real move).
msquic is the only surveyed implementation that does this on purpose. But the
client's own `QUIC_PARAM_CONN_LOCAL_ADDRESS` handler (`connection.c:6426+`)
mutates `Paths[0]` in place and never calls it.

So the **observing** endpoint resets and the **migrating** endpoint does not. The
same connection is simultaneously compliant at one end and non-compliant at the
other.

*Q3 is split, with a smoking gun in msquic's own source.* RTT measurements **are**
correctly excluded by path identifier (`NewLargestAckDifferentPath` gates the RTT
update at `loss_detection.c:1502`). Acknowledged byte counts are **not**: the
`QUIC_ACK_EVENT` structure carries no path identifier field at all, and
`loss_detection.c:1206` hardcodes the first path under a comment written by
msquic's own developers:

```c
const QUIC_PATH* Path = &Connection->Paths[0]; // TODO - Correct?
```

They flagged their own uncertainty. This work reports what that uncertainty turns
out to cost.

*The most striking result in the survey.* After migrating, msquic's server never
recovers a working RTT estimate. Its smoothed RTT stays at exactly its 333 ms
initial default and its minimum-RTT field at the "no measurement yet" sentinel,
for every one of roughly 3,800 samples per run, across ~20 s, in 5 runs out of 5.
The true path delay was 40 ms. The consequence is visible in throughput: about
13 Mbit/s where quic-go achieved about 19 Mbit/s on the same 20 Mbit link.

The irony is the finding: the endpoint that **complies** with §9.4 ends up with a
permanently broken estimate, while the endpoint that does **not** comply keeps a
working one.

> **This is an observation, not a diagnosis.** The values are read through
> msquic's public statistics API. An alternative explanation — that the path swap
> leaves the polled field stale rather than the estimator being genuinely stuck —
> has not been ruled out. Doing so requires an instrumented build, which has not
> been done. An earlier draft of this work attributed the behaviour to the Q3 RTT
> gate never re-opening; that attribution is **not supported** (`path.c:29`
> assigns each new path a fresh incrementing identifier, so the gate should open)
> and has been withdrawn. The mechanism is unexplained.

*Instrumentation.* The hardest of the five. msquic has no usable qlog on Linux —
its only qlog code is a post-processor for Windows event traces. It was built with
stdout tracing instead, and its statistics API polled every 5 ms.

*One run in five crashed.* The client aborted after a stale packet addressed to
its old location was processed just after the switch, causing the connection to
reactively promote the old path back, fighting the migration that had just
completed. Characterised from the logs; not root-caused. Reported rather than
dropped.

#### 4.4.5 ngtcp2 (C) — `d7fb3ed0`

**Answers: Q1 YES, Q2 NO, Q3 YES.**

*The fifth architecture, and the only symmetric one.* Congestion state is
connection-wide, as in msquic — but where msquic resets at only one end, ngtcp2
resets wholesale on any path change, at **both** ends.

*Q1 — explicit, thorough, symmetric.* `conn_reset_congestion_state()` resets the
window **and** the RTT estimator, then dispatches each algorithm's own reset
handler. Six call sites, four of them migration-related; it fires on both
endpoints — the client at `ngtcp2_conn.c:13892` inside
`initiate_immediate_migration`, and the observer at `:6188` when path validation
promotes a different path.

The reset itself (`conn_reset_conn_stat_cc`, `ngtcp2_conn.c:906`) is the most
complete in the survey: latest RTT to zero, minimum RTT to its sentinel, smoothed
RTT to the configured initial value, variance to half of that, first-sample
timestamp and bytes-in-flight cleared, and the window recomputed from
`ngtcp2_cc_compute_initcwnd`.

Two details show a codebase that has read the specification closely. Setting the
RTT variance to half the initial RTT is RFC 9002 Appendix A.3 exactly, where
picoquic's own convention uses zero. And the initial window is the RFC 9002 §7.2
formula implemented literally: `min(10 × 1200, max(2 × 1200, 14720)) = 12,000`.

*Q3 — a packet-number watermark, the third distinct mechanism.* ngtcp2 neither
nulls out old packets (quic-go) nor separates state per path (quiche). It draws a
line by packet number: `ngtcp2_rtb_reset_cc_state` records `cc_pkt_num` as the
next packet number it will send, documented in its own header at `rtb.h:181` as
"the smallest packet number that is contributed to congestion control". Three
guards (`rtb.c:183`, `:470`, `:923`) test whether a packet number is at or above
that watermark, so everything sent before the migration is excluded from
congestion accounting from that instant onward.

This is the cleanest answer in the survey to the problem that broke our own
Phase 1 patch. picoquic had no way to tell an old-path acknowledgement from a
new-path one. ngtcp2 never has to ask: the packet number already says.

*Q2.* `conn_recv_path_response` (`ngtcp2_conn.c:6154`) validates the challenge and
promotes the path without ever touching the RTT estimator. The reset then seeds
smoothed RTT from the configured initial value instead.

---

## 5. Cross-cutting findings

**F1 — Two of the five ship a migration-reset hook that nothing calls.**
picoquic's `picoquic_congestion_notification_reset` has 7 handlers and 0 callers.
quiche's `on_connection_migration()`, commented with its own purpose, has 0
callers and one empty implementation. The other three are reachable: quic-go's has
2 call sites, msquic's 2, ngtcp2's 6. Independent codebases, different languages,
the same dead-hook pattern in two of them.

**F2 — Every implementation reaches its answer by a different mechanism.**
quic-go replaces its controller explicitly. quiche is compliant by construction,
because per-path state means a new path is born at the initial window. picoquic
fails because its path object, and therefore its congestion state, is reused.
msquic is connection-wide for congestion and per-path for RTT, so the observing
endpoint resets while the migrating one does not. ngtcp2 is connection-wide too,
but resets at both ends and excludes old-path packets with a packet-number
watermark. Five implementations, five architectures, five different routes to the
answer.

*Whether an implementation complies turns out to be the less interesting question.
How it complies is determined by how it stores its state — a design decision made
long before anyone considered migration.*

**F3 — The RFC 9002 §6.2.2 initial-RTT option is universally unused.**
All five perform the compulsory path-validation round trip, and not one uses the
result. Four seed a fixed default instead; two of those were caught doing it in
consecutive log lines — measuring the new path at roughly 40 ms, then seeding
100 ms and 333 ms respectively. picoquic is the near-miss and still does not use
it: the code exists but is gated behind a condition that is never true for the
path being migrated.

**F4 — Partial compliance with §9.4 is worse than ignoring it.** (Established in
Phase 1.) Implementing the reset (second paragraph) without the old-path
exclusion (first paragraph) took transfer completion from **5/5 to 0/15** in our
own picoquic patch. Stale old-path acknowledgements re-seed the freshly cleared
estimator, pacing slow start roughly 3× too fast for the new path.

**F5 — Compliance is not binary.** msquic cannot be scored yes or no on either
MUST, and required two new answer categories: ASYMMETRIC (compliant at one end of
a connection and not the other, simultaneously) and SPLIT (obeying the rule for
RTT and disobeying it for congestion input).

**F6 — In msquic the sender's RTT estimator never recovers after a migration.**
5/5 repetitions, ~3,800 samples each, ~20 s, smoothed RTT pinned at 333 ms and
minimum RTT at its sentinel, against a true path RTT of 40 ms. Reported as an
observation; the mechanism is not established.

---

## 6. Methodology

### 6.1 Every question answered twice

Source code can mislead in both directions. Code that looks like it resets may
never be called — F1 is exactly that case, twice. Code that looks absent may be
reached through a function pointer that a naive grep will not find. A running
program can mislead too: a number that looks like a reset may be an ordinary loss
event.

So every question was answered **twice**: once by reading the source, once by
measuring the running program. Where the two agreed, the answer was recorded.
Where they disagreed, the disagreement *was* the finding, and it was investigated
until explained.

### 6.2 The reset-versus-loss discriminator

This is the single most important safeguard in the study.

When a congestion window collapses at a migration, that could be either the
implementation obeying the rule (a reset) or ordinary congestion control reacting
to dropped packets (a loss event). If the two produce the same number, the
observation proves nothing.

So before claiming anything from a collapse, three constants were read out of the
implementation's own source — the initial window a reset would produce, the
minimum window a loss cascade would floor at, and the multiplicative reduction a
single loss event applies — and the observed value confirmed to be explicable
**only** by a reset.

| Implementation | Initial window | Loss floor | Loss factor |
|---|---|---|---|
| picoquic | 10 × 1536 = 15,360 B by the constant; **14,240 B effective** (10 × the negotiated 1424 B send size) | 2 × 1424 = **2,848 B** | — |
| quic-go | 32 × 1280 = 40,960 B | 2,560 B | ×0.7 |
| quiche | 10 × 1200 = 12,000 B | 2,400 B | ×0.7 |
| msquic | 10 × 1220 = 12,200 B | 2,440 B | ×0.7 |
| ngtcp2 | 12,000 B (RFC 9002 §7.2 formula) | 2,400 B | ×0.7 |

In quic-go this mattered decisively. The observed sequence was
279,456 → 195,619 → 40,960 B. The middle value is exactly 279,456 × 0.7, a Reno
loss backoff; only the final value can be a reset. A loss event and a reset both
occurred, 0.4 ms apart. Without the discriminator this would have been reported as
one event where there were two.

### 6.3 The emulation testbed

Two independent virtual network paths between a client and a server, built from
Linux network namespaces and `veth` pairs, each shaped separately with `tc`
(`tbf` for rate, `netem` for delay). The **server's address never changes**; the
client's does — which is what actually happens in a handover, and is what makes
the migration a genuine §9.4 event rather than a port rebinding.

Standard operating point for all Phase 2 trials:

| Parameter | Value |
|---|---|
| Path A | 20 Mbit/s, 20 ms round-trip delay |
| Path B | 20 Mbit/s, 40 ms round-trip delay |
| Token-bucket burst | 3,200 B (calibrated; see §6.4) |
| Migration trigger | ~5 s into a 15–25 s transfer |
| Repetitions | 5 per implementation (picoquic: 1) |

The two different delays are load-bearing: they make the RTT alone sufficient to
identify which network an implementation is measuring after the switch, which is
what makes Q3 answerable from a trace at all.

All five implementations, picoquic included, are measured at this operating
point. Phase 1 additionally used a step-down pair with the new path at 20 Mbit /
60 ms, which is where the sharper Q3 demonstration in §4.3 comes from.

### 6.4 Testbed calibration

The emulator was validated before it was trusted to measure anything, and this
found two flaws that would have corrupted every subsequent number.

**Token-bucket burst.** Dispersion-accuracy testing accepted a burst of both
1,600 and 3,200 B. Sustained-throughput testing rejected 1,600: it produced
−14.5% at 100 Mbit/s and −6.0% at 50 Mbit/s, with tight min/max spread, so the
error was systematic rather than noise. At 3,200 B the error is −0.82% at
100 Mbit/s. **Neither test finds this alone**, which is the reason both are run.
Judge goodput against the ~96% ceiling implied by TCP/IP/Ethernet framing
overhead, not against the raw configured rate.

**Probe-train length.** At burst 3,200 a token bucket passes
`floor(burst / 1242) = 2` packets unshaped. With `K = 5` probes that contaminates
2 of only 4 gaps — 50% — which breaks the median: +56% error, IQR/median 25–174.
The operating point is therefore `K ≥ 8` with `discard_leading = 2`, which gives
0.30% / 0.63% / −0.88% error at 20 / 50 / 100 Mbit/s.

Timing fidelity was verified independently: a 10 ms `netem` delay measured
10.072 / 10.104 / 10.137 ms with 26 µs mean deviation.

### 6.5 Instrumentation, per implementation

The five do not agree on how to expose their internal state, and this shaped a
large part of the work. Three different trace formats are represented, plus one
implementation with no usable trace at all:

| Implementation | Trace mechanism | Format detail |
|---|---|---|
| picoquic | qlog | Single JSON document, positional arrays, microseconds |
| quic-go | qlog | JSON-SEQ `.sqlog`, `0x1E` record separators, millisecond floats |
| quiche | qlog | JSON-SEQ `.sqlog`; **no path identifier on metrics events** |
| ngtcp2 | qlog | JSON-SEQ `.sqlog` |
| msquic | **none usable on Linux** | stdout tracing + `QUIC_PARAM_CONN_STATISTICS_V2` polled every 5 ms; `bytes_in_flight` unavailable |

Separate parsers were therefore written for each format
([`code/analysis/parse_qlog*.py`](code/analysis)). Kernel receive timestamps
(`SO_TIMESTAMPNS`) are used where packet-level timing matters.

### 6.6 Independent validation

Because the analysis pipeline could in principle be consistently wrong, a second
validator was written **from scratch**, sharing no code with any parser or figure
generator in the project. It re-derives every claim from primary sources: source
code read via `git show HEAD:<path>` rather than from the working tree, and raw
traces re-parsed with its own independent parsers for all three qlog formats.

It runs **30 checks and passes all 30**
([`code/validation/validation_run_output.txt`](code/validation/validation_run_output.txt)).

It also earned its keep, twice over. It caught the claims recorded in
[§11](#11-record-of-corrections) — and when picoquic's repetitions were added it
rejected the first version of its own new check, which tested the whole trace for
the initial window. That test can never pass: every connection *begins* at its
initial window, so the value always appears near t=0. Scoping it to the migration
is what makes it evidence.

---

## 7. How the experiments were conducted

### 7.1 Phase 0 — Environment and calibration

Verified the WSL2 kernel exposes what the testbed needs (`sch_netem`, `sch_tbf`,
`ifb`, network namespaces) and that its clock source is suitable for
microsecond-scale timing. Built the two-path topology, then calibrated the shaper
against three independent gates as described in §6.4. Nothing was measured until
the emulator had been shown to be accurate.

### 7.2 Phase 1 — Establishing the question

Audited picoquic and found the dead reset hook. Verified it four independent ways,
then re-verified against pristine upstream source. Implemented §9.4 ourselves to
measure what compliance costs — and discovered that a partial implementation
(the reset without the old-path exclusion) is worse than none: 5/5 completions
became 0/15. That result is F4, and it is what motivated Phase 2: if the rule is
this easy to get wrong, what does everyone else do?

### 7.3 Phase 2 — The survey

For each of the remaining four implementations:

1. **Clone and pin** at a specific commit; record it.
2. **Source audit** — locate the congestion-reset path, enumerate its call sites,
   determine whether the hook is reachable, and read out the discriminator
   constants. Scripted and re-runnable
   ([`code/audits/`](code/audits)).
3. **Build a harness** — a client and server for that implementation capable of
   triggering a migration on command and emitting usable telemetry
   ([`code/harness/`](code/harness)).
4. **Instrument** — enable qlog, or, for msquic, build with stdout tracing and
   poll the statistics API.
5. **Run 5 repetitions** of the migration scenario on the calibrated testbed,
   archiving each repetition before starting the next.
6. **Apply the discriminator** to every observed window collapse.
7. **Reconcile** source and live answers. Record in `survey_results.json`.

### 7.4 Obstacles that shaped the method

These are documented because they are reproducible traps, not incidental
annoyances:

- **A migration that was not a migration.** ngtcp2's example client exposes
  `--change-local-addr` but provides no way to name a target address. Reading
  `change_local_addr()` (`examples/client.cc:1305`) shows why: it asks the
  **routing table** which local address reaches the server, which in this testbed
  answers "path A" again — a port-only change, which RFC 9000 §9.4 explicitly
  **exempts** from the reset. Run naively, this measures nothing and concludes
  something. The trial therefore flips the client namespace's route to path B a
  quarter-second before the migration timer fires, so the client genuinely binds
  the path B address, confirmed in every repetition by the client's own log line.
  This is also a more faithful model of a real handover than an API call would be.
  picoquic's demo set the same trap in different clothing during Phase 1.
  **An implementation's own migration demo is not evidence that a migration
  occurred.**
- **A build that reported success and produced nothing.** An interrupted ngtcp2
  build left zero-byte object files and executables behind. `ninja` treats a
  zero-byte file with a recent timestamp as up to date, so it reported "no work to
  do" while the client binary was zero bytes long. Deleting every zero-byte
  artefact and rebuilding fixed it.
- **Repetitions overwriting each other.** The first quic-go trial script hardcoded
  its output directory, so later repetitions silently overwrote earlier ones,
  leaving 3 retained runs reported as 4. Re-run through a wrapper that parses and
  archives each repetition before the next.
- **Source-based routing and unbound sockets.** In the client namespace, a socket
  that does not bind an explicit source address gets `ENETUNREACH`; this hung one
  test for 400 s before a main-table fallback route was added. Path isolation was
  re-verified with packet counters afterwards.

---

## 8. Reproduction

### 8.1 Prerequisites

Linux with network-namespace support (this work used WSL2, Ubuntu 24.04, kernel
6.6). Root is required for namespace and `tc` operations. Toolchains for C, Go and
Rust are needed to build the five implementations; `code/build/01_install_deps.sh`
installs the package-level dependencies.

### 8.2 Rebuild the findings from the recorded data

Every figure and table in the deliverables is generated from
[`data/survey_results.json`](data/survey_results.json). Nothing is hand-drawn.

```bash
python3 code/analysis/make_survey_figures.py
```

### 8.3 Re-run the independent validation

```bash
python3 code/validation/revalidate_fresh.py
```

Expected: `30 PASS, 0 FAIL, 0 UNVERIFIABLE (of 30 checks)`.

### 8.4 Re-run a source audit

The audits read the cloned upstream repositories and are the source-side evidence
for the answer columns.

```bash
bash code/audits/revalidate_pristine.sh
```

### 8.5 Re-run a live migration trial

Requires the topology to be up and the relevant implementation built. Each
scenario script is self-contained: it sets up, runs and tears down in a single
invocation, because the WSL2 virtual machine discards network namespaces when it
idles between invocations.

```bash
bash code/testbed/scenarios/quiche_migrate_demo.sh
```

---

## 9. Repository layout

```
.
├── README.md                          This document
├── PLAN.md                            Technical plan of record
├── PLAN.txt                           Plain-language companion to PLAN.md
├── QUIC-research-base.md              Background literature and gap analysis
├── CC-adaptation-candidates-survey.md Survey of candidate CC algorithms
│
├── data/
│   ├── survey_results.json            SINGLE SOURCE OF TRUTH for every claim
│   └── upstream_commits.txt           The five pinned upstream commits
│
├── code/
│   ├── analysis/                      Figure and deck generators; qlog parsers
│   ├── audits/                        Re-runnable source audits (per implementation)
│   ├── validation/                    Independent validator + its recorded output
│   ├── testbed/
│   │   ├── topology/                  Namespace and veth construction
│   │   ├── shaping/                   tc/tbf/netem application
│   │   ├── calibration/               The three calibration gates
│   │   └── scenarios/                 Migration trials, per implementation
│   ├── harness/                       Our own clients and servers
│   ├── qa/                            Deliverable verification (geometry, content, render)
│   ├── build/                         Environment setup, bundling, publishing
│   └── patches/
│       └── picoquic_spec_reset.diff   Our own §9.4 implementation (Phase 1)
│
├── phase1-deliverables/               Review deck, script, experiment log, evidence
└── phase2-deliverables/               Review deck, script, experiment log, evidence
    └── evidence/                      123-file submission bundle (survey data,
                                       audits, live measurements, validation,
                                       code, sample traces)
```

**`data/survey_results.json` is authoritative.** Every figure, table, slide and
number in this repository is generated from it, including the corrections
recorded under `_correction_*` keys. If a document and that file disagree, the
file is right and the document is a bug.

Upstream implementations are **not** vendored. They are pinned by commit in
`data/upstream_commits.txt`.

---

## 10. Limitations and claims not made

1. **No claim of user-visible harm.** This work measures what implementations do
   and what it costs in a controlled testbed. Whether that matters at internet
   scale is a separate study.
2. **Emulation only.** No real handsets, no real cellular networks, no real
   handover events.
3. **One configuration per implementation.** One commit, one congestion-control
   algorithm, one path-delay pair, one direction of transfer. Behaviour may differ
   elsewhere.
4. **"Does not comply" means against our reading of the quoted RFC text.** Some
   behaviours may be defensible under a different reading, and where such a
   reading is known it is stated.
5. **msquic's stuck-RTT result (F6) is an observation, not a diagnosis.** The
   mechanism is unexplained and an instrumented build is required to establish it.
6. **These are moving projects.** Each was tested at one commit, recorded in
   `data/upstream_commits.txt`.

---

## 11. Record of corrections

Six claims did not survive the validation pass. All six had already been written
down before they were caught. They are recorded here, and in the data file under
`_correction_*` keys with their reasoning, so that they are not reintroduced.

| Claim as originally written | Status | Correction |
|---|---|---|
| "picoquic's window stayed flat at 241,174 B" | **Wrong** | It declined 241,174 → 146,592 → 123,888 B through ordinary loss. The conclusion was unaffected — it never took the initial window, so no reset occurred — but "flat" overstated the evidence. |
| "picoquic's new path had a true RTT of 60 ms" | **Wrong** | That figure belongs to the step-down experiment (path B at 20 Mbit/60 ms) and had been copied into the live record by mistake. The run in question was shaped at 20 ms / 40 ms — confirmed by its own shaping logs and by its qlog settling at 41.9 ms. Corrected to 40 ms. |
| Parser verdict: "cwnd reached the initial window → RESET OCCURRED" | **Wrong** | The test was `min_cwnd <= initial × 1.05`, i.e. *at or below* the initial window. A window **below** the initial value cannot have been set by a reset, which assigns that value exactly — falling below it is the signature of a loss cascade. The defect was latent while picoquic ran at 50 Mbit, where the cascade never reached the floor; at 20 Mbit it fired on all five repetitions. The test now requires an exact hit. An early version of the independent validator shared the same flawed assumption and was corrected with it. |
| "quic-go, four repetitions" | **Wrong** | Three. The trial script hardcoded its output directory and later repeats overwrote earlier ones. Resolved by re-running five fresh repetitions through an archiving wrapper. |
| "msquic's client window stayed flat, therefore the client does not reset" | **Too weak** | In a download the client is acknowledgement-only, so a flat window is expected either way. The claim is true but rests on the source audit; the live trace only corroborates. |
| "msquic's RTT stays stuck because its path gate never re-opens" | **Unsupported** | `path.c:29` assigns each new path a fresh identifier, so the gate should open. Withdrawn; the mechanism is unknown and F6 is now reported as an observation only. |

The general lesson, recorded because it generalises: *a claim that agrees with
what you expected is the one to re-check hardest.*

---

## 12. References

- **RFC 9000** — QUIC: A UDP-Based Multiplexed and Secure Transport. §9.4
  (Connection Migration and Loss/Congestion Control), §8.2 (Path Validation).
- **RFC 9002** — QUIC Loss Detection and Congestion Control. §6.2.2 (Initial RTT),
  §7.2 (Initial Congestion Window), Appendix A.3.
- **draft-ietf-tsvwg-careful-resume** — Careful Resume for congestion control.
  Explicitly excludes the path-change case, which is the gap this work occupies.

Surveyed implementations, pinned in `data/upstream_commits.txt`:
[picoquic](https://github.com/private-octopus/picoquic) ·
[quic-go](https://github.com/quic-go/quic-go) ·
[quiche](https://github.com/cloudflare/quiche) ·
[msquic](https://github.com/microsoft/msquic) ·
[ngtcp2](https://github.com/ngtcp2/ngtcp2)
