#!/usr/bin/env swift
// Scripts/swift-ocr-preview.swift
//
// Проходит по фикстурам CaptchaSolver и печатает лучшее предположение
// Vision по каждой. Используется для разметки labels.csv вручную.
//
//   swift Scripts/swift-ocr-preview.swift sudrf
//   swift Scripts/swift-ocr-preview.swift msudrf [--preprocess]

import Foundation
import Vision
import AppKit
import CoreImage

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: swift swift-ocr-preview.swift <sudrf|msudrf> [--preprocess]\n".data(using: .utf8)!)
    exit(2)
}
let kind = arguments[1]
let preprocess = arguments.contains("--preprocess")

let fixturesDir = URL(fileURLWithPath: "Tests/CaptchaSolverTests/Fixtures/\(kind)")
let fm = FileManager.default
guard fm.fileExists(atPath: fixturesDir.path) else {
    FileHandle.standardError.write("missing dir: \(fixturesDir.path)\n".data(using: .utf8)!)
    exit(1)
}

let urls = (try? fm.contentsOfDirectory(at: fixturesDir,
                                        includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles])) ?? []
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

func otsuThreshold(grayscale: CIImage, context: CIContext) -> Double {
    let extent = grayscale.extent
    let histogram = grayscale.applyingFilter("CIAreaHistogram", parameters: [
        kCIInputExtentKey: CIVector(cgRect: extent),
        "inputCount": 256,
        "inputScale": 1.0
    ])
    var bytes = [UInt8](repeating: 0, count: 256 * 4)
    context.render(histogram, toBitmap: &bytes, rowBytes: 256 * 4,
                   bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    var weights = [Double](repeating: 0, count: 256)
    var total: Double = 0
    for i in 0..<256 {
        let v = (Double(bytes[i*4]) + Double(bytes[i*4+1]) + Double(bytes[i*4+2])) / 3
        weights[i] = v
        total += v
    }
    guard total > 0 else { return 0.5 }
    var sum: Double = 0
    for i in 0..<256 { sum += Double(i) * weights[i] }
    var sumB: Double = 0
    var wB: Double = 0
    var maxVar: Double = -1
    var best: Int = 127
    for t in 0..<256 {
        wB += weights[t]
        guard wB > 0 else { continue }
        let wF = total - wB
        guard wF > 0 else { break }
        sumB += Double(t) * weights[t]
        let mB = sumB / wB
        let mF = (sum - sumB) / wF
        let v = wB * wF * (mB - mF) * (mB - mF)
        if v > maxVar { maxVar = v; best = t }
    }
    return Double(best) / 255.0
}

func preprocess(pngData: Data) -> Data? {
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let raw = CIImage(data: pngData) else { return nil }
    let gray = raw.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
    let t = otsuThreshold(grayscale: gray, context: context)
    let bin = gray.applyingFilter("CIColorThreshold", parameters: [kCIInputThresholdKey: t])
    let scaled = bin.transformed(by: CGAffineTransform(scaleX: 2.0, y: 2.0))
    let canvas = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 64))
    let composed = scaled.composited(over: canvas)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let cg = context.createCGImage(composed, from: composed.extent, format: .RGBA8, colorSpace: cs) else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    return bitmap.representation(using: .png, properties: [:])
}

for url in urls {
    var data: Data
    if preprocess, let pre = preprocess(pngData: try Data(contentsOf: url)) {
        data = pre
    } else {
        data = (try? Data(contentsOf: url)) ?? Data()
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.3
    let handler = VNImageRequestHandler(data: data, options: [:])
    do {
        try handler.perform([request])
        let top = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .map { "\($0.string)|conf=\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: "  ")
        print("\(url.lastPathComponent)\t\(top.isEmpty ? "<empty>" : top)")
    } catch {
        print("\(url.lastPathComponent)\t<ERROR: \(error)>")
    }
}
