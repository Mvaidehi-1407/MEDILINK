# 05 — Hospital search reliability fix

Follows `amends/05-find-hospitals.md`, which built the "Find My Hospital" screen and its
Overpass-mirror-with-one-retry logic. That pass's own "Field fixes" section already found and
fixed one round of Overpass reliability problems (a dead fallback mirror, a server-side timeout
that outlived the client's, and rate-limit responses being read as zero results). This pass
addresses a further report that the service was still timing out even while online, by adding
more fallback mirrors and shortening each mirror's budget so the retry chain doesn't stall on one
bad host.

## Root cause this time

Only `frontend/lib/features/find_hospitals.dart` was touched.

The previous pass's retry loop only ever tried **two** hosts (`overpass-api.de`, then
`overpass.private.coffee`), each getting the *entire* 10-second client budget. Live measurement
during this pass showed that assumption no longer holds: `overpass.private.coffee` -- the only
fallback -- itself timed out on one of several test runs (10.0s, connection never completed),
which would have driven the exact same "Hospital map service didn't respond" failure this task
was filed to fix, even though the device was genuinely online and `overpass-api.de` (untried,
because the loop had already given up) might have answered a moment earlier or later. A
two-mirror chain has no headroom left once either host has a bad moment.

## Task 1 — fallback mirrors, measured before adding

`_overpassEndpoints` grew from 2 entries to 4. Every candidate mirror -- including the two named
as examples in the task -- was actually measured against the app's own query before being
added or rejected, twice, a few minutes apart, to catch flakiness a single measurement would miss:

| Endpoint | Result | Outcome |
| --- | --- | --- |
| `overpass-api.de` | 0.8-2.9s, 200 every time | kept, primary (unchanged) |
| `overpass.private.coffee` | 2.6-3.2s, but one run timed out at 10s | kept, first fallback -- exactly the mirror whose failure motivated this fix |
| `overpass.kumi.systems` | one run 5.3s/200, next run timed out at 10s | kept, third in the chain -- flaky but occasionally the one that answers when the two above don't, so it earns a place further down the chain rather than being trusted early |
| `maps.mail.ru/osm/tools/overpass` | 1.9-6.7s, 200 every time | kept, last resort -- slowest but the most consistently reachable of the four in testing |
| `overpass.openstreetmap.ru` | connection failure on every attempt (both runs), never returned an HTTP response at all | **rejected** -- this was one of the two mirrors the task suggested as an example; it simply doesn't work from here |

The loop itself changed from a hardcoded `for (attempt = 0; attempt < 2; attempt++)` indexing
`_overpassEndpoints[attempt % _overpassEndpoints.length]` (which could only ever reach the first
two entries no matter how many mirrors were added) to `for (final endpoint in
_overpassEndpoints)`, so every configured mirror is actually tried, in order, before the search
is reported as failed.

**Per-mirror timeout, shortened.** With up to 4 sequential attempts, keeping the old 10s-per-
attempt budget would let one search run up to 40s before giving up -- long enough to read as a
hung screen regardless of skeleton animation. `_overpassTimeout` is now 6s (every healthy
response measured above was well under 3s, so 6s is generous headroom, not a tight cutoff) and
`_overpassServerBudgetSeconds` (the `timeout:` Overpass itself is told) dropped from 8 to 5,
keeping the same "server gives up first" invariant the previous pass established. The existing
test asserting that invariant (`buildOverpassQuery never lets the server outlive the client
deadline`) still passes unchanged.

## Task 2 — high-accuracy GPS: confirmed, not changed

`resolveLocationFix()` already calls `Geolocator.getCurrentPosition(locationSettings: const
LocationSettings(accuracy: LocationAccuracy.high))` -- explicit `LocationAccuracy.high`, not the
default/network/low-power tier -- before `_run()` ever builds a query from the result. There is
no other code path in this file that obtains a position; `_run(keepFix: true)` (used when
widening the search radius) reuses the same high-accuracy fix already stored in state rather than
requesting a new, possibly lower-accuracy one. No change was needed here; this is a confirmation,
per task 2's own wording.

## Task 3 — debug-only lat/lng logging

`buildOverpassQuery()` now starts with:

```dart
if (kDebugMode) {
  debugPrint('Find My Hospital: querying Overpass at lat=$lat lng=$lng radius=${radiusMetres}m');
}
```

`kDebugMode` (from `package:flutter/foundation.dart`, now imported) is compiled out of release
builds entirely, so this can never print -- or leak a patient's coordinates -- in a production
build. It fires on every query, including each retry against a different mirror, so a developer
watching the console during a field test can see exactly what centre point was actually sent.
Confirmed firing during the test run (visible in the `flutter test` output for this file).

## UI/UX — tasks 4 and 5

**Task 4 (no regression to skeleton/error states):** `_LoadingSkeleton`, `_EmptyView`, and
`_FailureView` were not touched at all in this pass -- the diff is confined to
`_overpassEndpoints`, `_overpassTimeout`, `_overpassServerBudgetSeconds`,
`buildOverpassQuery`'s new debug-log lines, and `fetchNearbyHospitals`'s loop. `_FindHospitalsPageState._run()`, which decides which phase/skeleton label to show, is unchanged.

**Task 5 (all-mirrors-fail still reads as a server failure, not empty results, with Retry):**
unchanged and confirmed by inspection -- after the retry loop exhausts every mirror,
`fetchNearbyHospitals` still asks `Connectivity().checkConnectivity()` and throws
`HospitalSearchException(serverUnreachable)` (device online) or `.noInternet` (device offline);
it never falls through to returning an empty list or reaching the `_Phase.empty` branch. `_FailureView`'s `serverUnreachable` case still renders "Hospital map service didn't respond" with
`dns_outlined`, amber, and "Retry search" as the primary action -- none of that presentation code
was touched.

## New tests

Added to `frontend/test/find_hospitals_test.dart` (using `package:http/testing.dart`'s
`MockClient`, already available via the existing `http` dependency -- no new package):

- **"falls through failing mirrors to a later one that answers cleanly"** -- the first two mocked
  mirrors return a 200-with-remark (Overpass's own throttle signal), the third returns a clean
  empty result; asserts the function returns successfully and stopped at exactly 3 calls rather
  than continuing to try the fourth.
- **"tries every configured mirror, in order, before giving up"** -- all four mocked mirrors
  return 503; asserts exactly 4 requests were made, to 4 distinct hosts, before the function gives
  up (the eventual thrown exception itself isn't asserted, since the post-loop `Connectivity()`
  call hits a real platform channel unavailable in a plain unit test -- what this test verifies is
  that the retry loop itself tries every mirror, which is exactly what task 1 asked for).

`flutter test test/find_hospitals_test.dart`: 20/20 passing (18 pre-existing + 2 new).
`flutter test test/`: full suite passing, no regressions.
`flutter analyze lib/features/find_hospitals.dart`: no issues.

## Confirmation: emergency/calling code untouched

`git status`/`git diff --stat` against `backend/` and
`frontend/lib/core/native_comm_service.dart` show no changes from this pass. The only files
touched are `frontend/lib/features/find_hospitals.dart` and
`frontend/test/find_hospitals_test.dart`, both purely about the Overpass call and location-fetch
logic named in the scope guardrail.

## Residual risk

- `overpass.kumi.systems` was measured as flaky (healthy in one run, timing out in the next) both
  in this pass and in the original `05-find-hospitals.md` field-fix pass. It stays in the chain
  per the task's own suggestion and because it did answer in roughly half of this pass's test
  runs, but a deployment that finds it net-negative could remove it without touching anything
  else -- it is the third entry in `_overpassEndpoints`.
- Mirror health is a moving target for any public, unauthenticated service; the measurements above
  are a snapshot from this session, not a guarantee. `_overpassEndpoints` is a single list to edit
  if a mirror stops being viable.
- Not verified on-device in this pass (no handset available in this environment) -- the fallback
  chain and debug logging are verified by the mock-based unit tests and by the direct `curl`
  measurements against the real public endpoints above, not by an actual on-device Overpass round
  trip.
