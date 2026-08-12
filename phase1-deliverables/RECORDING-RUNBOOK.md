# Phase 1 — Runbook

## What's in this folder

| File | What it is |
|---|---|
| `PhaseI_Review.pptx` | **The deck** — 12 slides, editable |
| `PRESENTATION-SCRIPT.md` | **Speaking script**, split across the four presenters |
| `figures/v2_figA…figD.png` | The four narrative figures used in the deck |
| `figures/fig3, fig4` | Method figures (calibration), used on slide 10 |
| `PhaseI_PVSeed_Review.pptx` | Superseded v1 deck — kept only for reference, do not present |

Every number in the deck traces to captured measurement data or to a verbatim RFC quotation. Nothing is illustrative or projected.

---

## On the video

**The animated HTML demo has been discarded.** It replayed two congestion-window traces over a three-second window, but the underlying recordings contain only 15 and 11 sample points — QUIC only logs a sample when the value materially changes — so the animation was thin, and it conveyed nothing that slide 4's figure doesn't convey better as a still image people can study while you talk.

An animation has to show something a static chart cannot. That one didn't, and it would have been a second thing to go wrong on the day.

### If a video is required

Record the real system instead of an animation of its output. That is more convincing anyway — it shows the testbed exists and works:

```bash
wsl -d Ubuntu-24.04 -u root -- bash /home/sivaa/pvseed/testbed/scenarios/migrate_demo.sh
```

This stands up the four-namespace virtual network, starts a QUIC server and client, transfers a 64 MB file, forces the client to change network address partway through, captures the logs from both ends, and tears everything down. Roughly 60–90 seconds of real output.

**Narrate these three moments:**

1. **Setup** — "this builds a virtual network with two separate paths between a client and a server, each with its own bandwidth and latency."
2. **The migration line** — the client prints when it moves to the new address. "That's the handover happening — the client has changed network address mid-download."
3. **Completion** — "the transfer finished intact across the switch. The logs from that run are what produced the numbers in slide 4."

**Two cautions.** Live migration has a known intermittent stall (roughly one run in five) that resolves itself after about 30 seconds — do a dry run first, and record a clean take. And run it maximised in a dark terminal; the output is plain text and reads better with room.

If a video isn't strictly required, the deck plus the script is the stronger deliverable. Don't add a video for its own sake.

---

## Presenting

Read `PRESENTATION-SCRIPT.md` first — it has the full speaking text, the slide split, timings, and prepared answers to the five questions most likely to come up.

**Split:** Sivaa slides 1–4 (40%) · Kenin 5–7 (30%) · Krithik 8–10 (20%) · Shafeeq 11–12 (10%)

**The shape of the argument** — if you remember nothing else, remember this sequence:

> There's a rule → we checked → it's being ignored → so we followed it → **and it broke** → because the rule has two halves → nobody has checked who else gets this wrong → **that's the paper**

Slides 4, 5 and 6 are the talk. Everything else is setup or follow-through. If you run short on time, cut slide 9 and compress slide 10.

---

## Rebuilding anything

```bash
wsl -d Ubuntu-24.04 -u root -- bash -c "cd /home/sivaa/pvseed && python3 analysis/make_figures_v2.py && python3 analysis/make_deck_v2.py"
```

Then copy the results back into this folder:

```bash
wsl -d Ubuntu-24.04 -u root -- bash /home/sivaa/pvseed/_build/publish_deliverables.sh
```

Source files live in the WSL project at `/home/sivaa/pvseed/analysis/` — `make_figures_v2.py` builds the figures, `make_deck_v2.py` builds the deck.
