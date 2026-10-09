# Issue #337: compact week-hearing cards

## Scope

The week view keeps each hearing's time and case number visible in a compact
row. Selecting the row opens the existing hearing details in a native popover;
the case-opening action remains available there. Cross-court overlap warnings
remain on the card and in its details. The separate dense-group mock was accepted by the user on 9 October 2026.
Its two visible hearing rows and `+N` disclosure are included in the synthetic
fixture; native visual acceptance is still required.

The synthetic visual fixture covers Wednesday 21 October 2026: five hearings at different
courts at 11:00 (including one long number), a material hearing at 12:00, and a single hearing Thursday at
11:30. It is based on the approved #337 mock and the reported adjacent-slot
case; it is not a live court response or a user-data sample.

## Isolation audit

`GUIHost.swift` constructs the router with an in-memory SwiftData container and
injects a CAPTCHA corpus under `/private/tmp/sudrf-337/captcha-corpus`. It adds
only synthetic `TrackedHearing` values in memory. It does not seed/open the
working database, call `startBackgroundWork()`, fetch cards, or make network
requests. The generated target has bundle ID `ru.sudrf.qa.issue337` and network
client entitlement disabled.

The in-memory store deliberately has no cases. The popover's `Открыть дело`
action therefore performs the normal exact-number lookup and safely finds no
record; it cannot trigger a refresh. Navigation remains covered by the focused
raw-number regression and by inspection of the action wiring, not by this
visual host.

`AppRouter` does read and update `UserDefaults.standard` during initialization
and its initial empty `reload()`. In this QA target the standard defaults domain
belongs to the separate QA bundle ID; no product app preference domain is
used. The empty feed means the initial reload does not request a notification;
it does not call `FeedNotifier.configure()`. Spotlight indexing is constructed
but not scheduled: neither startup background work nor a reload with a
Spotlight scope is invoked. No production bootstrap is used.

## Build and visual review

The build-only script generates an isolated Xcode project and ad-hoc signed
Debug QA app under `/private/tmp/sudrf-337/xcode-qa`. It does not launch the app.

```sh
bash Docs/qa/issue-337/build-ui.sh
```

Native visual acceptance and permission to launch are still pending.
After code review, inspect the approved cases in light and dark
appearance. For the current synthetic fixture, confirm the 11:00 conflict
warning does not cover the 12:00 material row, open the conflict details and its `+3` disclosure (all five hearings),
and the material details, inspect the single-hearing disclosure, and verify that
case navigation is present, VoiceOver announces the row and disclosure state,
and changing week/mode/data closes any open popover. Do not use a bitmap
screenshot as visual acceptance evidence.

## Automated verification

`CalendarWeekLayoutTests.testIssue337CompactConflictAndMaterialCardsDoNotOverlap`
locks the reported cross-court conflict/material adjacency, preserves the
material caption, and checks both compact card geometry and reserved timeline
geometry. `testDisclosureContentKeyTracksHearingUpdatesAndRemoval` verifies
that changes to displayed hearing content and deletion change the observed key
that closes an open disclosure. Run the focused profile with:

```sh
swift test --filter CalendarWeekLayoutTests
```

The earlier profile passed 21 tests with 0 failures on 9 October 2026. The ad-hoc
signed Xcode 27.0 Debug QA build succeeded on 9 October 2026. The generated app is
`/private/tmp/sudrf-337/xcode-qa/DerivedData/Build/Products/Debug/Sudrf337QA.app`;
build log: `/private/tmp/sudrf-337/xcode-qa/build.log`, SHA-256
`f810e52822b0fbea54cd89d5370313f5cd300136e584267c1600a113637581ce`.
The generated app has bundle ID `ru.sudrf.qa.issue337` and network client
entitlement disabled. Neither production nor QA app was launched. Native visual
review remains pending.

The additional dense-group regression preserves all five raw hearing numbers
and keeps both the compact card and reserved timeline below the next-hour row.
The updated profile passed 22 tests with no failures on 9 October 2026;
log `/private/tmp/sudrf-337/dense-profile.log`, SHA-256
`93af427d23f60a1f7338905a1253272e778934dc34c5def7e1f0c8137fc0d720`.
The rebuilt QA host succeeded without launch; build-log SHA-256
`c7fbb4f50fb0796aed148b26c5a957b55e1b24d92177ec600f75baf16983c202`.
Its bundle identifier and ad-hoc signature were rechecked. Neither the
product app nor the QA app was launched for this checkpoint.

The ordinary Xcode project was regenerated and the product Debug build also
succeeded without launch. All three packaged models matched their manifests;
the packaged FSSP eligibility file matched the source. Build log
`/private/tmp/sudrf-337/product-build.log`, SHA-256
`5663b25ea9ad1241845d9854797068f157f3ef9c0fc406b4b825d60dbd6fbf89`.
The generated legal registry passed `--check`. Full hosted CI remains pending.
Release history and the recent-release table will be updated in this same PR
when the final patch version is assigned after acceptance.

## Current-main checkpoint

On 9 October 2026 the branch was rebased onto `60d7c45316b7bb2965d752e29c3a5a3346fff1ad`
(0.64.4, build 256). Only stale roadmap release/queue text conflicted; current
main's release information was preserved. The implementation delta is unchanged.
All App test targets compiled without execution (log SHA-256
`22210bfc47b4dc4ee832fe4ef7272c540938fbbc5e24d9c1d71320383975c777`).
The isolated pure layout profile then passed 22/22, 0 failures (log SHA-256
`8286301273d44412df4c81334f279b7d476dd25b4c9d90cfff29b1d58f4216d7`).
No application was launched. Native acceptance and new-head hosted CI remain
required; earlier CI evidence applies only to its recorded commit.
