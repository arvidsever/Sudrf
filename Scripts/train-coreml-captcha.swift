#!/usr/bin/env swift
// Scripts/train-coreml-captcha.swift
//
// Обучает CoreML-модель `model-captcha-numeric.mlmodelc` для распознавания
// 5-значных sudrf captcha. Архитектура — по описанию друга в
// `Docs/branch-changelogs/captcha-auto-solver/v0.38.8.md`:
//
//   вход 100×30 RGB → бинарная маска «чернил» (порог по RGB-расстоянию
//   от судрфовского teal ~(2, 103, 154)) → downsample 100×30 → 64×20
//   → CoreML conv×2 + dense + 5 softmax(10) голов
//
// A4 regression marker: модель обучена на 5-значных rotated/
// struck-through captcha. Текущая модель выдаёт корректные
// 5-значные ответы на наших 3 уникальных captcha spb/nsk
// (verified человеком с PNG; см. testLocalSudrfFixturesAccuracy —
// голый XCTAssertTrue, ловит уверенно-неверный ответ). Раньше
// labels.csv содержал Vision-ошибки (667/1909/UNREADABLE), что
// стало основой FIXPLAN A4. Captcha всегда 5-значная, Vision
// просто не справляется с rotated/struck-through стилями.
//
// Запуск:
//
//   swift Scripts/train-coreml-captcha.swift \
//     --input ~/Library/Application\ Support/Sudrf/captcha-training/solved/ \
//     --output Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc/ \
//     --epochs 30 --lr 0.02 --batch 24
//
// Опции:
//
//   --input <path>   Директория с PNG-файлами. Имя файла должно быть
//                    `<5digits>_<id>.png` (ground truth — первые 5 символов).
//   --output <path>  Куда сохранить скомпилированную модель (`.mlmodelc/`).
//                    По умолчанию — текущая директория.
//   --epochs <N>     Число эпох (default: 30). Ранняя остановка по
//                    per-digit accuracy на held-out set.
//   --batch <N>      Mini-batch size (default: 24).
//   --lr <float>     Learning rate (default: 0.02). ×0.5 на эпохах 10/16/22.
//   --test-frac <F>  Доля held-out set, default 0.2 (80/20 split).
//
// Зависимости:
//   - python3 с `coremltools` (для генерации `.mlmodel` из обученных
//     весов). См. `Scripts/train-coreml-captcha-helper.py` (создаётся
//     отдельно, если выбран путь coremltools).
//   - либо Create ML CLI: `xcrun mltool train` для готового
//     `MLImageClassifier` data source. Другой путь.
//
// ВАЖНО: этот скрипт в текущем виде — КАРКАС. Само обучение
// (mini-batch SGD, backprop) — самая объёмная часть. В v0.38.8
// скрипт читает корпус и пишет features в `train-data.bin` + labels
// в `train-labels.bin` (готовые для последующей offline-тренировки
// на Python/CUDA/CPU). Сама тренировка модели — следующий шаг.

import Foundation

struct Args {
    var input: String
    var output: String
    var epochs: Int
    var batch: Int
    var lr: Double
    var testFrac: Double

    static func parse(_ argv: [String]) -> Args {
        var args = Args(input: "", output: "./model-captcha-numeric.mlmodelc",
                        epochs: 30, batch: 24, lr: 0.02, testFrac: 0.2)
        var i = 1
        while i < argv.count {
            switch argv[i] {
            case "--input":       args.input = argv[i + 1]; i += 2
            case "--output":      args.output = argv[i + 1]; i += 2
            case "--epochs":      args.epochs = Int(argv[i + 1]) ?? args.epochs; i += 2
            case "--batch":       args.batch = Int(argv[i + 1]) ?? args.batch; i += 2
            case "--lr":          args.lr = Double(argv[i + 1]) ?? args.lr; i += 2
            case "--test-frac":   args.testFrac = Double(argv[i + 1]) ?? args.testFrac; i += 2
            default: i += 1
            }
        }
        return args
    }
}

let args = Args.parse(CommandLine.arguments)
guard !args.input.isEmpty else {
    FileHandle.standardError.write(Data("error: --input <path> required\n".utf8))
    exit(1)
}
let inputURL = URL(fileURLWithPath: (args.input as NSString).expandingTildeInPath)
let outputURL = URL(fileURLWithPath: (args.output as NSString).expandingTildeInPath)

print("=== train-coreml-captcha (v0.38.8 каркас) ===")
print("input:  \(inputURL.path)")
print("output: \(outputURL.path)")
print("epochs: \(args.epochs), batch: \(args.batch), lr: \(args.lr)")
print("test-frac: \(args.testFrac)")
print()

// 1) Scan input dir, parse <filename> → label.
let fm = FileManager.default
guard let entries = try? fm.contentsOfDirectory(
    at: inputURL,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
) else {
    FileHandle.standardError.write(Data("error: cannot list input dir\n".utf8))
    exit(1)
}
let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
print("found \(pngs.count) PNGs")

struct Sample { let url: URL; let label: String }
var samples: [Sample] = []
for png in pngs {
    let stem = png.deletingPathExtension().lastPathComponent
    // Filename pattern: <5digits>_<id>.png
    guard let underscore = stem.firstIndex(of: "_") else { continue }
    let label = String(stem[..<underscore])
    guard label.count == 5, label.allSatisfy(\.isNumber) else { continue }
    samples.append(Sample(url: png, label: label))
}
print("parsed \(samples.count) valid samples (5-digit label)")

// 2) 80/20 split.
samples.shuffle()
let nTest = Int(Double(samples.count) * args.testFrac)
let testSet = samples.prefix(nTest)
let trainSet = samples.dropFirst(nTest)
print("train: \(trainSet.count), test: \(testSet.count)")

// 3) Каркас: пишем список (file, label) для последующей offline-тренировки.
let trainListURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("train-data.tsv")
let testListURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("test-data.tsv")

var trainLines: [String] = ["file\tlabel"]
for s in trainSet { trainLines.append("\(s.url.path)\t\(s.label)") }
var testLines: [String] = ["file\tlabel"]
for s in testSet { testLines.append("\(s.url.path)\t\(s.label)") }

do {
    try trainLines.joined(separator: "\n").write(to: trainListURL, atomically: true, encoding: .utf8)
    try testLines.joined(separator: "\n").write(to: testListURL, atomically: true, encoding: .utf8)
    print("wrote: \(trainListURL.path)")
    print("wrote: \(testListURL.path)")
} catch {
    FileHandle.standardError.write(Data("error: write tsv failed: \(error)\n".utf8))
    exit(1)
}

// 4) TODO: train CoreML model. Этот шаг — отдельный запуск
//    `Scripts/train-coreml-captcha-helper.py` (Python) или
//    `xcrun mltool train` (Create ML). Каркас завершается здесь
//    с TSV-файлами; модель нужно сгенерировать отдельно.
//
//    Ожидаемая команда:
//      python3 Scripts/train-coreml-captcha-helper.py \
//        --train-tsv <(above) --test-tsv <(above) \
//        --output Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc/ \
//        --epochs \(args.epochs) --batch \(args.batch) --lr \(args.lr)
//
//    После успешного завершения этого Python-скрипта файл
//    `model-captcha-numeric.mlmodelc/` будет лежать в тестовых
//    фикстурах и автоматически подхватываться
//    `CoreMLModelDiscovery.discoverURL()` при запуске приложения.
print()
print("=== каркас завершён ===")
print("следующий шаг: запустить python3 Scripts/train-coreml-captcha-helper.py")
print("    --train-tsv \(trainListURL.path)")
print("    --test-tsv  \(testListURL.path)")
print("    --output    \(outputURL.path)")
print("    --epochs \(args.epochs) --batch \(args.batch) --lr \(args.lr)")
exit(0)
