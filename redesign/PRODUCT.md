# MediLink: product context for the redesign

- **What it is:** connected health monitoring and emergency response. A wearable streams vitals; abnormal patterns trigger a patient check ("I'm OK" / "I NEED HELP"); unanswered or confirmed emergencies call/text caretakers from the phone's SIM and alert hospitals.
- **Roles:** Patient, Caregiver, Doctor, Hospital. Same app, role-specific shell.
- **Users under stress:** emergency screens must be legible, high contrast and hard to mis-tap. No decorative motion there.
- **Trust:** real data only; status indicators show real values; no fake badges, charts or counts.
- **Scope of this redesign:** presentation layer only. Behaviour, data, timing, routes and backend are unchanged (see `redesign/01_PHASE1_AUDIT.md`).
- **Platform:** Android only. Senior Mode raises text scale to ≥1.18; layouts are verified at 1.0 / 1.18 / 1.3.
