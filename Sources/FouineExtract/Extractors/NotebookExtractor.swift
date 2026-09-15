// NotebookExtractor.swift — ipynb (SPEC §5.3).
// Propriété : A-Ingest.
//
// Extraction des carnets Jupyter (.ipynb). Analyse via JSONSerialization plutôt
// qu'un modèle Codable rigide car les schémas de carnets varient selon les versions
// de nbformat. Les cellules markdown, code et raw sont extraites dans l'ordre.
// Les sorties de cellules (outputs) sont délibérément ignorées : elles sont
// volumineuses (données tabulaires, traces, images base64) et redondantes avec
// le code source qui les génère.

import Foundation
import FouineCore

public struct NotebookExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["ipynb"]

    public init() {}

    /// Extrait le texte d'un champ source, qu'il soit représenté sous forme de
    /// chaîne unique ou de tableau de lignes (format standard nbformat).
    static func extractSource(_ raw: Any?) -> String? {
        if let str = raw as? String {
            return str
        }
        if let array = raw as? [String] {
            let hasNewlines = array.contains { $0.contains("\n") }
            return hasNewlines ? array.joined() : array.joined(separator: "\n")
        }
        return nil
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else {
            throw FouineError.extraction("not a Jupyter notebook (\(url.lastPathComponent))")
        }

        var cellTexts: [String] = []
        for cell in cells {
            guard let cellType = cell["cell_type"] as? String,
                  ["markdown", "code", "raw"].contains(cellType) else { continue }
            // Les sorties (outputs) sont délibérément ignorées : elles sont volumineuses et redondantes.
            guard let source = Self.extractSource(cell["source"]),
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            cellTexts.append(source)
        }

        let fullText = cellTexts.joined(separator: "\n\n")
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        let text = budget.take(fullText)
        return Assembler.paginatedResult(text: text, limits: limits, meta: [:])
    }
}
