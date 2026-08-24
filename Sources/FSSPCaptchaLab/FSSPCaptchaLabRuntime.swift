import Foundation
import CaptchaSolver
import SudrfKit

@MainActor
enum FSSPCaptchaLabRuntime {
    static func makeDependencies() -> FSSPCaptchaLabDependencies {
        let client = FSSPClient()
        let corpus = CorpusStore.shared
        let trainingRoot = FSSPCaptchaLabPaths.trainingRoot
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                 isDirectory: true)

        return FSSPCaptchaLabDependencies(
            trainingRoot: trainingRoot,
            discover: { documentID in
                do {
                    return try await client.discover(document: CourtEnforcementDocument(
                        electronicID: documentID))
                } catch is CancellationError {
                    return .error("Запрос CAPTCHA ФССП отменён.")
                } catch {
                    return .error(error.localizedDescription)
                }
            },
            submit: { code, challenge, documentID in
                do {
                    return try await client.submit(
                        code: code,
                        for: challenge,
                        document: CourtEnforcementDocument(electronicID: documentID))
                } catch is CancellationError {
                    return .error("Проверка CAPTCHA ФССП отменена.")
                } catch {
                    return .error(error.localizedDescription)
                }
            },
            saveConfirmedPair: { png, code in
                await corpus.add(png: png, code: code, host: "fssp.gov.ru", kind: .fsspDigits) != nil
            },
            corpusCount: {
                await corpus.currentCount(kind: .fsspDigits)
            },
            markTrained: { count in
                await corpus.markTrained(kind: .fsspDigits, count: count)
            },
            loadModel: {
                FSSPCaptchaLabBootstrapModel.load(from: trainingRoot)
            },
            train: { root in
                await FSSPCaptchaLabProcessRunner.run(
                    trainingRoot: root,
                    repositoryRoot: repositoryRoot)
            },
            waitBeforeRetry: {
                do {
                    try await Task.sleep(for: .seconds(60))
                    return true
                } catch {
                    return false
                }
            }
        )
    }
}

private enum FSSPCaptchaLabPaths {
    static let trainingRoot: URL = {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first {
            return support
                .appendingPathComponent("Sudrf", isDirectory: true)
                .appendingPathComponent("captcha-training", isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Sudrf-captcha-training", isDirectory: true)
    }()
}

@MainActor
private enum FSSPCaptchaLabBootstrapModel {
    static func load(from trainingRoot: URL) -> FSSPCaptchaLabModelProvider {
        let fm = FileManager.default
        let modelURL = trainingRoot.appendingPathComponent(
            "\(CoreMLModelDiscovery.fsspBootstrapModelName).mlmodelc", isDirectory: true)
        let reportURL = trainingRoot.appendingPathComponent(FSSPBootstrapReport.reportFileName)
        guard fm.fileExists(atPath: reportURL.path) else {
            return .init(
                status: "Черновая модель не установлена (нет bootstrap-отчёта)",
                trainedCorpusCount: nil,
                recognize: { _ in nil })
        }
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONDecoder().decode(FSSPBootstrapReport.self, from: data) else {
            return .init(
                status: "Черновый отчёт устарел или повреждён; требуется новое обучение",
                trainedCorpusCount: nil,
                recognize: { _ in nil })
        }
        guard report.isCurrentContract else {
            return .init(
                status: "Черновый отчёт устарел или не прошёл проверку; требуется новое обучение",
                trainedCorpusCount: nil,
                recognize: { _ in nil })
        }
        guard fm.fileExists(atPath: modelURL.path) else {
            return .init(
                status: "Bootstrap-отчёт есть, но скомпилированной модели нет",
                trainedCorpusCount: nil,
                recognize: { _ in nil })
        }
        guard let strategy = try? CoreMLCaptchaStrategy(modelURL: modelURL, kind: .fsspDigits) else {
            return .init(
                status: "Черновая CoreML-модель не загружается",
                trainedCorpusCount: nil,
                recognize: { _ in nil })
        }

        let accuracy = report.examStringAccuracy.formatted(
            .percent.precision(.fractionLength(0)))
        let status = "Автономная модель готова: \(accuracy) на независимом экзамене, \(report.uniqueCorpusCount) PNG"
        return .init(
            status: status,
            trainedCorpusCount: report.uniqueCorpusCount,
            recognize: { challenge in
                try? await strategy.solve(
                    pngData: challenge.imagePNG,
                    kind: .fsspDigits,
                    host: challenge.requestURL.host)
            })
    }

}

private enum FSSPCaptchaLabProcessRunner {
    static func run(trainingRoot: URL,
                    repositoryRoot: URL) async -> FSSPCaptchaLabTrainingResult {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let python = trainingRoot
                .appendingPathComponent("fssp-trainer-venv", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("python3")
            let script = repositoryRoot
                .appendingPathComponent("Scripts", isDirectory: true)
                .appendingPathComponent("train-fssp-bootstrap.py")
            guard fm.isExecutableFile(atPath: python.path) else {
                return .failed("Нет локального venv: \(python.path). Сначала запустите setup тренера.")
            }
            guard fm.fileExists(atPath: script.path) else {
                return .failed("Не найден скрипт тренера: \(script.path)")
            }

            let process = Process()
            let output = Pipe()
            process.executableURL = python
            process.arguments = [
                script.path,
                "--corpus", trainingRoot.appendingPathComponent("solved-fssp", isDirectory: true).path,
                "--output-dir", trainingRoot.path
            ]
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? "Тренер завершился без текстового журнала."
                return process.terminationStatus == 0 ? .succeeded(text) : .failed(text)
            } catch {
                return .failed("Не удалось запустить тренер: \(error.localizedDescription)")
            }
        }.value
    }
}
