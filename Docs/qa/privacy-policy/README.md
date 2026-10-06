# Политика конфиденциальности для внешнего TestFlight

Дата проверки и согласования: **6 октября 2026 года**.

Автор согласовал текст политики с публичным контактом `arvid.sever@gmail.com`,
предложенными сроками хранения полученных разработчиком обращений и копий
данных TestFlight, а также одну ссылку в существующем разделе настроек
«AI и приватность». Политика не утверждает отсутствие передачи данных в сеть
или автоматическое удаление всех файлов вместе с приложением.

## Проверенные пути

| Сведения | Проверенная реализация |
| --- | --- |
| Локальная база, резервные копии; CloudKit отключён | `DataCatalog.swift`, `TrackedStore.swift` |
| Локальные PDF, остающиеся отдельно от записей | `SudrfKit/ActFileCache.swift` |
| Передача текста, реквизитов и API-ключа Groq | `AIProviders.swift`, `AISettings.swift`, `AISummaryCoordinator.swift` |
| Ручной JSON benchmark; отзыв не отменяет запущенную операцию | `AISettings.swift`, `SummaryBenchmarkRunner.swift`, `AIProviders.swift` |
| Локальный Spotlight и его отключение | `SpotlightIntegration.swift`, `AISettings.swift` |
| Cookies, локальная диагностика и CAPTCHA | `SudrfClient.swift`, `SearchDiagnostics.swift`, `AutoCaptchaSolver.swift`, `CaptchaWebViewCoordinator.swift` |
| Номер исполнительного документа Казначейству и ФССП | `SudrfKit/Enforcement.swift`, `SudrfKit/FSSPClient.swift` |

Тексты/файлы пользовательской базы, ключи, cookies и настройки установленного
приложения для проверки не открывались. Проверка исходников не заменяет
юридическую оценку для каждой страны распространения. Согласованные сроки
хранения обратной связи — обязательства разработчика, а не свойство кода.

## Первичные источники

Проверены 6 октября 2026 года:

- [Apple App Review Guidelines, 2.2 и 5.1.1](https://developer.apple.com/app-store/review/guidelines/): требования политики применяются к TestFlight, ссылка нужна также внутри приложения.
- [TestFlight и конфиденциальность](https://www.apple.com/legal/privacy/data/en/test-flight/): сбор Apple, сведения разработчику и ограничения их использования.
- [Groq: Your Data](https://console.groq.com/docs/your-data), [Services Agreement](https://console.groq.com/docs/legal/services-agreement), [Data Processing Addendum](https://console.groq.com/docs/legal/customer-data-processing-addendum): хранение и обработка содержимого API.
- [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement): сведения посетителей хостинга.
- [Статический Pages workflow](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages): публикация отдельного каталога через официальный artifact/deploy.

## Границы

В независимом review исправлены отсутствие benchmark, слишком сильное обещание
прекращения сетевых запросов после отзыва согласия и неполная инструкция удаления.
Производственный diff содержит одну ссылку и уточнение существующей подписи;
данные, расчёт сроков, AI-запросы и прочие настройки не изменяются.

Наличие политики не означает автоматическое одобрение внешнего TestFlight.
Отправка на Beta App Review выполняется отдельным согласованным шагом.

## Проверки выпуска

- `swift test`: 1908 XCTest, 15 opt-in skips, 28 Swift Testing; без ошибок.
- Проверка генератора registry: актуальный файл.
- `xcodegen generate` и Debug Xcode build: успешно, Xcode 27.0 (27A266a).
- Побайтное сравнение с согласованной политикой: отличается только удалённой
  отметкой черновика и её CSS; SHA256 страницы — в `SHA256SUMS`.
- YAML workflow и Swift-синтаксис проверены; `git diff --check` прошёл.
- Независимый review реализации: блокеров нет.

CI, фактический HTTPS URL и загрузка нового билда проверяются отдельно при выпуске.
Визуальная композиция существующего раздела настроек и переход в браузере
автоматической Xcode-сборкой не подтверждаются.
