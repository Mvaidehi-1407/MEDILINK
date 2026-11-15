# MediLink design system

Source of truth: `frontend/lib/theme/tokens.dart`, `frontend/lib/theme/app_theme.dart`, `frontend/lib/ui/*`.
Home (reference 1) is the master reference; references 1–7 are kept in `redesign/references/`.

## Principles
- Calm, clean, trustworthy. One clear primary action per screen.
- Expressive motion only on splash and onboarding. Everywhere else motion is quiet and functional; emergency surfaces have none.
- Layouts differ by purpose; the tokens and components keep them consistent.

## Colour tokens (`AppColors`)
| Token | Hex | Use |
|---|---|---|
| canvas | `#EFF5FC` | Screen background, system nav bar, splash background |
| surface | `#FFFFFF` | Cards, inputs, sheets, dialogs |
| surfaceMuted | `#F6F9FD` | Quiet fills (switch track off) |
| border / borderStrong | `#E2E9F3` / `#C9D4E3` | 1px card + input borders / outlined buttons, inactive dots |
| ink | `#14213D` | Titles, primary text |
| inkSecondary | `#55657D` | Body, subtitles (5.9:1 on white, 5.4:1 on canvas) |
| inkMuted | `#8593A8` | Captions, placeholders, disabled (3.1:1: not for essential text) |
| primary / primaryPressed / primaryTint | `#0E7C86` / `#0A646C` / `#DDF0F1` | Primary actions, focus ring, brand mark (white on primary 4.95:1; pressed-on-tint 5.8:1) |
| accent / accentTint | `#2F6FEB` / `#DFE9FE` | Selection (nav pill), info, links to data |
| danger / dangerPressed / dangerTint | `#D2222C` / `#AE1820` / `#FFEDEF` | Emergency, errors |
| success / successTint | `#15803D` / `#E2F4E8` | Granted, connected |
| warning / warningTint | `#B45309` / `#FFF1DC` | Denied-but-retryable, offline banner |
| Feature tints (bg, icon) | blue `#DFECFF/#2F6FEB`, red `#FEE1DD/#DC3B31`, violet `#E8E1FF/#6A4FD3`, mint `#D5F3F1/#0E8A85`, amber `#FFEACB/#D57A00` | `IconBadge` circles |

Legacy `MedilinkColors` names remain and now point at these tokens (blue→accent, teal→primary, …).

## Type (`AppText`)
Plus Jakarta Sans everywhere; Bricolage Grotesque only for onboarding headlines and the wordmark. Letter-spacing is 0 or slightly negative on large sizes (fixes the spaced-out M3 titles).

| Style | Size / weight | Use |
|---|---|---|
| displayLg | Bricolage 30 / 700 | Onboarding headlines |
| headline | 26 / 700 | Page heading ("Welcome back", "Good day") |
| title | 20 / 700 | AppBar titles, section titles |
| titleSm | 17 / 600 | Card titles |
| body / bodyStrong | 15 / 400 / 600 | Body text |
| bodySm | 13.5 / 400 | Supporting text |
| label | 15 / 600 (16 in buttons) | Buttons |
| caption | 12 / 500 | Helper, captions, nav labels (12.5) |

## Spacing, radius, elevation, motion
- Spacing (4-pt base): 4, 8, 12, 16, 20, 24, 32, 48. Screen gutter 20.
- Radius: 10 small, 14 input/button, 18 card, 24 sheet/dialog, pill = full.
- Elevation: no Material elevation. Cards = 1px border + one soft shadow (`0x0D14213D`, blur 14, y 4, spread −4).
- Motion: fast 150 ms, expressive 650 ms; curves easeOutCubic / emphasized (0.2,0,0,1). `AppMotion.reduced(context)` honours the OS remove-animations setting; `Reveal`, `PressScale`, onboarding parallax all check it.

## Icons
Built-in Material, outlined/rounded variants only, fixed sizes (20 in buttons, 22 in inputs, 24 default), always centred in their container. Icon + label pairs share a centre line.

## Components (`lib/ui`)
| Component | Notes |
|---|---|
| `MedilinkMark`, `MedilinkLockup` | Direction B "Tile" (picked 6 Nov 2026). CustomPainter; launcher/splash PNGs rendered from the same painter |
| `IconBadge` | Tinted circle + centred icon |
| `StatusPill` | Used by `StatusBadge`, `EscalationStageBadge` |
| `PageDots` | Morphs with the live page offset |
| `PressScale`, `Reveal` | Press feedback; one-shot fade/lift |
| `SplashBrand`, `BrandBackdrop` | Splash and Welcome brand moment |
| `OnboardingCard`, `OnboardingIllustration` ×4 | 240 grid, 4-unit line weight, one composition per card, central axis |

Still to build in Round 2+: `FeatureTile`, `InfoCard`, `ListRowCard`, `SectionHeader`, `VitalsHero`, `SafetyButton`, `formatTimestamp`, `humanizeEnum`.

## Theme coverage (`AppTheme.light()`)
ColorScheme (no purple surface tints), text, AppBar, NavigationBar (accent pill, 12.5 sp labels), filled/outlined/text/icon buttons (52 dp, 48 dp min), inputs (focus 2px primary, visible error), cards, list tiles, chips, dialogs, bottom sheets, snackbars, switches, progress, popup menus, focus colour. System bars: transparent status bar, canvas nav bar, dark icons.
