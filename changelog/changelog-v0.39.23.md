# A7 — allowlist хостов для предобработки captcha

## Исправлено

- `SearchModel` и `AppRouter` теперь передают сохранённый allowlist
  `preprocessorHosts` в Vision-стратегию.
- При включённом preprocess power-user allowlist применяется только к
  указанным хостам, а не ко всем судам.

## Проверка

- Добавлен тест live-toggle с allowlist: разрешённый хост проходит
  предобработку, другой — нет.
