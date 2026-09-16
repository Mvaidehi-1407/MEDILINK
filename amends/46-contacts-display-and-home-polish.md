# 46 — Emergency Contacts real data + Home screen polish

## Part A — Emergency Contacts page

### Investigation

Traced the full path from signup to the Contacts screen before changing
anything:

- **Signup**: `RegisterRequest` (`backend/app/schemas/auth.py`) requires
  exactly 3 `caretakers` (name + phone) for every `PATIENT` account — a
  `model_validator` rejects registration otherwise. So the task's premise
  ("every account has at least one contact set up at registration") is
  enforced server-side, not just a convention.
- **Storage**: `AuthService._create_caretaker_contacts()`
  (`backend/app/services/auth_service.py`) writes one `emergency_contacts`
  document per caretaker: `patientId`, `name`, `phone`, `relation: None`,
  `isPrimary` (true for the first), `priority`.
- **Backend read**: `GET /contacts` (`backend/app/api/contacts.py`) returns
  `MongoRepository(db, "emergency_contacts").list({"patientId": user["id"]}, ...)`,
  sorted primary-first — i.e. exactly the logged-in patient's own real,
  registered contacts, scoped by their JWT-derived id.
- **Frontend**: `ContactsPage` (`frontend/lib/features/contacts.dart`) calls
  `ApiClient.emergencyContacts()` → `GET /contacts`, and renders each
  contact's real `name`, `phone`, `relation` (when set), and a `PRIMARY`
  badge — plus working edit/delete actions.

**Conclusion: this already works correctly end-to-end.** Every field the
task asked for (caretaker name + phone number, per registered contact,
pulled from the backend) was already wired correctly, with no mock/sample
data anywhere in the path. No code change was needed or made for Part A —
adding a duplicate/parallel implementation would just be redundant code for
behavior that already exists and was verified by reading the request →
storage → response → render chain in full.

If the actual complaint is something narrower than "it doesn't show real
data" — e.g., a specific field looks wrong on a real device, or the primary
badge doesn't show for one entry — flag exactly that and it can be checked
directly, since the wiring itself is confirmed correct.

## Part B — Home screen polish

Scoped to `PatientHome` in `frontend/lib/features/dashboard.dart` (the
screen with the Health / Emergency / Vault / Hospitals / QR / Messages
6-tile grid). Both tiles' rows already used one shared `ActionTile` widget
(no per-tile style overrides), so most of what was asked — text centering,
consistent per-tile padding, even grid spacing — was already correct by
construction. Two real, visible small inconsistencies were fixed:

1. **Icon sizing/centering** (`ActionTile`, `dashboard.dart`): the icon was
   a bare `Icon(icon, color: MedilinkColors.blue)` with no explicit size,
   so it inherited the ambient default (24dp) — technically identical
   across all 6 tiles, but different Material glyphs (e.g. the dense
   `qr_code_2_outlined` icon vs. the simpler `chat_bubble_outline`) don't
   fill that same nominal box the same way, so they can read as
   inconsistently sized/centered next to each other. Wrapped the icon in a
   fixed `SizedBox(height: 28)` + `Center`, with an explicit `size: 26`,
   so every icon now reserves the exact same footprint above its label
   regardless of that icon's own internal glyph bounds.
2. **Card spacing**: the gap was 16px between the health status card and
   the AI insight card, but 20px between the AI insight card and the
   feature grid — a visible, uneven step. Tightened the second gap to 16px
   to match the first.

Not changed (already consistent, so nothing to do): text label centering
(`textAlign: TextAlign.center`, identical style/spacing on every tile,
unchanged) and grid spacing between tiles (`Wrap(spacing: 10, runSpacing:
10)`, unchanged).

No redesign, no new widgets, no layout restructuring, and no color changes
— only the icon-box fix and the one spacing number above.

## Scope

Only `frontend/lib/features/dashboard.dart` was touched (Part B; two small
edits inside `ActionTile` and `PatientHome`). No changes were made for
Part A. No emergency-creation, calling, SMS, Bluetooth, or model/AI code
was touched.
