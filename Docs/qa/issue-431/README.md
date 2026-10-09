# Issue #431 visual QA

This optional native host is prepared for later review of the existing month,
week, agenda, and day views. Its build script only generates and builds the
`ru.sudrf.qa.issue431` app; it does not launch it. The host writes two synthetic
records to a newly created temporary disk store, starts no production bootstrap
or refresh, disables network entitlement, and does not synchronize Spotlight.

The target hearing is dated 21 October 2026 at 12:05 and has the legacy saved
court value `OBLSUD--MO`, with appeal number `33-42895/2026` under base number
`2-4461/2026`. A second synthetic hearing at the same time keeps the existing
cross-court conflict presentation visible. These are fixture values shaped by
the public issue report and local court directory; the fixture is not a read of
a user database or a live court response.

The QA app has its own bundle identifier and sandbox container; it does not use
the production defaults or corpus. The corpus, SwiftData store, and any app
support files created during a later QA launch stay under the QA container or
temporary directory.

The persisted regression removes `sourceCardID`, as in snapshots written before
#155, while retaining the appeal number (saved since #211 / v0.51.0). A separate
older-format test removes both identity fields and supplies two same-court
appeals with the same event tuple. Following the explicit user decision on
9 October 2026, the common confirmed court is shown without choosing an
appeal or filling missing identity fields. Different or unconfirmed courts
still remain `Суд не установлен` and never borrow the root court. A
separate exact-`sourceCardID` regression verifies that a blank saved court
label can be restored from that source card's own court, including a readable
saved district name on the shared Moscow portal host. A month/week projection
regression uses synthetic different court labels with the same raw portal key,
plus an out-of-month event; it verifies that labels stay per hearing while
month overlap and week queue identities keep the raw key.

The generated Xcode project, derived data, and app bundle are isolated under
`/private/tmp/sudrf-431/xcode-qa`. The root task may launch the app after code
review for native-window acceptance. No bitmap rendering is used as visual
acceptance evidence.

## Verification on 9 October 2026

The final production checkpoint `604030f` is based on `3381809`. Independent
Astra review returned Ship after the per-hearing month labels, mixed week
queue details, and room preservation findings were resolved.

The strict full suite passed: 721 SudrfKit XCTest, 1,161 SudrfApp XCTest
(15 skipped), 10 FSSPCaptchaLab XCTest, and 75 CaptchaSolver XCTest
(5 skipped), all without failures, plus 28 Swift Testing tests. Registry
validation and XcodeGen passed. The unsigned Xcode 27 Debug build contains
all three CoreML model folders and the eligibility manifest. The isolated
QA app also built successfully.

Logs: `/private/tmp/sudrf-431/final-full-strict.log`,
`/private/tmp/sudrf-431/final-xcode-main.log`, and
`/private/tmp/sudrf-431/xcode-qa/build.log`.

The root task launched only the isolated QA app through native computer use.
Month, day panel, week, agenda and both app-specific appearances were observed;
the day accessibility label contains the correct full court. The existing
narrow-card width fallback still prioritizes the number when court plus number
do not fit. No layout change was introduced for this fallback.

The user accepted the four shown month/day/week/agenda screenshots on
**9 октября 2026 года**: «Да, визуальная приёмка пройдена».

A separate user decision was received on 9 October 2026: show the confirmed
common court without attaching an old hearing to a specific registration.
The supplemental implementation and regression are recorded below.
No claim about a live court response is made. The production
app, working database and TestFlight were not opened.

## Compatibility after rebase (9 October 2026)

The branch was rebased from `3381809` onto `8403266` (`main`, v0.64.1/253)
without conflicts. Focused checks passed: `Issue431CalendarCourtLabelTests`
3/3, `MovementDerivationTests` 107/107, and
`python3 Scripts/generate-legal-deadline-registry.py --check`. `xcodegen
generate` and the unsigned Xcode 27 Debug build succeeded; all three bundled
CoreML models matched their manifests and the eligibility resource matched its
fixture. The app was not launched. Native QA and UserActivity tests were not
rerun; the visual acceptance above predates this rebase. This checkpoint
preceded the supplemental common-court implementation below; no release
version was assigned at that checkpoint.

## Agreed common-court fallback, 9 October 2026

For sessions without both production number and source ID, multiple matching
cards may provide one court title only when every candidate proves that court.
Dedicated domains use the official directory. Moscow's shared portal requires
each candidate's validated native card URL and own court alias; a KnownCard
matched only by host and case number is insufficient. No registration is
chosen and no raw session, number, source ID or hearing ID is changed.

Independent review found a cross-district same-number counterexample. Its RED
test reproduced one intended failure; after the native locator check, the
same focused pure test passed (1/1). It also covers two confirmed different
courts, a missing court, an unproved shared portal, and two same native aliases.
Log: `/private/tmp/sudrf-431-resume-policy-green.log`;
SHA-256: `019a8d046d8fc9ec663fc5d40abf21d513552760e1b0d27c3efae9ebc9be0065`.
This pure method does not construct AppRouter, open a store or publish Spotlight.
Independent Astra review accepted the corrected diff. CI `37943610348` for
`3c28f0919657662b660a1afd06470e8bd0c8e6dc` passed: 1,991 XCTest
(20 skipped), 28 Swift Testing, and 26 Python tests (6 skipped), no failures.
The hosted Xcode 27 lane skipped because its SDK was unavailable. The local
unsigned Xcode 27 Debug build succeeded without launching the app.
Build log: `/private/tmp/sudrf-431-resume-build.log`;
SHA-256: `550b7e8d7198529cf937a8ef82a4fbe55ffcd42a6b20388d67cb4ea2d3454188`.
CI log SHA-256: `4b196bebdfdae9e1d99fa725c5ab9cf1e96b7bda543a8df5bb996b77e3011c8b`.
Version 0.64.2 (254) was assigned against main 0.64.1 (253). The final release
commit CI and post-merge primary-folder build are still required gates.
