# Paper Framework

Working title: **Reset, Retain, or Neither? Congestion Control at QUIC Connection
Migration Across Five Implementations**

This document is the plan for the paper, not the paper. It fixes the argument,
the section structure, what evidence supports each claim, and — most importantly
— **what is not yet measured and must be before submission**.

---

## 1. What the paper actually argues

One sentence:

> RFC 9000 §9.4 states an endpoint MUST reset congestion and RTT state on
> migration; across five independent implementations we find that no two behave
> alike, that compliance is not even a binary property, and that the one
> mechanism the specification offers for re-seeding the cleared state is used by
> nobody.

The paper is a **measurement and conformance study**, not a systems paper. It
proposes no new mechanism. Its contribution is evidence about a requirement that
had not been checked, plus the method needed to check it soundly.

### 1.1 Claims, in priority order

| # | Claim | Strength | Where the evidence is |
|---|---|---|---|
| **C1** | Compliance with §9.4 is **not binary**. msquic is compliant at one endpoint and not the other simultaneously (ASYMMETRIC), and obeys the rule for RTT while disobeying it for congestion input (SPLIT). | Strong — source + live, plus msquic's own `// TODO - Correct?` | `data/survey_results.json` → msquic q1/q3; F5 |
| **C2** | Compliance is an **emergent property of state architecture**, not of intent. Five implementations reach their answer by five structurally different mechanisms. | Strong — source, all five | F2; per-implementation mechanism fields |
| **C3** | **Partial compliance is worse than none.** Implementing §9.4 ¶2 without ¶1 took transfer completion from 5/5 to 0/15 in our own patched build. | Strong — our own controlled patch | F4; `code/patches/picoquic_spec_reset.diff` |
| **C4** | Two of five ship a **congestion-reset function with zero call sites**, one carrying a comment stating its purpose. | Strong — source, re-derived from pristine upstream | F1; `code/audits/revalidate_pristine.sh` |
| **C5** | The RFC 9002 §6.2.2 initial-RTT option is **universally unused** (5/5), though every migration performs the measurement. | Strong — source, corroborated live in 2 | F3 |
| **C6** | A **reset-versus-loss discriminator is necessary** for this class of measurement; without it we would have misreported twice, in opposite directions. | Strong — demonstrated concretely | §3.3; corrections C6, C7 |
| **C7** | In msquic the sending endpoint's RTT estimator **does not recover** after migration (5/5, ~3,800 samples each, ~20 s). | **Observation only — mechanism unproven** | F6; must be stated as observation |

**C7 must never be written as a diagnosis.** We know what happens; we have not
built the instrumented build that would show why. An earlier attribution was
withdrawn (correction C4) and must not reappear.

### 1.2 What the paper must NOT claim

1. Any effect on real users, real handsets, or real cellular networks.
2. Generality beyond one commit, one congestion-control algorithm, one
   path-delay pair, one transfer direction per implementation.
3. That these behaviours are bugs. §9.4 non-compliance is a specification
   violation; the §6.2.2 non-use is not a violation at all (it is a MAY).
4. A cause for the msquic stuck-RTT observation.
5. Novelty of the *observation that QUIC migration exists* — only of the
   measurement of what happens to congestion state when it does.

---

## 2. The gap that must be closed before submission

**The paper currently has compliance and mechanism, but only one operating
point.** Everything live was measured at 20 Mbit with a 20 ms → 40 ms path pair.
That is enough to establish *what implementations do*; it is not enough to say
what it *costs*, which is the question a measurement venue will ask.

| Missing | Why it matters | Status |
|---|---|---|
| **Cost sweep across a handover grid** — vary new-path bandwidth and delay (step-up and step-down), measure time-to-recover, goodput loss, completion time | Turns "they behave differently" into "and here is what that costs" — the difference between a note and a paper | **Not started** (PLAN.md P4) |
| Per-implementation time series across migration (cwnd + RTT) | The most legible figure a reader can be given; we have the data, not the plot | Data exists, figure not made |
| msquic instrumented build | Would upgrade C7 from observation to result | Not started |
| Related-work survey | Cannot position the contribution without it | **Not started — see §6** |
| quiche migrate-back-to-old-path | Known untested edge case that a reviewer will ask about | Not started |

**Recommended order:** related work first (it may change the framing), then the
cost sweep, then the time-series figures. The instrumented msquic build is
optional — C7 is publishable as a clearly-labelled observation.

---

## 3. Section structure

Target ~10–12 pages, two-column. Section budget in columns-of-text, not pages.

### 1. Introduction (~1 page)
- Migration is QUIC's headline mobility feature; connection survives, but the
  new path is a different network.
- §9.4 is unambiguous and MUST-level. Nobody had checked whether it is obeyed.
- Contributions, as a bulleted list mapping to C1–C6.
- One-paragraph summary of the most surprising result (compliance is not binary).

### 2. Background (~0.75 page)
- QUIC migration, Connection IDs, path validation, anti-amplification.
- The three requirements, quoted verbatim with their strength levels
  (MUST / MAY / MUST). **Quote the RFC text exactly**; it is the paper's
  yardstick and must be reproducible.
- Why the two halves of §9.4 are inseparable (sets up C3).

### 3. Methodology (~2 pages) — *this section carries the paper's credibility*
- **3.1 The three questions** and why these three.
- **3.2 Dual verification.** Every question answered from source and from a
  running program; disagreement treated as a finding, not noise.
- **3.3 The reset-versus-loss discriminator.** The core methodological
  contribution. Present the constants table. Use the quic-go case as the worked
  example: peaks 274,025–280,414 B, ×0.7 backoff to 191,817–196,289 B, then the
  reset to exactly 40,960 B, 0.44–1.96 ms later, in 5/5 — two events that a naive
  reading records as one.
- **3.4 Testbed and calibration.** Two-path namespace testbed; report the
  calibration honestly, including that dispersion accuracy alone accepted a
  burst setting that sustained-throughput testing rejected (−14.5% at 100 Mbit).
- **3.5 Instrumentation.** Three qlog dialects plus one implementation with no
  usable qlog on Linux; separate parsers per format.
- **3.6 Threats to validity.** Emulation; single configuration; sparse cwnd
  sampling; msquic read through a public statistics API.

### 4. Results: per implementation (~2.5 pages)
One subsection each, in a fixed shape: architecture → Q1 → Q2 → Q3 → live
evidence. Keep each to roughly half a column; detail belongs in the table.

### 5. Cross-cutting findings (~2 pages)
F1–F6, each with its supporting evidence. This is where C1, C2, C4, C5 land.
F4 (partial compliance) deserves its own subsection with the 5/5 → 0/15 result.

### 6. Cost (~1.5 pages) — **depends on the missing sweep**
What each behaviour costs across the handover grid. Without this the paper is a
conformance note; with it, it is a measurement paper.

### 7. Discussion (~1 page)
- The specification angle: §9.4's two paragraphs are separable in prose and
  inseparable in practice; C3 is evidence that the split is a hazard.
- The MAY that nobody takes: is §6.2.2 worth keeping?
- Dead hooks as a signal that the requirement was understood but never wired up.
- What implementers should do; what a future revision might say.

### 8. Limitations (~0.4 page) — explicit, not buried
Lift §1.2 verbatim. State C7 as an observation here too.

### 9. Related work (~0.75 page) — **not yet written, see §6 below**

### 10. Conclusion (~0.3 page)

### Appendix / Artifact
Repository, pinned commits, the 30-check validator, how to reproduce.

---

## 4. Figures and tables

| ID | Content | Source | Status |
|---|---|---|---|
| **Table 1** | The compliance matrix: 5 implementations × 3 questions | `p2_fig1` → rebuild as LaTeX `tabular` | Rebuild as text |
| **Table 2** | Discriminator constants per implementation (initial, floor, factor) | `survey_results.json` | Easy |
| **Table 3** | Mechanism taxonomy: architecture → mechanism → answer | F2 | Easy |
| **Fig 1** | Congestion window at the switch, all five, with each implementation's own initial window marked | `p2_fig4` | Exists; relabel for print |
| **Fig 2** | **Time series of cwnd and RTT across the migration**, one panel per implementation | raw traces | **To build — highest-value missing figure** |
| **Fig 3** | picoquic RTT convergence: old-path value persisting, converging over ~1 s | picoquic reps | To build |
| **Fig 4** | Cost across the handover grid | **needs the sweep** | Blocked |

Do **not** paste the slide figures into the paper unchanged. They are sized for
a projector: fonts too large, colour-dependent, and captioned in presentation
voice. Regenerate at column width with print styling.

---

## 5. Evidence map (for the LaTeX writing pass)

Every number in the paper must come from `data/survey_results.json` or from a
named artifact. When writing, keep `_qa/audit_claims.py` in the loop — extend its
`DOCS` list to include the `.tex` sources so the same prose-versus-data audit
runs over the paper itself.

| Paper element | Authoritative source |
|---|---|
| Any per-implementation answer | `implementations[*].q1/q2/q3.answer` |
| Any window / RTT figure | `implementations[*].live.*` |
| Commit hashes | `data/upstream_commits.txt` |
| Validation count | `validation.checks` / `validation.passed` |
| Anything we got wrong | `corrections[]` (C1–C7) |
| Calibration numbers | `phase1-deliverables/EXPERIMENTS-EXPLAINED.txt` |

---

## 6. Related work — what must be read before framing the contribution

**This is the largest unstarted piece, and it can change the paper's framing.**
Do not write the introduction until it is done.

**Check first, before claiming novelty:**
- **QUIC Interop Runner** — it has a migration test case. Determine precisely
  what it asserts. If it only checks that the connection survives and the
  transfer completes, our gap statement holds and should cite it as the closest
  prior art. If it asserts anything about congestion state, the framing changes.
  *Do not write "nobody has measured this" until this is settled.*

Then survey:
- QUIC implementation-comparison and measurement studies (e.g. work by Rüth,
  Marx, Piraux and colleagues on implementation behaviour and qlog-based
  analysis).
- Connection-migration studies and mobility measurements.
- Congestion-control-on-path-change literature, including MPTCP path management
  and TCP mobility, for the analogous problem in an older transport.
- `draft-ietf-tsvwg-careful-resume` — closest specification-side work; note that
  it explicitly excludes the path-change case, which is where our gap sits.
- Conformance/verification work on transport specifications.

---

## 7. LaTeX setup

**Format decision is open** — it determines the document class and the section
conventions, so settle it before scaffolding.

Once chosen, the layout is:

```
paper/
├── main.tex              document class, packages, \input of sections
├── sections/
│   ├── 01-intro.tex … 10-conclusion.tex
├── figures/              print-styled PDFs, regenerated from the data
├── tables/               generated .tex tables, not hand-typed
├── refs.bib
└── Makefile              latexmk -pdf main.tex
```

Two rules worth fixing now:

1. **Tables are generated, not typed.** Add a `analysis/make_paper_tables.py`
   that emits `tables/*.tex` from `survey_results.json`, exactly as the figures
   and the deck are generated. Hand-typing the compliance matrix into LaTeX
   reintroduces precisely the drift class that has already been corrected three
   times in this project.
2. **Figures are PDF, generated at column width** (3.3 in single column /
   7.0 in double), with fonts at 8–9 pt so they match body text after placement.

---

## 8. Writing order

1. Related work (§6) — may change the framing.
2. Methodology — it is the most complete part and the most defensible.
3. Results and cross-cutting findings — the data is final.
4. Run the cost sweep; write §6 Cost; build Fig 2 and Fig 4.
5. Introduction and conclusion last, once the contribution list is settled.
6. Limitations — write from §1.2 verbatim, do not soften.
7. Run `_qa/audit_claims.py` over the `.tex` sources before every submission.

---

## 9. Honest status

What exists today: a complete five-implementation compliance and mechanism
survey at one operating point, independently validated (30/30), with every
correction recorded. That is a solid short paper or a strong workshop
submission as it stands.

What it is not yet: a full measurement paper, because the cost dimension is
unmeasured. The single most valuable next experiment is the handover grid.
