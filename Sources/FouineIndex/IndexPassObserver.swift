// IndexPassObserver.swift — ce qu'une passe d'indexation raconte à son appelant.
// Propriété : A-Core, audit F2.
//
// Les trois pipelines rendaient compte de trois façons : la CLI imprimait, l'agent
// journalisait, l'app publiait un état. C'est la SEULE chose qui les distinguait
// légitimement — le reste (erreurs fatales, `upsertDoc`, budget, annulation) a
// divergé par accident. On garde donc la sortie, et rien d'autre : `IndexPass`
// émet des événements, l'adaptateur les met en forme.
//
// CONCURRENCE. Les événements de document naissent sur les fils d'extraction.
// `IndexPass` les SÉRIALISE sur un verrou qui lui est propre : un observateur
// n'a pas à être réentrant, ne verra jamais deux appels en même temps, et n'est
// JAMAIS appelé pendant qu'un verrou de la base ou des compteurs est tenu (une
// impression bloquante ne peut donc pas retarder une écriture SQLite).

import Foundation
import FouineCore

/// Consultée entre deux documents et dans les boucles longues. Vrai = arrêter.
public typealias ShouldStop = @Sendable () -> Bool

/// Budget de DURÉE d'une passe (§4.3 `--budget-minutes`, §6.3).
public struct Budget: Sendable {
    public let deadline: Date?

    public init(deadline: Date?) { self.deadline = deadline }

    /// `nil` minute = pas de budget. Le passer par ici évite de refaire le
    /// calcul `Date() + m * 60` dans les trois pipelines.
    public static func minutes(_ minutes: Int?, from start: Date = Date()) -> Budget {
        Budget(deadline: minutes.map { start.addingTimeInterval(Double($0) * 60) })
    }

    public static let none = Budget(deadline: nil)

    public var isExhausted: Bool {
        guard let deadline else { return false }
        return Date() >= deadline
    }
}

/// Ce qu'un document est devenu.
public struct DocumentOutcome: Sendable {
    public enum Kind: Sendable { case extracted, failed, skipped }

    public let docID: Int64
    public let relPath: String
    public let kind: Kind
    /// Motif écrit dans `docs.err` (`.failed`, `.skipped`) ; `nil` sur succès.
    public let reason: String?
    public let pages: Int
    public let queuedForOCR: Int
}

/// Compteurs d'une passe. `total` est le nombre de cibles retenues, `done` ce
/// qui en est sorti — extraits, ignorés et échoués confondus.
public struct IndexCounters: Sendable, Equatable {
    public var total = 0
    public var done = 0
    public var extracted = 0
    public var failed = 0
    public var skipped = 0
    public var pages = 0
    public var queued = 0
    /// Documents laissés en file par l'échéance du budget (§4.3, sortie 4).
    public var budgetSkipped = 0
    /// Documents dont la LANGUE a été rattrapée en fin de passe (lot U3, R-10).
    /// Sans rapport avec `done` : ce sont d'anciens documents, indexés avant
    /// que la détection existe, pas des cibles de cette passe.
    public var languagesDetected = 0
}

/// Pourquoi la passe s'est terminée.
public enum IndexPassStop: Sendable, Equatable {
    case completed
    case cancelled
    case budgetExhausted
}

public struct IndexPassSummary: Sendable {
    public var counters = IndexCounters()
    public var stop: IndexPassStop = .completed
    /// Racines dont le parcours a échoué sans arrêter la passe (app, §5.6).
    public var rootFailures: [String] = []
}

/// Tout ce qu'une passe dit d'elle-même.
public enum IndexPassEvent: Sendable {
    /// Le parcours d'une racine commence. Les racines sont faites l'une après
    /// l'autre : c'est ce qui permet à l'app de nommer celle qui est en cours,
    /// un crawl n'étant pas interruptible et pouvant durer.
    case willCrawl(root: String)
    /// Une racine a été parcourue.
    case crawled(root: String, summary: CrawlSummary)
    /// Le parcours d'une racine a échoué ET la passe continue (§5.6).
    case rootFailed(root: String, message: String)
    /// Les cibles sont connues. Le total ne bougera plus.
    case extractionWillStart(total: Int)
    /// La lecture d'un document COMMENCE (ST1) — son nom de fichier.
    ///
    /// Il y en a autant en vol que de fils d'extraction. Ce n'est pas de quoi
    /// faire défiler un nom à l'écran (l'agent le fait déjà, avec le dernier
    /// ABOUTI) : c'est ce qui permet à l'application de dire ce qu'elle ATTEND
    /// quand on lui demande de s'arrêter — « Arrêt — “cours.mp4” se termine… ».
    case willExtract(document: String)
    /// Un document a quitté l'extraction SANS être compté : l'arrêt est arrivé
    /// pendant sa lecture (ST1). Il reste `.discovered`, rien n'a été écrit,
    /// et la passe suivante le reprendra. Le pendant de `.willExtract` quand il
    /// n'y aura pas de `.document`.
    case abandoned(document: String)
    /// Un document est sorti de la file d'extraction.
    case document(DocumentOutcome)
    /// Compteurs courants, pour une barre de progression.
    case progress(IndexCounters)
    /// Fin de passe : `optimize` + `vocab_tri` (§5.1, §5.5.2). Sans compteur,
    /// et long (18-25 s sur le vocabulaire réel) : l'app doit pouvoir le dire.
    case willConsolidate
    /// Journal : verrou périmé repris, cible non localisée, racine sautée.
    case note(String)
    /// Bilan. Toujours le dernier événement, y compris après une erreur fatale.
    case finished(IndexPassSummary)
}

public protocol IndexPassObserver: Sendable {
    func indexPass(_ event: IndexPassEvent)
}

/// Observateur qui ne fait rien : pour les appelants qui ne veulent que le bilan
/// rendu par `run`, et pour les tests qui n'observent pas.
public struct SilentObserver: IndexPassObserver {
    public init() {}
    public func indexPass(_ event: IndexPassEvent) {}
}
