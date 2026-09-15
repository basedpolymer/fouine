// Deadline.swift — délai de garde autour d'un appel BLOQUANT non annulable
// (audit F6). Propriété : A-Ingest (palier 3, 02/09/2026).
//
// POURQUOI. `Subprocess` borne déjà tout ce qui est un PROCESSUS : un enfant qui
// s'égare se tue (SIGTERM, puis SIGKILL). Restaient les appels de FRAMEWORK, qui
// ne s'interrompent pas et n'avaient aucune échéance :
//   · `VNImageRequestHandler.perform` — Vision, synchrone, sur l'image d'une page ;
//   · `PDFDocument(url:)` et `PDFPage.string` — PDFKit, sur un fichier que
//     personne n'a validé ;
//   · `PDFPage.draw(with:to:)` — le rendu de la page à OCRiser.
// Un seul de ces appels bloqué gelait un fil de la pompe, et la pompe attendant
// `waitUntilAllOperationsAreFinished`, la commande entière (le même mécanisme
// exact que A11.7 pour bsdtar, mais côté framework).
//
// CE QUE CE FICHIER FAIT, ET CE QU'IL NE FAIT PAS. Il exécute le corps sur un
// FIL DÉDIÉ et rend la main à l'échéance. Ce qu'il NE FAIT PAS, et qu'aucun code
// ne peut faire : arrêter le fil. `Thread.exit()` depuis l'extérieur n'existe
// pas, et `pthread_cancel` sur un fil arrêté au milieu de PDFKit laisserait des
// verrous CoreGraphics pris — ce serait échanger un gel contre une corruption.
//
//     UN FIL BLOQUÉ DANS PDFKIT OU DANS VISION N'EST PAS RÉCUPÉRABLE : IL FUIT,
//     avec sa pile (8 Mio réservés, quelques centaines de Kio résidents) et ce
//     que le framework retient. C'est ACCEPTÉ, pour deux raisons : le cas est
//     rare (aucune occurrence sur les 379 267 pages du corpus de recette), et
//     la seule alternative — laisser la passe entière gelée — est pire. Un
//     dépassement est donc JOURNALISÉ : si la fuite devient un motif, elle se
//     lira dans le journal avant de se lire dans la mémoire.
//
// Côté appelant, un dépassement se traduit en `FouineError.extraction` (le
// document tombe en `.failed` avec `docs.err`, la passe continue : c'est
// `IndexFault.perDocument`) ou en `FouineError.ocr` (la page est remise en file
// avec `attempts + 1`, et abandonnée au bout de trois : c'est `failOCR`).

import Foundation
import FouineCore

/// Levée quand `Deadline.run` n'a pas obtenu son résultat à temps.
public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let label: String
    public let seconds: TimeInterval
    public var description: String {
        "deadline exceeded (\(Self.format(seconds)) s): \(label)"
    }
    static func format(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.1f", seconds) : String(Int(seconds.rounded()))
    }
}

public enum Deadline {

    // MARK: - Budgets

    /// OCR d'UNE page par Vision.
    ///
    /// MESURÉ sur cette machine (Intel i5, 02/09/2026) : une page A4 dense —
    /// 40 lignes de texte vectoriel, rendue à 150 dpi (1 240 × 1 754) puis à
    /// 300 dpi (1 681 × 2 379, plafond de 4 Mpx du §6.3) — passe en `.accurate`
    /// en 2,1 s à 3,8 s selon la charge de la machine ; le préchauffage du
    /// modèle, lui, coûte 8,5 s une fois par processus (§2.6).
    ///
    /// 120 s laissent donc un facteur 30 sur la page la plus lente mesurée. Le
    /// seuil ne se déclenchera que sur un VRAI blocage, jamais sur une page
    /// difficile — c'est la seule chose qu'on lui demande.
    /// `FOUINE_OCR_TIMEOUT` (secondes) le remplace — pour la recette et les tests.
    public static var ocrSeconds: TimeInterval {
        seconds(from: "FOUINE_OCR_TIMEOUT") ?? 120
    }

    /// Rendu d'UNE page (PDFKit, archive BD, média OOXML). Médiane mesurée
    /// 0,140 s/page, seuil de recette P2 à 0,6 s : 120 s valent un facteur 200.
    /// `FOUINE_RENDER_TIMEOUT` le remplace.
    public static var renderSeconds: TimeInterval {
        seconds(from: "FOUINE_RENDER_TIMEOUT") ?? 120
    }

    /// Ouverture d'un `PDFDocument`. Une ouverture est un parse d'en-tête et de
    /// table des objets : MESURÉ à 0,075 s sur un PDF de 300 pages (02/09/2026).
    /// 60 s valent donc un facteur 800 ; au-delà, le fichier ne s'ouvre pas, il
    /// piège l'analyseur.
    public static var pdfOpenSeconds: TimeInterval {
        seconds(from: "FOUINE_PDF_TIMEOUT") ?? 60
    }

    /// Budget de la BOUCLE de pages d'un PDF, proportionnel à sa taille : la
    /// même échéance ne peut pas valoir pour une facture d'une page et pour un
    /// traité de 1 315.
    ///
    /// MESURÉ (02/09/2026) : 300 pages de texte vectoriel dense s'extraient en
    /// 1,36 s, réouvertures /100 pages comprises, soit 4,5 ms par page. 0,5 s
    /// par page laisse donc un facteur 100 — large exprès, parce qu'un PDF réel
    /// (polices exotiques, pages scannées mêlées) coûte plus qu'une fixture. Le
    /// socle de 60 s couvre les documents courts, où le coût fixe domine.
    /// Plafond à 30 minutes : le plus gros document du corpus (1 315 pages)
    /// demande 718 s par cette formule, soit moins de la moitié.
    ///
    /// `FOUINE_PDF_TIMEOUT` remplace le TOTAL (formule court-circuitée) : c'est
    /// ce qui permet aux tests d'injecter une échéance minuscule.
    public static func pdfPagesSeconds(pageCount: Int) -> TimeInterval {
        if let forced = seconds(from: "FOUINE_PDF_TIMEOUT") { return forced }
        return min(1_800, 60 + 0.5 * Double(max(0, pageCount)))
    }

    /// Lecture d'un budget en secondes dans l'environnement. Une valeur absente,
    /// vide, illisible ou ≤ 0 est ignorée : une variable mal saisie ne doit pas
    /// désarmer un garde-fou en silence.
    static func seconds(from variable: String,
                        environment: [String: String]
                            = ProcessInfo.processInfo.environment) -> TimeInterval? {
        guard let raw = environment[variable], !raw.isEmpty,
              let value = TimeInterval(raw), value > 0 else { return nil }
        return value
    }

    // MARK: - Exécution bornée

    /// Exécute `body` sur un fil dédié et rend son résultat ; lève
    /// `DeadlineExceeded` si l'échéance tombe d'abord.
    ///
    /// - Parameters:
    ///   - seconds: échéance.
    ///   - label: ce qu'on faisait, pour le message et le journal.
    ///   - onExpiry: appelé À L'ÉCHÉANCE, avant de lever. C'est là que Vision
    ///     reçoit son `request.cancel()` — le seul framework des trois qui sache
    ///     être prié d'arrêter. PDFKit n'a pas d'équivalent.
    ///   - body: l'appel bloquant. Il continue de tourner après l'échéance (voir
    ///     l'en-tête de ce fichier) ; son résultat, s'il arrive, est jeté.
    public static func run<T>(seconds: TimeInterval,
                              label: String,
                              onExpiry: (@Sendable () -> Void)? = nil,
                              body: @escaping @Sendable () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            do { box.set(.success(try body())) }
            catch { box.set(.failure(error)) }
            done.signal()
        }
        thread.name = "fouine.deadline"
        // 8 Mio : la pile par défaut d'un `Thread` est de 512 Kio, et PDFKit
        // comme Vision descendent profond sur un document tordu. Une pile trop
        // courte se solderait par un plantage du processus entier — un mal bien
        // pire que celui qu'on corrige ici.
        thread.stackSize = 8 << 20
        thread.qualityOfService = .utility
        thread.start()

        if done.wait(timeout: .now() + seconds) == .timedOut {
            onExpiry?()
            throw DeadlineExceeded(label: label, seconds: seconds)
        }
        switch box.take() {
        case .success(let value): return value
        case .failure(let error): throw error
        // Injoignable : le sémaphore n'est signalé qu'après l'écriture du
        // résultat. Une erreur explicite vaut mieux qu'un `!`.
        case nil: throw DeadlineExceeded(label: label, seconds: seconds)
        }
    }

    /// `run`, avec le dépassement déjà traduit en `FouineError.extraction`.
    ///
    /// Le document tombe alors en `.failed` avec le motif dans `docs.err`, et la
    /// passe CONTINUE : c'est `IndexFault.perDocument`. C'est aussi par là que le
    /// dépassement est journalisé — la passe écrit le motif de chaque document
    /// en échec, sans qu'un extracteur ait besoin d'un puits de journal à lui.
    public static func extraction<T>(seconds: TimeInterval,
                                     label: String,
                                     onExpiry: (@Sendable () -> Void)? = nil,
                                     body: @escaping @Sendable () throws -> T)
        throws -> T {
        do {
            return try run(seconds: seconds, label: label, onExpiry: onExpiry,
                           body: body)
        } catch let expired as DeadlineExceeded {
            throw FouineError.extraction(expired.description)
        }
    }

    /// `run`, avec le dépassement déjà traduit en `FouineError.ocr` : la page
    /// est remise en file avec `attempts + 1` (`failOCR`), et abandonnée au bout
    /// de trois tentatives.
    public static func ocr<T>(seconds: TimeInterval,
                              label: String,
                              onExpiry: (@Sendable () -> Void)? = nil,
                              body: @escaping @Sendable () throws -> T) throws -> T {
        do {
            return try run(seconds: seconds, label: label, onExpiry: onExpiry,
                           body: body)
        } catch let expired as DeadlineExceeded {
            throw FouineError.ocr(expired.description)
        }
    }

    /// Le résultat traverse deux fils : il lui faut un verrou, et il est
    /// `@unchecked Sendable` parce que `T` ne l'est pas toujours (un `CGImage`
    /// ne l'est pas ; il n'en est pas moins sûr à passer d'un fil à l'autre une
    /// fois construit et jamais plus modifié).
    final class ResultBox<T>: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: Result<T, Error>?
        func set(_ value: Result<T, Error>) {
            mutex.lock(); stored = value; mutex.unlock()
        }
        func take() -> Result<T, Error>? {
            mutex.lock(); defer { mutex.unlock() }; return stored
        }
    }
}
