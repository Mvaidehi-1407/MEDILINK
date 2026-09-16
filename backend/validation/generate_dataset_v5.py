"""
MediLink synthetic multi-sensor panic-detection dataset generator (v5).

Adds three sensors that v1/v3 never had -- eda_gsr_level, skin_temp_c, prv_ms --
on top of the original heart_rate_bpm, spo2_percent, motion_level. Every
sequence is one simulated patient across time, in one of three categories:

  normal       -- everyday baseline activity, no panic event at all.
  false_alarm  -- a real physiological event that LOOKS alarming on heart rate
                  alone (exercise) but is not panic. The multi-sensor signature
                  is what should let a model tell it apart from real_panic.
  real_panic   -- a genuine acute panic/anxiety episode while the patient is
                  physically still.

Row-level ground truth (per amends/26's row_label fix): every sequence in
false_alarm/real_panic has a randomized onset row. Rows BEFORE onset are
still genuinely normal vitals, so they're labeled "normal" in row_label even
though the sequence-level `category` column says false_alarm/real_panic for
the whole sequence. Only `row_label` should be used as row-level ground
truth; `category` is sequence-level metadata.

Output: panic_dataset_v5.csv
"""

import argparse
import csv
import random
from datetime import datetime, timedelta, timezone

random.seed(42)  # reproducible output

BASE_TIME = datetime(2026, 9, 13, 8, 0, 0, tzinfo=timezone.utc)
DEVICE_ID = "TEST-DEVICE-01"
INTERVAL_S = 10  # one reading every 10s, matching v1/v3's cadence

FIELDNAMES = [
    "category", "row_label", "sequence_id", "row_index", "device_id", "patient_id",
    "timestamp", "heart_rate_bpm", "spo2_percent", "motion_level",
    "eda_gsr_level", "skin_temp_c", "prv_ms",
]


def noisy(value, spread):
    return value + random.uniform(-spread, spread)


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


# ---------------------------------------------------------------------------
# Per-patient baselines
# ---------------------------------------------------------------------------
# Real patients don't share one resting heart rate or one resting skin
# conductance -- a fit 25-year-old's resting HR and a sedentary 60-year-old's
# can differ by 20+ bpm, and baseline EDA/PRV vary just as much with fitness,
# hydration, and autonomic tone. Drawing one baseline per PATIENT (not per
# reading) means the noise a model has to learn to ignore looks like real
# between-subject variation, not just sensor jitter.
def make_patient_baseline():
    return {
        "hr": random.uniform(62, 88),           # resting heart rate, bpm
        "spo2": random.uniform(96.5, 99),        # resting SpO2, %
        "eda": random.uniform(1.5, 4.5),         # resting skin conductance, microsiemens (uS)
        "temp": random.uniform(33.0, 35.0),      # resting peripheral (wrist) skin temp, C
        "prv": random.uniform(45, 75),           # resting PRV (beat-to-beat interval variability), ms
    }


# ---------------------------------------------------------------------------
# Category sensor models
# ---------------------------------------------------------------------------
# Each function returns the CATEGORY's target value at row `i` of `n`, given
# the patient's own baseline and (for false_alarm/real_panic) the onset row
# the event starts ramping at. `noisy()` is applied on top by the caller so
# every model here describes the true underlying signal, not sensor jitter.

def normal_sequence(baseline, i, n):
    """Everyday activity: nothing pathological is happening at any point.

    - heart_rate_bpm: sits at the patient's own resting baseline; small
      random walk instead of a flat line since real resting HR drifts
      breath-to-breath (respiratory sinus arrhythmia), not a constant.
    - motion_level: variable, not flat -- someone going about their day
      sits, stands, walks, sits again. This variability is exactly what
      must NOT be confused with the sharp, sustained ramps below.
    - eda_gsr_level: low and stable. Skin conductance only rises with
      sympathetic arousal (heat, exertion, stress) or emotional stimuli --
      none of which are present here.
    - skin_temp_c: stable around baseline; peripheral skin temperature
      doesn't move much without a thermoregulatory or vasomotor trigger.
    - prv_ms: HIGH and close to baseline. High beat-to-beat variability is
      the signature of a dominant, unstressed parasympathetic (vagal) tone
      -- the healthy resting state this category represents.
    """
    hr = baseline["hr"] + random.uniform(-4, 4)
    motion = clamp(3 + 3 * random.uniform(-1, 1), 0, 7)  # ambient daily-life motion
    eda = baseline["eda"] + random.uniform(-0.3, 0.3)
    temp = baseline["temp"] + random.uniform(-0.15, 0.15)
    prv = baseline["prv"] + random.uniform(-5, 5)
    return hr, motion, eda, temp, prv


def _ramp_progress(i, onset_row, ramp_rows):
    """0.0 before onset, rising to 1.0 over `ramp_rows`, then held at 1.0."""
    if i < onset_row:
        return 0.0
    return clamp((i - onset_row) / ramp_rows, 0.0, 1.0)


def false_alarm_sequence(baseline, i, n, onset_row, ramp_rows):
    """Exercise-type event: real exertion, not panic -- the physiology a
    naive HR-only model would wrongly flag as an emergency.

    - heart_rate_bpm: rises HIGH, but gradually, tracking motion -- exercise
      HR climbs over tens of seconds as the body ramps up effort, it doesn't
      spike instantly.
    - motion_level: rises HIGH and stays high, moving together with heart
      rate. This HR-motion correlation is exercise's defining signature --
      the heart is working because the body is working.
    - eda_gsr_level: rises, but MODERATELY -- exercise sweating is mostly
      thermoregulatory (the body cooling itself down) and builds up over
      the same timescale as the temperature rise below, not a fight-or-
      flight spike.
    - skin_temp_c: rises SLIGHTLY -- muscular exertion generates heat, and
      blood is shunted toward the skin (vasodilation) to help dissipate it,
      warming the periphery.
    - prv_ms: drops SOME -- sustained physical effort shifts autonomic
      balance toward sympathetic drive too, but it's a partial, proportional
      shift tied to workload, not the acute collapse seen under panic.
    """
    progress = _ramp_progress(i, onset_row, ramp_rows)
    hr = baseline["hr"] + progress * random.uniform(55, 75) + random.uniform(-5, 5)
    motion = clamp(3 + progress * random.uniform(5, 7), 0, 10)
    eda = baseline["eda"] + progress * random.uniform(3.5, 6.5) + random.uniform(-0.4, 0.4)
    temp = baseline["temp"] + progress * random.uniform(0.4, 0.9) + random.uniform(-0.1, 0.1)
    prv = baseline["prv"] - progress * random.uniform(20, 35) + random.uniform(-4, 4)
    return hr, motion, eda, temp, prv


def real_panic_sequence(baseline, i, n, onset_row, ramp_rows):
    """Genuine acute panic/anxiety episode while the patient stays still --
    the resting-anomaly signature no amount of exertion can explain.

    - heart_rate_bpm: rises HIGH, and SHARPLY -- a real panic attack's
      tachycardia is a fight-or-flight adrenaline surge, reaching a high
      rate within a much shorter ramp than exercise's gradual buildup.
    - motion_level: stays LOW throughout -- this is the key discriminator
      from false_alarm. The patient is sitting or lying still; nothing
      mechanical explains the racing heart, which is exactly what makes it
      a medical concern rather than exertion.
    - eda_gsr_level: SHARP spike -- eccrine sweat glands are innervated
      almost purely sympathetically, so acute psychological/emotional
      arousal (fear, panic) produces a fast-onset, high-amplitude
      conductance spike, distinct from exercise's slower thermoregulatory
      rise. This is modeled with a materially higher amplitude and a
      shorter ramp than false_alarm's EDA rise.
    - skin_temp_c: drops SLIGHTLY -- acute sympathetic activation causes
      peripheral vasoconstriction (blood is redirected away from the skin
      toward core muscles/organs, the "fight or flight" reflex), producing
      the classic cold, clammy extremities of a panic attack -- the
      opposite direction from exercise's vasodilation-driven warming.
    - prv_ms: drops SIGNIFICANTLY -- a much larger, more abrupt collapse in
      beat-to-beat variability than exercise, reflecting acute vagal
      withdrawal and sympathetic dominance rather than a workload-
      proportional shift.
    """
    progress = _ramp_progress(i, onset_row, ramp_rows)
    hr = baseline["hr"] + progress * random.uniform(45, 65) + random.uniform(-5, 5)
    motion = clamp(1 + random.uniform(-1, 1) * (1 - progress * 0.5), 0, 3)
    eda = baseline["eda"] + progress * random.uniform(9, 15) + random.uniform(-0.5, 0.5)
    temp = baseline["temp"] - progress * random.uniform(0.3, 0.7) + random.uniform(-0.1, 0.1)
    prv = baseline["prv"] - progress * random.uniform(35, 55) + random.uniform(-3, 3)
    return hr, motion, eda, temp, prv


# ---------------------------------------------------------------------------
# Row assembly
# ---------------------------------------------------------------------------

def build_sequence(category, sequence_id, patient_id, n_rows):
    baseline = make_patient_baseline()
    rows = []

    onset_row = None
    ramp_rows = None
    if category != "normal":
        # Onset randomized 15%-35% into the sequence (never in the first
        # couple of rows, and always leaving room for the ramp+sustain
        # phase after it) -- mirrors v3's randomized onset per amends/26.
        onset_row = random.randint(max(2, int(n_rows * 0.15)), int(n_rows * 0.35))
        # Panic ramps up faster (shorter transition) than exercise, per the
        # physiological reasoning above -- both are expressed as row counts
        # so they scale with the sequence's own length.
        ramp_rows = max(2, int(n_rows * (0.10 if category == "real_panic" else 0.25)))

    for i in range(n_rows):
        if category == "normal":
            hr, motion, eda, temp, prv = normal_sequence(baseline, i, n_rows)
            row_label = "normal"
        elif category == "false_alarm":
            hr, motion, eda, temp, prv = false_alarm_sequence(baseline, i, n_rows, onset_row, ramp_rows)
            row_label = "normal" if i < onset_row else "false_alarm"
        else:  # real_panic
            hr, motion, eda, temp, prv = real_panic_sequence(baseline, i, n_rows, onset_row, ramp_rows)
            row_label = "normal" if i < onset_row else "real_panic"

        # spo2 isn't a primary discriminator for any of these three
        # categories on this sensor set -- kept near the patient's own
        # baseline with mild noise (and a small extra dip once an event is
        # under way, from the mild hyperventilation/increased O2 demand
        # either exertion or acute anxiety can cause) rather than pinned
        # flat, so it still looks like a live sensor reading.
        active = category != "normal" and i >= onset_row
        spo2 = baseline["spo2"] + random.uniform(-0.6, 0.6) - (random.uniform(0, 1.5) if active else 0)

        ts = BASE_TIME + timedelta(seconds=i * INTERVAL_S)
        rows.append({
            "category": category,
            "row_label": row_label,
            "sequence_id": sequence_id,
            "row_index": i,
            "device_id": DEVICE_ID,
            "patient_id": patient_id,
            "timestamp": ts.isoformat().replace("+00:00", "Z"),
            "heart_rate_bpm": round(clamp(hr, 40, 190)),
            "spo2_percent": round(clamp(spo2, 85, 100), 1),
            "motion_level": round(clamp(motion, 0, 10), 1),
            "eda_gsr_level": round(clamp(eda, 0, 25), 2),
            "skin_temp_c": round(clamp(temp, 30, 39), 2),
            "prv_ms": round(clamp(prv, 5, 120)),
        })
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--num-sequences", type=int, default=180,
                         help="Total patient sequences across all 3 categories (default 180, split evenly).")
    parser.add_argument("--output", default="panic_dataset_v5.csv")
    args = parser.parse_args()

    categories = ["normal", "false_alarm", "real_panic"]
    # Round-robin assignment keeps the 3 categories within 1 sequence of each
    # other even when --num-sequences isn't divisible by 3.
    assignments = [categories[i % 3] for i in range(args.num_sequences)]

    all_rows = []
    counters = {c: 0 for c in categories}
    for idx, category in enumerate(assignments):
        counters[category] += 1
        patient_id = f"PATIENT-{idx + 1:04d}"
        sequence_id = f"seq_{category}_{counters[category]:03d}"
        # Sequence length varies per patient too -- not every recording is
        # the same duration in the real world.
        n_rows = random.randint(40, 70)
        all_rows.extend(build_sequence(category, sequence_id, patient_id, n_rows))

    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"Wrote {len(all_rows)} rows across {len(assignments)} patient sequences "
          f"({', '.join(f'{c}={counters[c]}' for c in categories)}) to {args.output}")


if __name__ == "__main__":
    main()
