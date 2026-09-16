# How MediLink tells a real panic attack from a false alarm

This explains, in plain language, the core idea behind MediLink's panic
detection: **multi-sensor agreement**. If you only remember one sentence,
remember this one: *no single sensor is ever trusted alone to call a real
emergency — the system looks for several sensors telling the same story
before it decides something is genuinely wrong.*

## The problem: heart rate alone lies to you

A racing heart is the most obvious sign something might be wrong. It's also,
on its own, almost useless for telling a panic attack apart from a jog up
the stairs — both send heart rate into the 120-160 bpm range. A wearable
that only watches heart rate has to choose between two bad options: alarm
on every workout (alarm fatigue, and eventually the patient ignores real
alerts too), or set the threshold so high that a real panic attack gets
missed.

This is not a hypothetical concern for this project — it's the exact
failure mode MediLink's own test dataset was built to expose. Two of its
three categories, `false_alarm` (exercise) and `real_panic`, are
*deliberately* given heart rates in the same range (round-trip check in
`amends/48b`: the two categories' mean heart rates land within 3 bpm of each
other). If heart rate were the only signal, the system genuinely could not
tell them apart.

## The principle: look for agreement, not just one loud signal

Instead of one sensor, MediLink reads up to six at once and asks: *do they
agree with each other in a way that only makes sense for one specific
situation?* A racing heart by itself proves nothing. A racing heart **and**
a body that's sitting still **and** skin turning cold and clammy **and** a
sudden spike in sweat — all four pointing the same direction — is a much
stronger, much harder-to-fake signature of real physiological distress.

Here's what each sensor actually reports, in plain terms, and what it looks
like under the two situations that most need telling apart:

| Sensor | What it measures | During exercise (false alarm) | During real panic |
|---|---|---|---|
| **Heart rate** | Beats per minute | High | High — **same as exercise, not useful alone** |
| **Motion** | How much the body is physically moving | High — the body is working | Low — the body is sitting still |
| **EDA / GSR** (skin conductance) | Sweat gland activity | Rises, but slowly, from heat build-up | Spikes sharply and fast — a fear/stress reflex, not a temperature reflex |
| **Skin temperature** | Peripheral (wrist) skin temp | Rises slightly — blood flows *to* the skin to cool the body down | Drops slightly — blood flows *away* from the skin, toward muscles ("fight or flight") |
| **Pulse rate variability (PRV)** | How much the gap between heartbeats varies, beat to beat | Drops somewhat | Drops sharply — a much bigger collapse than exercise causes |
| **SpO2 (blood oxygen)** | Oxygen saturation | Stays roughly normal | Stays roughly normal — not a useful discriminator here either |

The two situations that look identical on heart rate alone (top row) become
easy to tell apart the moment you add **motion** — the single biggest
discriminator, because exercise requires the body to move and panic doesn't.
The other three (EDA, skin temperature, PRV) add a second, independent line
of evidence, so the decision doesn't rest on motion alone either: a panic
attack has a very particular "fight or flight" fingerprint (sweat spike,
cold skin, collapsed heart-rhythm variability) that ordinary exertion simply
doesn't produce, even when both send heart rate to the same place.

## How this actually gets decided

MediLink doesn't hand-code a set of "if heart rate is high AND motion is
low THEN panic" rules. Instead, a trained model (`tier_classifier_v3`,
covered in `amends/48d`) looks at all six numbers together and learns the
combined pattern from thousands of examples — 180 simulated patients, each
with their own personal baseline heart rate, sweat level, skin temperature
and pulse variability, so the model learns real physiological patterns, not
one person's idea of "normal."

Tested honestly — on 45 simulated patients the model never saw a single
reading from during training — it got the category right **97.3% of the
time**. More importantly for the specific problem this document is about:
in that entire test, it **never once** mistook a false alarm for a real
panic attack, or a real panic attack for a false alarm, in either direction.
Every mistake it did make was a borderline call near "normal" (like the
first few seconds right as an episode starts), never confusing the two
categories multi-sensor agreement was specifically built to separate.

## What if the wearable only has 3 sensors, not 6?

Not every device MediLink supports has an EDA, skin-temperature, or PRV
sensor. The system is built to degrade gracefully instead of failing: if a
reading arrives without one of those three fields, the missing value is
filled in with a sensible population-average default (a resting-normal
number for that sensor) rather than crashing or refusing the reading (see
`amends/48e`). The decision leans more heavily on whichever sensors are
actually present. This is also why nothing about "multi-sensor agreement"
is an all-or-nothing requirement — heart rate + motion alone already rules
out the most common false alarm (exercise); the extra three sensors sharpen
the call further whenever they're available, they don't gate it.

## The takeaway

One racing pulse could mean anything. A racing pulse that arrives *together
with* stillness, cold sweaty skin, and a collapsing heart rhythm means
something specific — and that's the only combination the system will ever
call a real panic attack.
