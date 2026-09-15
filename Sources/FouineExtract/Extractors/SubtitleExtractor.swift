// SubtitleExtractor.swift — srt vtt (SPEC §5.3).
// Propriété : A-Ingest.
//
// Extraction des sous-titres .srt et .vtt. Le décodage réutilise les replis de
// PlainTextExtractor.decode. Seul le texte des répliques est conservé : pas de
// numéros de séquence, pas d'horodatages, pas d'en-tête WEBVTT, pas de blocs NOTE,
// pas de réglages de position, et balises (HTML ou ASS/SSA) nettoyées.
// Une réplique = une ligne ; les répliques consécutives identiques sont fusionnées.

import Foundation
import FouineCore

public struct SubtitleExtractor: TextExtractor {
    public static let supportedExtensions: Set<String> = ["srt", "vtt"]

    public init() {}

    /// Nettoie une ligne de réplique en retirant les balises de style ASS/SSA ({\...}),
    /// les balises HTML/XML (<...>), et en décodant les entités HTML (&amp;, &lt;...).
    static func cleanLine(_ raw: String) -> String {
        // Balises de formatage et positionnement ASS/SSA : {\an8}, {\pos(10,20)}, etc.
        let noAss = raw.replacingOccurrences(of: #"\{[^}]*\}"#,
                                            with: "",
                                            options: .regularExpression)
        // Balises HTML/XML et karaoke : <i>, </i>, <c.yellow>, <v Roger>, <00:19.000>, etc.
        let noTags = noAss.replacingOccurrences(of: #"<[^>]*>"#,
                                               with: "",
                                               options: .regularExpression)
        // Décodage des entités HTML (&amp; -> &, &lt; -> <, etc.)
        let decoded = HTMLText.decodeEntities(noTags)
        return decoded.trimmingCharacters(in: .whitespaces)
    }

    /// Analyse le texte brut d'un fichier .srt ou .vtt et extrait les répliques ordonnées.
    /// Une réplique = une ligne. Les répliques identiques consécutives sont fusionnées.
    static func parseSubtitles(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var cues: [String] = []
        var currentLines: [String] = []
        var hasTimestamp = false
        var inNote = false
        var inHeader = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Détection de l'en-tête WEBVTT ou d'un bloc de métadonnées/commentaires
            if trimmed.hasPrefix("WEBVTT") {
                inHeader = true
                continue
            }
            if trimmed == "NOTE" || trimmed.hasPrefix("NOTE ") || trimmed.hasPrefix("NOTE\t") {
                inNote = true
                continue
            }
            if trimmed == "STYLE" || trimmed.hasPrefix("STYLE ") || trimmed == "REGION" || trimmed.hasPrefix("REGION ") {
                inNote = true
                continue
            }

            // Ligne vide : réinitialise l'état de bloc et finalise la réplique en cours
            if trimmed.isEmpty {
                inHeader = false
                inNote = false
                if hasTimestamp {
                    let cleanedCue = currentLines.map(cleanLine).filter { !$0.isEmpty }.joined(separator: " ")
                    if !cleanedCue.isEmpty {
                        if cues.last != cleanedCue {
                            cues.append(cleanedCue)
                        }
                    }
                    currentLines = []
                    hasTimestamp = false
                }
                continue
            }

            if inHeader || inNote {
                continue
            }

            // Ligne d'horodatage : identifiée par "-->".
            // Tout réglage de position (align:start, line:0%, etc.) figure sur cette
            // ligne et se trouve ainsi éliminé avec elle.
            if trimmed.contains("-->") {
                // Dans un fichier mal formé sans saut de ligne entre répliques, la dernière
                // ligne accumulée peut être le numéro de séquence de la réplique suivante.
                if hasTimestamp {
                    if let last = currentLines.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                        currentLines.removeLast()
                    }
                    let cleanedCue = currentLines.map(cleanLine).filter { !$0.isEmpty }.joined(separator: " ")
                    if !cleanedCue.isEmpty {
                        if cues.last != cleanedCue {
                            cues.append(cleanedCue)
                        }
                    }
                    currentLines = []
                }
                hasTimestamp = true
                continue
            }

            // Si l'horodatage n'a pas encore été rencontré dans ce bloc, la ligne est
            // un numéro de réplique ou un identifiant de cue (ex. "1" en SRT, "cue-1" en VTT) :
            // on l'ignore.
            guard hasTimestamp else { continue }

            currentLines.append(trimmed)
        }

        // Dernier bloc en fin de fichier sans ligne vide terminale
        if hasTimestamp {
            let cleanedCue = currentLines.map(cleanLine).filter { !$0.isEmpty }.joined(separator: " ")
            if !cleanedCue.isEmpty {
                if cues.last != cleanedCue {
                    cues.append(cleanedCue)
                }
            }
        }

        return cues
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

        guard !data.isEmpty else {
            throw FouineError.extraction("empty subtitle file (\(url.lastPathComponent))")
        }

        // L'URL : un sous-titre enregistré par TextEdit porte son encodage
        // dans l'attribut étendu, et c'est lui qui départage (EX2).
        guard let decoded = PlainTextExtractor.decode(data, url: url) else {
            throw FouineError.extraction(
                "non-text content (\(url.lastPathComponent)): neither UTF-8, nor "
                + "Windows-1252, nor ISO-8859-1, nor plausible macOSRoman — binary file?")
        }

        let cues = Self.parseSubtitles(decoded)
        guard !cues.isEmpty else {
            throw FouineError.extraction("empty subtitle file (\(url.lastPathComponent))")
        }

        let fullText = cues.joined(separator: "\n")
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        let text = budget.take(fullText)
        return Assembler.paginatedResult(text: text, limits: limits, meta: [:])
    }
}
