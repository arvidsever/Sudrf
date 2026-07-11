# v0.39.20 — CoreML model delivery

## Pre-A5 bootstrap

Before the A5 implementation PR, the branch adds an immutable CoreML model
contract without committing the binary model itself:

- `Tests/CaptchaSolverTests/Fixtures/MODEL_MANIFEST.sha256` records SHA-256
  hashes for every regular file in `model-captcha-numeric.mlmodelc`.
- `Scripts/verify-model.sh` validates strict manifest syntax, rejects symlinks and
  unexpected files, and verifies every listed file.
- The matching model is published as the immutable GitHub Release asset
  `model-v1/model-captcha-numeric-v1.zip`.

The `.mlmodelc` directory stays gitignored. A future model revision must receive
a new release tag and a matching manifest commit; the `model-v1` asset is not
replaced.

## Что было сломано (A5)

1. **`testModelLoadsFromBundle` падал на чистом клоне.** Использовал
   `XCTUnwrap` для URL, который зависит от `.mlmodelc/` в test-bundle, а
   `.mlmodelc/` gitignored. На чистом checkout тест красный без возможности
   пропустить.
2. **CI и release не получали модель.** `.github/workflows/swift.yml` собирал
   app и тестировал, но `model-captcha-numeric.mlmodelc` отсутствовал и в
   test-bundle, и в `Sudrf.app/Contents/Resources/`. CoreML-стратегия
   всегда падала в fallback на Vision.
3. **Нет контракта между моделью и кодом.** Любой мог заменить или
   повредить `.mlmodelc/` без сигнала. SHA-256 и негативный список
   файлов отсутствовали.

## Что в v0.39.20

Шесть production-файлов в A5 PR (`Scripts/verify-model.sh` и
`MODEL_MANIFEST.sha256` уже в pre-A5 commit):

1. **`Tests/CaptchaSolverTests/CoreMLCaptchaStrategyTests.swift`** —
   `testModelLoadsFromBundle` теперь `guard let … else { throw XCTSkip }`,
   по образцу соседних model-тестов.

2. **`Tests/CaptchaSolverTests/CoreMLModelBundleIntegrityTests.swift`**
   (новый XCTest) — Swift-зеркало `verify-model.sh`:
   - manifest парсится **до** проверки модели и **обязателен** (fail если
     отсутствует);
   - `split(omittingEmptySubsequences: false)` ловит internal empty lines;
   - ровно 2 whitespace-separated поля, 64-char lowercase hex, safe paths,
     уникальные entries;
   - модель проверяется через `URLResourceValues.isRegularFileKey` /
     `isSymbolicLinkKey`; symlink → fail, прочие non-regular (sockets,
     devices) → fail через negative list;
   - SHA-256 каждого regular file через `Process` + `/usr/bin/shasum -a 256`.

3. **`Scripts/fetch-model.sh`** (новый, Bash 3.2) — скачивает immutable
   ZIP с GitHub Release в staging внутри `Fixtures/`, прогоняет
   `verify-model.sh`, затем verify-before-replace. ZIP count через
   `find + read-loop` (а не `ls | wc -l`), чтобы `set -euo pipefail` не
   ловила пустой glob.

4. **`Scripts/make-app.sh`** — добавлен `--ci` (noninteractive: без
   `open`, без `codesign`). В обоих режимах требуется уже-fetched модель
   в `Fixtures/`, прогоняется `verify-model.sh`, затем `cp -R` в
   `Sudrf.app/Contents/Resources/`. Сам make-app.sh **не** делает fetch —
   это делает CI или dev вручную.

5. **`.github/workflows/swift.yml`** — top-level
   `permissions: contents: read`. Два job'а:
   - `build-test` — fetch model-v1 → `swift build` → `swift test`;
   - `package-app` — fetch model-v1 → `make-app.sh --ci` → verify .app →
     ad-hoc sign + codesign verify → upload `.app` artifact.
   `push.tags` намеренно не добавлен (release Sudrf не запускает этот
   workflow).

6. **`Docs/branch-changelogs/captcha-auto-solver/v0.39.20.md`** — этот
   документ. Pre-A5 commit создал initial draft; A5 PR дополняет.

## Совместимость

- **A1, A2, A3, A4, A14, A15, A16** — не задействованы. Их тесты, логика
  и changelog'и остаются как есть.
- **AGENTS.md** — `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` и
  `changelog/changelog-v*.md` не правим до merge/release. Branch draft
  здесь, в `Docs/branch-changelogs/captcha-auto-solver/`.
- **`.gitignore`** — `*.mlmodelc/` остаётся.
- **SwiftPM `Package.swift:72`** — `.copy("Fixtures")` остаётся; SwiftPM
  подхватит `.mlmodelc/` если он есть в Fixtures.
- **`CoreMLModelDiscovery.swift`** — не трогаем: user-overlay
  (`~/Library/Application Support/Sudrf/`) уже работает.
- **`CoreMLCaptchaStrategy.swift`** — не трогаем.
- **`CaptchaConfiguration.modelURL`** — не трогаем.

## Тесты

| Класс | Тест | Поведение |
|---|---|---|
| `CoreMLCaptchaStrategyTests` | `testBinarizeAndDownsampleDimensions` | base, всегда pass |
| `CoreMLCaptchaStrategyTests` | `testBinarizeAndDownsampleOnRealCaptcha` | real-captchas, skip если `RealCaptchaFixture` пуст |
| `CoreMLCaptchaStrategyTests` | `testModelDiscoveryReturnsNilWhenAbsent` | base, всегда pass |
| `CoreMLCaptchaStrategyTests` | `testInitFailsForMissingModel` | base, всегда pass |
| `CoreMLCaptchaStrategyTests` | `testKindDispatchingRoutesByKind` | base, всегда pass |
| `CoreMLCaptchaStrategyTests` | `testModelLoadsFromBundle` | **skip** если модель не в bundle (A5) |
| `CoreMLCaptchaStrategyTests` | `testInferenceOnRealCaptcha` | skip если модель или captcha-failures отсутствуют |
| `CoreMLCaptchaStrategyTests` | `testLocalSudrfFixturesAccuracy` | skip если модель или labels.csv отсутствуют |
| `CoreMLModelBundleIntegrityTests` | `testBundleModelMatchesManifest` | **fail** если manifest отсутствует / malformed / duplicate / symlink / hash mismatch; **skip** если manifest есть, но модель отсутствует; **pass** при полном match |

С `M = MODEL_PRESENT`, `F = SUDRF_FIXTURE_DIR`:

| Сценарий | CaptchaTests (8) | Integrity (1) | Итого |
|---|---|---|---|
| Clean clone, без captcha-failures | 4 pass + 4 skip | skip | 4p + 5s |
| Чистый клон + F=set | 5 pass + 3 skip | skip | 5p + 4s |
| Локально с моделью, без F | 6 pass + 2 skip | pass | 7p + 2s |
| Локально с моделью + F=set | 8 pass + 0 skip | pass | 9p + 0s |
| Модель + manifest hash mismatch | 6 pass + 2 skip | **fail** | 6p + 1f + 2s |
| Manifest отсутствует | 4 pass + 4 skip | **fail** | 4p + 1f + 4s |

Запуск девяти A5-тестов одним regex filter:
```bash
swift test --filter 'CoreML(CaptchaStrategy|ModelBundleIntegrity)Tests'
```

## Verification

```bash
# 1. Sanity check локальной модели
bash Scripts/verify-model.sh \
  --model-dir Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc \
  --manifest Tests/CaptchaSolverTests/Fixtures/MODEL_MANIFEST.sha256

# 2. A5-тесты
swift test --filter 'CoreML(CaptchaStrategy|ModelBundleIntegrity)Tests'

# 3. Полный прогон
swift test

# 4. CI-equivalent build (без open/codesign)
bash Scripts/make-app.sh --ci
bash Scripts/verify-model.sh \
  --model-dir build/SudrfApp.app/Contents/Resources/model-captcha-numeric.mlmodelc \
  --manifest Tests/CaptchaSolverTests/Fixtures/MODEL_MANIFEST.sha256
```

## Backlog

- **`release-model.yml`** (отдельный workflow): `workflow_dispatch` trigger,
  pinned `torch coremltools` в `Scripts/requirements-train.txt`, реальная
  публикация asset, обновление manifest через PR. Не в Track A.
- **Tag-by-version в `package-app` job:** `MODEL_TAG=model-${{ github.event.release.tag_name }}` после добавления tag-trigger в отдельный workflow.
- **Composite manifest** (v2): SHA-256 + размер + mtime для каждого
  файла. Backlog при выходе новой версии модели.
- **Test-cleanup guard:** `testBundleModelMatchesManifest` использует
  `Bundle.module` — кэш `.build/`. Если модель поменяли между test-run'ами,
  bundle не пересоберётся до `swift package clean`. Backlog: cleanup или
  explicit `Bundle(path:)` для свежего `.app/`.
- **Pip-фиксация в release-model.yml:** `Scripts/requirements-train.txt`
  с pinned `torch==2.4.0 coremltools==8.0 numpy==1.26`.
- **Notarisation:** ad-hoc sign — не notarised. Backlog: `notarytool` +
  Apple Developer ID для distribution build.
- **Dev-flow требует fetch:** make-app.sh в v0.39.20 **не** делает fetch.
  Dev с `gh auth` запускает `fetch-model.sh` вручную. Dev без `gh auth`
  кладёт модель в Fixtures/ вручную (gitignored). Backlog: `--offline`
  mode для make-app.sh.

## Что остаётся вне A5

- A6–A12 (P2): preprocessor propagation, CorpusStore date decode, candidates
  diagnostic, log rotation, atomic pair для корпуса, deps CaptchaSolver →
  SudrfKit.
- A13 (P3): release-метаданные.
- A4-revisit: полный ре-трейн модели на 4–6 цифр (не планируется).
- B-tasks (Track B): отдельные PR от main.

## Release notes (черновик)

> A5 [P1]: CoreML-модель не попадала в bundle на чистом клоне. Теперь
> модель загружается из immutable GitHub Release asset `model-v1`,
> проверяется по tracked manifest и копируется в
> `Sudrf.app/Contents/Resources/`. XCTest и CI зеркалят тот же контракт
> через `Scripts/verify-model.sh` и `CoreMLModelBundleIntegrityTests`.
> `*.mlmodelc/` остаётся gitignored.
