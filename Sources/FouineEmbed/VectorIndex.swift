// VectorIndex.swift — balayage exhaustif int8 des vecteurs de FENÊTRES de page.
// Propriété : A-Embed.
//
// PAS d'index approché (ANN) : la force brute mesurée rend le top-200 en 15 ms
// sur 1 fil, 6,4 ms sur 4 (bench du 01/09, Intel i5-8257U). Un ANN n'apporterait
// que de la complexité et du rappel perdu. Le noyau élargit des SIMD16<Int8> en
// Int32 et se déroule par 64 octets ; la dimension doit être un multiple de 16
// (384 ✓).
//
// L'ÉCHELLE SE COMPTE EN FENÊTRES DEPUIS LE SCHÉMA v5 (audit A1m-15). L'en-tête
// annonçait « 379 k pages × 384 = 139 Mio » : c'est le chiffre du schéma v3, où
// une page valait un vecteur. Mesuré le 04/09/2026 sur la base de production
// réparée : **2,126 fenêtres réelles par page COMPLÈTE** (8 971 fenêtres pour
// 4 220 pages), c'est-à-dire le 2,13 de C2-05. À couverture pleine, 389 862
// pages indexées donnent donc ~829 000 fenêtres, soit **~318 Mio** de tampon —
// deux fois et demie l'estimation d'origine, et le second poste de la base
// après le texte.
//
// (Le rapport « lignes de page_vec / pages vues », 1,371 sur la base du
// 04/09 avant réparation, ne mesure PAS cela : il mélange les pages
// incomplètes de la campagne en cours, les sentinelles vides et — ce jour-là —
// 11 051 lignes d'un autre schéma. Après réparation il tombe à 1,12, et il
// montera vers 2,1 à mesure que la campagne complète les pages.)
//
// FENÊTRAGE (schéma v5, constat C2-05). Les rowids chargés sont des rowids de
// FENÊTRE — `page * 8 + chunk`. À l'INTÉRIEUR de l'index tout se compte en
// fenêtres ; à la FRONTIÈRE, `topK` et `neighbours` replient par page
// (max-pooling : le meilleur cosinus de ses fenêtres) et rendent des rowids de
// PAGE. `HybridSearch`, `RRF` et `pagePreviews` n'ont donc rien à savoir du
// fenêtrage, et le serveur MCP non plus.

import Foundation
import FouineCore

public struct VectorIndex {

    public let dim: Int
    /// Rowids de FENÊTRE (`(doc_id · pagesPerDocLimit + page) · 8 + chunk`),
    /// triés par rowid (garanti par GRDBStore.allVectors qui exécute
    /// ORDER BY rowid), parallèles au tampon. Les sentinelles de complétude,
    /// blobs vides, ne sont pas chargées.
    public let rowids: [Int64]
    /// Tampon contigu : `rowids.count × dim` octets signés.
    private let data: [Int8]

    /// Vecteur moyen du corpus RETIRÉ de chaque page, en unités de vecteur
    /// unitaire (donc à diviser par rien : `mean[i]` se soustrait directement
    /// d'une composante de vecteur unitaire). Nil quand l'index n'est pas
    /// centré, ce qui est le cas ordinaire. Voir `centered()`.
    public let centeringMean: [Float]?

    /// Nombre de FENÊTRES chargées. Reste le sens historique de `count`, mais
    /// ce n'est plus un nombre de pages : ce qui se montre à l'utilisateur, et
    /// ce qui sert de dénominateur de couverture, est `pageCount`.
    public var count: Int { rowids.count }

    /// Fenêtres chargées (synonyme explicite de `count`).
    public var chunkCount: Int { rowids.count }

    /// PAGES distinctes présentes dans l'index — comptées comme le nombre de
    /// fenêtres 0, une passe O(n) au chargement (0,3 ms sur 64 872 rowids).
    /// C'est le nombre que la couverture affiche (« 16,6 % des pages ») et que
    /// le serveur MCP doit rendre : « 1,1 M de vecteurs » ne veut rien dire
    /// pour quelqu'un qui cherche dans 390 000 pages.
    public let pageCount: Int

    public init(rowids: [Int64], data: [Int8], dim: Int,
                centeringMean: [Float]? = nil) {
        precondition(data.count == rowids.count * dim,
                     "misaligned vector buffer")
        self.rowids = rowids
        self.data = data
        self.dim = dim
        self.centeringMean = centeringMean
        var pages = 0
        for rowid in rowids where rowid % Schema.vecChunksPerPage == 0 {
            pages += 1
        }
        self.pageCount = pages
    }

    /// Charge tous les vecteurs de `page_vec`. Mesuré le 04/09/2026 sur la base
    /// de production (69 346 fenêtres chargeables) : **120 ms**, et ~1 s
    /// projeté à couverture pleine (~829 000 fenêtres). L'app le fait une fois
    /// et garde l'index, la CLI le paie à chaque invocation.
    /// Les vecteurs sont retournés triés par `rowid` ascendant.
    public init(store: GRDBStore, dim: Int) throws {
        let (rowids, data) = try store.allVectors(dim: dim)
        self.init(rowids: rowids, data: data, dim: dim)
    }

    /// Index CENTRÉ : le vecteur moyen du corpus — calculé sur les vecteurs non
    /// nuls seulement — est retiré de chaque page, qui est ensuite renormalisée
    /// et re-quantifiée en int8. Le même vecteur moyen doit être retiré de la
    /// requête (`centeringMean`), sans quoi les deux espaces ne se comparent
    /// plus.
    ///
    /// C'est le remède classique de l'anisotropie : les embeddings mean-poolés
    /// ont une composante commune énorme qui écrase la bande utile des cosinus
    /// (0,78-0,88 mesurés sur ce corpus, audit C2-01). Rien n'est écrit en
    /// base : c'est une transformation du tampon en mémoire, refaite à chaque
    /// chargement d'index.
    ///
    /// Les vecteurs nuls le RESTENT : une page trop courte n'a pas de direction
    /// à centrer, et lui en donner une la ferait remonter dans tous les top-k.
    public func centered() -> VectorIndex {
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        data.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for r in 0..<rowids.count {
                let row = base + r * dim
                if Self.isZero(row, dim) { continue }
                n += 1
                for i in 0..<dim { sum[i] += Double(row[i]) }
            }
        }
        guard n > 0 else { return self }
        let scale = Double(VecQuantizer.scale)
        // En unités de vecteur unitaire : les entiers stockés valent v·127.
        let mean = (0..<dim).map { Float(sum[$0] / Double(n) / scale) }

        var out = [Int8](repeating: 0, count: rowids.count * dim)
        var work = [Float](repeating: 0, count: dim)
        data.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for r in 0..<rowids.count {
                let row = base + r * dim
                if Self.isZero(row, dim) { continue }
                var norm: Float = 0
                for i in 0..<dim {
                    let v = Float(row[i]) / Float(VecQuantizer.scale) - mean[i]
                    work[i] = v
                    norm += v * v
                }
                norm = norm.squareRoot()
                guard norm > 0 else { continue }
                for i in 0..<dim {
                    let q = (work[i] / norm * Float(VecQuantizer.scale)).rounded()
                    out[r * dim + i] = Int8(max(-VecQuantizer.scale,
                                                min(VecQuantizer.scale, q)))
                }
            }
        }
        return VectorIndex(rowids: rowids, data: out, dim: dim,
                           centeringMean: mean)
    }

    /// Applique à une requête le centrage de CET index (sans effet s'il n'est
    /// pas centré), puis renormalise. À appeler avant la quantification.
    public func center(query v: [Float]) -> [Float] {
        guard let mean = centeringMean, v.count == mean.count else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var norm: Float = 0
        for i in 0..<v.count {
            out[i] = v[i] - mean[i]
            norm += out[i] * out[i]
        }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        for i in 0..<v.count { out[i] /= norm }
        return out
    }

    /// Rang du rowid dans l'index, trouvé par recherche dichotomique en O(log N)
    /// (les rowids étant triés par construction). Nil si absent.
    ///
    /// CONTRAT : le rowid attendu est un rowid de FENÊTRE
    /// (`Schema.vecRowID(pageRowID:chunk:)`), pas de page — c'est la seule
    /// méthode publique qui raisonne encore en fenêtres. Un rowid de page n'y
    /// trouve rien : pour partir d'une page, `neighbours(of:k:)`.
    public func index(of rowid: Int64) -> Int? {
        var lo = 0
        var hi = rowids.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let val = rowids[mid]
            if val == rowid { return mid }
            if val < rowid { lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return nil
    }

    // MARK: - Moments du balayage (C2-01)

    /// Moments des produits scalaires requête·page, accumulés PENDANT le
    /// balayage du top-k, sur la population des vecteurs **non nuls**.
    ///
    /// Pourquoi : les cosinus d'e5-small sont anisotropes — sur le corpus de
    /// production ils vivent tous entre 0,78 et 0,88, et la position dans cette
    /// bande suit la FORME de la requête plus que son sujet (audit C2-01).
    /// Aucun seuil constant ne peut donc trancher ; la seule référence qui ait
    /// un sens est celle de la requête elle-même, d'où la marge
    /// `z = (cos − μ) / σ`.
    ///
    /// Les vecteurs NULS (pages de moins de `EmbedRun.minChars` caractères,
    /// stockées à zéro pour que le curseur de la campagne avance) sont exclus
    /// des moments et comptés à part : mélangés à une population centrée sur
    /// 0,85, ils multiplient σ par trois et effacent la marge (contre-expertise
    /// D2 § 6). Ils restent offerts au top-k — leur cosinus est 0, ils n'y
    /// entrent que si l'index n'a presque rien d'autre.
    public struct ScanStats: Sendable {
        /// Cosinus moyen requête·page sur les vecteurs non nuls comparés.
        public let mu: Double
        /// Écart-type des mêmes cosinus.
        public let sigma: Double
        /// Vecteurs non nuls effectivement comparés (après `allowedDocs`).
        public let scanned: Int
        /// Vecteurs nuls rencontrés, exclus des moments.
        public let zeros: Int

        public init(mu: Double, sigma: Double, scanned: Int, zeros: Int) {
            self.mu = mu
            self.sigma = sigma
            self.scanned = scanned
            self.zeros = zeros
        }

        /// Marge d'un cosinus par rapport à la population de CETTE requête.
        /// σ nul (moins de deux vecteurs, population dégénérée) ⇒ 0, ce qui
        /// rend tout plancher strictement positif inatteignable : c'est le bon
        /// défaut, un index sans dispersion ne sait rien dire.
        public func z(_ cosine: Float) -> Double {
            sigma > 0 ? (Double(cosine) - mu) / sigma : 0
        }
    }

    /// Ce que rend un balayage : le top-k et les moments de la population.
    public struct ScanResult: Sendable {
        public let hits: [(rowid: Int64, cosine: Float)]
        public let stats: ScanStats

        public init(hits: [(rowid: Int64, cosine: Float)], stats: ScanStats) {
            self.hits = hits
            self.stats = stats
        }
    }

    /// Accumulateur par fil. `sum` en Int64 (exact : |dot| ≤ 127²·384 et
    /// 390 k lignes tiennent largement), `sumSq` en Double pour ne pas
    /// déborder dans le pire cas théorique (1,5·10¹⁹ > Int64.max).
    private struct Moments {
        var sum: Int64 = 0
        var sumSq: Double = 0
        var nonZero: Int = 0
        var zeros: Int = 0
    }

    /// Top-k par produit scalaire (≈ cosinus, vecteurs unitaires quantifiés),
    /// meilleur d'abord, ET les moments de la population balayée (`ScanStats`).
    /// `allowedDocs` restreint aux documents autorisés par les filtres de la
    /// requête (nil = tous) — les moments portent alors sur cette population
    /// restreinte, ce qui est la bonne référence : la marge d'un hit se juge
    /// contre ce que la requête a réellement balayé.
    ///
    /// REND DES ROWIDS DE PAGE (schéma v5). Le balayage porte sur les fenêtres ;
    /// chaque fil retient `k × vecWindowMax` fenêtres, et le repli final ne
    /// garde qu'une entrée par page — son MEILLEUR cosinus (max-pooling). Une
    /// page longue ne peut donc pas occuper trois places du top-10 avec trois
    /// de ses fenêtres, et la signature reste celle du schéma v3.
    ///
    /// Les moments, eux, portent sur les FENÊTRES non nulles balayées : c'est
    /// la population dont un cosinus est réellement tiré, et donc la seule
    /// référence qui donne un sens à la marge `z`. Ils ne sont pas comparables
    /// chiffre pour chiffre à ceux d'un index non fenêtré — μ bouge avec la
    /// composition de la population, pas avec le classement.
    public func topK(query: [Int8], k: Int,
                     allowedDocs: Set<Int64>? = nil) -> ScanResult {
        precondition(query.count == dim, "unexpected query dimension")
        let empty = ScanStats(mu: 0, sigma: 0, scanned: 0, zeros: 0)
        guard k > 0, !rowids.isEmpty else { return ScanResult(hits: [], stats: empty) }
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let n = rowids.count

        // Table booléenne indexée par doc_id, construite une seule fois par requête (C2-07).
        let allowedMap: [Bool]?
        if let allowedDocs {
            let maxDoc = allowedDocs.max() ?? -1
            if maxDoc >= 0 {
                var map = [Bool](repeating: false, count: Int(maxDoc) + 1)
                for doc in allowedDocs where doc >= 0 {
                    map[Int(doc)] = true
                }
                allowedMap = map
            } else {
                allowedMap = []
            }
        } else {
            allowedMap = nil
        }

        func withAllowedBuffer<R>(_ body: (UnsafePointer<Bool>?, Int) -> R) -> R {
            if let allowedMap {
                return allowedMap.withUnsafeBufferPointer { buf in
                    body(buf.baseAddress, buf.count)
                }
            } else {
                return body(nil, 0)
            }
        }

        var partials = [[Entry]](repeating: [], count: threads)
        var moments = [Moments](repeating: Moments(), count: threads)
        partials.withUnsafeMutableBufferPointer { parts in
            let partsBase = parts.baseAddress!
            moments.withUnsafeMutableBufferPointer { mom in
                let momBase = mom.baseAddress!
                data.withUnsafeBufferPointer { dbuf in
                    query.withUnsafeBufferPointer { qbuf in
                        withAllowedBuffer { allowedBase, allowedCount in
                            let base = dbuf.baseAddress!
                            let q = qbuf.baseAddress!
                            DispatchQueue.concurrentPerform(iterations: threads) { t in
                                // `k × vecWindowMax` avant repli : dans le pire
                                // cas, les k meilleures fenêtres appartiennent
                                // toutes à k/3 pages.
                                var top = TopK(k: k * Schema.vecWindowMax)
                                var m = Moments()
                                let lo = n * t / threads, hi = n * (t + 1) / threads
                                for r in lo..<hi {
                                    if let allowedBase {
                                        let docID = Int(Schema.pageRowID(
                                            vecRowID: rowids[r])
                                            / Schema.pagesPerDocLimit)
                                        if docID >= allowedCount || !allowedBase[docID] {
                                            continue
                                        }
                                    }
                                    let row = base + r * dim
                                    let s = Self.dot(row, q, dim)
                                    // Un vecteur nul rend TOUJOURS un produit
                                    // scalaire nul ; le contrôle complet ne
                                    // coûte donc que sur les lignes à 0, qui
                                    // sont les nulles plus une poignée
                                    // d'orthogonales exactes.
                                    if s == 0 && Self.isZero(row, dim) {
                                        m.zeros &+= 1
                                    } else {
                                        m.nonZero &+= 1
                                        m.sum &+= Int64(s)
                                        let d = Double(s)
                                        m.sumSq += d * d
                                    }
                                    top.offer(Entry(score: s, index: Int32(r)))
                                }
                                partsBase[t] = top.entries
                                momBase[t] = m
                            }
                        }
                    }
                }
            }
        }

        var sum: Int64 = 0
        var sumSq: Double = 0
        var nonZero = 0
        var zeros = 0
        for m in moments {
            sum &+= m.sum
            sumSq += m.sumSq
            nonZero += m.nonZero
            zeros += m.zeros
        }
        // Les moments sont accumulés en produits scalaires int8 ; on les ramène
        // en cosinus en divisant par 127² (VecQuantizer.scale²).
        let unit = Double(VecQuantizer.scale) * Double(VecQuantizer.scale)
        let mu = nonZero > 0 ? Double(sum) / Double(nonZero) / unit : 0
        let variance = nonZero > 1
            ? max(0, sumSq / Double(nonZero) / (unit * unit) - mu * mu)
            : 0
        let stats = ScanStats(mu: mu, sigma: variance.squareRoot(),
                              scanned: nonZero, zeros: zeros)

        return ScanResult(hits: foldByPage(partials.flatMap { $0 }, k: k),
                          stats: stats)
    }

    /// MAX-POOLING : trie les fenêtres par score décroissant et ne garde que la
    /// PREMIÈRE de chaque page — donc, l'ordre étant décroissant, la meilleure.
    /// Rend au plus `k` pages, par rowid de PAGE.
    private func foldByPage(_ entries: [Entry], k: Int)
        -> [(rowid: Int64, cosine: Float)] {
        var out: [(rowid: Int64, cosine: Float)] = []
        out.reserveCapacity(k)
        var seen = Set<Int64>()
        for entry in entries.sorted(by: { $0.score > $1.score }) {
            let page = Schema.pageRowID(vecRowID: rowids[Int(entry.index)])
            guard seen.insert(page).inserted else { continue }
            out.append((page, VecQuantizer.cosine(fromDot: entry.score)))
            if out.count == k { break }
        }
        return out
    }

    /// Voisinage sémantique d'une PAGE (C2-07, D2 § 5.8) — `rowid` est un rowid
    /// de page, celui que rend `topK`, jamais un rowid de fenêtre.
    ///
    /// Rend une liste vide si la page n'a aucune fenêtre chargée, ou si toutes
    /// ses fenêtres sont nulles (page sans texte : produit scalaire nul, donc
    /// aucun voisin qui veuille dire quelque chose). La page elle-même est
    /// toujours exclue ; `excludingSameDoc` exclut tout son document.
    ///
    /// AGRÉGATION PAR PAGE. Toutes les fenêtres présentes de la page source
    /// servent de requête, un balayage chacune, et les résultats sont réduits
    /// par page cible au MAXIMUM du cosinus, puis tronqués à `k`. Sans cette
    /// réduction, une page longue apparaîtrait `k` fois dans ses propres
    /// voisins — c'est le point 3 de D2 § 5.8. Le coût est celui de
    /// `vecWindowMax` balayages, ~40 ms sur la base de production, négligeable
    /// dans un serveur résident où l'index est déjà chargé.
    public func neighbours(of rowid: Int64, k: Int,
                           excludingSameDoc: Bool = false) -> [(rowid: Int64, cosine: Float)] {
        guard k > 0, rowids.count > 1 else { return [] }

        let sources = (0..<Schema.vecWindowMax)
            .compactMap { index(of: Schema.vecRowID(pageRowID: rowid, chunk: $0)) }
            .filter { idx in !withVector(at: idx) { $0.allSatisfy { $0 == 0 } } }
        guard !sources.isEmpty else { return [] }

        var best: [Int64: Int32] = [:]
        for source in sources {
            for entry in scan(from: source, k: k * Schema.vecWindowMax,
                              excludingPage: rowid,
                              excludingDoc: excludingSameDoc
                                  ? rowid / Schema.pagesPerDocLimit : nil) {
                let page = Schema.pageRowID(vecRowID: rowids[Int(entry.index)])
                if let previous = best[page], previous >= entry.score { continue }
                best[page] = entry.score
            }
        }

        return best.sorted { $0.value > $1.value }
            .prefix(k)
            .map { ($0.key, VecQuantizer.cosine(fromDot: $0.value)) }
    }

    /// Voisinage sémantique d'un jeu de vecteurs LIBRES — ceux d'une page qui
    /// n'est pas (encore) dans l'index (lot MC4, constat PM-07).
    ///
    /// MÊME AGRÉGATION que `neighbours(of:)` : un balayage par vecteur source,
    /// réduction par page CIBLE au maximum du cosinus, puis troncature à `k`.
    /// C'est ce qui garantit que `encode_if_missing` rend des voisins
    /// comparables à ceux d'une page déjà vectorisée — la seule différence est
    /// l'origine des vecteurs, jamais la façon de les comparer.
    ///
    /// `excludingDoc` remplace `excludingSameDoc` : la page source n'ayant pas
    /// de rowid dans l'index, il n'y a rien à en déduire, et c'est l'appelant
    /// qui sait de quel document elle vient. Les vecteurs NULS sont écartés :
    /// leur produit scalaire est nul partout, et ils rendraient un voisinage
    /// arbitraire.
    public func neighbours(ofVectors sources: [[Int8]], k: Int,
                           excludingDoc: Int64? = nil)
        -> [(rowid: Int64, cosine: Float)] {
        guard k > 0, !rowids.isEmpty else { return [] }
        let useful = sources.filter { $0.count == dim && $0.contains { $0 != 0 } }
        guard !useful.isEmpty else { return [] }

        var best: [Int64: Int32] = [:]
        for source in useful {
            for entry in scan(query: source, k: k * Schema.vecWindowMax,
                              excludingPage: nil, excludingDoc: excludingDoc) {
                let page = Schema.pageRowID(vecRowID: rowids[Int(entry.index)])
                if let previous = best[page], previous >= entry.score { continue }
                best[page] = entry.score
            }
        }
        return best.sorted { $0.value > $1.value }
            .prefix(k)
            .map { ($0.key, VecQuantizer.cosine(fromDot: $0.value)) }
    }

    /// Balayage brut depuis une fenêtre de l'index, en excluant une page (et
    /// éventuellement tout un document). Rend des entrées de FENÊTRE, non
    /// repliées : c'est l'appelant qui agrège.
    private func scan(from sourceIdx: Int, k: Int, excludingPage: Int64,
                      excludingDoc: Int64?) -> [Entry] {
        data.withUnsafeBufferPointer { dbuf in
            scan(query: dbuf.baseAddress! + sourceIdx * dim, k: k,
                 excludingPage: excludingPage, excludingDoc: excludingDoc)
        }
    }

    /// Idem, depuis un vecteur LIBRE (lot MC4) — celui d'une page encodée à la
    /// volée, qui n'a pas de rang dans le tampon.
    private func scan(query: [Int8], k: Int, excludingPage: Int64?,
                      excludingDoc: Int64?) -> [Entry] {
        query.withUnsafeBufferPointer { qbuf in
            scan(query: qbuf.baseAddress!, k: k,
                 excludingPage: excludingPage, excludingDoc: excludingDoc)
        }
    }

    /// Le noyau des deux : un balayage complet contre un vecteur requête, sans
    /// repli — c'est l'appelant qui agrège par page.
    private func scan(query q: UnsafePointer<Int8>, k: Int,
                      excludingPage: Int64?, excludingDoc: Int64?) -> [Entry] {
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let n = rowids.count
        var partials = [[Entry]](repeating: [], count: threads)
        partials.withUnsafeMutableBufferPointer { parts in
            let partsBase = parts.baseAddress!
            data.withUnsafeBufferPointer { dbuf in
                let base = dbuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: threads) { t in
                    var top = TopK(k: k)
                    let lo = n * t / threads, hi = n * (t + 1) / threads
                    for r in lo..<hi {
                        let page = Schema.pageRowID(vecRowID: rowids[r])
                        if let excludingDoc {
                            if page / Schema.pagesPerDocLimit == excludingDoc {
                                continue
                            }
                        }
                        if page == excludingPage { continue }
                        let s = Self.dot(base + r * dim, q, dim)
                        top.offer(Entry(score: s, index: Int32(r)))
                    }
                    partsBase[t] = top.entries
                }
            }
        }
        return partials.flatMap { $0 }
    }

    /// Accès en lecture au vecteur d'un rang (tests et diagnostics).
    public func withVector<T>(at index: Int,
                              _ body: (UnsafeBufferPointer<Int8>) -> T) -> T {
        data.withUnsafeBufferPointer { buf in
            body(UnsafeBufferPointer(start: buf.baseAddress! + index * dim,
                                     count: dim))
        }
    }

    // MARK: - Noyau

    private struct Entry { var score: Int32; var index: Int32 }

    /// Top-k borné par insertion dans un tableau trié croissant (k ≤ ~500 :
    /// l'insertion amortie bat un tas, la garde `worst` filtre 99 % des lignes).
    private struct TopK {
        let k: Int
        var entries: [Entry] = []
        var worst = Int32.min

        init(k: Int) { self.k = k; entries.reserveCapacity(k + 1) }

        mutating func offer(_ e: Entry) {
            if entries.count < k {
                entries.append(e)
                if entries.count == k {
                    entries.sort { $0.score < $1.score }
                    worst = entries[0].score
                }
            } else if e.score > worst {
                entries[0] = e
                var i = 0
                while i + 1 < k && entries[i].score > entries[i + 1].score {
                    entries.swapAt(i, i + 1)
                    i += 1
                }
                worst = entries[0].score
            }
        }
    }

    /// Vrai si la ligne est le vecteur nul (page trop courte pour être
    /// vectorisée, `EmbedRun.minChars`). Appelé seulement quand le produit
    /// scalaire est nul : le surcoût est celui d'une poignée de lignes.
    @inline(__always)
    static func isZero(_ a: UnsafePointer<Int8>, _ d: Int) -> Bool {
        var i = 0
        while i < d {
            if a[i] != 0 { return false }
            i += 1
        }
        return true
    }

    @inline(__always)
    static func dot(_ a: UnsafePointer<Int8>, _ b: UnsafePointer<Int8>,
                    _ d: Int) -> Int32 {
        var acc = SIMD16<Int32>()
        var i = 0
        while i + 64 <= d {
            for j in stride(from: 0, to: 64, by: 16) {
                let va = SIMD16<Int8>(UnsafeBufferPointer(start: a + i + j, count: 16))
                let vb = SIMD16<Int8>(UnsafeBufferPointer(start: b + i + j, count: 16))
                acc &+= SIMD16<Int32>(truncatingIfNeeded: va)
                    &* SIMD16<Int32>(truncatingIfNeeded: vb)
            }
            i += 64
        }
        var s = acc.wrappedSum()
        while i < d { s &+= Int32(a[i]) &* Int32(b[i]); i += 1 }
        return s
    }
}
