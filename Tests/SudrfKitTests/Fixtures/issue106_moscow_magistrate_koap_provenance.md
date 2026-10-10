# Issue 106 fixture provenance

The route and field contract was checked against the authorized private reference
`aptumyc/sudtudtestbot` at commit
`0ec0cc73bc0b23324a514f8298d858bc62fabb1c`. Relevant reference files:

- `server/mosgorsud-koap.js`
- `server/mosgorsud.js`
- `test/koap-mirovoy-moscow.mjs`

The pinned source describes lookup parameters `caseNumber`, `uid`, and
`participant`, and first-instance cards at
`/<unit>/cases/admin/details/<uuid>`. Its KoAP lookup attempts participant
search as a fallback after UID/number lookup; this is not evidence of a complete
participant index. It also documents the fixed search Referer and a bounded
meta-refresh follow. This records provenance; it does not claim a live
validation of the current portal or completeness of its search results.

The HTML files named `mos_sud_*_synthetic.html` in this fixture folder are
authored synthetic test data. They contain no copied court HTML, published case
number, participant, or credential. They exercise the selected field names,
path shape, and parser boundaries only.

The reference is used for attribution and contract checking. No reference
implementation code is included in these fixtures.
