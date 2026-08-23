# FSSP regression fixtures

This directory intentionally contains no generated or weakly labelled data.
Before the FSSP model can become eligible it must contain at least 30 unique,
manually verified PNG files named `<five-digits>_<sha256>.png`, plus a
`regression.tsv` with `file<TAB>label` rows.

The lab bootstrap model is written outside the app bundle as
`model-captcha-fssp-bootstrap.mlmodelc/` with the adjacent
`model-captcha-fssp-bootstrap-report.json`. It is not a production model and
is never discovered by the ordinary solver. The final production model still
stays disabled until the training pipeline records the fixture count together
with the corpus and held-out metrics in `model-captcha-fssp-eligibility.json`.
