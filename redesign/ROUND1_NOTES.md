# Round 1: logged-out first impression (6 Nov 2026)

Status: **awaiting your approval.** Nothing committed. Logo direction B (Tile) applied.

## Edited hunks (all vs git `a7eb01a`)
| File | Method / area | Change |
|---|---|---|
| `lib/app.dart` | `MedilinkApp.build` | `theme: AppTheme.light()`; `builder` wraps the unchanged Senior-Mode `MediaQuery` in an `AnnotatedRegion` (transparent status bar, canvas nav bar) |
| `lib/app.dart` | `StartupGate.build` | Returned widget only: `BrandBackdrop` + `SplashBrand` (was `LoadingState`). The `Future.microtask(context.go…)` line is untouched |
| `lib/app.dart` | imports | + `services`, `theme/*`, `ui/components` |
| `lib/widgets/common.dart` | `MedilinkColors` | Values now alias tokens (names unchanged) |
| `lib/widgets/common.dart` | `build()` of `EscalationStageBadge`, `PrimaryButton`, `StatusBadge`, `LoadingState`, `ErrorState`, `EmptyState`, `_OfflineBannerState`, `SectionCard` | Restyle only; constructors, labels and `OfflineBanner` connectivity logic unchanged |
| `lib/features/auth_flow.dart` | `_OnboardingPageState.build` | Lockup header, `OnboardingCard`, `PageDots`, `PressScale`; same `PageView`, `onPageChanged`, `_finish`, 250 ms `nextPage/previousPage` |
| `lib/features/auth_flow.dart` | `WelcomePage.build` | Centred lockup + tagline, primary Sign in, quiet Create account; same `context.go` targets |
| `lib/features/auth_flow.dart` | `_AuthPageState.build`, `_field`, `_phoneField`, `_caretakerFields` | Mark + single heading, grouped spacing, caretaker cards, inline error banner; validators, controllers, `_form` key, `_submit` unchanged |
| `lib/features/auth_flow.dart` | `_PermissionsPageState.build` | Heading in the scroll list, pinned bottom action; same tiles, `_onTileStatus`, `_allGranted` gate |
| `lib/features/auth_flow.dart` | `_PermissionTileState.build` | `IconBadge`, stacked layout, tonal Allow/Open Settings below text; same `_request`/`openAppSettings`, same strings (denial sentence now on its own line) |
| `pubspec.yaml` | `fonts:` | Plus Jakarta Sans ×4, Bricolage Grotesque ×2. No packages added |
| Android | `AndroidManifest.xml` | `android:label="MediLink"` (only line changed) |
| Android | `res/mipmap-*/ic_launcher.png`, `ic_launcher_foreground.png`, `mipmap-anydpi-v26/ic_launcher.xml`, `values/colors.xml` | New launcher: adaptive (teal bg + white pulse, themed-icon monochrome) + legacy PNGs |
| Android | `drawable*/launch_background.xml`, `drawable-*/splash_logo.png`, `drawable-*/splash_icon.png`, `values-v31`, `values-night-v31` | Native splash pre-12 and 12+ |
| New | `lib/theme/tokens.dart`, `lib/theme/app_theme.dart`, `lib/ui/brand.dart`, `lib/ui/components.dart`, `lib/ui/onboarding.dart` | Design system |

Logic check: every `onPressed`, `onChanged`, `onPageChanged`, `context.go`, `validator`, `setState`, controller and `Duration(milliseconds: 250)` line removed from `auth_flow.dart` reappears unchanged (re-indented). `lib/core/*` and `backend/` have zero diff lines.

## Results
- `flutter analyze`: 40 issues, all `info`, identical set to baseline. **0 new.**
- Existing tests (`flutter test`): **20/20 pass.**
- Harness copy (`redesigned_app_screenshots/_capture_tooling/round1_capture_test.dart`): 17/17 pass, no overflow at 360×800, 384×832, 412×915 × text scale 1.0 / 1.18 / 1.3.
- `adb logcat`: no Flutter errors during the phone run.

## Connection table (Round 1, logged out)
| Screen | Data loads | Actions work | New errors |
|---|---|---|---|
| Native splash → StartupGate | n/a (local session) | routes to onboarding / welcome as before | none |
| Onboarding ×4 | n/a | Next, Back, Skip, Get started (writes onboarded flag) ✓ phone | none |
| Welcome | n/a | Sign in, Create account ✓ phone | none |
| Login | not exercised on phone (no credentials typed) | empty-form validation ✓ phone; wrong password, loading, offline ✓ harness | none |
| Sign-up | not exercised on phone | role menu, empty-form validation ✓ phone; filled + duplicate email ✓ harness | none |
| Permissions | n/a | ✓ harness only (real grants are off-limits; screen needs login) | none |
| AuthGate loading | n/a | ✓ harness | none |
Backend reachability was not tested in Round 1 (no network call made from the phone). logcat showed the phone failing DNS for `play.googleapis.com` at one point, so check your connection before the Round 2 login.

## Android 12+ splash limits
- System controls timing and exit; the app cannot show the wordmark or tagline there (icon only, optional branding image is API 31+ and discouraged).
- Icon must fit the 192 dp safe circle; stock Android masks it to a circle. HyperOS on your phone does **not** mask and rendered the icon-background colour as a hard square, so the splash uses a pre-rendered rounded tile with no icon background (works on both).
- Dark mode uses the same light splash because the app UI is light-only.
- The Flutter splash (`StartupGate`) shows for about one frame, so its fade/scale is effectively invisible on device; the harness shot is taken after the reveal.

## Wording proposals (not applied)
| Where | Current | Proposed |
|---|---|---|
| Sign-up / Welcome headline | "Join MEDILINK", "MEDILINK" in body copy | "Join MediLink" / "MediLink" (matches launcher label) |
| Login button | "Login" (title says "Sign in") | "Sign in" |
| Phone field label | "Phone number (+countrycode...)" (truncates at 1.3×) | Label "Phone number", hint "+91 98765 43210" |
| Permissions | "MEDILINK needs every permission below … -- each one…" | "MediLink needs these to protect you. Each is used only during a real emergency." |
| Permission denial | "You said no -- tap Allow to try again." | "Not allowed yet. Tap Allow to try again." (also fixes audit §9.4 tone) |
| Sign-up grouping | (no headings) | Optional small headings "Your details" / "Sign-in details" |
| Android recents title | `MaterialApp.title: 'MEDILINK'` | "MediLink" |
| Home tagline | (none) | "Your health, our priority" (Round 2, only if you approve) |

## Known limits / deviations
- Role dropdown menu still opens edge-to-edge (framework behaviour of `DropdownButtonFormField`, no width option; type must stay for the harness). Selection highlight now teal.
- Welcome/Splash wordmark reads "MediLink" (was `MEDILINK` text) — your call (see proposals).
- `StartupGate` spinner removed (it was never visible for more than a frame).
- Home header logo is deferred to Round 2.
