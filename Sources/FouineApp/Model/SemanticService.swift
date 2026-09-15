// SemanticService.swift — chemin sémantique de l'app (SPEC §12). Propriété : A-App.
//
// Façade de FouineEmbed pour l'interface, sur le modèle de StoreService : rien
// ne s'exécute sur le fil principal.
//
// Les deux pièces sont CHÈRES et chargées PARESSEUSEMENT, à la première
// recherche hybride seulement, puis gardées. Les chiffres sont ceux du
// 04/09/2026, base de production, binaire release, MACHINE CHARGÉE (un autre
// agent compilait) : pessimistes d'un facteur 2 à 3, et les rapports entre eux
// valent mieux que les valeurs absolues. Table complète et détaillée dans
// `docs/search.md` § « Latence de la CLI vs serveur résident ».
//
//   · E5Encoder     8 787 ms AVANT le cache binaire de vocabulaire (lot K1),
//                   ~1 100 ms après. Le poste principal n'a jamais été
//                   l'inférence ni le balayage : c'était la lecture de
//                   `vocab.json` (9,3 Mo, 250 000 entrées matérialisées par
//                   `JSONSerialization`), divisée par vingt-cinq depuis ;
//   · VectorIndex     979 ms de chargement depuis SQLite ;
//   · la recherche  1 635 ms, dont 8 ms pour le canal lexical.
//   · TOTAL          11,7 s au premier coup avant K1, ~1,1 s après,
//                    495 Mio résidents.
//
// Ce que ces nombres ont remplacé : « E5Encoder ~2,5 s · VectorIndex ~1 s et
// jusqu'à ~146 Mo pour 379 k pages » (audit A2-04). Le second chiffre datait
// d'AVANT le fenêtrage du schéma v5, où une page porte jusqu'à trois vecteurs :
// l'index se compte en FENÊTRES, pas en pages, et la campagne en produit
// **1,371 fenêtre par page**. À 392 octets par fenêtre, la couverture complète
// du corpus (390 114 pages) fera donc ~535 000 fenêtres et **~210 Mo** de
// tampon résident, gardés pour toute la vie du processus.
//
// AUCUN CHIFFRE N'EST ANNONCÉ DANS L'INTERFACE, ni avant ni après : elle dit
// « quelques secondes », ce qui reste vrai des deux côtés de la mesure et ne
// devient pas faux sur une machine plus lente, un cache disque froid ou un
// corpus deux fois plus grand.
//
// L'app ne charge donc jamais rien au démarrage : un utilisateur qui ne touche
// pas à l'interrupteur ne paie rien, ni en temps ni en mémoire.
//
// La file est SÉRIE : elle sérialise le chargement (une seule fois, même si
// deux recherches partent coup sur coup) et l'inférence CoreML ; `topK`
// parallélise déjà en interne sur quatre fils.

import Foundation
import FouineCore
import FouineEmbed

/// Ce que l'interface a le droit de proposer, et pourquoi pas.
enum SemanticAvailability: Equatable {
    case unknown
    case ready(vectors: Int)
    case modelMissing
    case noVectors
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Aide affichée sous l'interrupteur : toujours le geste à faire, jamais un
    /// simple constat d'échec (§5.6).
    var help: String {
        switch self {
        case .unknown:
            return String(localized: "Checking search by meaning…")
        case .ready(let n):
            return String(localized: "\(n) page(s) ready for meaning search: results combine word search and meaning search.")
        case .modelMissing:
            // Le geste, pas la consigne de développeur (audit B1-07) :
            // cette phrase est affichée sous l'interrupteur de la barre
            // latérale ET dans l'onglet « Recherche par le sens », quinze lignes
            // au-dessus du bouton « Download the model (220.2 MB)… » —
            // elle renvoyait l'utilisateur d'une application grand
            // public vers un script Python absent du bundle. Le chemin
            // du répertoire du modèle n'y est plus : il ne servait qu'à
            // qui savait déjà quoi en faire.
            return String(localized: "Model not installed — Settings ▸ Search by meaning ▸ “Download the model”.")
        case .noVectors:
            // L'onglet ne se contente plus d'EXPLIQUER l'étape restante : il
            // porte le bouton qui la fait (UX-12). La phrase le dit, et la
            // barre latérale offre le même bouton sur place.
            return String(localized: "No page is ready for meaning search yet — Settings ▸ Search by meaning prepares them.")
        case .failed(let message):
            return message
        }
    }

    /// L'onglet « Recherche par le sens » doit-il montrer l'étape restante
    /// (préparer les pages) ? (audit A2-02)
    ///
    /// Le bloc n'apparaissait qu'à l'instant qui suit l'installation, et
    /// `ModelDownloadModel.refresh()` efface `justInstalled` dès le premier
    /// retour sur l'onglet. Or c'est là que la barre latérale envoie
    /// l'utilisateur — « Réglages ▸ Recherche par le sens » —
    /// et il n'y trouvait plus rien : modèle présent, interrupteur grisé,
    /// aucune explication. La bonne condition n'est pas « on vient
    /// d'installer » mais « le modèle est là et aucune page n'est prête » ;
    /// qui a déjà lancé la préparation est en `.ready` et ne la lit pas.
    static func showsRemainingStep(modelInstalled: Bool, justInstalled: Bool,
                                   availability: SemanticAvailability) -> Bool {
        guard modelInstalled else { return false }
        if justInstalled { return true }
        return availability == .noVectors
    }
}

/// Ce que `SearchModel` demande au sens (lot MN2).
///
/// Un protocole pour UNE raison : substituer un double qui répond quand le
/// test le décide. Une base de test n'a ni modèle CoreML ni vecteur, et sans
/// lui seul le chemin où le sens ne répond pas se prouvait — jamais
/// `semanticPending` autour d'une fusion qui arrive.
protocol SemanticSearching: AnyObject, Sendable {
    var isLoaded: Bool { get }
    func availability() async -> SemanticAvailability
    func search(query: SearchQuery, excludingDocsMatching negative: String?,
                rawQuery: String, typedQuery: String, limit: Int,
                depth: Int) async throws -> HybridResults
}

final class SemanticService: SemanticSearching, @unchecked Sendable {

    private let store: GRDBStore

    /// SÉRIE, délibérément : le modèle et l'index ne doivent être chargés
    /// qu'une fois, et l'inférence CoreML n'a rien à gagner à se recouvrir.
    private let queue = DispatchQueue(label: "io.github.basedpolymer.fouine.semantic",
                                      qos: .userInitiated)
    /// La disponibilité (présence du modèle + `count(*)`) se demande depuis
    /// l'interface à chaque retour au premier plan : elle ne doit PAS attendre
    /// derrière le chargement du modèle sur la file série (plusieurs secondes,
    /// voir l'en-tête).
    private let probeQueue = DispatchQueue(label: "io.github.basedpolymer.fouine.semantic.probe",
                                           qos: .utility)

    // Touchés seulement depuis `queue`.
    private var encoder: E5Encoder?
    private var index: VectorIndex?
    /// Nombre de lignes de `page_vec` (donc de FENÊTRES, schéma v5) au moment
    /// où l'index a été chargé — c'est lui, et non `index.count`, qui sert de
    /// référence de fraîcheur : un blob de dimension inattendue (sentinelle de
    /// complétude comprise) est ignoré au chargement et fausserait la
    /// comparaison. La dérive se mesure donc sur ce que la campagne ÉCRIT.
    private var indexVectors = 0

    private let lock = NSLock()
    private var loaded = false

    /// Vrai une fois le modèle et l'index en mémoire : l'interface s'en sert
    /// pour n'annoncer « préparation… » qu'au premier coup.
    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    /// Au-delà de cette dérive relative du nombre de vecteurs, l'index est
    /// rechargé : la campagne `fouine embed` tourne en arrière-plan et remplit
    /// `page_vec` au fil de l'eau, un index figé au premier chargement
    /// ignorerait tout ce qu'elle produit ensuite.
    private static let staleRatio = 10

    /// Les deux détails de `FouineEmbedError.model` que l'APP fabrique.
    ///
    /// Ils sont nommés parce qu'`ErrorText` les traduit : tout autre détail de
    /// `.model` vient de CoreML et passe tel quel. Les phrases restent
    /// françaises ici — c'est ce que la CLI imprimerait si elle les voyait.
    static let noVectorsDetail = "aucun vecteur en base — lancez « fouine embed »"
    static let indexNotLoadedDetail = "index vectoriel non chargé"

    /// `encoder` : un modèle DÉJÀ chargé, pour les tests qui en partagent une
    /// instance entre eux (lot I2 : plusieurs secondes par chargement). `nil` en
    /// production — le premier appel hybride charge. Rien d'autre ne change :
    /// `isLoaded` ne passe à vrai qu'une fois l'index construit, et
    /// `availability()` n'ouvre toujours rien.
    init(store: GRDBStore, encoder: E5Encoder? = nil) {
        self.store = store
        self.encoder = encoder
    }

    // MARK: - Disponibilité

    /// N'ouvre RIEN : présence des trois pièces du modèle et compte de vecteurs.
    func availability() async -> SemanticAvailability {
        await withCheckedContinuation { continuation in
            probeQueue.async { [store] in
                guard EmbedPaths.modelAvailable(at: EmbedPaths.modelDirectory()) else {
                    continuation.resume(returning: .modelMissing)
                    return
                }
                do {
                    // PAGES vectorisées, pas fenêtres : l'aide affichée sous
                    // l'interrupteur dit « N page(s) vectorisée(s) », et une
                    // page porte jusqu'à trois vecteurs depuis le schéma v5.
                    let n = try store.vectorisedPageCount()
                    continuation.resume(returning: n > 0 ? .ready(vectors: n) : .noVectors)
                } catch {
                    continuation.resume(returning: .failed(ErrorText.describe(error)))
                }
            }
        }
    }

    // MARK: - Recherche hybride

    /// Fusion RRF du canal lexical et du canal vectoriel (§12). Charge le modèle
    /// et l'index au premier appel ; jette `FouineEmbedError` si l'un ou l'autre
    /// manque — l'appelant retombe alors sur la recherche lexicale.
    func search(query: SearchQuery, excludingDocsMatching negative: String?,
                rawQuery: String, typedQuery: String, limit: Int,
                depth: Int = HybridSearch.defaultDepth) async throws -> HybridResults {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let (engine, index) = try load()
                    continuation.resume(returning: try HybridSearch.run(
                        store: store, engine: engine, index: index, query: query,
                        excludingDocsMatching: negative, rawQuery: rawQuery,
                        typedQuery: typedQuery, limit: limit, depth: depth))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Chargement paresseux et unique — À N'APPELER QUE DEPUIS `queue`.
    private func load() throws -> (engine: E5Encoder, index: VectorIndex) {
        let engine: E5Encoder
        if let encoder {
            engine = encoder
        } else {
            engine = try E5Encoder(modelDir: EmbedPaths.modelDirectory())
            encoder = engine
        }

        let current = try store.vectorCount()
        guard current > 0 else {
            // Le modèle est là, la base est vide : ce n'est pas une panne, c'est
            // une campagne `fouine embed` qui n'a pas encore tourné.
            setLoaded(false)
            throw FouineEmbedError.model(Self.noVectorsDetail)
        }
        if index == nil || abs(current - indexVectors) > max(1, indexVectors / Self.staleRatio) {
            index = try VectorIndex(store: store, dim: engine.dimension)
            indexVectors = current
        }
        guard let index else {
            throw FouineEmbedError.model(Self.indexNotLoadedDetail)
        }
        setLoaded(true)
        return (engine, index)
    }

    private func setLoaded(_ value: Bool) {
        lock.lock(); loaded = value; lock.unlock()
    }
}
