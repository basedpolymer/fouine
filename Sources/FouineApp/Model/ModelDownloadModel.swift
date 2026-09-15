// ModelDownloadModel.swift — l'état du modèle sémantique, vu de l'interface
// (audit D6, palier 3.4). Propriété : A-App.
//
// POURQUOI UN MODÈLE À PART. `ModelDownloader` (FouineEmbed) fait tout le
// travail : télécharger, vérifier l'empreinte, décompresser, installer. Ce qui
// manque à l'app n'est pas du travail, c'est de l'ÉTAT observable — la phase en
// cours, les octets reçus, le jeton d'annulation, l'issue — et un endroit où
// vérifier tout cela sans réseau. Le voici, testé dans `FouineAppTests` sur une
// archive `file://` fabriquée par le test (`FOUINE_MODEL_URL`,
// `FOUINE_MODEL_SHA256`, `expectedBytes: 0`).
//
// TROIS PIÈGES, ET LEUR RÉPONSE :
//
//   · le callback `progress` de `ModelDownloader` arrive d'un FIL QUELCONQUE,
//     à peu près une fois par morceau reçu — soit des milliers de fois sur
//     220 Mo. Le poster tel quel sur le fil principal noierait la boucle
//     d'événements. `ProgressRelay` retient la DERNIÈRE valeur et n'en
//     programme qu'une seule livraison à la fois : le dernier point gagne, et
//     l'interface reçoit ce qu'elle peut afficher, pas un point par paquet TCP ;
//
//   · `install` jette `alreadyInstalled` quand le modèle est déjà là et que
//     `force` est faux. L'utilisateur qui clique « Télécharger » ne veut jamais
//     lire ça : l'état est donc relu AVANT, et `force` posé en conséquence ;
//
//   · l'annulation ne passe PAS par `Task.cancel()`. Le corps de `install` est
//     synchrone et bloquant ; seul `ModelDownloadCancellation.cancel()` coupe
//     la tâche URLSession. Le jeton est retenu ici pendant tout le transfert.
//
// CE MODÈLE NE PARLE JAMAIS FRANÇAIS À L'UTILISATEUR. `ModelDownloadError`
// porte un `description` français (c'est ce qu'imprime `fouine model
// download`) ; l'app le rend depuis ses CAS, par `ErrorText.describe`, comme
// toutes les autres erreurs depuis le palier 3.2.

import Foundation
import FouineEmbed

@MainActor
final class ModelDownloadModel: ObservableObject {

    // MARK: - Types observés

    /// Un transfert en cours. `nil` quand rien ne tourne.
    struct Transfer: Equatable {
        let phase: ModelDownloadPhase
        let received: Int64
        let expected: Int64

        /// 0…1, ou `nil` si la taille totale est inconnue (barre indéterminée).
        var fraction: Double? {
            guard expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        }
    }

    /// Le modèle installé. `nil` = absent.
    struct Installed: Equatable {
        let modelID: String
        let revision: Int
        let bytesOnDisk: Int64
    }

    /// Un échec, rendu DEPUIS SON CAS. `detail` ne porte jamais une phrase :
    /// c'est une donnée brute (une adresse), affichée en petit et sélectionnable
    /// pour être recopiée dans un rapport de bogue.
    struct Failure: Equatable {
        let message: String
        let detail: String?
    }

    // MARK: - État

    @Published private(set) var installed: Installed?
    @Published private(set) var transfer: Transfer?
    @Published private(set) var failure: Failure?
    /// Vrai juste après une installation réussie : l'interface dit alors ce
    /// qu'il reste à faire (produire les vecteurs), et non « modèle présent ».
    @Published private(set) var justInstalled = false
    /// Vrai pendant la suppression : le bouton se grise, on ne clique pas deux
    /// fois sur `rm -rf` de 245 Mo.
    @Published private(set) var isRemoving = false

    /// Répertoire cible. Injecté pour que les tests écrivent dans un temporaire
    /// et JAMAIS dans `~/Library/Application Support/Fouine/models`.
    let directory: URL
    /// Taille attendue. `0` désactive le contrôle et la réservation de place —
    /// c'est ce que passent les tests, dont l'archive fait quelques kilo-octets.
    let expectedBytes: Int64

    private var cancellation: ModelDownloadCancellation?
    private var relay: ProgressRelay?

    init(directory: URL = EmbedPaths.modelDirectory(),
         expectedBytes: Int64 = ModelDownloader.expectedBytes) {
        self.directory = directory
        self.expectedBytes = expectedBytes
    }

    var isRunning: Bool { transfer != nil }

    /// La taille annoncée à l'utilisateur AVANT tout contact — celle de la
    /// constante, même quand le contrôle est désactivé.
    var announcedBytes: Int64 { ModelDownloader.expectedBytes }

    /// L'adresse qui sera contactée. `FOUINE_MODEL_URL` la remplace ; la feuille
    /// de consentement doit annoncer celle-là et pas une autre.
    var sourceURL: String {
        ((try? ModelDownloader.resolvedURL())?.absoluteString)
            ?? ModelDownloader.defaultURLString
    }

    // MARK: - Lecture de l'état

    /// Relit ce qui est installé, hors du fil principal (`status` parcourt le
    /// répertoire pour en faire la taille).
    func refresh() async {
        // « Modèle installé, il reste à vectoriser » est un message de L'INSTANT
        // qui suit l'installation. Il s'efface au premier retour sur l'onglet :
        // le laisser à demeure ferait lire « il reste une étape » à quelqu'un
        // qui a lancé `fouine embed` depuis longtemps.
        justInstalled = false
        apply(await Self.readStatus(directory))
    }

    private static func readStatus(_ directory: URL) async -> ModelStatus {
        await Task.detached(priority: .utility) {
            ModelDownloader.status(directory: directory)
        }.value
    }

    private func apply(_ status: ModelStatus) {
        installed = status.installed
            ? Installed(modelID: status.modelID ?? ModelDownloader.expectedModelID,
                        revision: status.revision ?? 0,
                        bytesOnDisk: status.bytesOnDisk)
            : nil
    }

    // MARK: - Téléchargement

    /// Le travail, attendable — c'est cette forme que les tests appellent, et
    /// celle que la vue lance dans une `Task` NON attachée à elle : fermer la
    /// fenêtre de réglages pendant un transfert de 220 Mo ne doit pas
    /// l'interrompre. Le modèle, lui, vit aussi longtemps que l'application.
    func download(force: Bool = false) async {
        guard transfer == nil, !isRemoving else { return }
        failure = nil
        justInstalled = false

        let token = ModelDownloadCancellation()
        cancellation = token
        let relay = ProgressRelay(model: self)
        self.relay = relay
        transfer = Transfer(phase: .downloading, received: 0,
                            expected: expectedBytes)

        // L'état est relu AVANT : sans cela, réinstaller par-dessus un modèle
        // présent rendrait `alreadyInstalled`, qui n'est pas une phrase à
        // montrer à quelqu'un qui vient de cliquer « Télécharger ».
        let current = await Self.readStatus(directory)
        let reinstall = force || current.installed

        let directory = self.directory
        let bytes = self.expectedBytes
        do {
            let status = try await ModelDownloader.install(
                into: directory, expectedBytes: bytes, force: reinstall,
                cancellation: token,
                progress: { value in relay.post(value) })
            finish()
            // UX-13 : le cache binaire du vocabulaire est produit ICI, hors du
            // fil principal, pendant que l'utilisateur regarde encore l'onglet
            // — et non à sa première recherche par le sens, où il coûtait ~5 s
            // de lecture de `vocab.json` (audit A1m-15). Best-effort : son
            // échec ne change rien à une installation réussie.
            await Self.warmVocabulary(directory)
            apply(status)
            justInstalled = status.installed
        } catch {
            finish()
            failure = Self.failure(for: error)
            await refresh()
        }
    }

    private static func warmVocabulary(_ directory: URL) async {
        await Task.detached(priority: .utility) {
            _ = EmbedPaths.warmVocabularyCache(at: directory)
        }.value
    }

    /// Coupe le transfert en cours. Idempotent ; sans effet si rien ne tourne.
    func cancel() { cancellation?.cancel() }

    private func finish() {
        transfer = nil
        cancellation = nil
        relay = nil
    }

    /// Reçoit un point de progression, DÉJÀ ramené sur le fil principal.
    fileprivate func receive(_ value: ModelDownloadProgress) {
        // Un point en retard qui arriverait après la fin ne doit pas rallumer
        // la barre : on ne met à jour qu'un transfert encore en cours.
        guard transfer != nil else { return }
        transfer = Transfer(phase: value.phase,
                            received: value.bytesReceived,
                            expected: value.bytesExpected)
    }

    // MARK: - Suppression

    func remove() async {
        guard transfer == nil, !isRemoving else { return }
        failure = nil
        justInstalled = false
        isRemoving = true
        let directory = self.directory
        do {
            _ = try await Task.detached(priority: .utility) {
                try ModelDownloader.remove(directory: directory)
            }.value
        } catch {
            failure = Self.failure(for: error)
        }
        isRemoving = false
        await refresh()
    }

    // MARK: - Rendu des échecs

    /// Le message localisé et, s'il y a lieu, la donnée brute qui l'accompagne.
    static func failure(for error: Error) -> Failure {
        guard let download = error as? ModelDownloadError else {
            return Failure(message: ErrorText.describe(error), detail: nil)
        }
        return Failure(message: ErrorText.describe(download),
                       detail: address(of: download))
    }

    /// L'adresse en cause, quand l'erreur en désigne une. Jamais une phrase.
    private static func address(of error: ModelDownloadError) -> String? {
        switch error {
        case .badURL(let raw), .unsupportedScheme(let raw):
            return raw
        case .notFound(let url), .httpStatus(_, let url):
            return url.absoluteString
        default:
            return nil
        }
    }
}

// MARK: - Relais de progression

/// Ramène les points de progression sur le fil principal, en les COALESÇANT.
///
/// `ModelDownloader` appelle son callback une fois par morceau reçu, depuis la
/// file du délégué URLSession : sur 220 Mo, cela fait des milliers d'appels.
/// Programmer un saut sur le fil principal à chaque fois remplirait sa file
/// d'attente de travail périmé — l'interface afficherait alors une progression
/// en retard de plusieurs secondes, et ne répondrait plus au bouton « Annuler ».
///
/// La règle est donc : une seule livraison en vol à la fois, et c'est TOUJOURS
/// la dernière valeur connue qui part. Les points sautés n'ont aucune valeur
/// (personne ne compte les octets un par un) ; le dernier, si.
private final class ProgressRelay: @unchecked Sendable {
    private let mutex = NSLock()
    private var latest: ModelDownloadProgress?
    private var scheduled = false
    private weak var model: ModelDownloadModel?

    init(model: ModelDownloadModel) { self.model = model }

    func post(_ value: ModelDownloadProgress) {
        mutex.lock()
        latest = value
        let inFlight = scheduled
        scheduled = true
        mutex.unlock()
        guard !inFlight else { return }
        Task { @MainActor [weak self] in
            guard let self, let pending = self.take() else { return }
            self.model?.receive(pending)
        }
    }

    /// Prend la dernière valeur et rouvre la porte à une nouvelle livraison.
    ///
    /// Fonction SYNCHRONE à part, et pas trois lignes dans la `Task` : `NSLock`
    /// est indisponible depuis un contexte asynchrone (erreur en mode Swift 6),
    /// parce qu'une suspension entre `lock()` et `unlock()` bloquerait un fil
    /// du pool. Ici il n'y en a aucune — mais le compilateur ne peut le savoir
    /// que si la section critique tient dans un appel qui ne peut pas suspendre.
    private func take() -> ModelDownloadProgress? {
        mutex.lock(); defer { mutex.unlock() }
        scheduled = false
        return latest
    }
}
