# Literature Survey: Congestion-Control Candidates for Post-Migration Seeding in QUIC

**Project:** Capstone — QUIC Performance Under Mobile Handover (Gap D3)
**Purpose of this document:** Catalog of existing congestion-control (CC) algorithms and mechanisms that are probable candidates for direct adaptation into a QUIC post-migration congestion-state seeding mechanism ("PV-Seed"). Compiled 2026-07-14.

**Problem this survey serves:** RFC 9000 §9.4 mandates that on confirming a peer's new address after connection migration, an endpoint "MUST immediately reset the congestion controller and round-trip time estimator for the new path to initial values." RFC 9002 §6.2.2 separately permits ("MAY") using the PATH_CHALLENGE→PATH_RESPONSE delay to set the *initial RTT* of the new path. No specification or published system extends this "informed initial values" loophole to the congestion window / bandwidth dimension. The candidates below are graded on how directly their machinery can be adapted to do so.

---

## How to read this document

- **Tier A — Host algorithms.** CC algorithms already deployed in QUIC stacks. These are what we seed *into*; our mechanism must define, per algorithm, which internal state variables get initialized from path-validation measurements.
- **Tier B — Machinery donors.** Algorithms/mechanisms whose estimation or safety logic we adapt *from*. These are the closest intellectual ancestors of seeding.
- **Tier C — Related work to cite and differentiate.** Solves adjacent problems (handover CC via ML, cross-layer radio hints, cellular-specialized CC). Not direct adaptation candidates, but reviewers will expect them in related work, and our design must articulate why it differs.

---

## Tier A — Host algorithms (seeding targets)

### A1. NewReno (QUIC profile)
- **Source:** RFC 9002, "QUIC Loss Detection and Congestion Control" — https://datatracker.ietf.org/doc/rfc9002/ (original NewReno: RFC 6582)
- **Year:** 2021 (QUIC profile; NewReno lineage 1999/2012)
- **Implementation overview:** The default CC sketched in RFC 9002. Loss-based AIMD: slow start doubles cwnd per RTT from an initial window of 10×max_datagram_size (§7.2); on loss, ssthresh = cwnd/2 and congestion avoidance grows cwnd by one max_datagram_size per cwnd of acked data. No bandwidth model — cwnd *is* the entire state.
- **Adaptation fit:** Simplest seeding target: state is just {cwnd, ssthresh, smoothed_rtt, rttvar}. Seed cwnd (and set ssthresh = seed as the "known-safe ceiling") from a path-validation capacity estimate. Best used as the *reference* host to demonstrate the mechanism in its purest form. Present in every QUIC stack (picoquic, quic-go, quiche).

### A2. CUBIC
- **Source:** Ha, Rhee, Xu, "CUBIC: A New TCP-Friendly High-Speed TCP Variant," ACM SIGOPS OSR 2008; standardized as RFC 9438 — https://www.rfc-editor.org/rfc/rfc9438
- **Year:** 2008 (paper); 2023 (RFC 9438)
- **Implementation overview:** Loss-based; replaces AIMD linear growth with a cubic function of time since last loss, anchored at W_max (cwnd at last loss event). Fast convergence and RTT-fairness improvements. The most widely deployed CC on the internet; default in Linux TCP and in several QUIC stacks (picoquic, quiche).
- **Adaptation fit:** Seeding requires initializing {cwnd, ssthresh, W_max, epoch start time}. Setting W_max to the seeded estimate makes CUBIC's concave region do the "cautious approach to estimated capacity" for free — a natural safety synergy. This is exactly the host the Careful Resume picoquic work (B1) targeted, so precedent code exists.

### A3. BBR (v1 → v3)
- **Source:** Cardwell, Cheng, Gunn, Yeganeh, Jacobson, "BBR: Congestion-Based Congestion Control," ACM Queue 14(5), 2016 — https://queue.acm.org/detail.cfm?id=3022184 ; BBRv3 maintained as IETF CCWG drafts (draft-cardwell-ccwg-bbr) since 2023
- **Year:** 2016 (v1); 2023– (v3 drafts)
- **Implementation overview:** Model-based: continuously estimates bottleneck bandwidth (BtlBw, windowed-max of delivery rate) and minimum RTT (RTprop, windowed-min), and paces at gain×BtlBw with cwnd ≈ gain×BDP. STARTUP phase doubles the sending rate per RTT until delivery rate plateaus; ProbeBW/ProbeRTT phases maintain the model. Implemented in picoquic (default), Google QUIC/quiche.
- **Adaptation fit:** *The most natural seeding target.* Its state literally is {BtlBw, RTprop} — precisely the two quantities a path-validation exchange can estimate (RTT directly; bandwidth via probe-train dispersion). Seeding = injecting (B̂, RTT_pv) into the model and entering steady-state (or a shortened STARTUP) instead of blind STARTUP. Cleanest story for the paper; requires care with BBR's windowed max/min filters so the seed ages out naturally if wrong.

---

## Tier B — Machinery donors (logic we adapt)

### B1. Careful Resume — the closest standards relative
- **Source:** Kuhn, Stephan, Fairhurst, Secchi, Huitema, "Convergence of Congestion Control from Retained State" (draft-ietf-tsvwg-careful-resume, at rev -24, approved as Proposed Standard) — https://datatracker.ietf.org/doc/draft-ietf-tsvwg-careful-resume/
- **Year:** 2021 (first individual draft) → 2025/2026 (IESG-approved)
- **Implementation overview:** Jump-starts a *new connection* using CC parameters (saved_cwnd, saved_rtt) retained from a *previous connection* to the same endpoint over the same path. Five-phase state machine: **Observe** (record capacity on the earlier connection) → **Reconnaissance** (send initial window, confirm path & RTT similarity) → **Unvalidated** (jump cwnd to saved_cwnd/2, paced) → **Validating** (confirm no congestion) → **Safe Retreat** (on loss/ECN: collapse to IW, ssthresh guard). Abandon conditions include: RTT dissimilarity (current RTT < 50% or substantially above saved), parameter lifetime expiry, congestion during jump.
- **Critical scope limitation (our opening):** The draft **explicitly forbids its own use across a path change**: "If the Remote Endpoint is not the same as any saved_remote_endpoint, or the sender receives a signal from the local stack indicating that the path is now different to the observed path, the sender MUST stop using Careful Resume." It seeds across **time** (old connection → new connection, same path); it has nothing for seeding across **space** (same connection, new path) — because on a new path there is no retained state that is trustworthy. Our contribution is precisely the missing complement: generate *fresh* evidence about the new path from the path-validation exchange itself.
- **Adaptation fit:** Donate the entire safety skeleton — Unvalidated/Validating/Safe Retreat phases, the jump-to-half rule, the abandon conditions — and re-source the *input* (from "retained old state" to "measured path-validation evidence"). Reusing an IESG-approved safety framework massively strengthens the paper's deployability argument.
- **Companion implementations/evaluations:**
  - "Careful Resume: Design and Analysis with Picoquic over Satellite Paths," ASMS/SPSC 2025 — https://ieeexplore.ieee.org/document/10946055/ (CUBIC host in picoquic; evaluated on emulated GEO, three real GEO networks, Starlink, and 5G; code public — our best code base to crib from)
  - "Getting up to Speed with Neqo and Careful Resume," ANRW 2025 — https://dl.acm.org/doi/10.1145/3744200.3744766 (Mozilla Neqo implementation)

### B2. TCP Westwood / Westwood+
- **Source:** Mascolo, Casetti, Gerla, Sanadidi, Wang, "TCP Westwood: Bandwidth Estimation for Enhanced Transport over Wireless Links," ACM MobiCom 2001 — https://dl.acm.org/doi/10.1145/381677.381704
- **Year:** 2001 (Westwood); 2004 (Westwood+ refinement)
- **Implementation overview:** The philosophical ancestor of measurement-driven window setting. Maintains a continuous bandwidth estimate from ACK arrival rate (Westwood+ fixes ACK-compression bias by sampling once per RTT). On loss, instead of blind halving, sets ssthresh = B̂ × RTTmin ("faster recovery") — i.e., *sets the window to a measured estimate of the path's BDP*. Designed specifically for lossy wireless links where loss ≠ congestion.
- **Adaptation fit:** Westwood answers "what should the window be when an event invalidates it?" with "the measured rate × min RTT" — exactly our question, with migration as the invalidating event instead of loss. Donates (a) the eligible-rate estimation concept, (b) the ssthresh = B̂×RTT seeding rule, (c) ACK-compression filtering techniques directly applicable to our reflected-probe dispersion bias problem. A QUIC-side ACK-rate variant could also continuously maintain B̂ during the *overlap window* of make-before-break handovers.

### B3. HyStart++
- **Source:** Balasubramanian, Huang, Olson (Microsoft), RFC 9406, "HyStart++: Modified Slow Start for TCP" — https://www.rfc-editor.org/rfc/rfc9406
- **Year:** 2023
- **Implementation overview:** Augments slow start with a delay-increase heuristic: monitors RTT growth during window doubling and exits slow start into a Conservative Slow Start (CSS) phase before the first loss, avoiding severe overshoot. Deployed in Windows TCP and several QUIC stacks.
- **Adaptation fit:** Two uses. (1) If a seed is *rejected* (low confidence), the fallback slow start should still be HyStart++-governed rather than loss-terminated. (2) Its RTT-slope logic is a ready-made *validation criterion* for the post-seed Validating phase: if RTT climbs immediately after applying the seed, the seed overshot — trigger Safe Retreat. Cheap, standardized, uncontroversial.

### B4. Packet-Pair / Packet-Train bandwidth estimation (the estimator itself)
- **Source (foundational):** Keshav, "A Control-Theoretic Approach to Flow Control," ACM SIGCOMM 1991 (packet-pair principle); Dovrolis, Ramanathan, Moore, "What do packet dispersion techniques measure?", IEEE INFOCOM 2001 (bias analysis); Ribeiro et al., "pathChirp: Efficient Available Bandwidth Estimation," PAM 2003 (chirp trains)
- **Year:** 1991 / 2001 / 2003
- **Implementation overview:** Two (or K) back-to-back packets of size L traverse the bottleneck; their arrival spacing Δ satisfies B̂ = L/Δ for the bottleneck capacity; trains + statistical filtering (median, harmonic mean, mode of pairwise estimates) recover capacity or available bandwidth under cross-traffic. Dovrolis et al. formalize what dispersion actually measures (capacity vs. asymptotic dispersion rate) — required reading for correctness.
- **Adaptation fit:** This is the measurement engine of our design. The QUIC-specific enabler nobody has exploited: RFC 9000 §8.2.1/§8.2.2 force *both* PATH_CHALLENGE and PATH_RESPONSE datagrams to be expanded to ≥1200 bytes, and §8.2.2 mandates exactly one response per challenge while permitting multiple challenges. A back-to-back train of K padded challenges therefore elicits K padded, individually-triggered response packets — a legal, in-band, encrypted packet train on the *unvalidated new path*, before a single byte of application data is committed to it. Known caveat to study honestly: on cellular links, per-UE scheduling quantizes dispersion (grant-rate, not wire-rate); mitigations = train length, median filtering, confidence gating.

### B5. Copa
- **Source:** Arun, Balakrishnan, "Copa: Practical Delay-Based Congestion Control for the Internet," USENIX NSDI 2018 — https://www.usenix.org/conference/nsdi18/presentation/arun
- **Year:** 2018
- **Implementation overview:** Delay-based model: targets a sending rate of 1/(δ·d_q) where d_q is measured queueing delay; adjusts velocity multiplicatively, converging to a small standing queue. Detects buffer-filling competitors and switches to a TCP-competitive mode. Deployed by Meta in mvfst (QUIC) for live video.
- **Adaptation fit:** Secondary host candidate (it is in a production QUIC stack) and a donor of an idea: Copa re-converges after rate perturbations in a few RTTs by design, so it is the natural *comparison point* for "do we even need seeding, or does a fast-adapting CC solve migration natively?" — an ablation reviewers will demand. Its queueing-delay measurement (RTT_standing − RTT_min) also gives a principled post-seed validation signal.

---

## Tier C — Related work to cite and differentiate (not direct candidates)

### C1. PBQ-Enhanced QUIC (DRL congestion control)
- **Source:** "PBQ-Enhanced QUIC: QUIC with Deep Reinforcement Learning Congestion Control Mechanism," Electronics/PMC — https://pmc.ncbi.nlm.nih.gov/articles/PMC9955954/
- **Year:** 2023
- **Overview:** Fuses BBR pacing with a PPO (deep RL) agent that outputs cwnd; improves post-latency-change throughput stability.
- **Differentiation:** Solves the same symptom (post-change window misconfiguration) with a trained agent. Our argument: the migration case doesn't need learning — the protocol already emits a measurement at exactly the right moment. We are the lightweight, deployable, interpretable alternative; PBQ is the key "heavyweight baseline" to argue against on deployability (training, compute, generalization).

### C2. CQUIC (cross-layer QUIC, Samsung)
- **Source:** Sinha, Kanagarathinam et al., "CQUIC: Cross-Layer QUIC for Next Generation Mobile Networks," IEEE WCNC 2020 — https://ieeexplore.ieee.org/document/9120850/
- **Year:** 2020
- **Overview:** Uses predicted SINR + QUIC session stats to compute a Cross-Layer Score steering *when/whether to migrate* (Wi-Fi-if-best policy). Live-network results on Galaxy S10: +20% over GQUIC.
- **Differentiation:** Optimizes the migration *decision*; leaves post-migration CC state untouched. Also requires modem/radio API access (vendor privilege). We are decision-agnostic and transport-native: whatever triggers the migration, we fix what happens *after*.

### C3. CQIC (cross-layer cellular CC)
- **Source:** Lu, Du, Jain, Katti, "CQIC: Revisiting Cross-Layer Congestion Control for Cellular Networks," ACM HotMobile 2015 — https://www.researchgate.net/publication/283093335
- **Year:** 2015
- **Overview:** Reads cellular PHY-layer capacity hints (CQI/DCI) to set the sending rate directly, bypassing probing.
- **Differentiation:** Same as C2 — cross-layer privilege we deliberately avoid. Cite as the "if you have radio access, this exists" bound; our design assumes only RFC 9000 wire mechanisms.

### C4. Sprout
- **Source:** Winstein, Sivaraman, Balakrishnan, "Stochastic Forecasts Achieve High Throughput and Low Delay over Cellular Networks," USENIX NSDI 2013
- **Year:** 2013
- **Overview:** Models cellular link rate as a stochastic process (flicker-noise), forecasts capacity distribution, sends only what keeps p95 queueing delay bounded.
- **Differentiation:** Continuous cellular-rate *tracking*; heavyweight receiver-side inference. We need a one-shot estimate at migration time, not a continuous forecaster. Its evidence that cellular per-UE queues isolate flows (self-congestion dominates) *supports* our dispersion-probe validity argument — cite for that.

### C5. Verus
- **Source:** Zaki, Pötsch, Chen, Subramanian, "Adaptive Congestion Control for Unpredictable Cellular Networks," ACM SIGCOMM 2015
- **Year:** 2015
- **Overview:** Learns a delay-vs-window profile online and walks it to pick cwnd each epoch; no explicit bandwidth estimation.
- **Differentiation:** Again continuous adaptation; needs a warm profile that a fresh path doesn't have — actually *suffers* the same cold-start problem we solve. Useful to note as a class of algorithms our seed could bootstrap.

### C6. Orca (representing the ML-hybrid line)
- **Source:** Abbasloo, Yen, Chao, "Classic Meets Modern: A Pragmatic Learning-Based Congestion Control for the Internet," ACM SIGCOMM 2020
- **Year:** 2020
- **Overview:** DRL agent adjusts a coarse target on top of classic CUBIC fine-grained control; more deployable than pure DRL but still requires trained models.
- **Differentiation:** Same argument as C1: our niche is the ML-free point on the design spectrum, exploiting a protocol-native measurement instant that generic ML approaches don't know exists.

### C7. mQUIC
- **Source:** Kim, Koh, "mQUIC: Use of QUIC for Handover Support with Connection Migration in Wireless/Mobile Networks," IEEE (2023) — https://ieeexplore.ieee.org/document/10268842/
- **Year:** 2023
- **Overview:** Transport-layer handover *detection* (ENETUNREACH error + Handover Detection Timer) triggering migration without OS/link-layer signals; testbed-validated.
- **Differentiation:** Solves *when to start* migration; we solve *how fast to go* afterward. Perfectly composable — mQUIC-style detection + PV-Seed recovery is a natural combined system and a possible stretch experiment.

### C8. Blitz-start / connection-establishment acceleration (context)
- **Source:** e.g., "Blitz-starting QUIC Connections," arXiv:1905.03144 — https://arxiv.org/pdf/1905.03144
- **Year:** 2019
- **Overview:** Accelerates initial connection ramp-up (aggressive IW / handshake piggybacking) for fresh QUIC connections.
- **Differentiation:** Start-of-connection cousin of Careful Resume; neither addresses mid-connection path change. Completes the taxonomy: fast start (Blitz), fast resume (Careful Resume), fast *re-path* (us — unoccupied).

---

## Summary matrix

| # | Candidate | Year | Type | State we take/seed | Direct adaptability | Role in our design |
|---|-----------|------|------|--------------------|--------------------:|--------------------|
| A1 | NewReno (RFC 9002) | 2021 | Host | cwnd, ssthresh | ★★★★★ | Reference host |
| A2 | CUBIC (RFC 9438) | 2008/2023 | Host | cwnd, ssthresh, W_max | ★★★★★ | Primary host (Careful Resume precedent) |
| A3 | BBR v1/v3 | 2016/2023 | Host | BtlBw, RTprop | ★★★★★ | Flagship host (model = our measurements) |
| B1 | Careful Resume | 2021–2026 | Donor | Phase machine, safety rules | ★★★★★ | Safety skeleton; the gap we complete |
| B2 | Westwood+ | 2001 | Donor | B̂×RTT window-setting rule | ★★★★ | Seeding rule + ACK-rate estimation |
| B3 | HyStart++ (RFC 9406) | 2023 | Donor | RTT-slope validation | ★★★★ | Seed-validation + fallback slow start |
| B4 | Packet-pair/train | 1991–2003 | Donor | Dispersion estimator | ★★★★ | The measurement engine (via padded PV frames) |
| B5 | Copa | 2018 | Donor/Host | Delay-based validation; fast reconvergence | ★★★ | Ablation baseline ("is seeding even needed?") |
| C1 | PBQ (BBR+PPO) | 2023 | Related | — | ★ | Heavyweight baseline to argue against |
| C2 | CQUIC | 2020 | Related | — | ★ | Cross-layer decision-side complement |
| C3 | CQIC | 2015 | Related | — | ★ | Radio-privileged upper bound |
| C4 | Sprout | 2013 | Related | — | ★ | Cellular self-congestion evidence |
| C5 | Verus | 2015 | Related | — | ★ | Cold-start-suffering class |
| C6 | Orca | 2020 | Related | — | ★ | ML-hybrid contrast |
| C7 | mQUIC | 2023 | Related | — | ★★ | Composable detection front-end |
| C8 | Blitz-start | 2019 | Related | — | ★★ | Completes fast-start taxonomy |

## Shortlist recommendation

**Hosts:** BBR (flagship — its {BtlBw, RTprop} model is literally what path validation can measure) + CUBIC or NewReno (to prove generality of the seeding interface).
**Skeleton:** Careful Resume's Unvalidated → Validating → Safe Retreat phases, re-sourced from path-validation evidence instead of retained state.
**Estimator:** Packet-train dispersion over padded PATH_CHALLENGE/PATH_RESPONSE exchanges (RFC 9000 §8.2 padding rules make this legal and free), filtered per Dovrolis/Westwood+ techniques, RTT from the RFC 9002 §6.2.2 MAY clause.
**Validation/fallback:** HyStart++ RTT-slope logic; on low confidence, degrade gracefully to (i) similarity-gated partial carry-over, then (ii) spec-default reset.

**Implementation vehicle:** picoquic — ships NewReno/CUBIC/BBR, already contains the Careful Resume implementation from the ASMS 2025 paper (public code), and its maintainer co-authors the Careful Resume draft. quic-go is the fallback if we prefer Go ergonomics over C.
