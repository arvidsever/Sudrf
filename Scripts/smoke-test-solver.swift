#!/usr/bin/env swift
// Scripts/smoke-test-solver.swift
//
// Smoke-тест: подключается к живому суду sudrf, скачивает форму,
// пропускает капчу через CaptchaSolver и печатает результат.
//
// Использование: swift Scripts/smoke-test-solver.swift <subdomain>
// По умолчанию — sankt-peterburgsky--spb.sudrf.ru.

import Foundation
import Vision
import AppKit
import CaptchaSolver
import SudrfKit

let args = CommandLine.arguments
let subdomain = args.count > 1 ? args[1] : "sankt-peterburgsky--spb.sudrf.ru"

print("Target: \(subdomain)")
let formURL = URL(string: "https://\(subdomain)/modules.php?name=sud_delo&srv_num=1&name_op=sf&delo_id=1540005&new=5")!
print("Form URL: \(formURL.absoluteString)")

let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
var req = URLRequest(url: formURL)
req.setValue(ua, forHTTPHeaderField: "User-Agent")
req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
req.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")
req.timeoutInterval = 30

let sem = DispatchSemaphore(value: 0)
var htmlData: Data?
URLSession.shared.dataTask(with: req) { data, response, error in
    if let error {
        print("HTTP error: \(error.localizedDescription)")
    } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        print("HTTP status: \(http.statusCode)")
    } else {
        htmlData = data
    }
    sem.signal()
}.resume()
sem.wait()

guard let data = htmlData, let html = String(data: data, encoding: .windowsCP1251) ?? String(data: data, encoding: .utf8) else {
    print("Failed to decode HTML")
    exit(1)
}
print("HTML size: \(data.count) bytes, encoding OK")

guard let extracted = try? CaptchaImageExtractor.extract(html: html) else {
    print("No captcha in this form — try a different subdomain, or the form doesn't show the image inline")
    exit(0)
}
print("Captchaid: \(extracted.captchaid)")
print("PNG size: \(extracted.png.count) bytes")
guard let image = NSImage(data: extracted.png) else {
    print("PNG is not a valid image")
    exit(1)
}
print("PNG dims: \(Int(image.size.width))x\(Int(image.size.height))")

let solver = CaptchaSolver(provider: VisionOCRStrategy())
let sem2 = DispatchSemaphore(value: 0)
var attempt: CaptchaAttempt?
Task {
    attempt = try? await solver.solve(pngData: extracted.png, kind: .sudrfToken)
    sem2.signal()
}
sem2.wait()

if let a = attempt {
    print("Solver result: value='\(a.value)' confidence=\(String(format: "%.2f", a.confidence)) duration=\(Int(a.duration * 1000))ms")
} else {
    print("Solver returned nil")
}
