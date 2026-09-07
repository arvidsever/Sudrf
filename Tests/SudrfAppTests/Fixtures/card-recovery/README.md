# Broken imported SUDRF card links

Captured on 7 September 2026 from the public court endpoints listed in
`provenance.json`, using the same Safari User-Agent as `SudrfClient`. Both
original requests returned HTTP 200 and only the site shell/hearing-date form.
Changing `delo_id=5&new=5` to `delo_id=42&new=0` with identical card identifiers
returned the corresponding KAS appeal card.

These are minimized UTF-8 excerpts of the captured Windows-1251 HTML, not
byte-identical captures. Line endings and indentation are normalized. The original shell fixture retains the actual hearing
form. The recovered fixture retains the actual case heading, metadata (`cont1`)
and movement table (`cont3`), including source HTML quirks. Navigation, contact
details, parties, lower-court references and judicial-act text are omitted.
Case numbers, the judicial UID and judges are replaced with test values.
Original-response SHA-256 and fixture SHA-256 are recorded in the manifest.

Expected test numbers: `33а-9001/2022`, `66а-9002/2020`. Only the Komi card
publishes a UID in the captured metadata. These fixtures test transport locator
recovery and parsing, not the legal correctness of court decisions.
