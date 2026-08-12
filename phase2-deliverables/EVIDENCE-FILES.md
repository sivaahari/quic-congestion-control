# Phase 2 — Evidence to Submit

A ready-made bundle is at **`phase2-deliverables/evidence/`** — **123 files, 43 MB**. Submit that folder.

Rebuild it any time:

```bash
wsl -d Ubuntu-24.04 -u root -- bash /home/sivaa/pvseed/_build/build_evidence_bundle_p2.sh
```

---

## The five strongest single files

If you can only point at a handful, point at these.

| File | What it proves |
|---|---|
| **`01_survey_data/survey_table.csv`** | The whole survey on one page — every implementation, all three answers, mechanism, commit hash, initial/minimum window, loss factor, and live results. |
| **`04_validation/validation_run_output.txt`** | **30 checks, 30 pass.** An independent re-derivation of every claim, by code sharing nothing with the analysis pipeline. |
| **`01_survey_data/survey_results.json`** | The single source of truth. Every figure and table is generated from it, and it carries the `_correction_*` entries recording what we got wrong and fixed. |
| **`05_code/commit_hashes.txt`** | The exact commit of all five implementations, so anyone can reconstruct precisely what was tested. |
| **`03_live_measurements/`** | The raw measurement CSVs behind every "reset observed" claim. |

---

## What's in the bundle

### `01_survey_data/` — the findings

- **`survey_results.json`** — authoritative record: per-implementation answers with mechanism and evidence, commit hashes, discriminator constants, live results, the six cross-cutting findings, a `corrections` list of every claim that did not survive validation, and a `validation` block the validator writes itself on each run.
- **`survey_table.csv`** — the same thing flattened to one row per implementation, for reading or pasting into a report.

### `02_source_audits/` — 12 re-runnable audit scripts

One or more per implementation. These are what established the source-side answers: dead-hook detection, call-site enumeration, discriminator constants, and the RFC-exemption checks. They can be re-run against the cloned repositories at any time.

Notable: `revalidate_pristine.sh` re-derives the picoquic finding from **pristine upstream source pulled out of git object storage**, so our own later modifications cannot contaminate it.

### `03_live_measurements/` — 27 files, the measured evidence

Per-repetition congestion-window and RTT time series for every implementation that was measured live:

| Implementation | Reps | What's included |
|---|---|---|
| quic-go | 5 | server metrics CSV per rep |
| quiche | 5 | server metrics CSV + parser summary per rep |
| msquic | 5 | server **and** client metrics CSV per rep, plus `rep_status.txt` |
| ngtcp2 | 5 | migration-evidence extract per rep |
| picoquic | 5 | server metrics CSV + parser summary per rep |

The ngtcp2 entries are extracts rather than full logs: its example client emits ~445 MB per run. The full logs are retained in the project tree.

### `04_validation/` — the independent check

- **`revalidate_fresh.py`** — a validator written from scratch that shares no code with any parser or figure generator in the project. It reads the claims and re-derives each from primary sources: `git show HEAD:<path>` for code, raw traces for measurements, with its own parsers for all three qlog formats.
- **`recheck_f6.py`** — resolves the one check that initially failed, which turned out to be a bug in the new validator rather than a wrong claim.
- **`validation_run_output.txt`** — the run: **30 PASS, 0 FAIL, 0 UNVERIFIABLE.**

### `05_code/` — the apparatus

Testbed construction and shaping scripts, all experiment scenarios, the analysis and figure code, the harness sources, our picoquic patch as a diff, and the commit hashes file. Source only — no binaries or build trees.

### `06_sample_traces/` — one raw trace per implementation, gzipped

So a reviewer can open the actual protocol logs rather than trusting our parsing. Three different formats are represented, which is itself part of the story: picoquic writes a single JSON document, quic-go and quiche write JSON-SEQ, msquic has no usable qlog on Linux at all and had to be instrumented differently.

---

## What is deliberately not included

| Excluded | Why |
|---|---|
| Full raw qlog set (many GB) | Fully summarised by the CSVs; one sample per stack is included. |
| ngtcp2 full client logs (~445 MB each) | Extracts included instead. |
| Compiled binaries and build trees | Reproducible from the recorded commits. |
| The five cloned implementations | Identified by commit hash; anyone can clone them. |

Everything excluded is at `/home/sivaa/pvseed/` inside WSL, reachable from Windows at `\\wsl.localhost\Ubuntu-24.04\home\sivaa\pvseed\`.

---

## If you're asked "how do you know this is right?"

Three answers, in increasing strength:

1. **Every claim was answered twice** — once from source, once from measurement — and they had to agree.
2. **The reset-vs-loss discriminator.** A drop to the initial window only proves a reset if an ordinary loss event could not produce the same number. We looked up each implementation's initial window, loss floor and reduction factor and confirmed it. In quic-go that revealed a loss event and a reset 0.4 ms apart, where we would otherwise have reported one.
3. **An independent validator**, written from scratch, re-derives all 30 checks from primary sources and passes all of them. It also caught six things we had got wrong along the way — including a verdict line in our own parser that would have called a loss event a reset. All six are corrected and recorded, with their reasons, in the `corrections` list in `survey_results.json`.
