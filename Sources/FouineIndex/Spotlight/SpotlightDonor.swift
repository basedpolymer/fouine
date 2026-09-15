// SpotlightDonor.swift — l'adaptateur vers `CSSearchableIndex` (lot INT-S1).
// Propriété : A-Core.
//
// TOUT CE QUI TOUCHE CORESPOTLIGHT EST ICI, ET RIEN D'AUTRE. La politique, la
// construction des éléments et la synchronisation sont pures et testées ; ce
// fichier-ci ne se teste pas — il exige un bundle installé —, et c'est
// exactement pourquoi il ne contient aucune décision.
//
// LE PIÈGE DU BUNDLE, DÉJÀ PAYÉ UNE FOIS (`Notifier.swift`). Un exécutable sans
// `CFBundleIdentifier` — `swift run FouineApp`, la CLI lancée depuis un
// terminal, l'agent launchd — n'a pas d'identité auprès des services système :
// `CSSearchableIndex` y refuse le travail (au mieux) ou termine le processus
// (au pire), comme `UNUserNotificationCenter`. D'où `isAvailable`, consulté
// AVANT toute autre chose. `fouine index` depuis le Terminal ne donne donc
// jamais rien à Spotlight : c'est l'application ou l'agent, au rattrapage
// suivant, qui le fait — et la CLI le dit dans son journal.
//
// SYNCHRONE, PAR CHOIX. `CSSearchableIndex` travaille par rappels ; la remise,
// elle, est appelée en fin de passe d'indexation, sur un fil de travail, et
// doit être finie quand la passe se termine — sans quoi le marqueur
// `spotlight.synced_at` serait écrit avant que Spotlight ait reçu quoi que ce
// soit, et les documents de cette passe ne seraient jamais redonnés. Un
// sémaphore avec ÉCHÉANCE : une remise qui n'a pas répondu en deux minutes est
// signalée comme une erreur (une note dans le journal), jamais une attente
// infinie.

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import FouineCore

/// Une remise à Spotlight qui n'a pas abouti. Anglais : c'est un message de
/// journal, pour les dépanneurs.
public struct SpotlightFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Ce que la synchronisation demande au système. Un protocole, parce que les
/// tests ont besoin d'un donateur qui ne parle à personne.
public protocol SpotlightDonating: Sendable {
    /// Ce processus peut-il donner ? (Bundle présent, indexation disponible.)
    var isAvailable: Bool { get }
    /// Remet des éléments. Idempotent : un élément déjà remis est remplacé.
    func index(_ items: [SpotlightItem]) throws
    /// Retire des éléments désignés.
    func delete(identifiers: [String]) throws
    /// Retire TOUT ce que Fouine a donné (son domaine, et lui seul).
    func deleteAll() throws
}

/// Le donateur réel.
public struct SpotlightDonor: SpotlightDonating {

    /// Taille d'un lot remis en une fois. Cent éléments portant chacun jusqu'à
    /// un mégaoctet de texte suffisent à faire un appel très lourd : deux cents
    /// est un compromis mesuré ailleurs (Apple recommande des lots, sans
    /// chiffre), et surtout un appel qui échoue ne fait perdre que ce lot.
    public static let batchSize = 200

    /// Au-delà, on considère que le service ne répondra pas. Deux minutes :
    /// l'indexation système peut être occupée après un démarrage.
    public static let timeout: TimeInterval = 120

    public init() {}

    /// Trois conditions, et aucune n'est théorique.
    ///
    /// 1. L'identifiant de bundle est celui de FOUINE, à l'octet près. « Un
    ///    bundle » ne suffirait pas : `swift test` s'exécute dans le bundle de
    ///    `xctest`, qui a un identifiant parfaitement valide — et les tests ont
    ///    effectivement remis des documents à l'index Spotlight de la machine
    ///    avant que cette ligne existe (constaté le 08/09/2026). Aucun test ne
    ///    touche la production, l'index de Spotlight compris.
    /// 2. Le processus est l'EXÉCUTABLE de ce bundle. L'agent d'arrière-plan
    ///    vit dans `Fouine.app/Contents/MacOS/FouineAgent` : `Bundle.main` lui
    ///    rend l'application, identifiant compris, alors qu'il n'en est pas
    ///    l'exécutable principal. C'est exactement la configuration où
    ///    `UNUserNotificationCenter.current()` TERMINE le processus
    ///    (« bundleProxy is nil », en-tête de `Notifier`), et un agent launchd
    ///    qui meurt toutes les soixante secondes est le pire mode de panne du
    ///    produit. L'agent ne donne donc rien : c'est le rattrapage de
    ///    l'application, au lancement suivant, qui remet ses documents.
    /// 3. L'indexation système est disponible.
    public var isAvailable: Bool {
        guard Bundle.main.bundleIdentifier == FouinePaths.appBundleIdentifier,
              let executable = Bundle.main.executableURL?.lastPathComponent,
              executable == ProcessInfo.processInfo.processName
        else { return false }
        return CSSearchableIndex.isIndexingAvailable()
    }

    public func index(_ items: [SpotlightItem]) throws {
        guard isAvailable, !items.isEmpty else { return }
        var start = items.startIndex
        while start < items.endIndex {
            let end = items.index(start, offsetBy: Self.batchSize,
                                  limitedBy: items.endIndex) ?? items.endIndex
            let batch = items[start..<end].map(Self.searchable)
            try wait("hand \(batch.count) document(s) to Spotlight") { done in
                CSSearchableIndex.default()
                    .indexSearchableItems(batch, completionHandler: done)
            }
            start = end
        }
    }

    public func delete(identifiers: [String]) throws {
        guard isAvailable, !identifiers.isEmpty else { return }
        var start = identifiers.startIndex
        while start < identifiers.endIndex {
            let end = identifiers.index(start, offsetBy: Self.batchSize,
                                        limitedBy: identifiers.endIndex)
                ?? identifiers.endIndex
            let batch = Array(identifiers[start..<end])
            try wait("remove \(batch.count) document(s) from Spotlight") { done in
                CSSearchableIndex.default()
                    .deleteSearchableItems(withIdentifiers: batch,
                                           completionHandler: done)
            }
            start = end
        }
    }

    public func deleteAll() throws {
        guard isAvailable else { return }
        // PAR DOMAINE, et non `deleteAllSearchableItems` : le domaine est celui
        // de Fouine (`SpotlightItemBuilder.domain`), et rien ne dit qu'un jour
        // l'application ne donnera pas autre chose (un dossier, un réglage).
        try wait("remove Fouine's documents from Spotlight") { done in
            CSSearchableIndex.default().deleteSearchableItems(
                withDomainIdentifiers: [SpotlightItemBuilder.domain],
                completionHandler: done)
        }
    }

    // MARK: - Traduction

    private static func searchable(_ item: SpotlightItem) -> CSSearchableItem {
        let type = item.contentTypeIdentifier
            .flatMap { UTType($0) } ?? .data
        let attributes = CSSearchableItemAttributeSet(contentType: type)
        attributes.title = item.title
        attributes.displayName = item.title
        attributes.contentDescription = item.contentDescription
        attributes.textContent = item.textContent
        attributes.keywords = item.keywords
        attributes.contentURL = item.contentURL
        return CSSearchableItem(uniqueIdentifier: item.identifier,
                                domainIdentifier: item.domainIdentifier,
                                attributeSet: attributes)
    }

    // MARK: - Attente bornée

    /// Le rappel de CoreSpotlight arrive d'une file qui n'est pas la nôtre :
    /// l'erreur passe par une boîte verrouillée, pas par une capture mutable
    /// (même patron qu'`Uninstaller.FailureBox`).
    private final class ErrorBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: Error?
        func set(_ error: Error?) { mutex.lock(); stored = error; mutex.unlock() }
        var value: Error? { mutex.lock(); defer { mutex.unlock() }; return stored }
    }

    private func wait(_ what: String,
                      _ work: (@escaping @Sendable (Error?) -> Void) -> Void) throws {
        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        work { error in
            box.set(error)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.timeout) == .success else {
            throw SpotlightFailure("Spotlight did not answer in "
                                   + "\(Int(Self.timeout))s (\(what))")
        }
        if let error = box.value {
            throw SpotlightFailure("Spotlight refused to \(what): "
                                   + error.localizedDescription)
        }
    }
}
