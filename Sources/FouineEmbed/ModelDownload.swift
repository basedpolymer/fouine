// ModelDownload.swift — installation À LA DEMANDE du modèle sémantique (audit D6).
// Propriété : A-Embed (palier 3, 02/09/2026).
//
// POURQUOI CE FICHIER EXISTE. Jusqu'ici la recherche sémantique était réservée
// aux développeurs : `EmbedModel` exige `meta.json`, `vocab.json` et
// `E5Small.mlmodelc`, que seul `Tools/convert_e5.py` savait produire — venv
// Python, torch, coremltools, une heure de conversion. Le modèle est sous
// licence MIT, donc redistribuable : il est désormais publié en asset de
// release et `fouine model download` l'installe.
//
// C'EST LE SECOND (ET DERNIER) ACCÈS RÉSEAU DU PRODUIT, après la vérification
// de mise à jour Sparkle. Les deux règles qui le rendent acceptable :
//   · il ne part JAMAIS tout seul. Aucun appel automatique, aucun « au premier
//     lancement » : il faut taper `fouine model download` ou cliquer un bouton.
//     La commande explicite EST le consentement ;
//   · ce qui arrive est vérifié avant d'être installé. SHA-256 en flux, taille
//     attendue, disposition de l'archive, `model_id`/`revision` de `meta.json`.
//     Un octet de travers et rien n'est installé.
//
// DEUX HÔTES SONT CONTACTÉS, pas un. GitHub sert les assets de release par une
// redirection 302 vers `release-assets.githubusercontent.com` : un pare-feu sortant
// verra donc deux demandes. C'est documenté dans docs/privacy.md ; suivre la
// redirection est obligatoire, sans quoi le téléchargement rend un corps vide.
//
// CE QUI PART SUR LE RÉSEAU : une requête GET, et un en-tête
// `User-Agent: Fouine/<version>`. Pas de cookie (session ÉPHÉMÈRE, magasin de
// cookies neuf et jeté), pas de cache, aucun identifiant, rien du corpus.

import Foundation
import CryptoKit
import FouineCore

// MARK: - Erreurs

/// Erreurs du téléchargement et de l'installation du modèle.
///
/// Enum DÉDIÉ, séparé de `FouineEmbedError` : les fautes d'ici ne sont ni des
/// fautes de tokenizer ni des fautes d'inférence, et l'appelant (CLI ou app)
/// doit pouvoir les distinguer pour proposer le bon geste. `LocalizedError`
/// pour que `IndexText.describe` — donc `fouine: …` — rende la phrase française
/// sans passer par un `switch` de plus.
public enum ModelDownloadError: Error, CustomStringConvertible, LocalizedError {
    case badURL(String)
    case unsupportedScheme(String)
    case notFound(URL)
    case httpStatus(Int, URL)
    case transport(String)
    case cancelled
    case notEnoughSpace(needed: Int64, available: Int64, path: String)
    case sizeMismatch(expected: Int64, got: Int64)
    case hashMismatch(expected: String, got: String)
    case extraction(String)
    case badLayout(String)
    case badIdentity(gotID: String, gotRevision: Int, wantID: String, wantRevision: Int)
    case install(String)
    case alreadyInstalled(revision: Int)

    public var description: String {
        switch self {
        case .badURL(let s):
            return "unreadable model address: “\(s)”"
        case .unsupportedScheme(let s):
            return "model address not supported: “\(s)” "
                + "(https:// or file:// only)"
        case .notFound(let url):
            return "the asset is not published yet (404): \(url.absoluteString)"
        case .httpStatus(let code, let url):
            return "the server answered \(code): \(url.absoluteString)"
        case .transport(let m):
            return "download interrupted: \(m)"
        case .cancelled:
            return "download cancelled"
        case .notEnoughSpace(let needed, let available, let path):
            return "not enough space on \(path): "
                + "\(Self.megabytes(needed)) needed, "
                + "\(Self.megabytes(available)) free"
        case .sizeMismatch(let expected, let got):
            return "unexpected size: \(got) bytes received, \(expected) expected"
        case .hashMismatch(let expected, let got):
            return "wrong SHA-256 fingerprint — archive REFUSED and deleted. "
                + "Expected \(expected), got \(got)"
        case .extraction(let m):
            return "unpacking failed: \(m)"
        case .badLayout(let m):
            return "malformed archive: \(m)"
        case .badIdentity(let gotID, let gotRevision, let wantID, let wantRevision):
            return "unexpected model: the archive carries \(gotID) r\(gotRevision), "
                + "this version of Fouine expects \(wantID) r\(wantRevision)"
        case .install(let m):
            return "installation failed: \(m)"
        case .alreadyInstalled(let revision):
            return "the model is already installed (revision \(revision)) — "
                + "`fouine model download --force` reinstalls it"
        }
    }

    public var errorDescription: String? { description }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

// MARK: - Progression

/// Étape en cours. L'app en fait un libellé, la CLI une ligne de journal.
public enum ModelDownloadPhase: String, Sendable {
    case downloading    // octets qui arrivent
    case verifying      // SHA-256 (calculé en flux : instantané à la fin)
    case extracting     // ditto
    case installing     // bascule atomique du répertoire

    /// Libellé ANGLAIS, celui de la CLI (palier 3.5). L'app, elle, part du
    /// CAS et rend le sien depuis le catalogue (`ModelPhaseText`).
    public var label: String {
        switch self {
        case .downloading: return "downloading"
        case .verifying:   return "checking the fingerprint"
        case .extracting:  return "unpacking"
        case .installing:  return "installing"
        }
    }
}

/// Un point de progression. `bytesExpected` vaut 0 quand la taille est inconnue
/// (elle ne l'est pas pour cet asset : elle est en constante).
public struct ModelDownloadProgress: Sendable {
    public let phase: ModelDownloadPhase
    public let bytesReceived: Int64
    public let bytesExpected: Int64

    public init(phase: ModelDownloadPhase, bytesReceived: Int64, bytesExpected: Int64) {
        self.phase = phase
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }

    /// 0…1, ou `nil` si la taille totale est inconnue.
    public var fraction: Double? {
        guard bytesExpected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }
}

/// Jeton d'annulation, partageable entre le fil qui télécharge et celui qui
/// clique. `cancel()` est idempotent et interrompt le transfert en cours (la
/// tâche URLSession est retenue ici le temps du téléchargement) ; le fichier
/// temporaire est supprimé par le chemin d'erreur, jamais laissé derrière.
public final class ModelDownloadCancellation: @unchecked Sendable {
    private let mutex = NSLock()
    private var requested = false
    private var task: URLSessionTask?

    public init() {}

    public func cancel() {
        mutex.lock()
        requested = true
        let running = task
        mutex.unlock()
        running?.cancel()
    }

    public var isCancelled: Bool {
        mutex.lock(); defer { mutex.unlock() }; return requested
    }

    /// Retient la tâche en cours pour qu'un `cancel()` tardif la coupe.
    /// Rend `false` si l'annulation a DÉJÀ été demandée — l'appelant s'arrête
    /// alors sans même démarrer.
    func adopt(_ running: URLSessionTask?) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        task = running
        return !requested
    }
}

// MARK: - État du modèle installé

public struct ModelStatus: Sendable {
    public let directory: URL
    /// Vrai si les TROIS pièces sont là (même critère qu'`EmbedPaths`).
    public let installed: Bool
    /// Taille cumulée du répertoire, 0 s'il n'existe pas.
    public let bytesOnDisk: Int64
    public let modelID: String?
    public let revision: Int?
    /// Hôtes RÉELLEMENT contactés, dans l'ordre : celui de l'adresse demandée,
    /// puis chaque cible de redirection (audit A1-05). Vide pour une source
    /// `file://`, et pour un `status()` qui n'a rien téléchargé.
    ///
    /// La CLI annonçait « github.com, puis release-assets.githubusercontent.com »
    /// quelle que soit l'adresse : une annonce fausse détruit la valeur des
    /// annonces justes. Ce champ permet de dire ce qui s'est passé, et non ce
    /// qu'on avait prévu.
    public internal(set) var contactedHosts: [String] = []
}

// MARK: - Le téléchargeur

public enum ModelDownloader {

    // MARK: Constantes de la release

    /// Asset de release du dépôt. Le tag `e5-small-v1` est FIGÉ : une révision
    /// suivante prend un nouveau tag et de nouvelles constantes (procédure dans
    /// RELEASING.md), de sorte qu'une version donnée de Fouine installe toujours
    /// exactement le modèle qu'elle sait lire.
    public static let defaultURLString =
        "https://github.com/basedpolymer/fouine/releases/download/"
        + "e5-small-v1/e5-small-v1.zip"

    /// SHA-256 de `e5-small-v1.zip`, mesuré sur l'archive de référence
    /// (`shasum -a 256 dist/e5-small-v1.zip`, 02/09/2026).
    public static let expectedSHA256 =
        "fa8ead627aa5cab20575e049d082bc4492cfc839414a3dba808fed549afa1484"

    /// Taille de la même archive. Contrôlée AVANT (place disque, `Content-Length`)
    /// et APRÈS (octets réellement écrits) : un transfert tronqué se voit sans
    /// attendre le hachage, et la place se réserve sur un chiffre connu.
    public static let expectedBytes: Int64 = 220_236_056

    /// Identité que cette version de Fouine sait lire (`meta.json`).
    public static let expectedModelID = "multilingual-e5-small"
    public static let expectedRevision = 1

    /// Dossier de tête de l'archive. Son contenu devient le répertoire cible.
    static let archiveRootName = "e5-small"

    /// Variables d'environnement de dépannage et de test.
    public static let urlVariable = "FOUINE_MODEL_URL"
    /// Remplace l'empreinte attendue. À n'utiliser QUE sur une archive dont on
    /// répond soi-même : la poser, c'est faire confiance à l'archive à la place
    /// de Fouine.
    public static let sha256Variable = "FOUINE_MODEL_SHA256"

    // MARK: Délais

    /// Silence toléré sur la connexion. Une minute : au-delà, le serveur ne
    /// répond plus, il ne « réfléchit » pas.
    static let requestTimeout: TimeInterval = 60
    /// Plafond du transfert entier. 220 Mo sur une ligne à 500 kio/s font sept
    /// minutes ; une heure laisse passer une connexion très lente sans jamais
    /// laisser un processus pendu pour la nuit.
    static let resourceTimeout: TimeInterval = 3_600
    /// `ditto` sur 220 Mo : mesuré à quelques secondes. Dix minutes couvrent un
    /// disque lent avec un facteur large.
    static let extractTimeout: TimeInterval = 600

    // MARK: - État

    /// Ce qui est installé, sans rien télécharger ni verrouiller.
    public static func status(directory: URL = EmbedPaths.modelDirectory())
        -> ModelStatus {
        let installed = EmbedPaths.modelAvailable(at: directory)
        let meta = installed ? try? EmbedPaths.loadMeta(at: directory) : nil
        return ModelStatus(directory: directory,
                           installed: installed,
                           bytesOnDisk: directorySize(directory),
                           modelID: meta?.model_id,
                           revision: meta?.revision)
    }

    /// Supprime le modèle installé. Sans effet — et sans erreur — s'il n'y est
    /// pas : `fouine model remove` deux fois de suite ne doit pas échouer.
    @discardableResult
    public static func remove(directory: URL = EmbedPaths.modelDirectory()) throws
        -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }
        do { try fm.removeItem(at: directory) } catch {
            throw ModelDownloadError.install(
                "\(directory.path) : \((error as NSError).localizedDescription)")
        }
        return true
    }

    // MARK: - Adresse

    /// URL effective : `FOUINE_MODEL_URL` s'il est posé, sinon la constante.
    /// `https` et `file` seulement — un `http` en clair sur 220 Mo d'un modèle
    /// qui va tourner sur la machine n'a pas à exister.
    public static func resolvedURL(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> URL {
        let raw = [override, environment[urlVariable]]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? defaultURLString
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased()
        else { throw ModelDownloadError.badURL(raw) }
        guard scheme == "https" || scheme == "file" else {
            throw ModelDownloadError.unsupportedScheme(raw)
        }
        return url
    }

    /// Empreinte attendue : `FOUINE_MODEL_SHA256` s'il est posé, sinon la
    /// constante. Rendue en minuscules pour que la comparaison soit littérale.
    public static func resolvedSHA256(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        ([override, environment[sha256Variable]]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? expectedSHA256)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Installation (synchrone)

    /// Télécharge, vérifie, décompresse et installe. **Bloquant** : c'est la
    /// forme dont la CLI a besoin. L'app utilise la variante `async` ci-dessous,
    /// qui n'est qu'une enveloppe autour de celle-ci.
    ///
    /// - Parameters:
    ///   - directory: répertoire cible, `EmbedPaths.modelDirectory()` par défaut.
    ///   - url: adresse ; `nil` = `FOUINE_MODEL_URL` ou la constante.
    ///   - sha256: empreinte attendue ; `nil` = `FOUINE_MODEL_SHA256` ou la constante.
    ///   - expectedBytes: taille attendue ; 0 pour ne pas la contrôler (tests).
    ///   - force: réinstalle même si le modèle est déjà là.
    ///   - cancellation: jeton d'annulation, partageable avec l'interface.
    ///   - progress: appelé depuis un fil quelconque, souvent (~1 fois par
    ///     morceau reçu). L'appelant fait le lissage et le saut sur le fil
    ///     principal ; on ne suppose rien ici.
    /// - Returns: l'état du modèle une fois installé.
    @discardableResult
    public static func install(
        into directory: URL = EmbedPaths.modelDirectory(),
        from url: URL? = nil,
        sha256: String? = nil,
        expectedBytes: Int64 = ModelDownloader.expectedBytes,
        force: Bool = false,
        cancellation: ModelDownloadCancellation = ModelDownloadCancellation(),
        progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) throws -> ModelStatus {
        let fm = FileManager.default
        let current = status(directory: directory)
        if current.installed, !force {
            throw ModelDownloadError.alreadyInstalled(revision: current.revision ?? 0)
        }
        let source = try url ?? resolvedURL()
        let wantedHash = resolvedSHA256(override: sha256)

        // La taille attendue ne vaut QUE pour l'archive de référence. Qui pose
        // `FOUINE_MODEL_SHA256` fournit SA propre archive : elle n'a aucune
        // raison de peser exactement autant, et lui opposer la taille de la
        // nôtre rendait l'override inutilisable — l'essai de recette du 02/09
        // l'a montré, « taille inattendue : 220 239 082 reçus, 220 236 056
        // attendus » sur une archive pourtant refabriquée par
        // `Tools/package_model.sh` (un zip porte les horodatages de ses
        // fichiers, sa taille bouge d'une fabrication à l'autre).
        //
        // Le paramètre `expectedBytes`, lui, reste souverain : c'est l'appelant
        // qui le pose, et les tests s'en servent. Seule la VARIABLE relâche le
        // contrôle. La constante sert de toute façon à estimer la place disque —
        // une estimation large sur un chiffre du bon ordre vaut mieux que rien.
        let hashOverridden = !(ProcessInfo.processInfo
            .environment[sha256Variable] ?? "").isEmpty
        let checkedBytes = hashOverridden ? 0 : expectedBytes

        // Le parent du répertoire cible : c'est LUI qui porte le temporaire, pour
        // que le renommage final soit un mouvement intra-volume (donc atomique)
        // et non une copie de 235 Mo à travers deux disques.
        let parent = directory.deletingLastPathComponent()
        try createDirectory(parent)
        // DROITS (A1-06, D2-09) : `models/` était en 0755. On ne le referme que
        // s'il s'agit de l'emplacement PAR DÉFAUT — qui pose `FOUINE_MODEL_DIR`
        // peut désigner un dossier partagé, et ses droits sont sa décision.
        // Best-effort : un échec n'interrompt jamais l'installation.
        if isDefaultModelParent(parent) {
            FilePermissions.restrictDirectory(parent)
        }

        // Place disque : l'archive (220 Mo) + son contenu décompressé (245 Mo) +
        // l'ancien modèle qui reste en place jusqu'au dernier instant. Trois fois
        // la taille de l'archive est la borne simple qui couvre les trois.
        if expectedBytes > 0 {
            let needed = expectedBytes * 3
            if let free = availableCapacity(parent), free < needed {
                throw ModelDownloadError.notEnoughSpace(
                    needed: needed, available: free, path: parent.path)
            }
        }

        let work = parent.appendingPathComponent(
            ".fouine-model-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(work)
        // UN SEUL point de nettoyage : quelle que soit la sortie — succès, refus
        // d'empreinte, annulation, erreur de ditto — le temporaire disparaît.
        defer { try? fm.removeItem(at: work) }

        let archive = work.appendingPathComponent("model.zip")
        let received = try fetch(from: source, to: archive,
                                expectedBytes: checkedBytes,
                                cancellation: cancellation,
                                progress: progress)
        if checkedBytes > 0, received.bytes != checkedBytes {
            throw ModelDownloadError.sizeMismatch(expected: checkedBytes,
                                                  got: received.bytes)
        }
        progress?(ModelDownloadProgress(phase: .verifying,
                                        bytesReceived: received.bytes,
                                        bytesExpected: received.bytes))
        guard received.sha256 == wantedHash else {
            // Le fichier part tout de suite, sans attendre le `defer` : une
            // archive dont l'empreinte est fausse n'a pas à survivre une ligne
            // de plus, fût-ce dans un temporaire.
            try? fm.removeItem(at: archive)
            throw ModelDownloadError.hashMismatch(expected: wantedHash,
                                                  got: received.sha256)
        }
        try throwIfCancelled(cancellation)

        progress?(ModelDownloadProgress(phase: .extracting,
                                        bytesReceived: 0,
                                        bytesExpected: 0))
        let unpacked = work.appendingPathComponent("x", isDirectory: true)
        try createDirectory(unpacked)
        try ditto(archive: archive, into: unpacked)
        try? fm.removeItem(at: archive)          // 220 Mo qui ne servent plus
        try throwIfCancelled(cancellation)

        let root = unpacked.appendingPathComponent(archiveRootName, isDirectory: true)
        try validate(root: root, within: unpacked)

        progress?(ModelDownloadProgress(phase: .installing,
                                        bytesReceived: 0,
                                        bytesExpected: 0))
        try swapIn(root, to: directory)
        var installed = status(directory: directory)
        installed.contactedHosts = received.hosts
        return installed
    }

    /// Variante asynchrone, pour l'interface : même travail, sur une file de
    /// service, avec progression et annulation.
    ///
    /// L'annulation passe par le jeton — PAS par `Task.cancel()` : le corps est
    /// synchrone et bloquant, une coopération de `Task` n'y changerait rien. Le
    /// jeton, lui, coupe la tâche URLSession pour de bon.
    @discardableResult
    public static func install(
        into directory: URL = EmbedPaths.modelDirectory(),
        from url: URL? = nil,
        sha256: String? = nil,
        expectedBytes: Int64 = ModelDownloader.expectedBytes,
        force: Bool = false,
        cancellation: ModelDownloadCancellation = ModelDownloadCancellation(),
        progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async throws -> ModelStatus {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try install(into: directory, from: url,
                                             sha256: sha256,
                                             expectedBytes: expectedBytes,
                                             force: force,
                                             cancellation: cancellation,
                                             progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Transfert

    struct Fetched {
        let bytes: Int64
        let sha256: String
        /// Hôtes traversés, dans l'ordre (vide pour un `file://`).
        var hosts: [String] = []
    }

    /// Écrit `url` dans `destination`, en calculant l'empreinte AU PASSAGE.
    ///
    /// Le hachage en flux n'est pas une coquetterie : relire 220 Mo pour les
    /// hacher après coup, c'est une seconde traversée du disque et une fenêtre
    /// pendant laquelle le fichier vérifié n'est plus celui qui a été écrit.
    static func fetch(from url: URL, to destination: URL,
                      expectedBytes: Int64,
                      cancellation: ModelDownloadCancellation,
                      progress: (@Sendable (ModelDownloadProgress) -> Void)?)
        throws -> Fetched {
        try throwIfCancelled(cancellation)
        if url.isFileURL {
            return try copyLocal(from: url, to: destination,
                                 cancellation: cancellation, progress: progress)
        }
        // Les deux réglages de recette de `download` (`floorBytes`,
        // `protocolClasses`) ne se propagent pas jusqu'ici : les tests de
        // transfert appellent `download` directement.
        return try download(from: url, to: destination,
                            expectedBytes: expectedBytes,
                            cancellation: cancellation, progress: progress)
    }

    /// `file://` — la voie des tests, et celle d'un utilisateur qui a déjà
    /// l'archive sur une clé USB. `URLSession` sait charger un `file://` mais
    /// n'en donne ni progression fiable ni code de statut : une copie en flux
    /// est plus simple ET plus honnête, et elle passe par exactement le même
    /// hachage que le réseau.
    static func copyLocal(from url: URL, to destination: URL,
                          cancellation: ModelDownloadCancellation,
                          progress: (@Sendable (ModelDownloadProgress) -> Void)?)
        throws -> Fetched {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path) else {
            throw ModelDownloadError.notFound(url)
        }
        let total = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
        guard let input = FileHandle(forReadingAtPath: url.path) else {
            throw ModelDownloadError.transport("cannot read: \(url.path)")
        }
        defer { try? input.close() }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ModelDownloadError.install("cannot write: \(destination.path)")
        }
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw ModelDownloadError.install("cannot write: \(destination.path)")
        }
        defer { try? output.close() }

        var hasher = SHA256()
        var written: Int64 = 0
        while true {
            try throwIfCancelled(cancellation)
            let chunk = input.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            output.write(chunk)
            written += Int64(chunk.count)
            progress?(ModelDownloadProgress(phase: .downloading,
                                            bytesReceived: written,
                                            bytesExpected: total))
        }
        return Fetched(bytes: written, sha256: hex(hasher.finalize()))
    }

    /// `https://` — session ÉPHÉMÈRE (ni cookie ni cache écrits sur le disque),
    /// redirections suivies, tout ce qui n'est pas 200 refusé avant le premier
    /// octet écrit.
    ///
    /// `floorBytes` et `protocolClasses` n'existent QUE pour la recette :
    /// le premier abaisse le plancher du plafond en vol (sans quoi il faudrait
    /// pousser 880 Mo à travers un `URLProtocol` fictif pour le franchir), le
    /// second branche ce `URLProtocol`. Aucun appelant de production ne les
    /// pose : les valeurs par défaut sont le comportement réel.
    static func download(from url: URL, to destination: URL,
                         expectedBytes: Int64,
                         cancellation: ModelDownloadCancellation,
                         progress: (@Sendable (ModelDownloadProgress) -> Void)?,
                         floorBytes: Int64 = ModelDownloader.expectedBytes,
                         protocolClasses: [AnyClass]? = nil)
        throws -> Fetched {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // FAUX à dessein : `true` ferait attendre indéfiniment une machine hors
        // ligne, sans un mot. On préfère échouer tout de suite et le dire.
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Fouine/\(FouineVersion.string)",
        ]

        if let protocolClasses { configuration.protocolClasses = protocolClasses }

        let sink = try DownloadSink(destination: destination,
                                    expectedBytes: expectedBytes,
                                    floorBytes: floorBytes,
                                    progress: progress)
        let delegate = DownloadDelegate(sink: sink)
        let session = URLSession(configuration: configuration,
                                 delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let task = session.dataTask(with: request)
        guard cancellation.adopt(task) else {
            sink.discard()
            throw ModelDownloadError.cancelled
        }
        // Plafond en vol (A1-04) : le franchir coupe la tâche et nomme la
        // panne. Le fichier temporaire est effacé par `sink.discard()` sur le
        // chemin d'erreur, comme pour toute autre panne de transfert.
        let cap = sink.cap
        sink.setOverflowHandler { [weak task] received in
            delegate.reportOversize(received: received, cap: cap)
            task?.cancel()
        }
        task.resume()
        delegate.wait()
        _ = cancellation.adopt(nil)

        if let failure = delegate.failure {
            sink.discard()
            if cancellation.isCancelled { throw ModelDownloadError.cancelled }
            throw failure
        }
        try sink.close()
        // Le premier hôte est celui de l'adresse DEMANDÉE ; les suivants sont
        // les cibles de redirection, toutes en `https:` (les autres schémas
        // sont refusés au-dessus).
        return Fetched(bytes: sink.bytes, sha256: sink.digest,
                       hosts: [url.host].compactMap { $0 } + delegate.hosts)
    }

    // MARK: - Décompression

    /// `/usr/bin/ditto -x -k <zip> <dossier>`.
    ///
    /// CHEMIN EXPLICITE, jamais une recherche dans `PATH` (audit D8) :
    /// sous launchd et sous le Finder, `PATH` est minimal ou absent, et un
    /// `PATH` inscriptible est un vecteur d'exécution. ENVIRONNEMENT FIGÉ pour
    /// la même raison (audit S1), avec la locale `C.UTF-8` qui rend les noms
    /// d'entrées accentués lisibles — la démonstration est dans
    /// `FouineExtract/Support/Subprocess.swift`.
    ///
    /// FouineEmbed ne dépend PAS de FouineExtract (et ne doit pas : le moteur
    /// sémantique n'a rien à faire de l'extraction de documents), d'où ce
    /// lancement borné minimal plutôt qu'un appel à `Subprocess`.
    static func ditto(archive: URL, into destination: URL) throws {
        let executable = "/usr/bin/ditto"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ModelDownloadError.extraction("\(executable) cannot be found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // ditto n'accepte pas `--` ; les deux derniers arguments sont des chemins
        // que NOUS fabriquons (un temporaire à UUID), jamais une saisie.
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        ]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // stderr est vidé sur une file à part : ditto bavard sur une archive
        // abîmée remplirait le tuyau et se bloquerait sur son écriture.
        let box = ErrorBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            box.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            try? errPipe.fileHandleForWriting.close()
            throw ModelDownloadError.extraction(
                "ditto could not start: \((error as NSError).localizedDescription)")
        }
        var timedOut = false
        if finished.wait(timeout: .now() + extractTimeout) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 5)
            }
        }
        _ = group.wait(timeout: .now() + 5)
        if timedOut {
            throw ModelDownloadError.extraction(
                "ditto did not return within \(Int(extractTimeout)) s — terminated")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: box.data.prefix(64 << 10), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelDownloadError.extraction(
                "ditto failed (code \(process.terminationStatus)): "
                + (message.isEmpty ? "no message" : message))
        }
    }

    final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func set(_ d: Data) { lock.lock(); buffer = d; lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    // MARK: - Validation de l'arbre extrait

    /// Vérifie la disposition, l'absence de lien symbolique, l'absence de chemin
    /// sortant, et l'identité du modèle.
    ///
    /// L'empreinte a DÉJÀ été vérifiée quand on arrive ici : ce qu'on décompresse
    /// est, à l'octet près, l'archive dont on connaît le SHA-256. Ces contrôles
    /// sont donc une seconde ceinture — utile parce que `FOUINE_MODEL_SHA256`
    /// permet à quelqu'un de fournir SA propre archive, et parce qu'un lien
    /// symbolique installé dans le répertoire du modèle ferait lire à CoreML un
    /// fichier arbitraire de la machine.
    static func validate(root: URL, within container: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelDownloadError.badLayout(
                "the top-level folder “\(archiveRootName)/” is missing")
        }
        for piece in ["meta.json", "vocab.json"] {
            guard fm.fileExists(atPath: root.appendingPathComponent(piece).path) else {
                throw ModelDownloadError.badLayout("\(archiveRootName)/\(piece) is missing")
            }
        }
        var modelIsDirectory: ObjCBool = false
        let compiled = root.appendingPathComponent("E5Small.mlmodelc")
        guard fm.fileExists(atPath: compiled.path, isDirectory: &modelIsDirectory),
              modelIsDirectory.boolValue else {
            throw ModelDownloadError.badLayout(
                "\(archiveRootName)/E5Small.mlmodelc/ is missing")
        }

        // Aucun lien symbolique, aucun chemin qui sorte du conteneur.
        let base = container.standardizedFileURL.path
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []) else {
            throw ModelDownloadError.badLayout("unreadable tree: \(root.path)")
        }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw ModelDownloadError.badLayout(
                    "symbolic link refused: \(item.lastPathComponent)")
            }
            guard item.standardizedFileURL.path.hasPrefix(base + "/") else {
                throw ModelDownloadError.badLayout(
                    "escaping path refused: \(item.path)")
            }
        }

        // `parity.json` est TOLÉRÉ (l'archive de référence le porte : c'est le
        // jeu de parité du tokenizer). Tout fichier supplémentaire l'est aussi :
        // le contrat est « au moins ces trois pièces », pas « exactement ».
        let meta: EmbedModelMeta
        do { meta = try EmbedPaths.loadMeta(at: root) } catch {
            throw ModelDownloadError.badLayout(
                "unreadable meta.json: \((error as NSError).localizedDescription)")
        }
        guard meta.model_id == expectedModelID, meta.revision == expectedRevision else {
            throw ModelDownloadError.badIdentity(
                gotID: meta.model_id, gotRevision: meta.revision,
                wantID: expectedModelID, wantRevision: expectedRevision)
        }
    }

    // MARK: - Bascule atomique

    /// Met `staged` à la place de `directory`. L'ANCIEN MODÈLE N'EST RETIRÉ QUE
    /// QUAND LE NOUVEAU EST COMPLET : `replaceItemAt` échange les deux répertoires
    /// puis efface l'ancien, de sorte qu'un plantage au milieu laisse toujours
    /// UN modèle entier en place — jamais un répertoire à moitié rempli, qui
    /// passerait `modelAvailable` et ferait échouer CoreML au chargement.
    static func swapIn(_ staged: URL, to directory: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: directory.path) {
                _ = try fm.replaceItemAt(directory, withItemAt: staged,
                                         backupItemName: nil,
                                         options: [.usingNewMetadataOnly])
            } else {
                try fm.moveItem(at: staged, to: directory)
            }
        } catch {
            throw ModelDownloadError.install(
                "\(directory.path) : \((error as NSError).localizedDescription)")
        }
    }

    // MARK: - Utilitaires

    static func throwIfCancelled(_ token: ModelDownloadCancellation) throws {
        if token.isCancelled { throw ModelDownloadError.cancelled }
    }

    /// `models/` est-il celui que Fouine s'est choisi ? Vrai seulement pour
    /// `~/Library/Application Support/Fouine/models`, jamais pour un chemin
    /// désigné par `FOUINE_MODEL_DIR`.
    static func isDefaultModelParent(_ url: URL) -> Bool {
        let expected = FilePermissions.defaultSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
        return url.standardizedFileURL.path == expected.standardizedFileURL.path
    }

    static func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true)
        } catch {
            throw ModelDownloadError.install(
                "\(url.path) : \((error as NSError).localizedDescription)")
        }
    }

    /// Place réellement utilisable par une écriture « importante » (macOS peut
    /// vider des caches purgeables pour la libérer). `nil` si le volume ne
    /// répond pas — on ne bloque alors pas l'installation sur une inconnue.
    static func availableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url,
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: []) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Réception en flux

/// Écrit ce qui arrive et hache au passage. Verrouillé : le délégué URLSession
/// tourne sur sa propre file d'opérations.
final class DownloadSink: @unchecked Sendable {
    private let mutex = NSLock()
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: (@Sendable (ModelDownloadProgress) -> Void)?
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var announced: Int64 = 0
    private var overflow: (@Sendable (Int64) -> Void)?
    private var overflowed = false

    /// PLAFOND EN VOL (audit A1-04).
    ///
    /// Il n'y en avait aucun : un serveur qui répond sans `Content-Length` (ou
    /// qui ment) faisait écrire tout ce qu'il envoyait, et 419 Mo étaient sur le
    /// disque avant le moindre refus. Sur un disque de démarrage plein, c'est
    /// une panne dont un utilisateur ne se relève pas seul.
    ///
    /// `2 × attendu`, avec la CONSTANTE pour plancher : poser
    /// `FOUINE_MODEL_SHA256` relâche le contrôle de taille exacte — une archive
    /// refabriquée ne pèse pas au kilo-octet près — mais ne doit pas désarmer
    /// le plafond. Sans ce plancher, `checkedBytes = 0` valait « écris tout ce
    /// qu'on t'envoie » précisément quand l'archive vient d'ailleurs.
    let cap: Int64

    init(destination: URL, expectedBytes: Int64,
         floorBytes: Int64 = ModelDownloader.expectedBytes,
         progress: (@Sendable (ModelDownloadProgress) -> Void)?) throws {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
        self.cap = 2 * max(expectedBytes, floorBytes)
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil),
              let opened = FileHandle(forWritingAtPath: destination.path) else {
            throw ModelDownloadError.install("cannot write: \(destination.path)")
        }
        handle = opened
    }

    var bytes: Int64 { mutex.lock(); defer { mutex.unlock() }; return written }
    var total: Int64 { mutex.lock(); defer { mutex.unlock() }; return announced }

    func setTotal(_ value: Int64) { mutex.lock(); announced = value; mutex.unlock() }

    /// Ce qu'il faut faire quand le plafond est franchi : couper la tâche et
    /// nommer la panne. Posé par `download`, une fois la tâche créée.
    func setOverflowHandler(_ handler: @escaping @Sendable (Int64) -> Void) {
        mutex.lock(); overflow = handler; mutex.unlock()
    }

    func append(_ data: Data) {
        mutex.lock()
        if overflowed { mutex.unlock(); return }      // plus rien n'est écrit
        // Le morceau est TRONQUÉ au plafond, jamais écrit puis regretté : le
        // fichier temporaire ne dépasse donc pas le plafond, même d'un morceau.
        // C'est ce qui compte sur un disque de démarrage plein.
        let room = cap - written
        let kept = Int64(data.count) <= room ? data : data.prefix(Int(max(0, room)))
        if !kept.isEmpty {
            hasher.update(data: kept)
            handle?.write(kept)
            written += Int64(kept.count)
        }
        // Ce que le serveur a POUSSÉ, tronqué compris : c'est le chiffre que le
        // message d'erreur doit citer.
        let pushed = written + Int64(data.count - kept.count)
        let now = written
        let expected = announced > 0 ? announced : expectedBytes
        let sink = progress
        var breached: (@Sendable (Int64) -> Void)?
        if pushed > cap {
            overflowed = true
            breached = overflow
        }
        mutex.unlock()
        if let breached { breached(pushed); return }
        sink?(ModelDownloadProgress(phase: .downloading,
                                    bytesReceived: now, bytesExpected: expected))
    }

    func close() throws {
        mutex.lock(); defer { mutex.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// Ferme et EFFACE : appelé sur tout chemin d'erreur, pour ne jamais laisser
    /// une archive partielle traîner dans le temporaire.
    func discard() {
        mutex.lock()
        try? handle?.close()
        handle = nil
        mutex.unlock()
        try? FileManager.default.removeItem(at: destination)
    }

    var digest: String {
        mutex.lock(); defer { mutex.unlock() }
        return ModelDownloader.hex(hasher.finalize())
    }
}

/// Délégué de la session de téléchargement.
///
/// `dataTask` plutôt que `downloadTask` : le second écrit dans un temporaire
/// choisi par le système — souvent sur un AUTRE volume que la cible — et ne
/// donne accès aux octets qu'à la fin, ce qui interdit le hachage en flux et
/// impose une copie de 220 Mo de plus.
final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sink: DownloadSink
    private let done = DispatchSemaphore(value: 0)
    private let mutex = NSLock()
    private var stored: ModelDownloadError?
    /// Les hôtes réellement contactés, redirections comprises. Le premier est
    /// celui de l'URL demandée ; sur GitHub le second est
    /// `release-assets.githubusercontent.com`. Lisible pour un futur journal.
    private(set) var hosts: [String] = []

    init(sink: DownloadSink) { self.sink = sink }

    var failure: ModelDownloadError? {
        mutex.lock(); defer { mutex.unlock() }; return stored
    }

    func wait() { done.wait() }

    private func fail(_ error: ModelDownloadError) {
        mutex.lock()
        if stored == nil { stored = error }
        mutex.unlock()
    }

    /// Plafond en vol franchi (A1-04). La panne est nommée AVANT l'annulation
    /// de la tâche, sinon `didCompleteWithError` la classerait en « annulé par
    /// l'utilisateur » et l'appelant remonterait `ModelDownloadError.cancelled`.
    func reportOversize(received: Int64, cap: Int64) {
        fail(.sizeMismatch(expected: cap, got: received))
    }

    // Redirection SUIVIE (c'est le chemin NORMAL de GitHub : 302 vers
    // release-assets.githubusercontent.com), mais SEULEMENT en `https:`.
    //
    // AUDIT A1-03 / D2-08. Le délégué se contentait de rendre `request` : une
    // redirection `https:` → `http:` était suivie (reproduit via httpbin), et
    // 220 Mo de modèle qui va tourner sur la machine passaient alors en clair,
    // modifiables par qui tient le réseau. Ce qui manquait n'est PAS un plafond
    // de sauts — `URLSession` les borne déjà à 20, et un compteur de plus
    // aurait remplacé le contrôle qui compte : celui du SCHÉMA.
    //
    // Pas de liste d'hôtes : `FOUINE_MODEL_URL` est documenté comme chemin de
    // recette, et une liste blanche le rendrait inutilisable.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let scheme = request.url?.scheme?.lowercased() ?? "?"
        guard scheme == "https" else {
            fail(.unsupportedScheme(request.url?.absoluteString ?? scheme))
            completionHandler(nil)
            return
        }
        if let host = request.url?.host {
            mutex.lock(); hosts.append(host); mutex.unlock()
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        let url = response.url ?? dataTask.originalRequest?.url ?? URL(fileURLWithPath: "/")
        guard http.statusCode == 200 else {
            // Refusé AVANT le premier octet écrit : un corps de 404 en HTML n'a
            // aucune raison de toucher le disque.
            fail(http.statusCode == 404
                 ? .notFound(url)
                 : .httpStatus(http.statusCode, url))
            completionHandler(.cancel)
            return
        }
        // PLAFOND ANNONCÉ (A1-04). 419 Mo étaient écrits sur le disque avant le
        // moindre refus, et le contrôle disparaissait entièrement dès que
        // `FOUINE_MODEL_SHA256` était posé — c'est-à-dire exactement quand
        // l'archive vient d'ailleurs. Un `Content-Length` au-delà du plafond se
        // refuse ici, avant le premier octet.
        if response.expectedContentLength > sink.cap {
            fail(.sizeMismatch(expected: sink.cap,
                               got: response.expectedContentLength))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0 {
            sink.setTotal(response.expectedContentLength)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        sink.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error, failure == nil {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                fail(.cancelled)
            } else {
                fail(.transport(ns.localizedDescription))
            }
        }
        done.signal()
    }
}
