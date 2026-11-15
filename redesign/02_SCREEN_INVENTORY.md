# MediLink UI/UX Redesign: Phase 2 Screen Inventory

**Date:** 4 Nov 2026 · Companion table with one row per screenshot: `screen_inventory.csv`.

## Headline numbers

| | Count |
|---|---|
| Screenshots in `MediLink_Screenshots` | **143** |
| Pixel-identical duplicates (same screen captured via another path or role) | 25 |
| Visually distinct captures | **118** |
| Debug-only red error screens (not design targets) | 6 |
| **Distinct screen widgets in source** | **30 pages + 7 dialogs/sheets + 1 global banner** |
| Screenshots matched to a source file | **143 / 143** (none unmatched; filenames were descriptive) |

The "143 screens" are many **states** of ~30 real screens. Redesign work is done per screen widget, and each batch then re-verifies every screenshot state that widget produces. Several widgets are shared across roles, for example `PatientDetailPage`, which serves Caregiver, Doctor and Hospital.

---

## Inventory by module

Line numbers refer to git HEAD `a7eb01a`. **Uncaptured** lists states the code can show that have no screenshot. They still get designed and are flagged here so nothing is skipped.

### 1. Onboarding / Auth (26 screenshots)
| Screen widget | Source | Screenshots | Uncaptured states |
|---|---|---|---|
| `StartupGate` (splash) | `app.dart:74` | 001 | — |
| `AuthGate` loading | `app.dart:98` | — | "Securing your MEDILINK session…" |
| `OnboardingPage` (4 intro cards) | `auth_flow.dart:13` | 002–005 | — |
| `WelcomePage` | `auth_flow.dart:154` | 006, 007 (=006) | — |
| `AuthPage(login: true)` | `auth_flow.dart:204` | 008–012, 074 (=008) | — |
| `AuthPage(login: false)` | `auth_flow.dart:204` | 013–020 (016 = 015) | Caregiver/Hospital role forms (same layout as 019) |
| `PermissionsPage` + `PermissionTile` | `auth_flow.dart:442` / `:578` | 021–025 | — |

### 2. Home (9)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `RoleShell` (bottom nav ×4 role variants) | `dashboard.dart:50` (build `:247`) | on every tab screenshot | — |
| `PatientHome` + `HealthStatusCard` + `AiInsightCard` + `ActionTile` | `dashboard.dart:452` (`:553`, `:613`, `:402`) | 026–029 (027, 028 = 026), 073 (Senior), 123 (no readings), 133 (loading) | Vitals error state (`ErrorState`) |
| `RoleOverview` (Caregiver / Doctor / Hospital home) | `dashboard.dart:332` | 075, 093, 111 | — |
| `NotificationsPage` | `dashboard.dart:3766` | 030, 124 (empty) | Loading, error |

### 3. Health and devices (6)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `HealthPage` (+ `BleNoDeviceCard`, `BleStatusBadge`, `BleWaitingPulse`) | `dashboard.dart:658` (`:1498`, `:1414`, `:1462`) | 031, 034, 035 | Connecting / reconnecting / waiting-for-data badges |
| `BlePage` "Connected devices" (`_summaryCard`, `_deviceCard`) | `dashboard.dart:1561` (`:1727`, `:1821`) | 032, 033 (=032), 036 | **Device list with results** (reference 5), scanning, connecting, permission-denied |

### 4. Emergency / SOS (patient, 5)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `EmergencyPage`: idle, hold, verification countdown, outcome | `dashboard.dart:1965` (build `:2534`) | 037 idle, 038 hold, 039 countdown, 040 marked safe, 041 confirmed | SOS sending; outcome **Cancelled**, **Resolved (vitals normal)**, **Hospital escalated**; post-safe cooldown; inline error message |

### 5. Alerts / emergencies (clinician and hospital roles, 9 + states)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `EmergencyList` (caregiver/doctor alerts; hospital active list + filter) | `dashboard.dart:2807` (build `:2927`) | 077, 090, 095, 108 (empty); 112, 113, 115, 120 (hospital); 131 (error); 136 (loading) | Populated caregiver list with "Acknowledge" (unreachable today, see audit §9) |
| Resolve-emergency `AlertDialog` | `dashboard.dart:2875` | 114 | — |

### 6. Connections (patient, 10)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `ConnectionsPage` (hub) | `dashboard.dart:3070` | 042 | — |
| `ConsentPage` | `dashboard.dart:3433` | 044, 045, 126 (empty) | Rejected state, error |
| `_ConnectDialog` | `dashboard.dart:3574` | — | **Whole dialog** (no in-app path reaches it; designed for consistency only) |
| `ContactsPage` (+ overflow `PopupMenuButton`) | `contacts.dart:8` | 046, 047, 051, 052 (=046), 127 (empty) | Loading, error |
| `_ContactForm` bottom sheet (add/edit) | `contacts.dart:141` | 048, 049, 050 | Saving state |

### 7. Patients (clinician roles, 20)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `PatientConnections` | `patients.dart:14` | 076, 089, 094, 107, 116; 129 (empty), 132 (error), 135 (loading) | — |
| `PatientDetailPage` | `patients.dart:96` | 081, 082, 084, 087, 088 (+ doctor/hospital duplicates 099, 100, 102, 105, 106, 117) | Report generating (loading) |
| Shared-record `AlertDialog` | `patients.dart:129` | 083, 101 | — |
| `PatientReportsPage` | `patients.dart:310` | 085, 103 | Empty / loading |

### 8. Messages (12 + 2 states)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `ChatPage` (conversation list) | `dashboard.dart:3662` | 053, 078, 096, 118, 128 / 130 (empty) | — |
| `ConversationPage` | `messaging.dart:21` | 054–057, 079, 086, 097, 104 | Empty thread, sending |

### 9. Vault (6 + 1 state)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `MedicalVaultPage` (+ overflow menu, snackbar) | `medical_vault.dart:14` | 058, 059, 061, 125 (empty) | Uploading |
| Record-viewer `AlertDialog` | `medical_vault.dart:74` | 060 (AI summary), 062 (no summary) | — |
| Remove-record `AlertDialog` | `medical_vault.dart:159` | 063 | — |

### 10. Hospitals and map (11)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `HospitalsPage` (backend registry) | `dashboard.dart:3128` | 043 (= 091, 109, 121) | Empty, error |
| `FindHospitalsPage` (OSM) + `_HospitalRow`, `_FailureView` | `find_hospitals.dart:340` (`:565`, `:807`) | 067, 068, 069, 070 | `_LoadingSkeleton` (`:663`), `_EmptyView` (`:747`), "locating" phase |
| `EmergencyMapPage` | `emergency_map.dart:22` | 092, 110 (empty), 122 | — (tiles don't load in tests) |

### 11. QR (3)
| Screen widget | Source | Screenshots | Uncaptured |
|---|---|---|---|
| `QrPage` | `dashboard.dart:3203` | 064, 065 | — |
| `QrScanPage` + `_PatientInfoResult` | `dashboard.dart:3278` / `:3332` | 066 (no camera) | **Scanned-patient result** (needs a real camera) |

### 12. Profile / settings (5)
| Screen widget | Source | Screenshots |
|---|---|---|
| `ProfilePage` (Senior Mode, Logout) | `dashboard.dart:3792` | 071, 072 (Senior on), 080, 098, 119 |

### 13. Global states and banners
| Widget | Source | Screenshots |
|---|---|---|
| `OfflineBanner` (offline / server unreachable / reconnecting) | `common.dart:207` | 134, 137 (reconnecting uncaptured) |
| `LoadingState`, `ErrorState`, `EmptyState` | `common.dart:132 / 148 / 173` | used across 123–136 |

### 14. Debug-build captures (6, not design targets)
138–143: Consent, Contacts, Messages ×2, Vault, Patients. These red screens disappear only with the State fix (audit decision D8). After the redesign they'll show the restyled screens in release mode.

---

## Flags (screenshots needing special handling)

| # | Flag |
|---|---|
| 044, 112, 120, 081/087/099/105/117 | Collapsed row layouts (audit §6.2–6.4) |
| 028, 075, 093, 111 | Broken action-tile grid |
| 074 | Labelled "after logout welcome" but is pixel-identical to Login (008) |
| 066, 092/110/122 | Camera feed and map tiles can't render in widget tests; "after" captures will have the same limitation |
| 031/034/035 | Trend card is a static placeholder (audit §8) |
| 138–143 | Debug-only error screens |

---

## Reusable components

**Existing (restyle, keep name and API):** `PageFrame`, `SectionCard`, `PrimaryButton`, `StatusBadge`, `EscalationStageBadge`, `LoadingState`, `ErrorState`, `EmptyState`, `OfflineBanner`, `ActionTile`, `HealthStatusCard`, `AiInsightCard`, `BleStatusBadge`, `BleWaitingPulse`, `BleNoDeviceCard`, `PermissionTile`, `_HospitalRow`, `_LoadingSkeleton`, `_EmptyView`, `_FailureView`, `MedilinkColors`.

**Proposed new (Phase 3, under `lib/theme/` and `lib/ui/`):**

* **Tokens:** `AppColors`, `AppSpacing`, `AppRadius`, `AppElevation`, `AppText` (type scale), `AppMotion` (durations, curves, reduce-motion check).
* **Theme:** a central `AppTheme.light()` covering `ColorScheme`, text theme, AppBar, NavigationBar, buttons (filled, tonal, outlined, text), inputs, cards, list tiles, chips, dialogs, bottom sheets, snackbars, switches, progress indicators and popup menus.
* **Components:**
  * `IconBadge` (tinted circle with a centered icon, sizes S/M/L)
  * `FeatureTile` (Home grid tile)
  * `InfoCard`
  * `ListRowCard` (title, meta, trailing, no collapse)
  * `SectionHeader`
  * `StatusPill`
  * `VitalsHero` (BPM plus vitals row)
  * `SafetyButton` (high-contrast emergency actions)
* **Brand:** `MedilinkMark` and `MedilinkLockup` (CustomPainter logo), `OnboardingIllustration` ×4, `PageDots` (morphing indicator).
* **Display helpers (pure formatting):** `formatTimestamp`, `humanizeEnum`.

---

## Proposed batch plan (Phases 4–5)

| Batch | Screens | Screenshots covered |
|---|---|---|
| Pilot (Phase 4) | Onboarding ×4, Splash, Home (patient), Health, Emergency alert/SOS, Profile, plus logo directions | 001–005, 026–029, 031, 034–041, 071–073, 123, 133 |
| B1 Auth | Welcome, Login, Sign-up, Permissions, AuthGate | 006–025, 074 |
| B2 Patient core | Notifications, BLE page, Connections hub, Contacts + sheet, Consent | 030, 032–033, 036, 042, 044–052, 124, 126–127 |
| B3 Records and QR | Vault + 2 dialogs, QR, QR scan | 058–066, 125 |
| B4 Messaging and hospitals | Chat list, Conversation, HospitalsPage, FindHospitals, Emergency map | 043, 053–057, 067–070, 091–092, 109–110, 121–122, 128, 130 |
| B5 Clinician roles | RoleOverview, PatientConnections, PatientDetail + dialog, Reports, EmergencyList + resolve dialog | 075–090, 093–108, 111–120, 129, 131–132, 135–136 |
| B6 Global and leftovers | OfflineBanner, Loading/Error/Empty, uncaptured states, launcher icon, Android splash | 134, 137 + all uncaptured states |
