# Phase 2 — Presentation Script

**Deck:** `PhaseII_Review.pptx` (13 slides) · **Runtime:** ~13 minutes + questions

| Presenter | Slides | Share |
|---|---|---|
| **Sivaa** | 1 – 5 | 40% |
| **Kenin** | 6 – 8 | 30% |
| **Krithik** | 9 – 11 | 20% |
| **Shafeeq** | 12 – 13 | 10% |

Text in quote blocks is meant to be **spoken**. Stage directions are in *italics*. Learn the shape, not the words.

**The one rule:** Phase 1 was a detective story with one suspect. Phase 2 is the line-up. The payoff is that **no two of them behave the same way** — so don't give that away early. Slides 2 and 3 should feel like setup, not conclusion.

---

# SIVAA — Slides 1 to 5 (~5 min 15 s)

You reconnect this to Phase 1, pose the question, and deliver the headline table.

## Slide 1 — Title (~15 s)

> "Last time we showed that one QUIC implementation ignores a rule the standard says it must follow. This time we checked the other four."

*Move on. Don't teach here.*

## Slide 2 — Where we left off (~1 min 15 s)

> "A quick recap, because everything today builds on it.
>
> When your phone switches from Wi-Fi to mobile data, the connection survives — but it has to work out how fast to send on the new network. The standard is explicit: an endpoint MUST reset its speed estimate. Forget the old network, start over.
>
> We checked picoquic. It doesn't. And the striking part wasn't that the behaviour was missing — it was that the *code* was there. The function that performs the reset exists, implemented for all seven of picoquic's congestion-control algorithms, and nothing calls it.
>
> Then we implemented the rule ourselves, to measure what it costs. Transfers went from completing five times out of five to zero out of fifteen — because the rule has a second half that's easy to miss.
>
> Which left an obvious question."

## Slide 3 — The question (~1 min 15 s)

> "Does anyone else get this right?
>
> We took the five QUIC implementations that carry most of the internet's traffic — picoquic, quic-go, quiche, Microsoft's msquic, and ngtcp2 — across three programming languages. And we asked each of them the same three questions.
>
> One: when the network changes, does it reset the speed estimate? That's a MUST.
>
> Two: the protocol already takes a free measurement of the new network, for security reasons. Does the implementation use it? That one's optional — a MAY.
>
> Three: does it ignore the leftover replies still arriving from the old network? Also a MUST — and that's the half we ourselves missed last phase.
>
> *[beat]* And we answered every question twice. Once by reading the source code, once by measuring the running program. If the two disagreed, we'd made a mistake and we went and found it."

*That last line matters. Say it deliberately — it's the methodological claim the whole talk rests on.*

## Slide 4 — The table (~1 min 30 s)

> "Here's the answer.
>
> *[let them read for a moment]*
>
> Five implementations. Three questions. **No two of them behave the same way.**
>
> *[point to picoquic]* One fails both of the MUSTs outright.
>
> *[point to quic-go and quiche]* Two of them pass both — and we'll see in a moment that they get there by completely unrelated routes.
>
> *[point to msquic]* One can't be scored yes or no at all, and needed two new categories we hadn't planned for.
>
> *[point to the bottom row]* And the middle row — the optional one, the free measurement — is a clean sweep. Not one of the five uses it.
>
> Every cell here is backed by both source and measurement."

## Slide 5 — Dead code (~1 min 15 s)

> "The first finding is the one we didn't expect to repeat.
>
> In picoquic, the reset function exists and is never called. We assumed that was a one-off — a single project's oversight.
>
> Then we found the same thing in quiche. A function named `on_connection_migration`, carrying a comment written by its own authors saying *'Called when connection migrates and cwnd needs to be reset'* — and zero call sites. One empty implementation, and nothing that ever invokes it.
>
> *[point]* Two of the five ship the code to obey the rule, and never run it. Different projects, different languages, different companies. The same dead hook.
>
> The other three do call theirs. So this isn't a universal problem — it's a pattern in half the field."

**Hand over:**
> "Kenin will take you through what the ones that *do* comply are actually doing — because that turned out to be the more interesting half."

---

# KENIN — Slides 6 to 8 (~4 min)

You own the three cross-cutting findings. Yours is the section that turns a compliance checklist into a result.

## Slide 6 — Five mechanisms (~1 min 20 s)

> "Here's what surprised us most. The implementations that comply don't comply in the same way. There are five implementations here and five different mechanisms.
>
> quic-go does the obvious thing: when it migrates, it throws away its congestion controller and builds a new one.
>
> quiche never resets anything at all. It keeps separate state per network path, so migrating creates a *new* path — and a new path is simply born at the starting value. It's compliant by accident of architecture.
>
> ngtcp2 uses a packet-number watermark: it records the number of the next packet it will send, and everything older than that is excluded from congestion accounting from then on.
>
> msquic resets at one end of the connection and not the other.
>
> And picoquic reuses its path object, so the old speed estimate simply carries across.
>
> The point is that 'does it comply?' turns out to be the *less* interesting question. *How* it complies is determined by how the implementation stores its state — and that's a design decision made long before anyone thought about migration."

## Slide 7 — The unanimous finding (~1 min 20 s)

> "The second finding is the only one where all five agree.
>
> Before a connection will trust a new network address, it has to run a security check — it sends a random number and requires it echoed back. That's compulsory. It happens at every single handover.
>
> And because it's a round trip on the new network, it measures that network's speed. For free. The standard explicitly permits using that measurement.
>
> All five decline.
>
> *[beat]* Two of them we caught in the act, in consecutive lines of their own logs. Measure the new network at about forty milliseconds — then discard it and seed a fixed default instead. One uses a hundred milliseconds, the other three hundred and thirty-three.
>
> Nobody is breaking a rule here; it's a MAY, not a MUST. But every implementation in this survey performs a measurement and throws the result away."

## Slide 8 — Not binary (~1 min 20 s)

> "The third finding is that our own question was too simple.
>
> msquic splits its state. Congestion control is shared across the whole connection, but round-trip time is tracked separately per network path. That produces two answers that don't fit in a yes-or-no column.
>
> On the first question, the answer is *asymmetric*. The endpoint that **observes** the move resets. The endpoint that **makes** the move does not. So the same connection is compliant at one end and non-compliant at the other, simultaneously.
>
> On the third question, the answer is *split*. Round-trip measurements from the old network are correctly excluded. Acknowledged byte counts are not — they reach the congestion controller unfiltered.
>
> *[point at the code line]* And we're not the first to wonder about that. This is msquic's own source, at the exact line responsible. `Paths[0]`, hardcoded, with a comment from their own developers reading *'TODO — Correct?'*
>
> They flagged the uncertainty. We're reporting what it costs."

**Hand over:**
> "Krithik has the result that came out of that, and how we checked ourselves."

---

# KRITHIK — Slides 9 to 11 (~2 min 45 s)

You deliver the most striking single result, then establish why the numbers can be trusted.

## Slide 9 — The striking one (~1 min 10 s)

> "Following that thread gave us the most striking result in the survey.
>
> After msquic's server migrates, it never recovers its sense of the new network. Its round-trip estimate stays pinned at exactly its starting default — three hundred and thirty-three milliseconds — and its minimum-RTT field stays at the 'no measurement yet' marker.
>
> For every one of about three thousand eight hundred samples per run. For twenty seconds. In five runs out of five. The real network delay was forty milliseconds.
>
> You can see the cost: about thirteen megabits per second, where another implementation managed nineteen on exactly the same link.
>
> And the irony is the finding. The endpoint that *follows* the rule ends up with a permanently broken estimate. The endpoint that *ignores* it keeps a working one.
>
> One caveat, and it matters: this is an observation, not a diagnosis. We know what happens. We have not yet built an instrumented version to prove *why*, so we're not going to claim we have."

## Slide 10 — The evidence (~50 s)

> "This is what the measurements look like underneath all of that.
>
> For each implementation, the send-rate setting just before the network switch, and just after. The dashed line is that implementation's own starting value.
>
> *[point]* Where the bar drops to exactly the dashed line, that's a reset.
>
> And we were careful here. A collapse to the starting value only *proves* a reset if an ordinary loss event couldn't produce the same number. So for each implementation we looked up its loss arithmetic first and confirmed it couldn't. In quic-go that mattered a great deal — in all five runs there are actually *two* events, not one: an ordinary loss backoff to exactly seven tenths of the peak, and then, one to two milliseconds later, the real reset to exactly forty thousand nine hundred and sixty bytes. Without the arithmetic we'd have reported a single collapse."

## Slide 11 — Rigour (~45 s)

> "Which brings me to how we know we're not fooling ourselves.
>
> Every claim answered twice, from source and from measurement, and they had to agree.
>
> Then we wrote a second validator from scratch — sharing no code with the first — that re-derives every claim independently, pulling source straight out of git and re-parsing the raw traces with its own parsers. Twenty-seven checks. Twenty-seven pass.
>
> And it earned its keep: along the way this process caught seven things we'd got wrong. A window we'd described as flat that had actually declined. A repetition count of four that was really three. A piece of live evidence too weak to carry the claim we'd hung on it. A cause we'd asserted without proving. A path delay recorded as sixty milliseconds that was really forty. And — the one that stings — a verdict line in our own parser that would have called a loss event a reset.
>
> All seven are corrected, and all seven are recorded in the data with the reason — so nobody re-introduces them later."

**Hand over:**
> "Shafeeq will close."

---

# SHAFEEQ — Slides 12 to 13 (~1 min 20 s)

Short, confident, honest.

## Slide 12 — What we're not claiming (~45 s)

> "What we're deliberately *not* claiming.
>
> We haven't shown any of this harms real users. We measured what implementations do and what it costs in our testbed — whether that matters at internet scale is a different study.
>
> Everything here is emulation. No real phones, no real cellular networks.
>
> Each implementation was tested at one commit, one configuration, one direction of transfer.
>
> The stuck-estimate result is an observation whose cause we haven't proven.
>
>
> We'd rather say all that ourselves than have it found for us."

## Slide 13 — Where this goes (~35 s)

> "The survey is complete. Five implementations, three questions, source and measurement behind every cell.
>
> Next is the cost — how much each of these behaviours actually loses, across a range of network conditions rather than the single pair we used here. Then the paper.
>
> And the findings go back to the projects. Two of them ship a reset that never runs. One has a comment in its own source asking whether the line we identified is correct. Those are worth reporting upstream regardless of what we publish.
>
> Nobody had measured this. Now it's measured.
>
> Thank you — happy to take questions."

---

# Questions your guide is likely to ask

**"Isn't 'nobody uses the free measurement' just because it's optional?"** *(Kenin)*
> "Partly — it's a MAY, so nobody's in violation. But it's still striking that five independent teams all built the same round trip and all discarded the result. Either the option isn't worth taking, which would be worth knowing, or it's been overlooked five times over, which would also be worth knowing. Nobody has asked the question before."

**"How do you know a drop to the initial window is a reset and not just loss?"** *(Krithik)*
> "We checked each implementation's loss arithmetic before claiming anything. quic-go, for instance, cuts by thirty percent on loss and floors at 2,560 bytes — neither can produce 40,960. And in one trace we found both events, four tenths of a millisecond apart. Without that check we'd have reported one."

**"Could your testbed be producing these results?"** *(Krithik)*
> "That's why Phase 1 spent two weeks validating the emulator before measuring anything, and found two flaws that would have corrupted every number. Also — the source audits don't involve the testbed at all, and they agree with the measurements in every case."

**"Is picoquic's behaviour a bug you should report?"** *(Sivaa)*
> "Yes, and we intend to. But the interesting part isn't the individual bug — it's that half the field ships this code and never calls it, and that our own careful attempt to implement the rule made things worse. That's a sign the rule is harder to follow than it looks, which is a finding about the specification, not just about one project."

**"On slide 10, picoquic's bar is BELOW the dashed line. Doesn't that mean it reset harder than the others?"** *(Krithik)*
> "No, and this is the case the discriminator was built for. A reset assigns the initial window *exactly* — 15,360 bytes, or 14,240 from the negotiated packet size. Across five runs, not one sample took either value. What happened instead is that the window fell straight past both, down to 2,848 bytes, which is exactly two packets — picoquic's floor — about 110 milliseconds later, with roughly fifty packets lost. A window below the initial value can't have been *set* by a reset, because a reset sets that value precisely. Below it is what a loss cascade looks like."

**"Are all five implementations measured the same way?"** *(Shafeeq)*
> "Yes. All five now have five repetitions at the same operating point — 20 megabit, 20 and 40 millisecond paths. picoquic originally had a single run at 50 megabit, which wasn't directly comparable, so we re-ran it at the standard point. Same conclusion, five times over, and every run verified from the packet log to be a genuine address change rather than a port change — because a port-only change is exempt from the rule and would prove nothing."

---

# Practical notes

- **Rehearse the three handovers.** They're written above; say them as written.
- **Slides 4, 6 and 8 carry the talk.** If time runs short, compress 10 and 11 — never 4, 6 or 8.
- **Slide 4 needs a pause.** Let people read the table before you start narrating it.
- **Read the msquic `// TODO - Correct?` line aloud, verbatim.** It's the single most quotable thing in the deck.
