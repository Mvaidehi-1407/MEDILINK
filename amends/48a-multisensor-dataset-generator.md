# 48a — Multi-sensor dataset generator (Step 1)

## What was built

Recreated `backend/validation/` (deleted earlier for the multi-sensor model
rebuild) with one new file: `generate_dataset_v5.py`. It generates synthetic
patient sequences across three categories -- `normal`, `false_alarm`
(exercise), `real_panic` -- each row carrying six sensor fields:
`heart_rate_bpm`, `spo2_percent`, `motion_level` (all three carried over from
v1/v3), plus three new ones: `eda_gsr_level` (skin conductance, microsiemens),
`skin_temp_c` (peripheral/wrist skin temperature), and `prv_ms` (pulse rate
variability derived from beat-to-beat timing).

## Design

- **Per-patient baselines**: `make_patient_baseline()` draws one resting HR,
  SpO2, EDA, skin temp, and PRV per patient (not per reading), so between-
  patient variation looks like real physiology, not sensor noise.
- **Category signatures** (`normal_sequence`, `false_alarm_sequence`,
  `real_panic_sequence`), each with inline physiological reasoning:
  - `normal`: HR at baseline with small breath-driven drift, variable
    daily-activity motion, low/stable EDA, stable temp, HIGH PRV (vagal
    dominance at rest).
  - `false_alarm` (exercise): HR and motion rise HIGH together and
    gradually (the HR-motion correlation IS the exercise signature),
    moderate/slower EDA rise (thermoregulatory sweating), slight temp RISE
    (exertional vasodilation), moderate PRV drop (workload-proportional
    sympathetic shift).
  - `real_panic`: HR rises HIGH and SHARPLY while motion stays LOW (patient
    physically still -- the key discriminator from false_alarm), EDA
    SPIKES sharply and fast (sympathetic-only eccrine sweat response),
    slight temp DROP (peripheral vasoconstriction -- "cold clammy hands"),
    PRV collapses SIGNIFICANTLY (acute vagal withdrawal, much larger than
    exercise's drop).
- **Row-level ground truth**: `false_alarm`/`real_panic` sequences get a
  randomized onset row (15-35% into the sequence); rows before onset are
  genuinely normal vitals and are labeled `row_label="normal"` even though
  the sequence-level `category` column says otherwise -- the same mechanism
  `amends/26` fixed scoring against for v3.
- **Noise**: every sensor value gets `random.uniform(...)` jitter on top of
  its category-driven target, then is clamped to a physiologically sane
  range (e.g. SpO2 85-100%, PRV 5-120ms).
- **Sequence count/length**: 180 total sequences (60 per category, via
  round-robin assignment), each 40-70 rows at a 10s cadence -- one simulated
  patient per sequence.

## Proof run

```
$ python generate_dataset_v5.py
Wrote 10072 rows across 180 patient sequences (normal=60, false_alarm=60, real_panic=60) to panic_dataset_v5.csv
```

No crash. Row counts:

| | by sequence-level `category` | by row-level `row_label` |
|---|---|---|
| normal | 3331 | 4962 |
| false_alarm | 3470 | 2639 |
| real_panic | 3271 | 2471 |
| **total** | **10072** | **10072** |

`row_label`'s normal count (4962) is higher than `category`'s (3331) because
it correctly absorbs every false_alarm/real_panic sequence's pre-onset rows
-- confirming the row-level mechanism works, not a bug.

Whole-dataset value ranges (all physiologically plausible, no blanks/NaNs):

| field | min | max |
|---|---|---|
| heart_rate_bpm | 57 | 166 |
| spo2_percent | 94.5 | 99.6 |
| motion_level | 0.0 | 10.0 |
| eda_gsr_level | 1.05 | 19.69 |
| skin_temp_c | 32.26 | 35.95 |
| prv_ms | 5 | 79 |

Sample rows, `seq_false_alarm_001` (46 rows, onset at row 16) vs.
`seq_real_panic_001` (40 rows, onset at row 14) -- the discriminating
signature is visible by the last few rows of each:

```
false_alarm, sustained (rows 42-45):
row_index | row_label    | hr  | spo2 | motion | eda  | temp  | prv
42        | false_alarm  | 141 | 97.9 | 10.0   | 7.50 | 35.42 | 43
43        | false_alarm  | 137 | 97.1 | 9.8    | 4.77 | 35.78 | 42
44        | false_alarm  | 127 | 97.4 | 8.7    | 7.06 | 35.75 | 28
45        | false_alarm  | 130 | 97.4 | 8.6    | 5.36 | 35.79 | 27

real_panic, sustained (rows 36-39):
row_index | row_label   | hr  | spo2 | motion | eda   | temp  | prv
36        | real_panic  | 124 | 98.4 | 1.2    | 12.04 | 33.16 | 5
37        | real_panic  | 128 | 98.1 | 1.5    | 12.03 | 33.48 | 5
38        | real_panic  | 125 | 98.0 | 1.3    | 15.01 | 33.16 | 8
39        | real_panic  | 130 | 98.5 | 1.1    | 11.86 | 33.27 | 9
```

Both reach comparably HIGH heart rate (~125-140), but false_alarm holds HIGH
motion (8.6-10.0) the whole time while real_panic holds LOW motion (1.1-1.5)
-- and real_panic's EDA (12-15 uS) and PRV (5-9ms) are far more extreme than
false_alarm's (5-7.5 uS, 27-43ms), exactly per the design above.

Onset transition also confirmed directly in the raw output --
`seq_real_panic_001` rows 14-16: EDA jumps 2.49 -> 6.08 -> 8.24 and PRV drops
52 -> 48 -> 39 -> 27 within 3 rows of onset (sharp), vs.
`seq_false_alarm_001` rows 16-18: HR climbs 66 -> 79 -> 85 and motion rises
3.0 -> 3.5 -> 4.1 gradually (slower ramp), matching the "sharp panic onset vs.
gradual exercise onset" design intent.

**Step 1 CONFIRMED WORKING.**

## Scope guardrail confirmed

Only `backend/validation/generate_dataset_v5.py` and its output
`backend/validation/panic_dataset_v5.csv` were created. No other files
touched.
