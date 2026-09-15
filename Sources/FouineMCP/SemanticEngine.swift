// SemanticEngine.swift — le modèle et l'index vectoriel, résidents.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// C'EST L'ARGUMENT DU PALIER 4 TOUT ENTIER. Mesuré (D2 § 5.1, contre-expertise
// C2) : `fouine search --hybrid` met 8,5 s de mur, dont ~5,6 s de chargement du
// `.mlmodelc` et de l'index — payées À CHAQUE INVOCATION parce qu'une commande
// meurt à la fin de sa sortie. Un serveur qui vit les paie UNE fois. Sans ce
// fichier, le serveur MCP ne serait qu'un habillage de la CLI ; avec lui, la
// recherche sémantique devient utilisable par un agent.
//
// TROIS RÈGLES, ET CHACUNE RÉPOND À UNE MESURE.
//
//  1. **Le modèle est chargé PARESSEUSEMENT.** 571 Mo de RSS pour le seul
//     `.mlmodelc`, 2,6 à 6,3 s selon la machine. Un utilisateur qui ne fait que
//     du lexical — et il y en aura — n'a aucune raison de payer cela : le
//     serveur reste à ses ~16 Mio tant que personne ne demande d'hybride.
//     `fouine_similar_pages` n'en a PAS besoin non plus : les voisins d'une
//     page se calculent sur son vecteur DÉJÀ en base, sans jamais encoder de
//     texte. Seul `fouine_search` en `mode: hybrid` charge le modèle.
//
//  2. **L'index vectoriel est RECHARGÉ sur dérive.** La campagne `fouine embed`
//     ajoute ~5 vecteurs/s : un serveur ouvert vingt heures à côté d'elle
//     ignorerait des centaines de milliers de vecteurs, et répondrait « je ne
//     trouve rien » sur des pages qu'il a sous les yeux. Le critère est celui de
//     `SemanticService.staleRatio` (app, 10 %), pas un seuil inventé : un
//     critère d'ÉGALITÉ STRICTE serait faux en permanence pendant une campagne.
//     Plafond de dix minutes en plus, pour le cas où la dérive relative reste
//     sous les 10 % (un gros index qui grossit lentement).
//
//  3. **Aucune requête n'attend un rechargement.** Le premier chargement, lui,
//     bloque forcément — il n'y a rien à répondre avec. Les suivants partent
//     sur une file de fond et la référence est ÉCHANGÉE quand ils aboutissent :
//     la requête en cours répond avec l'index qu'elle a, un peu vieux, plutôt
//     que d'attendre une seconde. Un index vieux d'une minute est une bonne
//     réponse ; une réponse en retard d'une seconde, non.
//
// COMPTAGE : `vectorLineCount()` est un `SELECT count(*) FROM page_vec`, index
// couvrant, mais ce n'est pas gratuit sur 390 k lignes. Il est demandé au plus
// une fois par minute — le reste du temps, la fraîcheur se juge sur la dernière
// valeur connue.
//
// LIGNES contre PAGES : la comparaison de fraîcheur oppose des lignes de
// `page_vec` à `VectorIndex.count`, qui est lui aussi un nombre de lignes. Elle
// reste JUSTE sous le fenêtrage v5, où une ligne cesse d'être une page. Ce qui
// change alors est ailleurs : voir `ReadOnlyStore.vectorisedPageCount()`.

import Foundation
import FouineCore
import FouineEmbed

public final class SemanticEngine: @unchecked Sendable {

    /// Dérive relative au-delà de laquelle l'index est rechargé, en pourcents
    /// inverses : 10 = 10 %. La MÊME valeur que `SemanticService.staleRatio`
    /// dans l'application — une seule référence dans le produit.
    public static let staleRatio = 10

    /// Âge au-delà duquel l'index est rechargé quoi qu'il arrive.
    public static let maxIndexAge: TimeInterval = 600

    /// Période minimale entre deux `count(*)` sur `page_vec`.
    public static let countInterval: TimeInterval = 60

    /// Ce que `fouine_status` publie sous `semantic` et `index_freshness`.
    public struct Freshness: Sendable {
        public let modelLoaded: Bool
        public let indexLoadedAt: Date?
        public let indexCount: Int?
    }

    private let store: ReadOnlyStore
    private let modelDirectory: URL
    private let now: () -> Date

    /// Chargements en série : ni le modèle ni l'index ne gagnent à se
    /// recouvrir, et deux constructions d'index simultanées doubleraient
    /// franchement la pointe mémoire (145 Mio à 377 k vecteurs).
    private let loadQueue = DispatchQueue(
        label: "io.github.basedpolymer.fouine.mcp.semantic", qos: .userInitiated)

    private let mutex = NSLock()
    private var encoder: E5Encoder?
    private var index: VectorIndex?
    private var indexLines = 0
    private var indexLoadedAt: Date?
    private var lastCount: Int?
    private var lastCountAt: Date?
    private var refreshing = false

    public init(store: ReadOnlyStore,
                modelDirectory: URL = EmbedPaths.modelDirectory(),
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.modelDirectory = modelDirectory
        self.now = now
    }

    // MARK: - Disponibilité

    /// N'ouvre RIEN et ne charge RIEN : la présence des trois pièces du modèle
    /// sur le disque, comme `fouine doctor`.
    public var modelInstalled: Bool {
        EmbedPaths.modelAvailable(at: modelDirectory)
    }

    /// Le modèle est installé ET il y a des vecteurs à comparer. C'est la
    /// condition exacte du `mode: "auto"` de `fouine_search`, et la
    /// transposition de `runHybrid` (`CommandsSearch.swift:157-176`).
    public func isAvailable() -> Bool {
        guard modelInstalled else { return false }
        return (try? vectorLines()) ?? 0 > 0
    }

    public func freshness() -> Freshness {
        mutex.lock(); defer { mutex.unlock() }
        return Freshness(modelLoaded: encoder != nil,
                         indexLoadedAt: indexLoadedAt,
                         indexCount: index?.count)
    }

    // MARK: - Le modèle

    /// Charge au premier appel, puis rend la même instance. ~2,6 s et 571 Mo,
    /// une seule fois pour la vie du serveur.
    public func loadedEncoder() throws -> E5Encoder {
        mutex.lock()
        if let encoder { mutex.unlock(); return encoder }
        mutex.unlock()

        return try loadQueue.sync {
            // Re-contrôle SOUS la file : deux requêtes arrivées en même temps
            // ne doivent pas charger deux fois 571 Mo.
            mutex.lock()
            let existing = encoder
            mutex.unlock()
            if let existing { return existing }

            let fresh = try E5Encoder(modelDir: modelDirectory)
            mutex.lock(); encoder = fresh; mutex.unlock()
            return fresh
        }
    }

    // MARK: - L'index

    /// L'index vectoriel courant, chargé si besoin.
    ///
    /// Rend `nil` quand la base ne porte aucun vecteur : ce n'est pas une panne
    /// mais une campagne `fouine embed` qui n'a pas tourné, et l'appelant doit
    /// pouvoir le dire au modèle plutôt que d'échouer.
    public func currentIndex(dimension: Int) throws -> VectorIndex? {
        mutex.lock()
        let resident = index
        mutex.unlock()

        guard let resident else { return try loadIndex(dimension: dimension) }
        if isStale() { scheduleRefresh(dimension: dimension) }
        return resident
    }

    /// Chargement BLOQUANT — le premier, ou celui qui suit un index vidé.
    private func loadIndex(dimension: Int) throws -> VectorIndex? {
        try loadQueue.sync {
            mutex.lock()
            let existing = index
            mutex.unlock()
            if let existing { return existing }

            let lines = try vectorLines(force: true)
            guard lines > 0 else { return nil }
            let fresh = try store.makeVectorIndex(dim: dimension)
            adopt(fresh, lines: lines)
            return fresh
        }
    }

    /// Rechargement de FOND. La requête en cours ne l'attend pas : elle répond
    /// avec l'index qu'elle a déjà.
    private func scheduleRefresh(dimension: Int) {
        mutex.lock()
        if refreshing { mutex.unlock(); return }
        refreshing = true
        mutex.unlock()

        loadQueue.async { [self] in
            defer { mutex.lock(); refreshing = false; mutex.unlock() }
            guard let lines = try? vectorLines(force: true), lines > 0,
                  let fresh = try? store.makeVectorIndex(dim: dimension)
            else { return }
            adopt(fresh, lines: lines)
        }
    }

    /// Échange ATOMIQUE de la référence : une requête voit l'ancien index ou le
    /// nouveau, jamais un tampon à demi rempli.
    private func adopt(_ fresh: VectorIndex, lines: Int) {
        mutex.lock()
        index = fresh
        indexLines = lines
        indexLoadedAt = now()
        mutex.unlock()
    }

    /// L'index doit-il être rechargé ? Dérive de plus de `staleRatio` %, ou âge
    /// de plus de `maxIndexAge` — le premier des deux.
    private func isStale() -> Bool {
        mutex.lock()
        let loadedAt = indexLoadedAt
        let reference = indexLines
        mutex.unlock()

        if let loadedAt, now().timeIntervalSince(loadedAt) > Self.maxIndexAge {
            return true
        }
        guard let current = try? vectorLines() else { return false }
        return abs(current - reference) > max(1, reference / Self.staleRatio)
    }

    /// `count(*)` sur `page_vec`, au plus une fois par minute.
    private func vectorLines(force: Bool = false) throws -> Int {
        if !force {
            mutex.lock()
            let cached = lastCount
            let at = lastCountAt
            mutex.unlock()
            if let cached, let at, now().timeIntervalSince(at) < Self.countInterval {
                return cached
            }
        }
        let value = try store.vectorLineCount()
        mutex.lock(); lastCount = value; lastCountAt = now(); mutex.unlock()
        return value
    }

    // MARK: - Ce que les outils demandent

    /// La dimension attendue des vecteurs en base. Elle vient de `vec_meta`, et
    /// non du modèle : les voisins d'une page se calculent sans charger CoreML,
    /// et il serait absurde de payer 571 Mo pour lire un entier.
    ///
    /// À défaut, la longueur d'un blob de `page_vec` — voir
    /// `GRDBStore.vectorBlobDimension()`. Une base dont `vec_meta` manque porte
    /// quand même des vecteurs utilisables, et refuser de les charger ferait
    /// répondre « aucun vecteur » sur un index qui en a des dizaines de
    /// milliers.
    public func storedDimension() throws -> Int? {
        if let declared = Int(try store.vecMeta()["dim"] ?? ""), declared > 0 {
            return declared
        }
        return try store.vectorBlobDimension()
    }

    /// Identité du modèle telle que la base la porte (`vec_meta`).
    public func storedIdentity() throws -> (modelID: String?, revision: Int?) {
        let meta = try store.vecMeta()
        return (meta["model_id"], meta["revision"].flatMap(Int.init))
    }

    /// L'index vectoriel SEUL, sans jamais charger CoreML — ce dont
    /// `fouine_similar_pages` a besoin, et rien de plus.
    public func indexWithoutModel() throws -> VectorIndex? {
        guard let dim = try storedDimension(), dim > 0 else { return nil }
        return try currentIndex(dimension: dim)
    }
}
