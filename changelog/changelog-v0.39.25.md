# A9 — candidates-диагностика через dispatcher

## Исправлено

- Top candidates стали частью контракта `CaptchaSolvingProvider` с
  безопасным пустым default для провайдеров без диагностики.
- `KindDispatchingStrategy` направляет diagnostics по тому же kind,
  поэтому CoreML-кандидаты доступны для числовых captcha.

## Проверка

- Добавлен тест, что `CaptchaSolver` поверх dispatcher с CoreML-primary
  возвращает непустые candidates для `.sudrfToken`.
