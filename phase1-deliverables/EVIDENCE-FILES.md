# Evidence of Experiments — What to Submit

A ready-made bundle has been assembled at **`phase1-deliverables/evidence/`** — **59 files, 3.6 MB**. Submit that folder.

It is a curated subset. The full raw dataset is **2.6 GB** (138 qlog protocol traces, several 46 MB each). That is not submittable and most of it is redundant — the summary CSVs already contain everything derived from those traces. One representative trace pair is included, gzipped, so a reviewer can inspect the raw format.

Rebuild the bundle at any time:

```bash
wsl -d Ubuntu-24.04 -u root -- bash /home/sivaa/pvseed/_build/build_evidence_bundle.sh
```

---

## What's in the bundle, and what each file proves

### `01_calibration/` — proof that the measuring instrument was validated

The strongest methodological evidence in the project. It shows the emulator was tested against known ground truth *before* any real measurement was taken.

| File | Rows | What it proves |
|---|---|---|
| `calibration.csv` | 20 | Emulator accuracy across 4 link speeds × 5 shaper settings. Shows the failure mode where a mis-set shaper reports 39.6 Gbit/s on a 5 Mbit link. |
| `calibration_raw.csv` | 100 | Every individual trial behind the above. |
| `sustained.csv` | 20 | Sustained-throughput check. Shows burst 1600 loses 14.5% at 100 Mbit while burst 3200 loses 0.8%. |
| `sustained_raw.csv` | 100 | Individual trials. |
| `train_length_sweep.csv` | 72 | Measurement-burst length sweep. Shows 5-packet bursts fail (+56% error) and 8-packet bursts with correction are accurate to <1%. |
| `train_length_sweep_raw.csv` | 504 | Individual trials. |
| `aud_1/2/3.json` | — | Raw per-packet arrival timestamps and derived rate estimates from three independent reproduction runs. |

### `02_measurements/` — the actual findings

| File | Rows | What it proves |
|---|---|---|
| `baseline_migration.csv` | 3,185 | Full time series (congestion window, bytes in flight, RTT estimates) for every migration trial, labelled by scenario, arm and repeat. |
| `baseline_summary.csv` | 20 | One row per trial: window before/after migration, recovery time, byte deficit, loss counts, completion. **This is the file the headline numbers come from.** |

### `03_test_output/` — proof the implementation under test is sound

| File | What it proves |
|---|---|
| `_task2_full_suite_flag_off.log` | picoquic's own test suite: **548 tests, 0 failures**, with our modification present but disabled. |
| `_baseline_results_only.txt` | Migration/NAT-rebinding test output **before** our change. |
| `_afteredit_results_only.txt` | The same tests **after** our change, flag off. |
| `CONTROL_IS_CLEAN.txt` | A diff of the two showing they are **byte-identical** — i.e. our control arm really is unmodified picoquic. |
| `_tls_full_output.log` | Encryption-library build and test output. |

### `04_run_logs/` — the experiments actually executing

Timestamped console output from each experiment run: the two baseline suites, the routing verification, the port/IP checks, and the rebuild. These show the commands, parameters and results as they happened.

### `05_code/` — the apparatus

| Path | What it is |
|---|---|
| `testbed/` (18 files) | Network construction, traffic shaping, calibration tools, experiment scenarios. |
| `analysis/` (8 files) | Trace parsing, dataset construction, figure and deck generation. |
| `harness/migrate_client.c` | The modified QUIC client that performs an IP-changing migration. |
| `picoquic_our_changes.diff` | **314 lines** — the exact source change we made to picoquic, as a patch. |
| `picoquic_upstream_commit.txt` | `0dc8ba8b2be30246720934d3f43a144b372e1a90` |
| `picotls_upstream_commit.txt` | `f07f1c8c68b237f1468bc1f1fe1b68aba3ff23b4` |

The two commit files matter: they let anyone reconstruct the exact code we tested.

### `06_sample_traces/` — raw protocol evidence

Three gzipped qlog files (a client/server pair from the rule-following run, plus a server trace from the rule-ignoring run) and the corresponding console output. qlog is the IETF-standard QUIC logging format — a reviewer can open these and inspect every packet, frame and congestion-window change directly.

---

## The four strongest individual files

If you can only point at a handful:

1. **`02_measurements/baseline_summary.csv`** — the findings, one row per trial.
2. **`03_test_output/CONTROL_IS_CLEAN.txt`** — proves the comparison is fair.
3. **`01_calibration/calibration.csv`** — proves the instrument was validated.
4. **`05_code/picoquic_our_changes.diff`** — proves exactly what we changed and what we didn't.

---

## Not included, and why

| Excluded | Reason |
|---|---|
| 138 qlog traces (2.6 GB) | Too large; fully summarised by the CSVs. Three samples included. |
| `results/raw/baseline_v1_contaminated/` (320 files) | Superseded measurements, invalidated by the bug documented in Experiment 10. Retained locally for the record but **must not be quoted**. |
| Built binaries, object files | Reproducible from the recorded commits. |

If your evaluator wants the complete raw dataset, it is at `/home/sivaa/pvseed/results/` inside WSL — reachable from Windows at `\\wsl.localhost\Ubuntu-24.04\home\sivaa\pvseed\results\`.

---

## Reproducibility statement

Every figure and number in the deck is generated by a checked-in script from checked-in data. Nothing was hand-edited. `EXPERIMENTS-EXPLAINED.txt` Part 4 lists the exact command to reproduce each experiment.
