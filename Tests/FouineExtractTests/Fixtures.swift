// Fixtures.swift — fabrique de fixtures SYNTHÉTIQUES (SPEC §9.3 : les tests
// unitaires d'un module ne dépendent pas du corpus personnel).
// Propriété : A-Ingest, cible de test uniquement.
//
// Les archives sont fabriquées par /usr/bin/zip pour que les noms d'entrée
// soient exactement ceux attendus (« word/document.xml », sans « ./ »).
// Les PDF sont fabriqués par CoreGraphics + CoreText : c'est du VRAI texte
// vectoriel, donc PDFPage.string le rend comme sur un document réel.

import Foundation
import CoreGraphics
import CoreText
import XCTest

enum Fixtures {

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// Archive ZIP (docx, xlsx, pptx, epub, cbz…) aux noms d'entrée exacts.
    static func makeArchive(_ entries: [(name: String, data: Data)],
                            at destination: URL) throws {
        let staging = try temporaryDirectory("staging")
        defer { try? FileManager.default.removeItem(at: staging) }
        for entry in entries {
            let file = staging.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try entry.data.write(to: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // « -- » : sans lui, /usr/bin/zip lit lui aussi un nom d'entrée commençant
        // par un tiret comme une option, et la fixture piégée du test S1 ne peut
        // pas être fabriquée (« long option 'use-compress-program' not supported »).
        process.arguments = ["-q", "-X", destination.path, "--"]
            + entries.map(\.name)
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Fixtures", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip a échoué"])
        }
    }

    /// Premier exécutable `name` trouvé dans le PATH, nil sinon.
    static func which(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String],
                    in directory: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Fixtures", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "\(tool.lastPathComponent) a échoué"])
        }
        return process.terminationStatus
    }

    /// DjVu multipage RÉEL : une image bitonale par page (cjb2 + djvm) et, pour
    /// chaque texte non vide, une couche `TXTz` posée par djvused — exactement la
    /// forme des 5 fichiers du corpus. Un texte vide laisse la page SANS couche
    /// texte, cas qui décalait la numérotation.
    /// Nil si djvulibre n'est pas installé : le test appelant se saute (§9.3).
    static func makeDjvu(pages: [String], at destination: URL) throws -> Bool {
        guard let cjb2 = which("cjb2"), let djvm = which("djvm"),
              let djvused = which("djvused"), !pages.isEmpty
        else { return false }

        let staging = try temporaryDirectory("djvu")
        defer { try? FileManager.default.removeItem(at: staging) }

        // PBM 64×64 tout noir : le contenu de l'image n'a aucune importance ici,
        // seule compte la couche texte.
        let pbm = staging.appendingPathComponent("page.pbm")
        var bitmap = Data("P4\n64 64\n".utf8)
        bitmap.append(Data(repeating: 0xFF, count: 64 * 8))
        try bitmap.write(to: pbm)

        var singles: [String] = []
        for index in pages.indices {
            let single = staging.appendingPathComponent("p\(index + 1).djvu")
            try run(cjb2, [pbm.path, single.path])
            singles.append(single.path)
        }
        try? FileManager.default.removeItem(at: destination)
        try run(djvm, ["-c", destination.path] + singles)

        var script: [String] = []
        for (index, text) in pages.enumerated() where !text.isEmpty {
            let layer = staging.appendingPathComponent("t\(index + 1).txt")
            try Data("(page 0 0 64 64\n (line 0 0 64 64 \"\(text)\"))\n".utf8)
                .write(to: layer)
            script.append("select \(index + 1); set-txt \(layer.path)")
        }
        if !script.isEmpty {
            try run(djvused, [destination.path, "-e",
                              script.joined(separator: "; ") + "; save"])
        }
        return true
    }

    static func xml(_ body: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body).utf8)
    }

    /// Un PNG minuscule mais valide : les tests ne le décodent pas, ils vérifient
    /// l'ordre et le contenu d'octets rendus par bsdtar.
    static func pngBytes(_ marker: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, marker])
    }

    /// PDF réel : une page par élément, chaque ligne dessinée en texte vectoriel.
    static func makePDF(pages: [[String]], at url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "Fixtures", code: 1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "Fixtures", code: 2)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 740
            for line in lines {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 40, y: y)
                CTLineDraw(ctLine, context)
                y -= 16
                if y < 40 { break }
            }
            context.endPDFPage()
        }
        context.closePDF()
        try data.write(to: url)
    }

    /// Lignes de `count` caractères, marquées, pour dépasser le seuil des 100
    /// caractères natifs du §6.1 sans dépendre d'un livre réel.
    static func filler(marker: String, lines: Int = 8) -> [String] {
        (0..<lines).map { index in
            "\(marker) ligne \(index) chromatographie enthalpie polymere azote"
        }
    }

    /// Chemins réels du §8.1, si `Tests/Fixtures/paths.json` est présent.
    /// GITIGNORÉ : tout test qui en dépend se saute proprement (§9.3).
    static func corpusPath(fixture: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: #filePath)                 // Tests/FouineExtractTests
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/paths.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let fixtures = root["fixtures"] as? [String: Any],
                  let entry = fixtures[fixture] as? [String: Any],
                  let path = entry["path"] as? String
            else { continue }
            return FileManager.default.isReadableFile(atPath: path) ? path : nil
        }
        return nil
    }
}
