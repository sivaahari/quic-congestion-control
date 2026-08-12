# Congestion Control at QUIC Connection Migration: What Implementations Actually Do
## Technical Plan of Record

> **v2.0 — DIRECTION CHANGED 2026-08-05.** This project was originally framed around proposing a mechanism (**PV-Seed**: seeding congestion control from path-validation measurements). An audit of that novelty found it too weak to carry a paper — see §4.0. The project is now **measurement-led**: a cross-implementation study of what QUIC stacks actually do to congestion control at migration, and what each choice costs. PV-Seed survives as a proof-of-concept section (§6), not the thesis.
>
> Sections describing the testbed, calibration, RFC analysis, and picoquic internals (§2, §8–§10) were validated during Phase 1 and carry forward unchanged. Read §4.0 before proposing any return to the mechanism framing.

**Document status:** Plan of record, v2.0
**Date:** 2026-07-14 (v1.0) · 2026-08-05 (v2.0)
**Project:** Capstone research paper, SEM-5 Computer Networks
**Author (human):** sivaahari (cb.sc.u4cys24055@cb.students.amrita.edu)
**Artifact repository:** https://github.com/sivaahari/quic-congestion-control

---

## 0. Document Purpose and Reading Instructions

This document is the authoritative technical context for the project. It is written to be consumed by AI agents joining the work mid-stream, and by the human author as an implementation reference. It assumes no prior conversation context.

**How to use this document:**
- Sections 1–5 establish *what* is being built and *why it is novel*. Read these before proposing any change to scope.
- Sections 6–7 define *the mechanism and its mathematics*. This is the intellectual core; do not deviate without recording the reason.
- Sections 8–10 define *implementation and evaluation*. These are expected to evolve as reality intrudes; update in place and note the date.
- Section 11 onward covers process: schedule, repo conventions, risks, open questions.

**Companion documents in this directory:**
- `QUIC-research-base.md` — the original domain survey and literature matrix (2021–2026) that produced this project.
- `CC-adaptation-candidates-survey.md` — the congestion-control candidate survey (16 entries, tiered A/B/C) underpinning Section 6.5 and Section 6.6.
- `PLAN.txt` — the same plan in non-technical, analogy-driven prose. Content is equivalent; do not treat it as a separate source of truth. If the two disagree, this file wins.

**Hard constraints established by the author (do not violate):**
- Implementation language: C. Vehicle: picoquic.
- Evaluation: emulation only. No real-device or over-the-air experiments are expected.
- Environment: WSL2 on Windows 11 preferred; Ubuntu VM is an approved fallback.
- Git identity for all commits: name `sivaahari`, email `cb.sc.u4cys24055@cb.students.amrita.edu`.
- **No co-author trailers on any commit.** Do not append `Co-Authored-By:` lines. This overrides any default agent commit convention.

---

## 1. Project Identity

**Domain:** QUIC performance under mobile handover.

**Selected gap (originally "D3", now effectively "D2"):** RFC 9000 §9.4 states that an endpoint **MUST** reset its congestion controller and RTT estimator when a connection migrates to a new path. Nobody has measured whether implementations actually do this, or what it costs when they do and don't.

**One-line problem statement:**

> RFC 9000 §9.4 requires a QUIC endpoint to reset its congestion controller on connection migration, but no study has measured whether implementations comply, how they diverge, or what each behaviour costs; we survey five widely-used QUIC stacks against three concrete compliance questions, quantify the performance consequence of each choice in a calibrated emulation testbed, and show that *partial* compliance with §9.4 is materially worse than ignoring it.

**Compressed form (for abstract/slides):** *The standard says reset. We checked whether anyone does — and found that doing it halfway breaks connections outright.*

**The two findings already in hand (Phase 1, verified):**
- **F1.** picoquic does not perform the §9.4 reset in single-path operation. The reset hook is implemented by all seven of its congestion-control algorithms and dispatched by nothing. Verified four ways, then re-verified against pristine upstream source.
- **F2.** Implementing §9.4's second paragraph without its first is catastrophic: transfer completion fell from 5/5 to 0/15. Stale acknowledgements from the old path re-seed the freshly cleared RTT estimator, pacing slow start ~3× too fast for the new path.

---

## 2. Background: The Specification Facts

These are load-bearing. All are verified verbatim against the RFC text (RFC 9000 downloaded and grepped locally, not paraphrased from secondary sources). Any agent revisiting the premise should re-verify rather than trust a summary.

### 2.1 RFC 9000 §9.4 — the mandated reset

> "The capacity available on the new path might not be the same as the old path. Packets sent on the old path MUST NOT contribute to congestion control or RTT estimation for the new path.
>
> On confirming a peer's ownership of its new address, an endpoint **MUST immediately reset the congestion controller and round-trip time estimator for the new path to initial values** (see Appendices A.3 and B.3 of [QUIC-RECOVERY]) **unless the only change in the peer's address is its port number**. Because port-only changes are commonly the result of NAT rebinding or other middlebox activity, the endpoint MAY instead retain its congestion control state and round-trip estimate in those cases instead of reverting to initial values. In cases where congestion control state retained from an old path is used on a new path with substantially different characteristics, a sender could transmit too aggressively until the congestion controller and the RTT estimator have adapted. Generally, implementations are advised to be cautious when using previous values on a new path."

Two observations that define the entire project:

1. The reset is a **MUST**, not a SHOULD. The amnesia is mandated, not incidental. This *strengthens* the motivation (it is not an implementation oversight, it is the specified behaviour) and simultaneously constrains the design space (we cannot simply carry state over and claim compliance).
2. The normative object is the phrase **"initial values."** The RFC constrains *that* the controller be reset to initial values; it does not fix what those initial values numerically are for a path about which evidence exists. This is the seam the project works in.

### 2.2 RFC 9002 §6.2.2 — the precedent for informed initial values

> "A connection MAY use the delay between sending a PATH_CHALLENGE and receiving a PATH_RESPONSE to set the initial RTT (see kInitialRtt in Appendix A.2) for a new path, but the delay SHOULD NOT be considered an RTT sample."

The specification **already** blesses deriving one of the two relevant initial values from the path-validation exchange — the RTT. It does not do so for the congestion window. That asymmetry is the gap.

Compliance note for our design: "SHOULD NOT be considered an RTT sample" means the measurement must not be fed into the `smoothed_rtt` / `rttvar` sample-update path (which would corrupt PTO computation). It may be used to *initialize* `kInitialRtt` for the path. PV-Seed complies by assigning to the initial-value slot, never invoking the sample-update routine.

### 2.3 RFC 9002 §7.2 — the initial window is only a SHOULD

> "Endpoints SHOULD use an initial congestion window of ten times the maximum datagram size (max_datagram_size), while limiting the window to the larger of 14,720 bytes or twice the maximum datagram size."

The initial congestion window carries **SHOULD** strength, and the value is explicitly a heuristic inherited from RFC 6928. A well-justified, measurement-derived, safety-gated deviation is exactly the kind of change the IETF entertains — and has already accepted once, in Careful Resume (§4.1).

### 2.4 RFC 9000 §8.2 — path validation packets are, by mandate, full-sized

> §8.2.1: "An endpoint MUST expand datagrams that contain a PATH_CHALLENGE frame to at least the smallest allowed maximum datagram size of 1200 bytes, unless the anti-amplification limit for the path does not permit sending a datagram of this size."
>
> §8.2.2: "An endpoint MUST expand datagrams that contain a PATH_RESPONSE frame to at least the smallest allowed maximum datagram size of 1200 bytes. This verifies that the path is able to carry datagrams of this size in both directions. However, an endpoint MUST NOT expand the datagram containing the PATH_RESPONSE if the resulting data exceeds the anti-amplification limit."
>
> §8.2.2: "An endpoint MUST NOT send more than one PATH_RESPONSE frame in response to one PATH_CHALLENGE frame... The peer is expected to send more PATH_CHALLENGE frames as necessary to evoke additional PATH_RESPONSE frames."

This is the enabling mechanism and it is worth stating plainly: **the specification mandates that path validation traffic consists of full-MTU datagrams, in both directions, with a strict one-response-per-challenge relationship, and explicitly anticipates multiple challenges.** A back-to-back sequence of *K* PATH_CHALLENGE frames therefore elicits *K* full-sized, individually-triggered response datagrams. That is, by construction, a packet train — the classical instrument for bottleneck capacity estimation — running on the new path before a single byte of application data has been committed to it. No specification change is needed to *emit* it.

### 2.5 RFC 9000 §9.4 — probe packets are exempt from congestion control accounting

> "A sender can make exceptions for probe packets so that their loss detection is independent and does not unduly cause the congestion controller to reduce its sending rate."

Path-validation traffic does not have to be gated by the (currently empty) congestion window. Corroborated by an in-the-wild implementation fix: nginx PR #795 explicitly changed PATH_CHALLENGE emission so it is not deferred when the congestion window is full, because deferral was slowing migration. Our probe train is thus consistent with both the spec and deployed practice.

### 2.6 Anti-amplification (RFC 9000 §8)

An endpoint MUST NOT send more than three times the bytes received from an unvalidated address. This bounds the length of a *server-initiated* challenge train on a freshly migrated client address, and is a first-class design constraint (see §6.2.4). It does **not** constrain a client sending toward an already-validated server address.

---

## 3. The Gap, and Why It Is Still Open

### 3.1 What exists

| Work | What it seeds | Across what | Status |
|---|---|---|---|
| Careful Resume (draft-ietf-tsvwg-careful-resume-24) | cwnd, RTT | **Time**: previous connection → new connection, *same path* | IESG-approved, Proposed Standard |
| Blitz-start (arXiv 1905.03144) | initial window aggressiveness | Start of a fresh connection | Research |
| RFC 9002 §6.2.2 MAY | RTT only | New path, same connection | Standard, optional, unmeasured deployment |
| **PV-Seed (this work)** | **cwnd + bandwidth model + RTT** | **Space**: same connection, *new path* | **Unoccupied** |

### 3.2 The decisive finding

Careful Resume is the closest relative and it **explicitly excludes our case**:

> "If the Remote Endpoint is not the same as any saved_remote_endpoint, or the sender receives a signal from the local stack indicating that the path is now different to the observed path, the sender MUST stop using Careful Resume."

The reason is sound: on a *new* path, retained state from an *old* path is not evidence. Careful Resume therefore has nothing to offer at a handover — precisely the moment a mobile user most needs it. PV-Seed resolves this not by trusting stale state, but by **generating fresh, path-specific evidence** from an exchange the protocol was already going to perform. The safety machinery Careful Resume built is fully reusable once the input is re-sourced.

### 3.3 Prior-art clearance (checked, negative)

- **draft-paulo-quic-migration-00** (Rui Paulo, Apple, 2019, expired): notes that PATH_CHALLENGE→PATH_RESPONSE timing yields the new path's RTT, and mentions PATH_CHALLENGE+PADDING for MTU discovery — but explicitly *recommends resetting* the congestion controller ("endpoints reset their congestion controller and don't have to deal with packet loss"). It proposes no capacity estimation and no seeding. Closest near-miss; must be cited and distinguished.
- **Seemann, "Exploiting QUIC's Path Validation" (2023):** uses the same frames adversarially (PATH_CHALLENGE flood → PATH_RESPONSE queue exhaustion DoS). Establishes that the community has examined these frames' side effects — for attack, not for measurement. Cite as evidence the mechanism is understood but unexploited constructively; also a source of a safety constraint (unbounded response queuing is a known hazard, so our train length must be bounded and our design must not worsen it).
- **nginx PR #795 (2025-ish):** an implementation-level fix to PATH_CHALLENGE scheduling. Confirms migration-time probe scheduling is an active engineering concern, and that probes are treated as CC-exempt.
- **quic-go issue #5580:** production report that reordering during slow start causes premature slow-start exit that caps throughput for the lifetime of long-lived connections. Direct empirical support for the "post-migration ramp is fragile, not merely slow" argument.
- **CQUIC (WCNC 2020), CQIC (HotMobile 2015):** cross-layer capacity hints from the radio. Requires vendor/modem privilege; optimizes the migration *decision*, not post-migration CC state.
- **PBQ-enhanced QUIC (2023), Orca (SIGCOMM 2020):** learned CC. Same symptom, heavyweight and opaque solution.
- **draft-ietf-quic-multipath:** per-path congestion controllers. Establishes the "new path needs its own CC state" framing; does not address how to initialize it. **PV-Seed is directly applicable to MPQUIC path addition** — note as extended applicability / future work.

**Conclusion:** the specific claim — *use the mandatory path-validation exchange as a capacity measurement instrument to initialize post-migration congestion state, under a formal safety envelope* — is unclaimed.

---

## 4. Novelty Claims (enumerated and defensible)

### 4.0 Why the mechanism framing was abandoned — read this first

An audit on 2026-08-05, prompted by the author asking whether the research was worth pursuing, found the original PV-Seed novelty could not carry a paper. Three independent problems:

1. **The RTT half is not novel.** RFC 9002 §6.2.2 explicitly permits using the PATH_CHALLENGE→PATH_RESPONSE delay to set a new path's initial RTT. It is known, it is used in real implementations, and picoquic already implements it (`frames.c:4943`) — merely gated inert for the single-path migration case. The "the specification forces you to discard this" framing was **overstated**: that door is already open.
2. **The capacity half is novel but fragile.** Probe-train dispersion measures `min(C_fwd, C_rev)` — the wrong quantity for downloads, the common case. Fixing it requires a wire extension. Anti-amplification caps train length. Whether receiver batching preserves the spacing is untested. And packet-pair dispersion is unreliable under cross traffic (Dovrolis, INFOCOM 2001) — untestable in an emulation-only project.
3. **The impact ceiling is modest.** Recovery costs ≈ log₂(BDP/IW) RTTs ≈ **80–250 ms per handover**. Careful Resume reached Proposed Standard because the same arithmetic yields 5+ seconds on GEO satellite links — so PV-Seed's benefit is largest exactly where a standard already exists, and smallest in the mobile handover case targeted here. SIGCOMM CCR 2025 further shows most servers refuse migration entirely, shrinking the beneficiary population.

**Retained conclusion:** the strongest results are the ones found *while building* the mechanism — F1 and F2 in §1. Those are measurement findings about deployed behaviour. The paper is now built on them.

### 4.1 Claims

These are the claims the paper will make. Each is falsifiable and each maps to a section of the evaluation.

- **M1 (Compliance survey).** The first cross-implementation measurement of congestion-control behaviour at QUIC connection migration, covering picoquic, quic-go, quiche, msquic and ngtcp2 against three questions: (a) is the congestion controller reset on migration as §9.4 requires? (b) is the RFC 9002 §6.2.2 initial-RTT option exercised? (c) are old-path acknowledgements correctly excluded from the new path's estimators?
- **M2 (A MUST violated).** picoquic does not perform the §9.4 reset in single-path operation — the default configuration and the one standard migration uses. Evidenced by static analysis against pristine upstream and by live qlog.
- **M3 (Partial compliance is harmful).** Implementing §9.4 ¶2 without ¶1 reduces transfer completion from 5/5 to 0/15. This is a non-obvious, actionable systems result: the rule is subtle enough that a careful implementation attempt made things dramatically worse.
- **M4 (Cost quantification).** The performance consequence of each observed behaviour, measured across a controlled step-up/step-down handover grid in a calibrated testbed.
- **M5 (Methodology).** A validated emulation testbed for migration experiments, including two documented emulator artefacts (token-bucket burst masking, short-train contamination) that would silently invalidate results, with the calibration procedure that detects them.
- **M6 (Artifact).** Open testbed, harness, analysis tooling, and an RFC 9000 §9.4-compliant reset implementation for picoquic, which the project contributes back.

**Legacy mechanism claims (N1–N8 in v1.0)** are retained below for reference and remain factually correct, but are demoted: N8 is now **M2**, and the PV-Seed mechanism claims become future work (§6).

- **N1 (Framing).** Identification and quantification of a specification-mandated information-discard: QUIC performs a measurement on every new path and RFC 9000 requires the congestion controller to ignore it. Quantified by the S0 baseline curves (§10).
- **N2 (Analysis).** A formal characterization of what a *reflected* path-validation train can and cannot measure — specifically the min-direction result (§6.2.3): a reflected train's dispersion is governed by the narrower of the two directions, regardless of which endpoint initiates. This determines which deployment variants are viable and is, to our knowledge, unstated in the QUIC literature.
- **N3 (Mechanism, zero-extension).** PV-Seed-R: a unilateral, wire-compatible sender-side mechanism requiring **no** protocol extension, no peer cooperation, and no negotiation — deployable against unmodified peers today.
- **N4 (Mechanism, extension).** PV-Seed-X: a single-frame, transport-parameter-negotiated extension enabling the receiver to report forward-path dispersion, resolving the asymmetry N2 exposes for the download direction. Shaped to be submittable as an IETF Internet-Draft.
- **N5 (Safety).** Adaptation of the Careful Resume safety envelope (Unvalidated → Validating → Safe Retreat) from the temporal case, which the draft supports, to the spatial case, which the draft explicitly forbids — with re-derived abandon conditions appropriate to measured rather than retained evidence.
- **N6 (Generality).** A CC-agnostic seeding interface implemented across three structurally different controllers (NewReno: window-only; CUBIC: window + loss-epoch anchor; BBR: explicit rate/RTT model), demonstrating that the seeding contract is not tied to one algorithm's internals.
- **N7 (Artifact + measurement).** Open implementation in picoquic plus a systematic characterization of post-migration recovery cost across a bandwidth × RTT × asymmetry × buffer × handover-style grid, including the first measurement of whether deployed stacks implement the RFC 9002 §6.2.2 RTT MAY at all.
- **N8 (Compliance finding — added 2026-08-03, Phase 1).** picoquic does not implement the RFC 9000 §9.4 **MUST**-reset on connection migration: the reset notification is a dead hook with zero callers, and live qlog confirms the congestion window survives an IP-changing migration unchanged. It therefore performs, by default, precisely the blind carry-over the RFC warns "could transmit too aggressively." This reframes the whole contribution: **both** pathological extremes exist in the wild — spec-mandated blind reset (wasteful) and deployed blind carry-over (unsafe) — and PV-Seed is the evidence-based middle. The safety argument stops being synthetic, because the dangerous arm is a real implementation's default rather than a strawman. Extends naturally to a multi-stack compliance survey (quic-go, quiche, msquic, ngtcp2).

**Minimum publishable core:** N1 + N3 + N5 + N6 + N7 + N8 (emulation). N2 is analysis and costs nothing extra. N4 is the stretch that turns a workshop paper into a draft-shaped contribution.

---

## 5. Threat to the Premise (state honestly, address explicitly)

A reviewer will ask: *"Modern CC algorithms adapt within a few RTTs. Is the post-migration ramp actually expensive enough to warrant a mechanism?"* The plan must answer with data, not assertion.

- **Analytical cost.** Slow start needs ≈ log₂(BDP / IW) round trips to reach the path's BDP. For a 100 Mbps × 50 ms path: BDP ≈ 625 KB ≈ 520 × 1200 B packets; IW = 10 packets; so ≈ log₂(52) ≈ 5.7 RTTs ≈ 285 ms of below-capacity transmission — per handover. The integral of the throughput deficit over that window is the quantity we reduce.
- **Fragility, not just slowness.** quic-go #5580 documents that reordering during slow start triggers premature exit into congestion avoidance, capping throughput for the *lifetime* of the connection. Migration is precisely a reordering event (RFC 9000 §9.4 warns of "apparent reordering at the receiver... during the migration period"). So the realistic cost is often worse than the clean-path analytical model.
- **The honest ablation.** We include Copa as a host CC specifically because it re-converges quickly by design. If PV-Seed's advantage largely evaporates under Copa, that is a finding, and it must be reported. The paper is stronger for having asked.
- **Bounding the claim.** The mechanism's value scales with BDP and with handover frequency. We will state the regime where it matters (high-BDP paths, frequent handovers, medium-to-large transfers) and the regime where it does not (small objects that finish inside the initial window; low-BDP paths). Overclaiming universality is the fastest way to lose a reviewer.

---

## 6. Mechanism Design: PV-Seed

### 6.1 Overview

At the instant a QUIC endpoint validates a new path, PV-Seed:

1. **Probes** — emits a bounded, back-to-back train of *K* padded PATH_CHALLENGE frames (legal per §2.4, CC-exempt per §2.5, length-bounded per §2.6).
2. **Measures** — timestamps the resulting PATH_RESPONSE arrivals, deriving a minimum-RTT estimate and a dispersion-based rate estimate with an associated confidence score.
3. **Gates** — accepts the estimate only if confidence and sanity checks pass; otherwise degrades down a ladder to weaker but safer strategies.
4. **Seeds** — initializes the new path's congestion state from the accepted estimate via a CC-agnostic interface (per-algorithm adapters).
5. **Validates** — sends the first post-migration data under a paced, monitored Unvalidated phase; any congestion signal triggers Safe Retreat to specification-default behaviour.

The fallback of last resort is byte-for-byte the RFC 9000 §9.4 mandated behaviour. **The mechanism's worst case is the status quo.** This property should be stated in the abstract; it is the strongest deployability argument available.

### 6.2 The measurement primitive

#### 6.2.1 Train construction

- Train length *K*: **≥ 8 probes (12 preferred); K = 5 is ruled out.** Originally specified as 5–8; corrected 2026-08-03 by the Phase-0 train-length sweep. A token bucket passes `floor(burst / wire_bytes)` packets unshaped, contaminating that many leading gaps; at the calibrated `burst = 3200 B` that is 2 gaps, which is 50% of the 4 gaps a K=5 train yields — enough to break the median (measured error +56%, IQR/median 25–174). K=8 with `discard_leading = 2` measures within 1% at 20/50/100 Mbit. Must still be bounded (see §2.6 and the DoS precedent in §3.3).
- **Anti-amplification consequence (hardened).** K=8 padded challenges = 9600 B, so under the 3× rule the server needs ≥3200 B received from the client first. A single 1200 B migration packet permits only 3 challenges. The client-side priming mitigation in §6.2.4 is therefore **required, not optional**.
- Each PATH_CHALLENGE is emitted in its own datagram, padded to exactly the same size (≥1200 B, and identical across the train — equal packet size is a precondition for dispersion arithmetic).
- Packets are emitted back-to-back with pacing **disabled for the train** (a paced train measures our own pacer, not the path — this is a trap worth writing into the code as a comment).
- Each challenge carries distinct 8-byte entropy so responses are individually attributable; the implementation must retain a `(challenge_data → send_timestamp, sequence_index)` map.

#### 6.2.2 Timestamps and RTT

- For each *i*, measure `d_i = t_response_i − t_challenge_i`.
- `RTT_pv := min_i d_i`. The minimum is used, not the mean: later probes in the train experience self-induced queueing at the bottleneck, so their delays are inflated by construction. The minimum is the least-biased estimator of path minimum RTT available from a self-congesting train.
- `RTT_pv` initializes the path's initial RTT. Per §2.2, it is assigned to the initial-value slot and **must not** be pushed through the RTT-sample update path.

#### 6.2.3 The reflection result (Claim N2)

Let the two directions of the new path have bottleneck capacities `C_fwd` (initiator → responder) and `C_rev` (responder → initiator), and let all probe and response datagrams have equal size `L`.

A train emitted back-to-back by the initiator is dispersed by the forward bottleneck to spacing `L / C_fwd` on arrival at the responder. The responder emits exactly one response per challenge; assuming responses are generated on arrival, they inherit that spacing. Traversing the reverse path, the reverse bottleneck can only *increase* spacing (to `L / C_rev`) and never decrease it. The initiator therefore observes:

```
Δ_observed  ≈  max( L / C_fwd , L / C_rev )
B̂           =  L / Δ_observed  ≈  min( C_fwd , C_rev )
```

**A reflected path-validation train measures the minimum of the two directional capacities, irrespective of which endpoint initiates it.**

Consequences, and they shape the entire deployment story:

- **Client is the data sender (upload).** The client needs `C_up`. On mobile access links `C_up < C_down` typically, so `min(C_up, C_down) = C_up`. The reflected estimate is *the correct quantity*. PV-Seed-R works natively and accurately here.
- **Server is the data sender (download — the common web case).** The server needs `C_down`, but a reflected train yields `min ≈ C_up`, an underestimate (5–10× on typical cellular asymmetry). This is **safe but conservative**: seeding to `C_up × RTT` still vastly exceeds a 10-packet initial window, so PV-Seed-R remains a large improvement over S0 while never being aggressive. It is, however, leaving most of the benefit on the table — which motivates N4.
- **Resolution (PV-Seed-X, N4).** The *responder* can measure the forward train's arrival dispersion directly and locally — that measurement is of `C_fwd`, exactly what the sender needs — and report it in a small extension frame. One frame, negotiated by transport parameter, closes the gap.

**A second-order hazard that must be measured, not assumed:** the derivation above requires the responder to generate each PATH_RESPONSE upon arrival of its challenge. A stack that reads a batch of datagrams in one event-loop iteration and emits all responses together destroys the inherited spacing, collapsing the observation to the reverse-path rate alone. Whether picoquic (and other stacks) preserve inter-packet spacing under batched I/O (`recvmmsg`, GSO/GRO) is an **empirical question with a Phase-2 experiment attached** (§9.4). If reflection turns out to be uninformative in practice, that is a legitimate and publishable negative result that *further* motivates the extension, and the paper must present it as such rather than burying it.

#### 6.2.4 Anti-amplification interaction

A server probing a freshly migrated client address may send at most 3× the bytes received from that address. If the client's migration is signalled by a single ~1200 B non-probing packet, the server's budget is ~3600 B ≈ 3 datagrams — too short a train for a stable estimate.

Mitigations, in order of preference:
1. **Client-side priming (legal, unilateral).** On migrating, the client immediately emits a few padded datagrams (its own PATH_CHALLENGE train, or PING+PADDING) from the new address. This is independently useful (it validates the path in the client's direction) and raises the server's amplification budget as a side effect.
2. **Deferred second train.** RFC 9000 §8.2.1 already anticipates a second, expanded validation once the budget allows; PV-Seed can attach its measurement to that second train.
3. **Accept short trains with widened confidence intervals** — i.e., let the confidence gate (§6.4) reject rather than special-case.

This interaction is worth a subsection in the paper; it is exactly the kind of protocol-detail reasoning that distinguishes a transport paper from a simulation exercise.

### 6.3 Estimator mathematics

Given arrival timestamps `t_1 … t_K` of equal-size responses (size `L` bits):

**Pairwise dispersion estimates:**
```
b_i = L / (t_{i+1} − t_i),      i = 1 … K−1
```

**Point estimate — median, not mean:**
```
B̂ = median{ b_i }
```
The median is chosen over the mean for robustness to single-packet outliers (a scheduling hiccup, an interrupt-coalescing artefact, a cellular grant boundary). The alternative *asymptotic dispersion rate* `B̂_ADR = (K−1)L / (t_K − t_1)` will be computed and logged in parallel, since Dovrolis et al. (INFOCOM 2001) show ADR and capacity diverge under cross traffic; reporting both lets us characterize the divergence rather than silently pick one. Under cross traffic, dispersion estimators generally measure something between available bandwidth and capacity — for seeding purposes an available-bandwidth-leaning estimate is *preferable*, and this should be argued explicitly rather than treated as estimator error.

**Dispersion of the estimates (confidence input):**
```
IQR = Q3{b_i} − Q1{b_i}
CV_robust = IQR / median{b_i}
```

**Bandwidth-delay product and the seed:**
```
BDP_est   = B̂ × RTT_pv
cwnd_seed = clamp( α · BDP_est , IW , min(cap_abs, cap_rel, fc_limit) )
```
where:
- `α ≤ 0.5` — the fraction of the estimated BDP taken on the jump. Careful Resume uses a jump to half the saved window; matching α = 0.5 keeps us no more aggressive than an IESG-approved mechanism, which is a defensible default and a strong rhetorical position.
- `IW` — the RFC 9002 §7.2 initial window; the seed is never *smaller* than spec default.
- `cap_abs` — an absolute ceiling in packets, guarding against a wildly wrong estimate.
- `cap_rel` — a ceiling relative to the *old* path's observed window/rate (e.g. κ × old_cwnd_max). Rationale: a handover between real access networks rarely produces an order-of-magnitude capacity increase; a seed implying one is more likely an estimator artefact than a genuine windfall.
- `fc_limit` — the peer's flow-control credit. **A seed exceeding available flow control is inert**; the testbed must configure large `max_data`/`max_stream_data` or the entire experiment silently measures flow control instead of congestion control. This is a classic and embarrassing failure mode; it goes in the Phase-0 checklist.

**Analytical targets to derive for the paper (Section 7 work items):**
- Recovery time under S0: `T_recover ≈ RTT · log₂(BDP / IW)` (slow start), with the congestion-avoidance variant for the case where slow start exits early.
- Byte deficit: `D = ∫₀^{T_recover} ( min(C, achievable) − rate(t) ) dt`, closed form under the geometric slow-start model, giving predicted savings as a function of (C, RTT, IW, α).
- Overshoot bound: with pacing at `α·B̂` and abort within one RTT of the first congestion signal, the excess bytes injected beyond true capacity are bounded by ≈ `(α·B̂ − C_true)⁺ · RTT_pv`; combined with the `cap_rel` clamp this yields a worst-case queue occupancy bound to compare against the emulated buffer depth.
- Sensitivity: `∂cwnd_seed / ∂B̂` and the resulting overshoot as a function of estimator relative error — this determines how accurate the estimator actually has to be, and may well show that ±50% accuracy suffices, which would be a reassuring result to report.

### 6.4 Confidence gate and the degradation ladder

The seed is applied only if **all** hold:
- `K_responses ≥ K_min` (default 4) — enough samples for a median.
- `CV_robust ≤ θ_cv` (default 0.3, to be calibrated in Phase 2).
- `B̂` within absolute sanity bounds (e.g. 0.5 Mbps … 10 Gbps) — rejects arithmetic pathologies and zero/negative intervals.
- `RTT_pv` within sanity bounds and not absurdly below the old path's minimum RTT (mirrors Careful Resume's `< 50% of saved_rtt` abandon condition).
- Flow-control credit ≥ the intended seed (else clamp and record).

**Degradation ladder** (each rung is also an independently evaluated design point):
```
S3x  probe-train capacity seed (extension-reported forward dispersion)   [most informed]
S3r  probe-train capacity seed (reflected, min-direction)
S2   similarity-gated partial carry-over from the old path
S1   RTT-only seed (the RFC 9002 §6.2.2 MAY)
S0   RFC 9000 §9.4 mandated blind reset                                  [spec default]
```
Each rung's failure falls to the next. Because S0 terminates the ladder, **PV-Seed can never behave worse than an unmodified stack when its evidence is bad** — only when its evidence is *wrong but confident*, which is what the Validating phase and Safe Retreat exist to catch.

### 6.5 Seeding adapters per congestion controller (Claim N6)

A single interface, three adapters. The interface (added to picoquic's CC algorithm vtable):

```c
/* Applied at path-validation completion, in place of the default reset. */
void (*seed)(picoquic_path_t *path,
             uint64_t seed_cwnd_bytes,     /* clamped per §6.3            */
             uint64_t seed_rate_bps,       /* B̂                           */
             uint64_t seed_rtt_us,         /* RTT_pv                      */
             pvseed_confidence_t conf);    /* accepted / degraded / none  */
```

**NewReno adapter (reference case).** State is `{cwnd, ssthresh}`. Set `cwnd = seed`, `ssthresh = seed` — entering congestion avoidance immediately at the seeded window rather than slow-starting to it. Simplest possible demonstration that the interface is meaningful.

**CUBIC adapter.** State is `{cwnd, ssthresh, W_max, epoch_start, K}`. Set `cwnd = ssthresh = seed`, and `W_max = seed`, resetting the epoch. Setting `W_max` to the seed places CUBIC at its plateau, so its concave region provides a *cautious approach to the estimated capacity* for free — the algorithm's own shape does the safety work. This synergy is worth a paragraph in the paper. Careful Resume's picoquic implementation targets CUBIC, so there is precedent code to follow.

**BBR adapter (flagship).** State includes `BtlBwFilter` (windowed max of delivery rate) and `RTpropFilter` (windowed min of RTT). Seeding means injecting `B̂` into the bandwidth filter and `RTT_pv` into the RTprop filter, setting `pacing_rate = pacing_gain × B̂` and `cwnd = cwnd_gain × B̂ × RTT_pv`, then entering ProbeBW (or a truncated STARTUP anchored at `B̂`) instead of a from-scratch STARTUP.

> **Critical subtlety, do not lose this.** BBR's `BtlBwFilter` is a *windowed maximum* over ~10 round trips. An over-estimated seed injected into a max-filter **persists for ten round trips even after contradicting evidence arrives** — the failure mode is far more durable than in a window-based CC. The adapter must therefore either (a) tag the seeded sample with a short expiry so it can be evicted early, or (b) flush the filter on the first Safe Retreat trigger. Implement (b) at minimum; (a) is cleaner. This asymmetry between window-based and model-based controllers is itself an interesting finding for the paper's discussion section.

### 6.6 Safety phase machine (Claim N5)

Adapted from Careful Resume's five phases, re-sourced from measured rather than retained evidence:

| Phase | Careful Resume (temporal) | PV-Seed (spatial) |
|---|---|---|
| Observe | record capacity on a previous connection | **replaced**: run the probe train during path validation |
| Reconnaissance | send IW, confirm path/RTT similarity to saved | confirm estimator confidence gate (§6.4) |
| Unvalidated | jump to `saved_cwnd/2`, paced | jump to `α · B̂ · RTT_pv`, paced at `α·B̂` |
| Validating | confirm the jump caused no congestion | identical: monitor for loss / ECN-CE / RTT-slope |
| Safe Retreat | collapse to IW, set ssthresh guard | identical, plus BBR filter flush (§6.5) |

**Abandon triggers during Unvalidated/Validating:**
- Any lost packet attributable to the new path.
- Any ECN-CE mark (enable ECN in the testbed where possible — it is the cleanest early signal).
- HyStart++ (RFC 9406) style RTT-slope detection: if the round-trip minimum rises beyond a threshold fraction over the pre-seed baseline within the first monitored round, the seed overshot. Reusing a standardized heuristic here rather than inventing one is deliberate — it reduces the number of novel knobs a reviewer must accept.

On abandon: collapse to IW, set `ssthresh` to a fraction of the attempted seed (so the path is not re-probed blindly), flush any model-based filters, and record the event in qlog for post-hoc analysis of false-accept rate.

### 6.7 The extension frame (PV-Seed-X, Claim N4)

- **Negotiation:** a new transport parameter (experimental codepoint), e.g. `pv_dispersion_report`, offered by both endpoints during the handshake. Absent negotiation, the mechanism silently reduces to PV-Seed-R. Backwards compatibility is total.
- **Frame:** a small frame carrying `{path_id / challenge_sequence_ref, observed_dispersion_rate, sample_count, confidence_code}`. Sent by the *responder* of a challenge train, on the new path, immediately after the train completes.
- **Semantics:** advisory only. The receiving sender treats it as one more input to the same confidence gate and the same Unvalidated phase — never as a licence to bypass safety. A malicious or broken peer inflating the report is bounded by `cap_rel`, `cap_abs`, pacing, and Safe Retreat. **This threat model must be written up explicitly**; "a peer can lie about capacity" is the first question any transport reviewer will ask, and the answer is that the report is untrusted evidence subject to the same envelope, exactly as ACK-derived rate estimates already are.
- **Deliverable shape:** written as an IETF Internet-Draft appendix even if never submitted. It costs little and materially raises the paper's perceived contribution.

### 6.8 Design points and baselines (the experimental arms)

> **Revised 2026-08-03 by finding 8.2.1(A).** S0 is *not* obtainable from stock picoquic — it must be implemented (behind `PVSEED_SPEC_RESET`, default off, so the unmodified path stays provably stock). Conversely NAIVE requires no work: it is picoquic's shipped behaviour. The "status quo" is therefore two different things depending on whether you mean the specification or the deployment, and the paper should say so explicitly.

| ID | Arm | Wire change | Purpose |
|---|---|---|---|
| S0 | RFC-mandated blind reset (**we implement**) | none | **Control.** What the spec demands. |
| S1 | RTT-only seed (RFC 9002 §6.2.2 MAY) | none | Isolates the value of the already-permitted half. |
| S2 | Similarity-gated carry-over (`β × old_cwnd` if RTT ratio in band) | none | The "cheap trick" strawman; tests whether measurement is needed at all. |
| S3r | PV-Seed-R (reflected train) | none | **N3.** Deployable today. |
| S3x | PV-Seed-X (extension-reported) | 1 frame + TP | **N4.** Accurate for download. |
| NAIVE | full carry-over, no gate | none | **= picoquic's default behaviour, free.** Unsafe reference; expected to overshoot on step-down transitions. Demonstrates *why* the gate exists — and that a real deployed stack does this today. |
| ORACLE | seeded with ground-truth `C`, `RTT` from testbed config | n/a | Upper bound on achievable benefit; quantifies estimator loss (= ORACLE − S3). |
| COPA | Copa as host CC under S0 | none | Tests the "fast-adapting CC makes this moot" objection (§5). |

The `ORACLE − S3x` gap is the single most informative number in the paper: it separates "the idea is wrong" from "the estimator needs work."

---

## 7. Formal Analysis Work Items

To be produced as a short analysis section (target: one page plus one figure).

- **A1.** Closed-form recovery time and byte deficit under S0, geometric slow-start model; validated against measured S0 curves. Deliverable: a figure of predicted vs. measured deficit across the BDP grid.
- **A2.** The reflection result (§6.2.3) stated as a proposition with its assumptions made explicit (equal packet sizes, on-arrival response generation, no reverse-path cross traffic during the train, FIFO bottleneck) and each assumption's violation discussed.
- **A3.** Overshoot bound under the Unvalidated phase; worst-case excess bytes and resulting queue occupancy as a function of estimator relative error and buffer depth. Determines the required estimator accuracy — a key practical result.
- **A4.** Fairness: bound on the throughput perturbation experienced by an incumbent flow sharing the new path's bottleneck during the Unvalidated phase; validated by the fairness experiment (§10.3).
- **A5.** Regime analysis: the (BDP, transfer size, handover frequency) region in which PV-Seed's benefit exceeds a stated threshold. Defines and *bounds* the claim, pre-empting the "this doesn't matter for small objects" critique.

---

## 8. Implementation Plan

### 8.1 Vehicle

**picoquic** (https://github.com/private-octopus/picoquic), C.

Rationale: ships NewReno, CUBIC, and BBR in-tree (all three Tier-A hosts in one codebase); contains a Careful Resume implementation from the ASMS 2025 satellite work whose structure is directly relevant; has first-class qlog output; its maintainer (Christian Huitema) co-authors the Careful Resume draft, so the codebase's CC-seeding abstractions are already sympathetic to this class of change.

### 8.2 Integration points — VERIFIED against the tree (2026-08-03)

> Corrected in place during Phase 1, per the instruction that previously stood here. Verified against picoquic `0dc8ba8b2be30246720934d3f43a144b372e1a90` / picotls `f07f1c8c68b237f1468bc1f1fe1b68aba3ff23b4`. Claims below were confirmed by reading the source and by live qlog, not inferred.

| Concern | **Actual** location | What we do |
|---|---|---|
| Per-path state | `picoquic_path_t` — `picoquic/picoquic_internal.h:1030`. Holds `cwin`, `bytes_in_transit`, `congestion_alg_state`, `pacing`, `smoothed_rtt`, `rtt_variant`, `rtt_min`, `rtt_sample`, `rtt_is_initialized` | attach `pvseed_state_t` |
| **Challenge state — plan was WRONG** | NOT in `picoquic_path_t`. Lives in `picoquic_tuple_t` (`picoquic_internal.h:974`): `challenge[PICOQUIC_CHALLENGE_REPEAT_MAX]` (max 3), `challenge_time`, `challenge_time_first`, `challenge_repeat_count`, `challenge_response`, bitfields `challenge_required/verified/failed`. A `path_x` owns `first_tuple` plus a linked list of candidate tuples | train state attaches to the tuple, not the path |
| Challenge emission | formatted in `picoquic_format_path_challenge_frame` (`frames.c:4794`), scheduled by `picoquic_prepare_tuple_challenge_frames` (`paths.c:33`, format call `:54`) | train-mode emission, pacing bypass |
| Padding to 1200 B | decided at `paths.c:64-69` (source quotes RFC 9000 §8.2 verbatim), applied in `sender.c` (~2770, ~3208) via `picoquic_pad_to_target_length` to `PICOQUIC_ENFORCED_INITIAL_MTU` = 1200 (`picoquic_internal.h:42`) | already gives us full-MTU probes for free |
| Response processing | `picoquic_decode_path_response_frame` (`frames.c:4912`) | capture arrival timestamps, match challenge entropy |
| Validation completion | `frames.c:4912` where `tuple->challenge_verified = 1` | **primary hook** for PV-Seed |
| CC vtable | `picoquic_congestion_algorithm_t` (`picoquic.h:1827`): `alg_init`, `alg_notify`, `alg_delete`, `alg_observe` | **no new entrypoint needed** — see §8.2.1 |
| CC implementations | `newreno.c`, `cubic.c` (also holds "dcubic"), `bbr.c` (BBRv3) **and** `bbr1.c` (BBRv1), plus unanticipated `fastcc.c`, `prague.c` (L4S), `c4.c` | adapters already exist — §8.2.1 |
| Logging | qlog via CLI `-q <dir>` or `picoquic_set_qlog()` (`picoquic_qlog.h:32`); draft-00 JSON, `recovery/metrics_updated` carries `cwnd`, `bytes_in_flight`, `smoothed_rtt`, `min_rtt`, `latest_rtt` | emit custom PV-Seed events (§8.4) |

#### 8.2.1 Two findings that materially change the implementation

**(A) picoquic does not implement the RFC 9000 §9.4 MUST-reset.** Verified four independent ways:

1. `picoquic_congestion_notification_reset` (`picoquic.h:1794`) has switch-case handlers in newreno, cubic, bbr, bbr1, c4, fastcc, prague — and **zero callers**. A dead hook.
2. `picoquic_decode_path_response_frame` sets `challenge_verified`, calls `picoquic_update_path_rtt(..., epoch=-1, ...)`, promotes the tuple, and calls `picoquic_reset_path_mtu(path_x)` — **MTU only**.
3. `cwin = PICOQUIC_CWIN_INITIAL` appears only inside CC-init functions and `picoquic_create_path` (`quicctx.c:1907`) — neither on the single-path migration route. Single-path migration creates a new *tuple* on the existing path object, so `cwin` survives by construction.
4. Live qlog across real IP-changing migrations (5 repetitions at the standard operating point): the window never once takes the value a reset would assign - `PICOQUIC_CWIN_INITIAL` = 15,360 B (10 x `PICOQUIC_MAX_PACKET_SIZE` = 1536), or 14,240 B effective at the negotiated 1424 B send size. It instead falls *past* both to the 2,848 B floor via loss. (An earlier draft said "cwnd flat at 241,174 B"; that was the 50 Mbit run and it was not flat - see the corrections record.)

Consequence: **S0 must be implemented by us, not observed.** Our first code contribution is making picoquic RFC-compliant. Conversely the **NAIVE carry-over arm is free** — it is picoquic's default behaviour.

**(B) A live congestion-window seeding pathway already exists.** `picoquic_congestion_notification_seed_cwin` (`picoquic.h:1793`) IS dispatched — `timing.c:108`, from `picoquic_validate_bdp_seed()` (`timing.c:91`) — alongside `picoquic_seed_bandwidth()` (`quicctx.c:4200`) and BDP-frame support across `frames.c`/`transport.c`/`config.c`. The handlers already implement §6.5's design:

- NewReno → `picoquic_newreno_sim_seed_cwin()`, then `path_x->cwin = nr_state->nrss.cwin` (`newreno.c:241-244`)
- CUBIC → sets `cwin`, `ssthresh`, **`W_max`, `W_last_max`** (`cubic.c:393-401`) — exactly the "place CUBIC at its plateau" design
- BBR → `BBRSetBdpSeed()` (`bbr.c:2450`)

It is currently wired to Careful Resume / the BDP frame, i.e. seeding across **time**. **PV-Seed therefore is not "build a seeding interface" but "re-source existing, already-trusted seeding machinery from path-validation measurement (space) instead of retained state (time)."** Smaller build, stronger claim: reviewers need only accept a new evidence source, not new plumbing.

**(C) RFC 9002 §6.2.2 is implemented but inert here.** `frames.c:4943` calls `picoquic_update_path_rtt` with `epoch=-1`; `timing.c:180` gates on `!rtt_is_initialized`, so for `path[0]` in ordinary single-path migration it is a no-op. Implemented — but not exercised in the scenario this project targets.

### 8.3 New modules

```
picoquic/pvseed.h      /* public types, config knobs, phase enum          */
picoquic/pvseed.c      /* train scheduler, estimator, gate, phase machine */
```

> **Scope reduced by finding 8.2.1(B).** The CC-adapter work originally planned here is largely unnecessary: the seeding notification and its per-algorithm handlers already exist and are already exercised by picoquic's BDP/Careful-Resume path. What we build is the *evidence producer* (train scheduler, estimator, confidence gate, safety phase machine) plus the wiring that dispatches the existing `seed_cwin` notification from path validation. Additionally we must implement the **spec-compliant reset** (the S0 arm) that picoquic lacks, behind a runtime switch so the control arm is provably stock.

Design constraints on the new code:
- **No dependency on CC internals.** All CC interaction goes through the existing `alg_notify` / `seed_cwin` notification. This is what makes N6 (generality) a real claim rather than three bespoke hacks.
- **Compile-time and run-time disable.** A build flag plus a runtime config so S0 is exactly the unmodified path. The control arm must be *provably* unmodified behaviour, not "the new code with the feature off."
- **All tunables in one struct** (`K`, `α`, `θ_cv`, `cap_abs`, `cap_rel`, `K_min`, RTT-slope threshold) — settable from the test harness so parameter sweeps do not require rebuilds.
- **Every decision logged**, including rejections, with the inputs that produced them. False-accept and false-reject rates are results, and they are unrecoverable if not logged at decision time.

### 8.4 Instrumentation

- **qlog** as the primary data source. Extend with PV-Seed event types: `pvseed_train_sent`, `pvseed_response_observed`, `pvseed_estimate`, `pvseed_decision` (accept/degrade/reject + reason), `pvseed_phase_change`, `pvseed_abandon`. Align event naming with `draft-ietf-tsvwg-careful-resume-qlog`, which already standardizes logging for congestion control from retained state — citing and extending it is cheap credibility.
- **pcap** on both endpoints' interfaces for ground-truth dispersion, independent of the stack's own timestamps. Essential for the §9.4 spacing-preservation experiment, because there we are specifically testing whether the stack's behaviour matches its own belief.
- **Testbed config manifest** emitted per run (JSON): every tc parameter, seed, arm ID, git commit hash. Runs that cannot be reproduced are worthless; the manifest is the reproduction key.

---

## 9. Testbed Design

### 9.1 Environment decision

**Primary: WSL2.** **Fallback: Ubuntu VM (Hyper-V or VirtualBox).**

Rationale for gating rather than choosing outright: WSL2 runs a Microsoft-built kernel that has historically omitted some `sch_*` scheduler modules, and it is a virtualized environment whose timer and network-path jitter directly affect microsecond-scale dispersion measurement — at 100 Mbps a 1200 B packet is a 96 µs gap, so tens of microseconds of jitter is material. Rather than guess, we test.

**Phase-0 environment gate — run these first:**

```bash
uname -r && cat /proc/sys/kernel/osrelease
```

```bash
sudo modprobe sch_netem sch_tbf ifb && tc qdisc add dev lo root netem delay 10ms && tc qdisc show dev lo && sudo tc qdisc del dev lo root
```

```bash
sudo ip netns add pvtest && sudo ip netns del pvtest && echo "netns OK"
```

If any step fails, or if the §9.5 calibration shows unacceptable variance, move to an Ubuntu 22.04+ VM with 2+ dedicated vCPUs. Record the decision and the measured variance in the repo — "we validated our emulator before trusting it" is a methodology point worth stating in the paper.

### 9.2 Topology

Linux network namespaces, dual-path, single host:

```
                 ┌──────────────┐  vethA   ┌───────────────┐
                 │              ├──────────┤  ns_bottleA   ├────┐
   ┌─────────────┴──┐           │          │ (tbf + netem) │    │   ┌──────────────┐
   │   ns_client    │           │          └───────────────┘    ├───┤  ns_server   │
   │  (picoquic     ├───────────┤                               │   │  (picoquic   │
   │   client)      │  vethB    │          ┌───────────────┐    │   │   server)    │
   └────────────────┘           ├──────────┤  ns_bottleB   ├────┘   └──────────────┘
                                │          │ (tbf + netem) │
                                └──────────┘───────────────┘
```

- Client namespace holds two interfaces (path A = pre-handover, path B = post-handover).
- Each bottleneck namespace shapes **each direction independently** on its two egress interfaces — this is how directional asymmetry (`C_down` ≠ `C_up`) is produced, and asymmetry is central to §6.2.3.
- Migration is triggered programmatically in the client at a fixed time offset (picoquic exposes a probe/migrate API — expected `picoquic_probe_new_path()`; verify name in Phase 1), optionally combined with taking path A administratively down to emulate break-before-make.

### 9.3 Shaping configuration

- **Capacity:** `tbf` (rate, burst, limit).
- **Delay / loss / reorder:** `netem`.
- **Buffer depth:** the `limit` parameter, swept as a multiple of BDP. Buffer depth is a first-order variable for overshoot safety and must not be left at a default.

> **The single most important testbed trap.** A token-bucket shaper with a large `burst` lets an entire back-to-back train through at line rate **without dispersing it**. If `burst ≥ K × 1200 B`, our estimator measures the emulator's bucket, not the emulated link, and every capacity number in the paper is an artefact. `burst` must be set just above one MTU — but too small a burst throttles achievable throughput below the nominal rate. This tension is real and must be resolved empirically, per rate, in §9.5. (Note: a *real* link always disperses, because serialization is physical; this is purely an emulation fidelity problem, and it is exactly the kind of thing that invalidates otherwise-good measurement papers.)

### 9.4 Spacing-preservation experiment (gates the whole mechanism)

Before any performance evaluation, establish empirically:

1. Does a back-to-back challenge train emitted by picoquic actually leave the host back-to-back? (pcap at sender)
2. Does the shaped link disperse it as `L/C`? (pcap at receiver — this validates §9.5)
3. Does the responder emit one response per challenge *preserving arrival spacing*, or does batched I/O (`recvmmsg`, GRO/GSO) collapse it? (pcap at responder egress)
4. Does the initiator's observation match `min(C_fwd, C_rev)` as §6.2.3 predicts?

Outcomes and what each means:
- All four hold → PV-Seed-R is viable; proceed with both arms.
- (3) fails → reflection is uninformative in this stack; PV-Seed-R degrades to a rate-limited estimate. **This is a publishable negative result and the strongest possible motivation for PV-Seed-X.** Report it prominently; do not treat it as a project failure.
- (2) fails → testbed problem, return to §9.5 calibration. Never interpret an emulator artefact as a protocol finding.

### 9.5 Calibration gate (Phase 0 exit criterion)

Do not run a single performance experiment until:
- A known-rate shaped link produces measured train dispersion within ±10% of `L/C` for every rate in the grid — i.e. **the emulator can express the phenomenon we intend to measure.**
- Repeated identical runs show acceptable run-to-run variance (target: coefficient of variation < 5% on steady-state throughput; < 10% on dispersion estimates).
- Flow-control windows are confirmed large enough that no run is flow-control-limited (§6.3).
- ECN behaviour through the shapers is characterized (works / silently stripped), so §6.6 triggers are known-available or known-absent.

This gate is what separates a credible emulation paper from a rejected one. It is not optional and it is not fast.

### 9.6 Workloads

- **Bulk transfer** (10 MB, 50 MB) — cleanest signal for recovery time and byte deficit.
- **Fixed-object fetches** (100 KB, 1 MB, 10 MB) — flow completion time; establishes the regime boundary of A5.
- **Paced media-like stream** (constant bitrate near a fraction of capacity) — stall/rebuffer-proxy metrics; closest to the QoE framing in the domain survey.

---

## 10. Evaluation

### 10.1 Parameter grid

| Dimension | Values |
|---|---|
| Path B capacity (down) | 5, 20, 50, 100 Mbps |
| Directional asymmetry (down:up) | 1:1, 5:1, 10:1 |
| Path B RTT | 10, 30, 60, 120 ms |
| Path B loss | 0, 0.1, 1 % |
| Buffer depth | 0.5, 1, 4 × BDP |
| Transition type | symmetric (A≈B), step-up (B≫A), step-down (B≪A), RTT-inverting |
| Handover style | break-before-make (gap 0, 50, 200, 500 ms), make-before-break (overlap) |
| Arm | S0, S1, S2, S3r, S3x, NAIVE, ORACLE, COPA |
| Host CC | NewReno, CUBIC, BBR |
| Repetitions | ≥ 20 per cell |

The full cross-product is far too large. **Strategy:** define a *default cell* (50 Mbps, 5:1, 30 ms, 0% loss, 1×BDP buffer, step-down, break-before-make 200 ms, CUBIC) and sweep one dimension at a time from it, plus a small full-factorial over the two dimensions expected to interact most (capacity × asymmetry). Document the reduction explicitly — an unexplained sparse grid reads as cherry-picking.

**Step-down transitions are the safety-critical cell** (fast old path → slow new path): this is where NAIVE should visibly hurt and where the gate must prove its worth. It gets extra repetitions.

### 10.2 Metrics

- **T₉₀** — time from path-validation completion to sustained ≥90% of the new path's achievable throughput. *Primary metric.*
- **Byte deficit** — ∫(achievable − actual) over the recovery window. Primary metric; more robust than T₉₀ to noisy tails.
- **FCT** — flow completion time for fixed objects with migration injected at a fixed offset.
- **Safety: overshoot** — peak queue occupancy, peak one-way delay, loss events and retransmissions induced in the first 2 RTTs post-seed.
- **Safety: fairness** — throughput perturbation of an incumbent long-lived flow on the new path's bottleneck; Jain index across the two flows during the Unvalidated phase.
- **Estimator quality** — distribution of `|B̂ − C_true| / C_true`; gate acceptance rate; false-accept rate (accepted but overshot); false-reject rate (rejected but would have been fine, measured against ORACLE).
- **Cost** — CPU time and bytes added by the probe train, per migration. Small, but must be reported: a mechanism that helps throughput while burning battery is a different trade than claimed.

### 10.3 Required experiments beyond the main grid

- **Fairness (mandatory).** Incumbent flow on path B's bottleneck; measure its loss during the seeded flow's Unvalidated phase. A reviewer will ask; not having it is fatal.
- **Adversarial / wrong-seed injection.** Deliberately feed a 10× over-estimate to verify Safe Retreat bounds the damage as A3 predicts. This is how the safety claim is *demonstrated* rather than argued.
- **Stack-behaviour survey (N7 sub-result).** Do deployed stacks implement the RFC 9002 §6.2.2 RTT MAY? Inspect picoquic, quic-go, quiche, msquic, ngtcp2 source; where feasible, confirm behaviourally against the local testbed. Cheap, self-contained, and a genuinely useful community contribution.
- **Batched-I/O sensitivity.** Vary `recvmmsg` batch size / GRO settings to characterize the §9.4 spacing-preservation boundary.

### 10.4 Statistics

- Report medians with bootstrap confidence intervals, not means ± SD — recovery-time distributions are skewed.
- ≥20 repetitions per cell; report the distribution (CDFs), not just point estimates. The domain survey shows CDF-of-FCT is the field's expected presentation format.
- Randomize arm order within a repetition block to avoid drift artefacts (thermal, background load).
- Pin CPU affinity for the picoquic processes; record load average per run and discard runs above a threshold, documenting the discard rate.

### 10.5 Threats to validity (to be written honestly in the paper)

- Emulation is not cellular: no scheduler grants, no HARQ, no rate oscillation. State plainly that dispersion-based estimation on real cellular links may measure the grant rate rather than the wire rate, cite Sprout's evidence that per-UE queues isolate flows (which *supports* estimate stability), and mark real-link validation as future work. **Do not overclaim cellular applicability from netem results.**
- Single-host emulation shares a clock and a CPU; timing artefacts are possible. Mitigated by the §9.5 calibration gate and by pcap-based cross-validation.
- picoquic-only results; generality of the CC interface is argued across three CCs but only one stack.
- The extension arm (S3x) is evaluated against our own implementation on both ends — it demonstrates the mechanism's ceiling, not deployability.

---

## 11. Phased Schedule

No external deadline; phases are ordered by dependency with explicit exit criteria. Week estimates are indicative for a single part-time author.

> **Revised 2026-08-05 for the measurement-led direction.** P0 and P1 are COMPLETE. P2–P4 as originally written (build the mechanism) are superseded; the mechanism is now future work. The remaining phases are the survey and its evaluation.

| Phase | Work | Exit criterion | Status |
|---|---|---|---|
| **P0 — Environment & calibration** | WSL2 gate; netns topology; tc scripts; burst calibration; train-length sweep | §9.5 gate passed; operating point fixed at burst 3200 / K≥8 / discard 2 | **DONE** |
| **P1 — Baseline & first subject** | Build picoquic; verify §8.2 source map; audit §9.4 compliance; implement the compliant reset; step-up/step-down baselines | F1 and F2 established and independently re-verified | **DONE** |
| **P2 — Survey harness** | Generalise the testbed to drive non-picoquic stacks; define the three compliance probes as reusable tests; decide per-stack instrumentation (qlog where available, packet capture where not) | One non-picoquic stack runs end-to-end through the harness and answers all three questions | **NEXT** |
| **P3 — The survey** | Apply the harness to quic-go, quiche, msquic, ngtcp2. Source audit + live measurement for each, so static and dynamic evidence agree as they did for picoquic | All five stacks characterised on all three questions, with divergences documented | — |
| **P4 — Cost quantification** | For each observed behaviour class, measure recovery time, byte deficit, completion rate and overshoot across the handover grid | §10 metrics collected with confidence intervals; results frozen | — |
| **P5 — Analysis & writing** | Comparison tables; figures; paper draft | Complete draft with reproducible figure pipeline | — |
| **P6 — Artifact & contribution** | Repo cleanup, one-command reproduction, archived data; upstream the §9.4 reset patch and the compliance findings to affected projects | A stranger reproduces the headline table; patch submitted | — |

**Kill/pivot checkpoints:**
- End of P1: if S0 recovery cost is negligible across the whole grid, the premise is wrong → pivot to gap D2 (cross-stack migration benchmark), reusing the entire P0/P1 testbed. Cost of this pivot is low by design.
- End of P2: if the estimator cannot achieve usable accuracy even on clean emulated links, the mechanism is unsound → pivot to a measurement paper on post-migration recovery cost + estimator feasibility, which is still publishable and uses all work to date.

Both fallbacks preserve most of the investment. This is deliberate: the project is structured so that no phase can strand the work.

---

## 12. Repository and Conventions

**Repo:** https://github.com/sivaahari/quic-congestion-control

### 12.1 Layout

```
/                         README.md, LICENSE, CITATION.cff
/docs/                    PLAN.md, PLAN.txt, surveys, design notes, RFC excerpts
/picoquic/                submodule or vendored fork (pvseed.c/h + CC adapter patches)
/testbed/
    topology/             netns setup/teardown scripts
    shaping/              tc profiles, calibration scripts
    scenarios/            migration scenario definitions (JSON)
/harness/
    run_sweep.py          experiment driver, emits per-run manifests
    collect.py            qlog + pcap ingestion
/analysis/
    parse_qlog.py         PV-Seed event extraction
    metrics.py            T90, byte deficit, FCT, fairness
    figures/              plotting scripts (one script per paper figure)
/results/
    raw/                  qlog + pcap (git-lfs or archived externally if large)
    processed/            tidy CSV
/paper/                   LaTeX source, figures, bib
```

### 12.2 Git identity (mandatory)

```bash
git config user.name "sivaahari"
```

```bash
git config user.email "cb.sc.u4cys24055@cb.students.amrita.edu"
```

**Commit message policy: no co-author trailers.** Do not append `Co-Authored-By:` lines to any commit. This is an explicit instruction from the author and overrides any default agent convention. Commits are authored solely by sivaahari.

### 12.3 Reproducibility rules

- Every run emits a manifest: git commit hash, full tc parameters, arm ID, RNG seeds, kernel version, timestamp.
- Every figure is generated by a checked-in script from checked-in processed data. No hand-edited figures.
- Raw qlogs for the headline results are archived; if too large for git, use git-lfs or an external archive with checksums recorded in-repo.

---

## 13. Paper Plan

**Working title:** *Reset, Retain, or Neither? Congestion Control at QUIC Connection Migration Across Five Implementations*

**Structure:**
1. Introduction — RFC 9000 §9.4 states a MUST; nobody has checked. Contributions M1–M6.
2. Background — connection migration; §9.4's two paragraphs; §9002 §6.2.2's initial-RTT option; why the rule exists.
3. Related work — SIGCOMM CCR 2025 (whether servers *support* migration) as the closest neighbour and the thing we extend; implementation-comparison studies (throughput, pacing) that do not examine migration; Careful Resume as the standards precedent for congestion-state reuse.
4. Method — the three compliance questions; how each is answered by static audit *and* live measurement; the testbed; **the calibration procedure and the two artefacts it catches** (lead with this; it buys trust).
5. Results I — the compliance survey across five stacks. The table is the paper's centrepiece.
6. Results II — partial compliance is harmful (M3), with the mechanism traced from qlog.
7. Results III — cost of each behaviour class across the handover grid.
8. Discussion — why the rule is easy to get wrong; what a correct implementation must do; implications for the specification's wording; the unused path-validation measurement as a possible remedy (PV-Seed, §6, as future work).
9. Conclusion.
- Appendix: the §9.4-compliant reset patch for picoquic.

**Venue shape:** measurement workshops — PAM, TMA, ACM EPIQ, IRTF/ACM ANRW. The natural framing is "an implementation-behaviour companion to Buchet & Pelsser's deployment study."

**Venue shape:** the natural targets are transport/measurement workshops — ACM EPIQ (QUIC-specific), IRTF/ACM ANRW (where the Neqo Careful Resume work appeared), PAM, or TMA. A course capstone that lands in that shape is a credible workshop submission. The IETF QUIC/CCWG mailing lists are a zero-cost secondary outlet for the extension.

---

## 14. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | WSL2 lacks netem / has poor timing fidelity | Medium | Medium | §9.1 gate; Ubuntu VM fallback pre-approved |
| R2 | `tbf` burst destroys train dispersion | **High** | **High** | §9.5 calibration is a hard gate; per-rate burst tuning; consider HTB/netem-rate alternatives |
| R3 | Responder batching collapses reflected spacing | Medium | High | §9.4 experiment; if it fails, becomes a publishable negative result motivating S3x |
| R4 | Anti-amplification truncates server-side trains | High | Medium | Client-side priming (§6.2.4); deferred second train; gate rejects short trains |
| R5 | Estimator too noisy for a safe seed | Medium | High | Confidence gate; degradation ladder; A3 shows required accuracy may be modest |
| R6 | picoquic learning curve / API drift | Medium | Medium | P1 dedicated to orientation; verify §8.2 map against real source early |
| R7 | BBR max-filter retains a bad seed for ~10 RTTs | Medium | High | Filter flush on Safe Retreat (§6.5); seeded-sample expiry |
| R8 | Benefit vanishes under fast-adapting CC | Low–Med | High | COPA arm measures it; A5 bounds the claim regime; honest reporting |
| R9 | Flow control silently caps the seed | Medium | High | Phase-0 checklist item; per-run assertion in the harness |
| R10 | Scope creep (MPQUIC, real devices, ML) | Medium | Medium | Emulation-only is a fixed constraint; MPQUIC and cellular are future work, explicitly |

---

## 15. Open Questions

1. **Which endpoint is the paper's protagonist?** Client-sender (upload) is where PV-Seed-R works natively; server-sender (download) is the commercially important case needing PV-Seed-X. Current plan covers both; if scope must shrink, decide deliberately rather than by drift.
2. **Is S2 (similarity-gated carry-over) worth full evaluation, or is it a strawman?** It is cheap to implement and makes the "measurement is necessary" argument concrete. Currently retained.
3. **ECN availability** through the emulated shapers — determines whether the cleanest Safe Retreat trigger is available. Answered in Phase 0.
4. **Multipath applicability** — PV-Seed generalizes to initializing a newly added MPQUIC path. Currently scoped as discussion/future work only.
5. **Artifact size policy** — raw qlogs may be large; decide git-lfs vs. external archive at P5.

---

## 16. Reference List

**Specifications**
- RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport. §8.2 (path validation, padding), §9.3–9.4 (migration, CC reset). https://www.rfc-editor.org/rfc/rfc9000
- RFC 9002 — QUIC Loss Detection and Congestion Control. §6.2.2 (initial RTT from PATH_CHALLENGE), §7.2 (initial window). https://www.rfc-editor.org/rfc/rfc9002
- RFC 9438 — CUBIC for Fast and Long-Distance Networks. https://www.rfc-editor.org/rfc/rfc9438
- RFC 9406 — HyStart++. https://www.rfc-editor.org/rfc/rfc9406
- draft-ietf-tsvwg-careful-resume — Convergence of Congestion Control from Retained State. https://datatracker.ietf.org/doc/draft-ietf-tsvwg-careful-resume/
- draft-ietf-tsvwg-careful-resume-qlog — qlog for CC from retained state. https://datatracker.ietf.org/doc/draft-ietf-tsvwg-careful-resume-qlog/
- draft-ietf-quic-multipath — Managing multiple paths for a QUIC connection. https://datatracker.ietf.org/doc/html/draft-ietf-quic-multipath
- draft-paulo-quic-migration-00 — Exploring QUIC Connection Migration (expired, 2019). https://datatracker.ietf.org/doc/html/draft-paulo-quic-migration-00

**Congestion control**
- Cardwell et al., BBR: Congestion-Based Congestion Control, ACM Queue, 2016.
- Ha, Rhee, Xu, CUBIC, ACM SIGOPS OSR, 2008.
- Mascolo et al., TCP Westwood, ACM MobiCom, 2001.
- Arun & Balakrishnan, Copa, USENIX NSDI, 2018.
- Winstein et al., Sprout, USENIX NSDI, 2013.
- Zaki et al., Verus, ACM SIGCOMM, 2015.
- Abbasloo et al., Orca, ACM SIGCOMM, 2020.

**Bandwidth estimation**
- Keshav, A Control-Theoretic Approach to Flow Control, ACM SIGCOMM, 1991.
- Dovrolis, Ramanathan, Moore, What do packet dispersion techniques measure?, IEEE INFOCOM, 2001.
- Ribeiro et al., pathChirp, PAM, 2003.

**QUIC mobility & measurement**
- Buchet & Pelsser, An Analysis of QUIC Connection Migration in the Wild, ACM SIGCOMM CCR, 2025. https://dl.acm.org/doi/10.1145/3727063.3727066
- Kim & Koh, mQUIC, IEEE, 2023. https://ieeexplore.ieee.org/document/10268842/
- Sinha et al., CQUIC, IEEE WCNC, 2020. https://ieeexplore.ieee.org/document/9120850/
- Lu et al., CQIC, ACM HotMobile, 2015.
- Careful Resume with picoquic over satellite paths, ASMS, 2025. https://ieeexplore.ieee.org/document/10946055/
- Getting up to Speed with Neqo and Careful Resume, ACM ANRW, 2025. https://dl.acm.org/doi/10.1145/3744200.3744766
- PBQ-Enhanced QUIC, 2023. https://pmc.ncbi.nlm.nih.gov/articles/PMC9955954/
- Seemann, Exploiting QUIC's Path Validation, 2023. https://seemann.io/posts/2023-12-18---exploiting-quics-path-validation/
- quic-go issue #5580 (reordering → premature slow-start exit). https://github.com/quic-go/quic-go/issues/5580
- nginx PR #795 (PATH_CHALLENGE scheduling under a full cwnd). https://github.com/nginx/nginx/pull/795

**Software**
- picoquic — https://github.com/private-octopus/picoquic
- quic-go — https://github.com/quic-go/quic-go (fallback vehicle; source for the stack survey)

---

## 17. Change Log

| Date | Change |
|---|---|
| 2026-07-14 | v1.0 — initial plan of record. Gap D3 selected and guide-approved; vehicle, environment, repo, and identity constraints fixed. |
| 2026-08-03 | v1.1 — Phase 0 complete: WSL2 gate passed, testbed built and calibrated (`tbf burst = 3200 B`, probe train `K ≥ 8`, `discard_leading = 2`; K=5 ruled out). §9.3's predicted burst trap confirmed and quantified. Phase 1 partial: picoquic built and verified; §8.2 source map corrected against the real tree; **N8 added** (picoquic does not implement the §9.4 MUST-reset); §8.3 scope reduced and §6.8 revised after discovering a live `seed_cwin` pathway already exists. |
| 2026-08-05 | **v2.0 — DIRECTION CHANGED to measurement-led.** Novelty audit (§4.0) found the PV-Seed mechanism framing unable to carry a paper: the RTT half is already permitted by RFC 9002 §6.2.2, the capacity half is fragile and untestable in emulation, and the impact ceiling is 80–250 ms per handover. New claims M1–M6 built on the two findings discovered while building: picoquic violates the §9.4 MUST (M2) and partial compliance is harmful (M3). §11 phases rewritten — P0/P1 done, P2 is now the survey harness. §13 paper plan rewritten. PV-Seed retained as future work in §6. Dead-code finding re-validated against pristine upstream and scoped precisely to single-path (non-multipath) operation. |
