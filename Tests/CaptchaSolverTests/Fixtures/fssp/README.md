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
is never discovered by the ordinary solver. The production model is published
separately as the immutable `model-fssp-v1` release asset and is discovered
only beside the tracked `model-captcha-fssp-eligibility.json`, which records
the fixture count, independent-exam metrics and CoreML parity result.
