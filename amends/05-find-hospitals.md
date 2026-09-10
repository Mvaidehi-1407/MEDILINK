# 05 — Find My Hospital

A key-less, billing-free "hospitals near me" screen, wired behind the hospital icon that was
already on the patient home screen. No Google Maps SDK, no API key, no billing account: hospital
data comes from OpenStreetMap's Overpass API, the map draws OSM raster tiles through the
`flutter_map` package the app already depends on, and directions hand off to Google Maps through a
plain universal link. No new package was added to `pubspec.yaml`.

## Which icon was wired up (no new icon added)

The patient home screen (`_PatientHomeState.build` in `frontend/lib/features/dashboard.dart`) has
a `Wrap` of six `ActionTile`s: Health, Emergency, Vault, **Hospitals**, QR, Messages. The
Hospitals tile — `Icons.local_hospital_outlined`, label `'Hospitals'` — already existed and already
had a tap handler, `() => _open(context, const HospitalsPage())`.

**Only the destination of that existing handler changed**, to `const FindHospitalsPage()`. The
tile's icon, label, colour, size, position in the grid, and spacing relative to its neighbours are
untouched, as is the shared `ActionTile` widget that all six tiles are built from. No icon, button,
or entry point was added anywhere on the home screen, and no tile was moved or restyled.

Deliberately left alone:

- `RoleOverview` (the caregiver/doctor/hospital overview) still opens the old `HospitalsPage`.
- `ConnectionsPage`'s "Nearby hospitals" row still opens the old `HospitalsPage`.
- `HospitalsPage` itself is unchanged and still lists MEDILINK-registered facilities from
  `/hospitals/nearby`. It answers a different question ("which partner hospitals does MEDILINK
  know about?") than the new screen ("what hospital can I physically reach right now?"), so
  replacing it everywhere would have removed real functionality.

## Icon distinctness audit — one thing to flag

Item 8 asked for confirmation that the hospital icon is visually distinct from the manual SOS
button. Two findings, neither of which was silently changed:

1. **The manual SOS button is not on the home screen.** It lives inside `EmergencyPage`
   (`_idleContent`, a press-and-hold `GestureDetector` with a red border and a red fill that
   deepens as the hold progresses). Reaching it takes a tap on the home screen's *Emergency* tile
   first. So on the home screen itself there is no hospital-icon-vs-SOS-button clash at all.

2. **Flagging, not fixing:** on the home screen every `ActionTile` — including *Hospitals* and
   *Emergency* — renders with the identical treatment: the same `SectionCard`, the same
   112×104 box, and the same `MedilinkColors.blue` icon. They differ only by glyph and label, not
   by colour or shape. That is a pre-existing property of the shared `ActionTile` widget, so
   giving the emergency tile (or the hospital tile) a distinct colour would have restyled a widget
   used by every tile on every role's home screen — outside this feature's scope. Raising it here
   rather than changing it.

Inside the new screen, the distinction is unambiguous: nothing on it is red.

## Files and functions changed

| File | Change |
| --- | --- |
| `frontend/lib/features/find_hospitals.dart` | **New file.** The whole feature. |
| `frontend/lib/features/dashboard.dart` | Two lines: added the `find_hospitals.dart` import, and repointed the existing home-screen Hospitals tile's handler at `FindHospitalsPage`. |
| `frontend/android/app/src/main/AndroidManifest.xml` | Added two `<queries><intent>` entries (`VIEW` + `https`, `VIEW` + `geo`). |
| `frontend/test/find_hospitals_test.dart` | **New file.** 12 unit tests over the pure parsing/formatting logic. |

New symbols in `find_hospitals.dart`:

| Symbol | Role |
| --- | --- |
| `Hospital` | One result: id, name, `LatLng`, distance, nullable `address`/`phone`, `emergency` flag, plus `distanceLabel`. |
| `HospitalSearchFailure` / `HospitalSearchException` | Failure kinds classified at the source: `noInternet`, `serverUnreachable`, `locationPermissionDenied`, `locationServicesOff`, `locationUnavailable`. |
| `LocationFix` | A GPS point plus the accuracy the OS reported, with `isCoarse`. |
| `resolveLocationFix` | Permission handshake + high-accuracy fix. |
| `buildOverpassQuery` | The Overpass QL query for a centre and radius. |
| `addressFromTags` | Builds a one-line address from `addr:*` tags, or returns null. |
| `parseOverpass` | Response → sorted, deduped `Hospital` list. |
| `dedupeHospitals` | Collapses the node/way/relation copies OSM keeps for one site. |
| `fetchNearbyHospitals` | 9s timeout, one retry on the second mirror, classified failures. |
| `directionsUri` | The key-less Google Maps directions link. |
| `FindHospitalsPage` | The screen: phases, map/list sync, radius ladder. |
| `_HospitalRow`, `_LoadingSkeleton`, `_EmptyView`, `_FailureView` | The four visual states. |

## Functional changes

1. **GPS reused from emergency dispatch.** `resolveLocationFix` follows the same
   `checkPermission` → `requestPermission` → `getCurrentPosition` handshake the emergency confirm
   step uses, with `LocationAccuracy.high` requested explicitly. It adds an
   `isLocationServiceEnabled` pre-check so "GPS is switched off" can be told apart from
   "permission denied" — the emergency path swallows both, because there a missing location must
   not block the SOS; here location *is* the feature, so each cause gets its own message.

2. **Overpass fetch, key-less.** `fetchNearbyHospitals` POSTs an Overpass QL query for
   `amenity=hospital` and `healthcare=hospital` across nodes, ways and relations within the
   radius. `out center tags 60` is what makes a mapped hospital *building* (a way with no
   coordinates of its own) usable as a point, and the `60` caps the payload. Requests carry a
   10-second timeout — the top of the 8–10s budget — and retry exactly once, against a different
   host. See "Field fixes" below for why each of those numbers is what it is.

3. **Sorted by distance, deduped.** Distances come from `Geolocator.distanceBetween` (local
   haversine, no network, no key), and the list is sorted nearest-first. `dedupeHospitals` then
   collapses entries with the same name within 150m, since a large hospital is routinely mapped as
   a site node *and* a building way *and* sometimes a relation; the nearest copy survives.

4. **Map.** `flutter_map` with the same OSM tile URL and `userAgentPackageName` already used by
   `emergency_map.dart`. The user's own position is a small blue `my_location` marker; hospitals
   are teal cross markers that turn blue and grow when selected.

5. **Directions.** `directionsUri` builds
   `https://www.google.com/maps/dir/?api=1&destination=<lat>,<lng>&travelmode=driving` and opens
   it with `LaunchMode.externalApplication`, so it lands in the Google Maps app when installed and
   falls back to the browser when it isn't. If the launch is refused, a SnackBar says so instead
   of failing silently.

6. **Android/iOS config.** Android 11+ package visibility means `url_launcher` cannot see any
   handler it hasn't declared, so the deep link would silently not launch. Two `<intent>` entries
   were added to the existing `<queries>` block: `VIEW`+`https` and `VIEW`+`geo`. **The repository
   has no `ios/` directory** — the Flutter project is Android-only as checked in, so there is no
   `Info.plist` to edit. When the iOS project is generated, add to `ios/Runner/Info.plist`:

   ```xml
   <key>LSApplicationQueriesSchemes</key>
   <array>
     <string>comgooglemaps</string>
     <string>maps</string>
   </array>
   ```

   plus the usual `NSLocationWhenInUseUsageDescription`. The https universal link itself works on
   iOS without any declaration; the array only matters if a `comgooglemaps://` scheme is ever
   preferred over the universal link.

## UI/UX changes

7. **Zero taps to results.** `initState` starts locating and searching immediately. There is no
   "Search" button, because under stress every extra tap is a failure point. The only controls are
   a refresh action in the app bar and the radius widening.

8. **List hierarchy.** Hospital name is the heaviest text on the row (16px, `w800`, up to two
   lines). Distance is the clear secondary line (13px, `w600`, teal). The address renders *only*
   when OpenStreetMap actually has `addr:*` tags — `addressFromTags` returns `null` rather than an
   empty or placeholder string, and the widget omits the line entirely, so no row can ever show
   "null", "undefined", or a blank gap. An entry with no `name` tag at all is kept under the
   generic label "Hospital" rather than being dropped, since a correctly located hospital is worth
   navigating to whether or not someone has typed its name into OSM. Directions is a single filled
   button on every row — not a menu item, not a swipe, not behind a detail screen — and it works
   for address-less entries because it navigates by coordinates.

9. **Map/list sync, both directions.** `_select` is the single entry point. Tapping a marker
   selects the row, centres the map on it, and animates the list to it; tapping a row does the
   same without the redundant scroll. Rows use a fixed `itemExtent` of 104, which makes the scroll
   offset for index *i* exactly `i * 104` — precise syncing without adding a positioned-list
   package. Selection is shown twice over: the marker grows and turns blue, the row gets a blue
   border and tint.

10. **Loading feels active.** `_LoadingSkeleton` shows a map-shaped block and four row-shaped
    placeholders pulsing on a 900ms `AnimationController`, above a line naming the current step
    ("Getting your location…", "Finding hospitals within 5 km…", "Widening the search to 10 km…").
    A bare spinner for nine seconds reads as a hung screen; a breathing skeleton reads as work in
    progress and previews the layout that is about to arrive.

11. **Empty state offers the next action.** "No hospitals within 5 km" is followed by a
    full-width **Expand search to 10 km** button. The radius ladder is 5 → 10 → 25 → 50 km; each
    press advances one rung and re-queries, reusing the GPS fix already obtained rather than
    re-prompting. Once the widest rung is reached the button is replaced by a plain note saying
    so. A "Search wider" text button is also present above the results list, so widening does not
    require emptying the list first.

12. **Error state is unmistakably not the empty state.** `_FailureView` uses different icons,
    different copy and a *retry* primary action, versus the empty state's *expand* action.
    "No internet connection" (`wifi_off`) and "Hospital map service didn't respond"
    (`dns_outlined`) are distinguished by asking `connectivity_plus` whether the device is
    actually online, and by treating a `SocketException` as a connectivity failure, rather than by
    guessing from an exception string. Location failures get their own three variants.

13. **No red anywhere.** The screen's palette is `MedilinkColors.blue` (primary actions, selection,
    the user's own marker), `teal` (hospital markers, distance), `green` (the optional "Emergency
    dept." tag), and `amber` (all warnings and every failure icon). Red stays reserved for genuine
    emergency states elsewhere in the app, so opening this screen never reads as "something is
    wrong". The OSM `emergency=yes` tag is only ever shown as a positive — its absence is not
    presented as "no emergency department", because in OSM absence usually just means nobody
    tagged it.

14. **Low-accuracy honesty.** The fix's reported `accuracy` is kept on `LocationFix`. Above 100m,
    an amber strip above the map reads "Location accuracy is low — results may not be fully
    nearby". Results still show, because a rough answer beats no answer, but the user is told the
    distances may be off rather than being handed numbers from a bad centre as though they were
    exact.

## Scope confirmation

- `backend/.../emergency_service.py`, `calling_service.py`, `calling_provider.py` and every other
  backend file: **not touched**. `git status` shows no backend changes from this work, and no new
  or modified endpoint. The feature talks only to Overpass and OSM tiles, never to the MEDILINK
  backend.
- The emergency/escalation/SOS Dart code in `dashboard.dart` (`EmergencyPage`, `_action`,
  `_startSosHold`, the escalation listeners): **not touched**. The only edits to that file are the
  new import and the one-line destination change on the existing home-screen tile.
- No home-screen icon was added, removed, moved or restyled; `ActionTile` itself is unchanged, so
  no other tile on any role's home screen is affected.
- `pubspec.yaml`: unchanged. Everything used here (`flutter_map`, `latlong2`, `geolocator`,
  `http`, `url_launcher`, `connectivity_plus`) was already a dependency.

## Verification

- `flutter analyze lib/features/find_hospitals.dart lib/features/dashboard.dart` — no errors and
  no warnings. The five remaining `curly_braces_in_flow_control_structures` infos are pre-existing
  in untouched parts of `dashboard.dart`.
- `flutter test test/find_hospitals_test.dart` — 12/12 passing, covering way/relation `center`
  handling, distance sorting, the unnamed-hospital fallback, elements with no geometry, the
  node/way dedupe, a malformed/rate-limited response body, null-safe address assembly, the
  key-less directions URI, and distance formatting.
- Not verified on a device: the live Overpass round trip, the OSM tile render, and the Google Maps
  deep-link launch all need a real handset with GPS, so they remain to be exercised manually.

## Field fixes (after first on-device run)

The first build on a real handset reached the "Hospital map service didn't respond" state every
time. GPS was not at fault — the screen had already advanced past "Getting your location…" to
"Finding hospitals within 5 km…", which only renders once a fix has resolved. The Overpass call
itself was failing, for three separate reasons, all of them introduced by the original pass.

1. **The fallback mirror was dead.** `overpass.kumi.systems` was chosen without being tested; it
   returns **HTTP 504 after 33 seconds**. The retry path was therefore guaranteed to fail from the
   day it was written, so any hiccup on the primary became a hard failure. Mirrors were then
   actually measured against the app's own query:

   | Endpoint | Result |
   | --- | --- |
   | `overpass-api.de` | 200 in ~1.9s — healthy, kept as primary |
   | `overpass.private.coffee` | 200 in ~1.8s — healthy, **now the fallback** |
   | `maps.mail.ru/osm/tools/overpass` | 200 in ~6.6s — works, too slow to prefer |
   | `overpass.osm.jp` | does not resolve — rejected |
   | `overpass.kumi.systems` | 504 after 33s — **removed** |

2. **The server budget outlived the client's.** The query declared `[out:json][timeout:25]` while
   the client gave up at 9s. Overpass kept executing a query nobody was waiting for, holding one
   of the caller's small number of rate-limit slots and making it likely the retry would be
   throttled too. The server budget is now `_overpassServerBudgetSeconds = 8`, deliberately under
   the client's 10s, so the server gives up first and returns a real error. A unit test asserts
   this ordering rather than trusting the two constants to be edited together.

3. **Overpass's own errors were being shown as an empty result.** Overpass reports rate limits and
   internal timeouts as **HTTP 200** with a `remark` field and no elements. `parseOverpass` read
   that as "zero hospitals", which routed the user to the *empty* state — inviting them to widen a
   search that had never actually run — instead of the error state with a retry. The new
   `overpassRemark` detects a remark, a non-Overpass document, or an HTML error page from an
   overloaded mirror, and `fetchNearbyHospitals` treats all three as a server failure worth
   retrying on the other host.

Alongside these, the query now ends `out center tags 60`. Uncapped it returned ~120KB for a dense
city; capped it returns ~25KB for the same area with no loss of usable results, since the list is
distance-sorted and nobody scrolls to the 60th nearest hospital. Relations were kept — they were
measured and cost nothing once the cap is in place. The client timeout moved 9s → 10s, the top of
the permitted band, because on mobile data the TLS handshake alone can consume a second before the
query starts, and too tight a deadline turns a merely slow answer into a false error.

Test count rose from 12 to 17: four cover `overpassRemark` (clean document, throttle-as-200, HTML
error page, non-Overpass JSON) and one asserts the server budget stays below the client deadline.
`flutter analyze` on the feature file reports no issues.

**Still unverified:** whether the live Overpass round trip now succeeds from the handset. The
endpoint health, timings and payload sizes above were measured from the development machine; the
fixed build is installed and running on the device, but a successful on-device search has not yet
been observed.
