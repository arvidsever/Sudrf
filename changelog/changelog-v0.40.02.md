# 0.40.2 — Swift Concurrency для CaptchaSolver

> Alpha, build 82.

## Исправлено

- `CoreMLCaptchaStrategy` изолирует `MLModel` внутри actor и совместим со
  Swift 6 concurrency checking без `@unchecked Sendable`.
- Live-настройка preprocess читается через `@MainActor @Sendable`-границу;
  переключатель по-прежнему действует на следующий вызов готового солвера.
- `CaptchaSolverLog.shared` стал неизменяемым singleton, а тесты используют
  dependency injection вместо подмены глобального состояния.
- Удалена устаревшая обработка исключения вокруг невыбрасывающего
  `VNImageRequestHandler` initializer.

## Проверка

- `CaptchaSolver` собирается без предупреждений с
  `-strict-concurrency=complete` и в Swift 6 language mode.
- Регрессионные тесты покрывают live-toggle preprocess, host allowlist,
  CoreML dispatch/inference и изолированную запись логов.
