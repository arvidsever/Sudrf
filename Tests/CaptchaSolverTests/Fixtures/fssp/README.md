# FSSP regression fixtures

This directory contains 30 unique CAPTCHA images manually verified against
their server-confirmed labels on 25 August 2026. The PNG files are named
`<five-digits>_<sha256>.png`; `regression.tsv` records the corresponding
`file<TAB>label` rows used by the independent production gate.

`parity/` contains three server-confirmed CAPTCHA at left, central and right
horizontal positions. They verify that the Swift and Python preprocessors use
the same pixels, but do not count toward the 30 manually reviewed production
regression fixtures.

The lab bootstrap model is written outside the app bundle as
`model-captcha-fssp-bootstrap.mlmodelc/` with the adjacent
`model-captcha-fssp-bootstrap-report.json`. It is not a production model and
is never discovered by the ordinary solver. The final production model still
stays disabled until the training pipeline records the fixture count together
with the corpus and independent-exam metrics in
`model-captcha-fssp-eligibility.json`.
