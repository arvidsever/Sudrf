//  ActWindow.swift — Sudrf · v2 · новый файл
//  Отдельное окно с текстом акта + постраничный экспорт в PDF (A4).

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Полезная нагрузка отдельного окна
//  openWindow(value:) требует Codable & Hashable — передаём снимок, а не модель.

struct ActWindowPayload: Codable, Hashable {
    var caseNumber: String
    var actText: String
}

// MARK: - Содержимое отдельного окна

struct ActWindowView: View {
    let payload: ActWindowPayload

    var body: some View {
        ScrollView {
            ActTextView(text: payload.actText)
                .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Дело № \(payload.caseNumber) — текст судебного акта")
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 600)
        .toolbar {
            ToolbarItem {
                Button {
                    ActPDFExporter.save(caseNumber: payload.caseNumber, text: payload.actText)
                } label: {
                    Label("Сохранить в PDF", systemImage: "square.and.arrow.down")
                }
                .help("Сохранить в PDF")
            }
        }
    }
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
    static func save(caseNumber: String, text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue =
            "Дело № \(caseNumber.replacingOccurrences(of: "/", with: "-")).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url, text: text)
    }

    @MainActor
    private static func write(to url: URL, text: String) {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paper
        printInfo.topMargin = marginTop
        printInfo.bottomMargin = marginBottom
        printInfo.leftMargin = marginLeft
        printInfo.rightMargin = marginRight
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let contentWidth = paper.width - marginLeft - marginRight
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 10))
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributedAct(text))
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }

    // MARK: типографика — зеркало ActTextView

    private static func attributedAct(_ text: String) -> NSAttributedString {
        let blocks = CourtActFormatter.parse(text)
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
