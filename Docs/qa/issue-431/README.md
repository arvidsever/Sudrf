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

The native visual acceptance has not yet been performed. No claim about a live
court response is made.
