# Changed-files log

Running list of every project file changed by the redesign, updated after each batch.

| Batch | File | Type | Notes |
|---|---|---|---|
| Phase 1–2 | — | — | No source, asset, config or screenshot file changed. Only `redesign/` was added. |
| Round 1 | `frontend/lib/app.dart` | edit | `MedilinkApp.build` theme + system bars; `StartupGate.build` returned widget |
| Round 1 | `frontend/lib/widgets/common.dart` | edit | `MedilinkColors` values; `build()` of 8 shared widgets |
| Round 1 | `frontend/lib/features/auth_flow.dart` | edit | `build()` + private builders of Onboarding, Welcome, Auth, Permissions, PermissionTile |
| Round 1 | `frontend/pubspec.yaml` | edit | `fonts:` only |
| Round 1 | `frontend/lib/theme/tokens.dart`, `app_theme.dart` | new | Tokens and theme |
| Round 1 | `frontend/lib/ui/brand.dart`, `components.dart`, `onboarding.dart` | new | Components |
| Round 1 | `frontend/assets/fonts/*` | existing, now referenced | Provided by you |
| Round 1 | `frontend/android/app/src/main/AndroidManifest.xml` | edit | Label "MediLink" |
| Round 1 | `frontend/android/app/src/main/res/**` | edit + new | Launcher icons, adaptive icon, colors, native splash (pre-12 and 12+) |
| Round 1 | `redesigned_app_screenshots/**` | new | Screenshots, harness copy, contact sheets |
| Round 1 | `redesign/DESIGN.md`, `PRODUCT.md`, `ROUND1_NOTES.md`, `references/` | new | Docs |

Never touched: `frontend/lib/core/*`, `backend/`, `MediLink_Screenshots/`, `find_hospitals.dart`, `dashboard.dart` and all other feature files.

| Round 3 | `frontend/lib/features/dashboard.dart` | edit | Nav bar (MedilinkNavBar + reference icons), Home per ref 1, HealthStatus/AI cards, Health trends -> coming-soon fallback, Emergency **build only** (siren, pill buttons, pink info strip, bell; onTapCancel lock guard), QR per ref 3 (+Download), Notifications error state, ProfilePage -> ProfileBody, 2 setState fixes. BLE region restored to a7eb01a (Round 2 BLE widget restyle reverted, saved in `redesign/patches/`) |
| Round 3 | `frontend/lib/features/profile_pages.dart` | new | Profile (ref 4), avatar (camera/gallery, crop, backend save), App settings, Server address, About, Help |
| Round 3 | `frontend/lib/ui/fallback.dart`, `frontend/lib/ui/app_icons.dart` | new | FallbackScreen/View (5 kinds), crash widget; reference icons, nav bar, shimmer/skeletons |
| Round 3 | `frontend/lib/ui/components.dart`, `theme/tokens.dart`, `widgets/common.dart` | edit | FeatureTile `leading`, haptic; stadium SafetyButton; motion 250/400 ms; LoadingState skeleton; ErrorState -> FallbackView |
| Round 3 | `frontend/lib/main.dart`, `app.dart` | edit | `ErrorWidget.builder`; go_router `errorBuilder` (no route changes) |
| Round 3 | `frontend/lib/features/auth_flow.dart` | edit | "Server settings" link on Login/Sign-up |
| Round 3 | `contacts.dart`, `medical_vault.dart`, `patients.dart`, `emergency_map.dart` | edit | `setState(() => _future = ...)` -> block body (5 calls) |
| Round 3 | `frontend/pubspec.yaml` | edit | `image_picker: ^1.1.2`; `assets: - assets/icons/` |
| Round 3 | `frontend/assets/icons/*.png` | new | 14 icons cropped from your reference screenshots |
| Round 3 | `redesign/freeze/*`, `redesign/verify.ps1`, `redesign/PHONE_SETUP.md`, `redesigned_app_screenshots/_capture_tooling/{sos_regression,profile_fallback}_test.dart` | new | Freeze check, verification script, phone setup, tests |
