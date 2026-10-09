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
appeals with the same event tuple; that ambiguous source remains
`Суд не установлен` and never borrows the root court. This boundary is
intentional: no court label proves which appeal produced an event when the
saved identity is absent and the movement has multiple matching cards. A
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

A separate user decision is still pending for very old snapshots with neither
production number nor source ID and multiple matching cards of the same court.
The current code remains conservative; visual approval does not resolve that
policy question. No claim about a live court response is made. The production
app, working database and TestFlight were not opened.
