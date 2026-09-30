//  ActWindow.swift — Sudrf · v2 · новый файл
//  Отдельное окно с текстом акта + постраничный экспорт в PDF (A4).

import SwiftUI
import AppKit
import SudrfKit
import UniformTypeIdentifiers
import PDFKit

enum SafeFilename {
    static func component(_ raw: String, fallback: String = "Судебный акт",
                          maxLength: Int = 120) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let mapped = String(raw.unicodeScalars.map {
            forbidden.contains($0) ? "-" : Character(String($0))
        })
        let collapsed = mapped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".")))
        let limited = String(collapsed.prefix(maxLength))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".")))
        return limited.isEmpty ? fallback : limited
    }
}

// MARK: - Полезная нагрузка отдельного окна
//  openWindow(value:) требует Codable & Hashable — передаём снимок, а не модель.

struct ActWindowPayload: Codable, Hashable {
    var caseNumber: String
    var actText: String
    var paragraphs: [ActParagraph]? = nil
    var pdfFileURL: URL? = nil
    var pdfProvenance: PublishedActProvenance? = nil

    func hash(into hasher: inout Hasher) {
        hasher.combine(caseNumber)
        hasher.combine(actText)
        hasher.combine(paragraphs)
        hasher.combine(pdfFileURL)
        hasher.combine(pdfProvenance?.contentHash)
    }
}

// MARK: - Содержимое отдельного окна

struct ActWindowView: View {
    let payload: ActWindowPayload
    @State private var pdfData: Data?
    @State private var fileError: String?
    @State private var isLoading = false

    var body: some View {
        CourtActContent(text: payload.actText, pdfData: pdfData,
                        isPublishedFile: payload.pdfFileURL != nil,
                        isLoading: isLoading, error: fileError,
                        paragraphs: payload.paragraphs, retry: loadFile)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Дело № \(payload.caseNumber) — судебный акт")
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 600)
        .task { loadFile() }
        .toolbar {
            ToolbarItem {
                Button {
                    ActPDFExporter.save(caseNumber: payload.caseNumber, text: payload.actText,
                                        paragraphs: payload.paragraphs, originalPDF: pdfData)
                } label: {
                    Label("Сохранить в PDF", systemImage: "square.and.arrow.down")
                }
                .disabled(payload.pdfFileURL != nil && pdfData == nil)
                .help("Сохранить в PDF")
            }
        }
    }

    private func loadFile() {
        guard let url = payload.pdfFileURL, let provenance = payload.pdfProvenance else { return }
        isLoading = true
        fileError = nil
        Task {
            let cache = ActFileCache(directory: url.deletingLastPathComponent())
            if await cache.fileURL(provenance: provenance) == url,
               let data = await cache.load(provenance: provenance) {
                pdfData = data
            } else {
                fileError = "Сохранённый PDF недоступен. Повторно откройте акт в карточке дела."
            }
            isLoading = false
        }
    }
}

/// The same text/PDF content is used in search, tracked cases and separate windows.
struct CourtActContent: View {
    let text: String?
    let pdfData: Data?
    var isPublishedFile = false
    var isLoading = false
    var error: String? = nil
    var paragraphs: [ActParagraph]? = nil
    var highlightedParagraphID: String? = nil
    var retry: () -> Void = {}
    @State private var showingOriginal = false

    private var hasText: Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if pdfData != nil && hasText {
                Picker("Вид судебного акта", selection: $showingOriginal) {
                    Text("Текст").tag(false)
                    Text("Оригинал PDF").tag(true)
                }
                .pickerStyle(.segmented).padding(10)
            }
            if let error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Повторить", action: retry)
                }.padding(10)
            }
            if let pdfData, showingOriginal || !hasText {
                PublishedPDFView(data: pdfData)
                    .accessibilityLabel("Оригинал судебного акта PDF")
            } else if hasText {
                ScrollViewReader { proxy in
                    ScrollView {
                        ActTextView(text: text ?? "", highlightedParagraphID: highlightedParagraphID,
                                    paragraphs: paragraphs)
                            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: highlightedParagraphID) { _, paragraphID in
                        guard let paragraphID else { return }
                        withAnimation { proxy.scrollTo(paragraphID, anchor: .center) }
                    }
                }
            } else if isLoading {
                CenterNote(spinner: true, title: "Загрузка опубликованного PDF…")
            } else if isPublishedFile {
                CenterNote(title: error == nil ? "Опубликованный PDF готов к загрузке" : "Не удалось загрузить PDF",
                           caption: "Оригинал доступен по ссылке на сайте суда.")
            } else {
                CenterNote(title: "Судебные акты по делу не опубликованы",
                           caption: "В полученных карточках нет текста или ссылки на опубликованный файл.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PublishedPDFView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .textBackgroundColor
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}

// MARK: - Постраничный экспорт в PDF (A4)
//  NSAttributedString (та же структура, что в ActTextView, через CourtActFormatter)
//  → NSTextView → NSPrintOperation с jobDisposition = .save: AppKit сам разбивает
//  текст на страницы A4 с заданными полями.
//  PDF всегда набирается шрифтом с засечками (Times New Roman) —
//  как принято в судебных документах, независимо от экранного вида.

enum ActPDFExporter {

    // A4 в типографских пунктах
    private static let paper = NSSize(width: 595.28, height: 841.89)
    private static let marginTop: CGFloat = 56
    private static let marginBottom: CGFloat = 64
    private static let marginLeft: CGFloat = 70   // запас под подшивку
    private static let marginRight: CGFloat = 56

    @MainActor
    static func save(caseNumber: String, text: String,
                     paragraphs: [ActParagraph]? = nil, originalPDF: Data? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename(caseNumber: caseNumber)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try write(to: url, text: text, paragraphs: paragraphs, originalPDF: originalPDF) }
        catch { NSAlert(error: error).runModal() }
    }

    static func filename(caseNumber: String) -> String {
        SafeFilename.component(
            "Дело № \(caseNumber)", fallback: "Судебный акт", maxLength: 116) + ".pdf"
    }

    /// Без UI-панели — для ExportCourtActPDFIntent. Возвращает байты, чтобы
    /// App Intents сам управлял временным файлом и его временем жизни.
    @MainActor
    static func renderData(text: String, paragraphs: [ActParagraph]? = nil) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sudrf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try? write(to: url, text: text, paragraphs: paragraphs)
        return try? Data(contentsOf: url)
    }

    @MainActor
    static func write(to url: URL, text: String, paragraphs: [ActParagraph]? = nil,
                      originalPDF: Data? = nil) throws {
        if let originalPDF {
            try originalPDF.write(to: url, options: .atomic)
            return
        }
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paper
        printInfo.topMargin = marginTop
        printInfo.bottomMargin = marginBottom
        printInfo.leftMargin = marginLeft
        printInfo.rightMargin = marginRight
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let contentWidth = paper.width - marginLeft - marginRight
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 10))
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(
            attributedAct(text, paragraphs: paragraphs))
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }

    // MARK: типографика — зеркало ActTextView

    static func attributedAct(_ text: String,
                              paragraphs: [ActParagraph]? = nil) -> NSAttributedString {
        let blocks = CourtActFormatter.parse(text, paragraphs: paragraphs)
        let out = NSMutableAttributedString()

        let bodySize: CGFloat = 13
        let body: NSFont = NSFont(name: "Times New Roman", size: bodySize)
            ?? NSFont(name: "Georgia", size: bodySize)
            ?? .systemFont(ofSize: bodySize)
        let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        let italicBold = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)

        func style(_ configure: (NSMutableParagraphStyle) -> Void) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            configure(p)
            return p
        }

        func append(_ string: String, font: NSFont,
                    color: NSColor = .black,
                    kern: CGFloat = 0,
                    paragraph: NSMutableParagraphStyle) {
            out.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: color,
                .kern: kern, .paragraphStyle: paragraph,
            ]))
        }

        for block in blocks {
            switch block {
            case .meta(let s):
                append(s, font: NSFontManager.shared.convert(body, toSize: 9.5),
                       color: .darkGray,
                       paragraph: style { $0.alignment = .center; $0.paragraphSpacing = 4 })
            case .title(let s):
                append(s, font: NSFontManager.shared.convert(bold, toSize: 14),
                       kern: 1.5,
                       paragraph: style { $0.alignment = .center
                                          $0.paragraphSpacingBefore = 14
                                          $0.paragraphSpacing = 6 })
            case .subtitle(let s):
                append(s, font: NSFontManager.shared.convert(body, toSize: 11),
                       color: .darkGray,
                       paragraph: style { $0.alignment = .center; $0.paragraphSpacing = 10 })
            case .verb(let s):
                append(s, font: italicBold,
                       paragraph: style { $0.alignment = .center
                                          $0.paragraphSpacingBefore = 8
                                          $0.paragraphSpacing = 8 })
            case .paragraph(let s):
                append(s, font: body,
                       paragraph: style { $0.alignment = .justified
                                          $0.firstLineHeadIndent = 22
                                          $0.lineSpacing = 3
                                          $0.paragraphSpacing = 6
                                          $0.hyphenationFactor = 0.9 })
            }
        }
        return out
    }
}
