// VisionOCREngine.swift — Vision `.accurate`, passe unique (SPEC §2.7, §6.2).
// Propriété : A-OCR. NOM IMPOSÉ : la CLI se câble dessus.
//
// Configuration IMPOSÉE (§6.2), reproduite ici sans variante :
//     recognitionLevel       = .accurate      (D1 : `.fast` n'est plus jamais émis)
//     recognitionLanguages   = ["fr-FR", "en-US"]
//     usesLanguageCorrection = true
//     revision               = VNRecognizeTextRequestRevision3
//     customWords            = vocabulaire de l'index (§6.2, durcissement n°2)
//     automaticallyDetectsLanguage : JAMAIS activé — il annule recognitionLanguages.
//
// `OCRLevel.fast` reste accepté par `recognize` pour les bancs d'essai comparatifs
// d'A-Recette (§4.2) ; la pompe du §6.3 ne le demande jamais.
//
// Convention de coordonnées : la boîte de Vision est déjà normalisée 0..1, origine
// EN BAS À GAUCHE — exactement la convention d'`ocr_layout` (§4.1) et du canal
// externe (annexe B). Elle est donc recopiée TELLE QUELLE : toute « correction »
// d'origine ici casserait le surlignage et l'import JSONL du même coup.

import Foundation
import CoreGraphics
import Vision
import FouineCore
import FouineExtract

public final class VisionOCREngine: OCREngine {

    /// Seuil de confiance d'entrée dans `page_fts` (§6.2, durcissement n°3).
    /// PROVISOIRE et exposé en `var` pour qu'A-Recette le calibre sans recompiler
    /// le module : c'est un réglage, pas une constante physique.
    ///
    /// RECTIFICATIF du 01/09/2026 (audit A5). La note précédente affirmait, sur
    /// une mesure du 31/08 faite sur trop peu de pages, que « Vision ne rend que
    /// DEUX valeurs de confiance, 0,5 et 1,0 » et qu'à 0,30 le filtre ne
    /// rejetait donc rien. C'est FAUX : la base de production porte 107 pages
    /// dont `page_src.conf` — moyenne des lignes RETENUES — tombe strictement
    /// entre 0,30 et 0,50 (0,3476…, 0,4166…, 0,4348…), ce qui est arithmétiquement
    /// impossible si toutes les lignes valaient 0,5 ou 1,0. Vision rend donc bien
    /// des confiances continues, et ce filtre écarte du texte de `page_fts`.
    ///
    /// Le seuil n'est PAS modifié ici — le recalibrer est une décision produit,
    /// à prendre sur recette. En revanche la perte n'est plus silencieuse :
    /// `rejection` la compte et la journalise, page par page.
    public static var confidenceThreshold: Double = 0.30

    /// Compteur — et journal — des lignes écartées par le seuil de confiance.
    ///
    /// Le protocole `OCREngine` (§4.2) impose la signature de `recognize` : il
    /// n'y a pas de paramètre `log:` où faire passer le journal du run. La pompe
    /// y branche donc le sien par `rejection.attach(log:)` avant d'ouvrir la
    /// file ; sans branchement, le moteur compte sans rien écrire.
    public let rejection = RejectionLog()

    /// Langues par défaut (§6.2). `fr-FR` vérifié présent en rev3.
    ///
    /// Elles ne sont plus IMPOSÉES depuis le palier 2.3 : `ocr.languages`
    /// (table `settings`) les remplace, et ce tableau n'est plus que le défaut
    /// du catalogue — c'est-à-dire ce que faisait le code avant (audit X2 :
    /// « langues figées, CJK inindexable »).
    public static let defaultLanguages = ["fr-FR", "en-US"]

    /// Les langues que CETTE machine sait reconnaître, en `.accurate` rev3.
    ///
    /// À DEMANDER AVANT DE TRANSMETTRE, toujours : Vision fait échouer la
    /// requête ENTIÈRE sur une langue inconnue de la révision — une page ne
    /// serait pas « moins bien reconnue », elle ne le serait pas du tout, et
    /// l'échec se compterait page par page dans `failOCR` sans que rien ne dise
    /// pourquoi. La liste dépend de la version de macOS et des paquets de
    /// langue installés : elle se lit à l'exécution, jamais en dur.
    ///
    /// Rendue triée, pour que la liste à cocher de la fenêtre de réglages ait
    /// un ordre stable. Vide si Vision refuse de répondre — l'appelant retombe
    /// alors sur `defaultLanguages` plutôt que de n'OCRiser rien du tout.
    public static func supportedLanguages(level: OCRLevel = .accurate) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.revision = VNRecognizeTextRequestRevision3
        guard let languages = try? request.supportedRecognitionLanguages() else {
            return []
        }
        return languages.sorted()
    }

    /// Filtre une liste demandée sur ce que la machine sait faire.
    ///
    /// - Returns: les langues retenues (dans l'ordre demandé) et celles qui ont
    ///   été écartées. Une liste vide après filtrage retombe sur
    ///   `defaultLanguages` : mieux vaut OCRiser en français et en anglais que
    ///   de ne rien reconnaître parce qu'un réglage désigne une langue absente.
    public static func filterLanguages(_ wanted: [String])
        -> (kept: [String], rejected: [String]) {
        let supported = supportedLanguages()
        guard !supported.isEmpty else { return (wanted, []) }
        // Comparaison insensible à la casse : « fr-fr » saisi à la main dans
        // `fouine config set` doit valoir « fr-FR ».
        let index = Dictionary(supported.map { ($0.lowercased(), $0) },
                               uniquingKeysWith: { first, _ in first })
        var kept: [String] = []
        var rejected: [String] = []
        for language in wanted {
            if let canonical = index[language.lowercased()] { kept.append(canonical) }
            else { rejected.append(language) }
        }
        return (kept.isEmpty ? defaultLanguages : kept, rejected)
    }

    public let id: OCREngineID = .vision
    /// Recopié dans `page_src.engine_rev` (§4.1).
    public let revision: String = "vision-rev3"

    public init() {}

    // MARK: - Préchauffage

    /// Charge le modèle une fois par processus (mesuré : 8,5 s au premier
    /// `.accurate`, §2.6). Sans lui, à 4 fils et des lots courts, chaque relance
    /// paie ce chargement autant de fois qu'il y a de fils.
    public func prewarm() throws {
        _ = try Self.perform(image: Self.prewarmImage(), level: .accurate,
                             languages: Self.defaultLanguages, customWords: [])
    }

    /// Mire minuscule générée en mémoire : un trait noir sur fond blanc.
    /// Rien n'est lu sur le disque, rien n'est écrit.
    static func prewarmImage() -> CGImage {
        // 64 × 64 : assez pour que Vision instancie son modèle, assez petit pour
        // que la reconnaissance elle-même ne coûte rien.
        guard let context = try? GrayRaster.grayContext(width: 64, height: 64) else {
            // Chemin injoignable en pratique ; un CGImage 1×1 vaut mieux qu'un crash.
            let fallback = CGContext(data: nil, width: 1, height: 1,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return fallback.makeImage()!
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: 28, width: 44, height: 8))
        return context.makeImage()!
    }

    // MARK: - Reconnaissance

    public func recognize(_ image: CGImage, level: OCRLevel,
                          languages: [String], customWords: [String]) throws -> OCRPage {
        let started = Date()
        let effectiveLanguages = languages.isEmpty ? Self.defaultLanguages : languages
        let observations = try Self.perform(image: image, level: level,
                                            languages: effectiveLanguages,
                                            customWords: customWords)
        let seconds = Date().timeIntervalSince(started)

        // TOUTES les lignes, boîte de Vision recopiée telle quelle.
        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            lines.append(OCRLine(text: candidate.string,
                                 x: Double(box.origin.x), y: Double(box.origin.y),
                                 w: Double(box.size.width), h: Double(box.size.height),
                                 confidence: Double(candidate.confidence)))
        }

        // Seules les lignes retenues alimentent page_fts et la moyenne de conf.
        // TOUTES restent dans `lines`, donc dans ocr_layout : le surlignage ne
        // perd rien, l'index si — d'où la mesure ci-dessous (audit A5).
        let threshold = Self.confidenceThreshold
        let retained = lines.filter { $0.confidence >= threshold }
        rejection.record(total: lines.count, retained: retained.count,
                         threshold: threshold)
        // Césures recollées (constat C2-10) : Vision rend une ligne par ligne
        // IMPRIMÉE, donc « dispen- » et « ser » sur deux lignes d'un scan
        // justifié. Les deux formes restent (voir `Dehyphenation`).
        let text = Dehyphenation.rejoin(
            retained.map(\.text).joined(separator: "\n"))
        let meanConfidence = retained.isEmpty
            ? 0
            : retained.reduce(0.0) { $0 + $1.confidence } / Double(retained.count)

        return OCRPage(text: text, lines: lines, level: level, seconds: seconds,
                       engine: id, engineRev: revision,
                       meanConfidence: meanConfidence)
    }

    // MARK: - Requête Vision

    /// Une requête NEUVE par appel : `VNRecognizeTextRequest` porte son résultat,
    /// la partager entre fils serait une course.
    static func perform(image: CGImage, level: OCRLevel, languages: [String],
                        customWords: [String]) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (level == .fast) ? .fast : .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        request.customWords = customWords
        // rev3 est la révision de référence des mesures du §2.6 ; on ne laisse pas
        // le système choisir à notre place d'une version de macOS à l'autre.
        if VNRecognizeTextRequest.supportedRevisions
            .contains(VNRecognizeTextRequestRevision3) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        // automaticallyDetectsLanguage reste à false : l'activer annulerait
        // recognitionLanguages (§6.2).

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // DÉLAI DE GARDE (audit F6). `handler.perform` est SYNCHRONE et sans
        // échéance : sur une image pathologique, il ne rend jamais la main, et
        // le fil OCR qui l'attend est perdu — avec lui la pompe, qui attend
        // `waitUntilAllOperationsAreFinished`. Rien dans l'API de Vision ne
        // permet d'imposer une durée.
        //
        // `request.cancel()` est demandé à l'échéance : Vision est le seul des
        // trois frameworks bornés (avec PDFKit) à savoir qu'on ne veut plus de
        // son résultat. Il n'y a AUCUNE garantie qu'il obtempère — d'où le
        // commentaire de `Deadline` sur le fil qui fuit.
        do {
            try Deadline.run(seconds: Deadline.ocrSeconds,
                             label: "Vision recognition of one page",
                             onExpiry: { request.cancel() }) {
                try handler.perform([request])
            }
        } catch let expired as DeadlineExceeded {
            // `.ocr` et non `.extraction` : la page est remise en file avec
            // `attempts + 1` (`failOCR`) et retentée deux fois avant d'être
            // abandonnée. Une page lente une fois n'est pas une page perdue.
            throw FouineError.ocr("Vision — \(expired.description)")
        } catch {
            throw FouineError.ocr(
                "Vision failed: \((error as NSError).localizedDescription)")
        }
        return request.results ?? []
    }
}

// MARK: - Mesure des lignes écartées (audit A5)

/// Ce que le seuil de confiance coûte à l'index, page par page puis en cumul.
///
/// Rendre la perte MESURABLE était la vraie demande de l'audit : le seuil, lui,
/// ne bouge pas tant qu'une recette ne l'a pas recalibré. Écrit depuis les
/// quatre fils OCR, d'où le mutex.
public final class RejectionLog: @unchecked Sendable {

    private let mutex = NSLock()
    private var sink: (@Sendable (String) -> Void)?
    private var rejectedLines = 0
    private var totalLines = 0
    private var affectedPages = 0
    private var pages = 0

    public init() {}

    /// Branche le journal du run. Appelé une fois, avant que les fils ne partent.
    public func attach(log: @escaping @Sendable (String) -> Void) {
        mutex.lock(); sink = log; mutex.unlock()
    }

    /// Cumul depuis l'ouverture du moteur.
    public var tally: (pages: Int, affectedPages: Int, rejected: Int, total: Int) {
        mutex.lock(); defer { mutex.unlock() }
        return (pages, affectedPages, rejectedLines, totalLines)
    }

    func record(total: Int, retained: Int, threshold: Double) {
        let rejected = max(0, total - retained)
        mutex.lock()
        pages += 1
        totalLines += total
        rejectedLines += rejected
        if rejected > 0 { affectedPages += 1 }
        let log = sink
        mutex.unlock()
        guard rejected > 0, let log else { return }
        log(String(format:
            "confidence: %d line(s) out of %d dropped from page_fts "
            + "(threshold %.2f) — kept in ocr_layout", rejected, total, threshold))
    }

    /// Une ligne de bilan pour le résumé de run. `nil` si rien n'a été écarté :
    /// inutile d'écrire « 0 » à chaque lot.
    public func summary() -> String? {
        let t = tally
        guard t.rejected > 0 else { return nil }
        let share = t.total > 0 ? 100.0 * Double(t.rejected) / Double(t.total) : 0
        return String(format:
            "confidence: %d line(s) out of %d dropped from page_fts (%.1f%%), "
            + "on %d page(s) out of %d — everything stays in ocr_layout",
            t.rejected, t.total, share, t.affectedPages, t.pages)
    }
}
