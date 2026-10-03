# Issue #361 — PDF export metadata

## Result

Exported text PDFs and exported copies of published PDFs carry a case and act
title, act date, readable court name when available, and judicial UID when the
loaded case card supplies it. `Author` and `Creator` are `Sudrf`. The currently
selected Moscow attachment supplies its own title and date rather than inheriting
the result-row summary.

Metadata is applied to a newly serialized export copy. The published PDF cached
by the app and its provenance hash are not rewritten. A source PDF that has a
digital signature is not represented as signature-preserving after this
metadata rewrite; retain the original source bytes for authenticity checks.

## Automated checks

- `ActPDFMetadataTests`: 3 tests pass. Covers the exact Moscow title, court and
  UID; selected VS production number and label; rendered-text and published-file
  PDF metadata; pages, extracted text and annotations after reopening the
  serialized source; and unchanged source-file bytes.
- `SearchResultSelectionTests`: 26 tests pass. The mocked Moscow card supplies
  UID, court and attachment date/title; metadata clears on close and a late card
  response cannot replace the current selection's metadata.
- `ActPresentationTests/testRapidSelectionUsesExactStoredSnapshotEndToEnd`:
  passes. The tracked VS act projection uses `3-ИКАД25-3-А2` in the App Intent
  document metadata while retaining the root case key and source hash.
- Root's full Swift test run: see `/private/tmp/sudrf361-full.log`.

## PDF evidence

The focused metadata test wrote these headless artifacts:

- `/private/tmp/sudrf361-pdf-qa/rendered-text.pdf` — 9-page A4 PDF rendered
  from the selected Moscow act text.
- `/private/tmp/sudrf361-pdf-qa/file-copy.pdf` — 1-page copy of the repository's
  `Fixtures/published-act/valid.pdf` with export metadata.
- The `.txt` files beside them contain text extracted after reopening each PDF
  with PDFKit. The original fixture's SHA-256 is
  `6b08289252da45ff52a5880b158953a94ac6cd1720f8d599b20b14b6594a448b`.

`pdfinfo` reports the same metadata on both exports:

```text
Title:   Дело № 3а-1318/2021 — Мотивированное решение от 21.06.2021
Subject: Московский городской суд
Author:  Sudrf
Creator: Sudrf
```

The Keywords entry is the source-card UID `77RS0001-01-2021-000123-45`; the
PDFKit test verifies it after reopening each exported file. `pdfinfo` confirms
9 pages for the text export and 1 page for the published-file copy.

No app window, working database, or TestFlight build was used.
