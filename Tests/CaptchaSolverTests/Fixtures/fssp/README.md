# FSSP regression fixtures

This directory intentionally contains no generated or weakly labelled data.
Before the FSSP model can become eligible it must contain at least 30 unique,
manually verified PNG files named `<five-digits>_<sha256>.png`, plus a
`regression.tsv` with `file<TAB>label` rows.

The model stays disabled until the training pipeline records that fixture
count together with the corpus and held-out metrics in
`model-captcha-fssp-eligibility.json`.
