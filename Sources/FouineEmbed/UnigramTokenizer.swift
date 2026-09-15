// UnigramTokenizer.swift — tokenizer SentencePiece Unigram de XLM-RoBERTa
// (multilingual-e5-small), réimplémenté sans dépendance. Propriété : A-Embed.
//
// Pipeline reproduit (tokenizer.json du modèle, vérifié par les vecteurs de
// parité de Tools/convert_e5.py) :
//   1. normalisation NFKC (approximation Swift du charsmap précompilé de
//      SentencePiece — identique sur du texte latin courant) ;
//   2. Metaspace : chaque espace devient ▁ (U+2581), préfixe ▁ systématique
//      (`prepend_scheme: always`), découpage par mot (`split: true`) ;
//   3. Viterbi Unigram par mot : segmentation de log-probabilité maximale ;
//   4. caractères hors vocabulaire -> <unk>, fusionnés par plage consécutive.

import Foundation

public final class UnigramTokenizer {

    private let pieces: [String: (id: Int32, score: Float)]
    private let unkID: Int32
    private let unkScore: Float
    private let maxPieceLength: Int

    /// Charge `vocab.json` : `{"vocab": [[pièce, log-prob], …], "unk_id": n}`,
    /// la position dans la liste est l'identifiant du jeton.
    ///
    /// CACHE BINAIRE (audit A1m-15). Ce chargement était le POSTE PRINCIPAL de
    /// la recherche hybride en ligne de commande — mesuré à **4,8 s sur les
    /// 6,5 s** d'ouverture du moteur (binaire debug, machine chargée), contre
    /// 0,9 à 1,8 s pour l'ouverture du réseau par CoreML. La cause n'est pas la
    /// taille du fichier (9,3 Mo) mais sa FORME : `JSONSerialization` matérialise
    /// 250 000 `NSString` et 250 000 `NSNumber` avant qu'on n'en garde rien
    /// d'autre qu'une chaîne et un flottant.
    ///
    /// Au premier chargement, la table est donc réécrite à côté du modèle sous
    /// une forme qui se lit d'un seul balayage : `vocab.bin`. Il est INVALIDÉ
    /// par la révision du modèle **et** par la taille de `vocab.json` — un
    /// vocabulaire remplacé sans changement de révision (un modèle reconstruit
    /// à la main par `Tools/convert_e5.py`) doit reproduire le cache, pas le
    /// réutiliser. Sa production comme sa lecture sont en BEST-EFFORT : un
    /// répertoire de modèle en lecture seule, un cache tronqué par un disque
    /// plein ou un format d'une autre version retombent silencieusement sur le
    /// JSON, qui reste la seule source de vérité.
    ///
    /// `revision: nil` désactive le cache — c'est ce que font les tests qui
    /// veulent éprouver le chemin JSON lui-même.
    public convenience init(vocabURL: URL) throws {
        try self.init(vocabURL: vocabURL, revision: nil)
    }

    public init(vocabURL: URL, revision: Int?) throws {
        let sourceBytes = (try? FileManager.default
            .attributesOfItem(atPath: vocabURL.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        let cacheURL = Self.cacheURL(besides: vocabURL)

        if let revision,
           let cached = Self.readCache(at: cacheURL, revision: revision,
                                       sourceBytes: sourceBytes) {
            self.pieces = cached.table
            self.unkID = cached.unkID
            self.unkScore = cached.minScore - 10
            self.maxPieceLength = cached.maxLength
            return
        }

        let data = try Data(contentsOf: vocabURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vocab = root["vocab"] as? [[Any]],
              let unk = root["unk_id"] as? Int else {
            throw FouineEmbedError.model("unreadable vocab.json: \(vocabURL.path)")
        }
        var table: [String: (Int32, Float)] = [:]
        table.reserveCapacity(vocab.count)
        var ordered: [(String, Float)] = []
        ordered.reserveCapacity(vocab.count)
        var maxLen = 1
        var minScore = Float(0)
        for (id, entry) in vocab.enumerated() {
            guard entry.count == 2, let piece = entry[0] as? String,
                  let score = (entry[1] as? NSNumber)?.floatValue else { continue }
            // En cas de doublon (n'arrive pas dans XLM-R), le premier id gagne,
            // comme dans SentencePiece.
            if table[piece] == nil { table[piece] = (Int32(id), score) }
            ordered.append((piece, score))
            maxLen = max(maxLen, piece.count)
            minScore = min(minScore, score)
        }
        self.pieces = table
        self.unkID = Int32(unk)
        // Pénalité <unk> de SentencePiece : min(score) - 10.
        self.unkScore = minScore - 10
        self.maxPieceLength = maxLen

        if let revision {
            Self.writeCache(at: cacheURL, revision: revision,
                            sourceBytes: sourceBytes, unkID: Int32(unk),
                            maxLength: maxLen, minScore: minScore,
                            entries: ordered)
        }
    }

    // MARK: - Cache binaire

    /// `vocab.bin`, à côté du modèle : `fouine model remove` efface le
    /// répertoire entier, le cache part donc avec ce qu'il décrit.
    static func cacheURL(besides vocabURL: URL) -> URL {
        vocabURL.deletingLastPathComponent().appendingPathComponent("vocab.bin")
    }

    /// « FOUVOC » + version de format. Un format futur change ce nombre : un
    /// cache d'une autre version est ignoré, jamais mal relu.
    private static let cacheMagic: [UInt8] =
        Array("FOUVOC".utf8) + [0x00, 0x02]

    private static func readCache(at url: URL, revision: Int, sourceBytes: Int64)
        -> (table: [String: (id: Int32, score: Float)], unkID: Int32,
            minScore: Float, maxLength: Int)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 36 else { return nil }
        return data.withUnsafeBytes { raw -> (table: [String: (id: Int32, score: Float)],
                                              unkID: Int32, minScore: Float,
                                              maxLength: Int)? in
            var cursor = 0
            func take(_ n: Int) -> UnsafeRawPointer? {
                guard cursor + n <= raw.count else { return nil }
                let p = raw.baseAddress! + cursor
                cursor += n
                return p
            }
            guard let magic = take(cacheMagic.count) else { return nil }
            for (i, byte) in cacheMagic.enumerated()
            where magic.load(fromByteOffset: i, as: UInt8.self) != byte {
                return nil
            }
            guard let header = take(4 + 8 + 4 + 4 + 4 + 4) else { return nil }
            let storedRevision = header.loadUnaligned(as: Int32.self)
            let storedBytes = header.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            let unkID = header.loadUnaligned(fromByteOffset: 12, as: Int32.self)
            let count = Int(header.loadUnaligned(fromByteOffset: 16, as: Int32.self))
            // `maxLength` et `minScore` sont STOCKÉS, pas recalculés : les
            // recalculer, c'est 250 000 `String.count` (un comptage de grappes,
            // donc un parcours par chaîne) sur un chemin qu'on cherche
            // justement à rendre gratuit.
            let maxLen = Int(header.loadUnaligned(fromByteOffset: 20, as: Int32.self))
            let minScore = header.loadUnaligned(fromByteOffset: 24, as: Float.self)
            guard storedRevision == Int32(revision), storedBytes == sourceBytes,
                  count >= 0, count < 5_000_000, maxLen >= 1 else { return nil }

            var table: [String: (id: Int32, score: Float)] = [:]
            table.reserveCapacity(count)
            for id in 0..<count {
                guard let lengthPtr = take(4) else { return nil }
                let length = Int(lengthPtr.loadUnaligned(as: Int32.self))
                guard length >= 0, let bytes = take(length),
                      let scorePtr = take(4) else { return nil }
                let piece = String(decoding: UnsafeRawBufferPointer(
                    start: bytes, count: length), as: UTF8.self)
                let score = scorePtr.loadUnaligned(as: Float.self)
                if table[piece] == nil { table[piece] = (Int32(id), score) }
            }
            return (table, unkID, minScore, maxLen)
        }
    }

    private static func writeCache(at url: URL, revision: Int, sourceBytes: Int64,
                                   unkID: Int32, maxLength: Int, minScore: Float,
                                   entries: [(String, Float)]) {
        var out = Data()
        out.reserveCapacity(entries.count * 12 + 32)
        out.append(contentsOf: cacheMagic)
        withUnsafeBytes(of: Int32(revision)) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: sourceBytes) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: unkID) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(entries.count)) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(maxLength)) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: minScore) { out.append(contentsOf: $0) }
        for (piece, score) in entries {
            let utf8 = Array(piece.utf8)
            withUnsafeBytes(of: Int32(utf8.count)) { out.append(contentsOf: $0) }
            out.append(contentsOf: utf8)
            withUnsafeBytes(of: score) { out.append(contentsOf: $0) }
        }
        // Écriture atomique : deux processus peuvent produire le cache en même
        // temps (l'app, la CLI, le serveur MCP), et un lecteur ne doit jamais
        // tomber sur un fichier à moitié écrit.
        try? out.write(to: url, options: .atomic)
    }

    /// Identifiants du texte, `<s>` et `</s>` compris, tronqués à `maxTokens`
    /// (le `</s>` survit toujours à la troncature, comme chez Hugging Face).
    public func encode(_ text: String, maxTokens: Int,
                       bos: Int32, eos: Int32) -> [Int32] {
        var body: [Int32] = []
        for word in metaspaceWords(text) {
            body.append(contentsOf: viterbi(word))
        }
        if body.count > maxTokens - 2 { body.removeLast(body.count - (maxTokens - 2)) }
        return [bos] + body + [eos]
    }

    // MARK: - Metaspace

    /// Mots de la forme `▁…`, fidèles au normaliseur SentencePiece
    /// (`remove_extra_whitespaces` : une SUITE de blancs vaut UN espace —
    /// vérifié par les vecteurs de parité) puis à Metaspace (`replacement: ▁`,
    /// `prepend_scheme: always`, `split: true`) :
    ///   « a b »   -> « ▁a▁b » -> [▁a, ▁b]
    ///   « a   b » -> « ▁a▁b » -> [▁a, ▁b]
    ///   « a b  »  -> « ▁a▁b▁ » -> [▁a, ▁b, ▁]
    /// Un texte vide ne produit rien (comme Hugging Face).
    private func metaspaceWords(_ text: String) -> [[Character]] {
        let normalized = text.precomposedStringWithCompatibilityMapping
        guard !normalized.isEmpty else { return [] }
        var replaced: [Character] = []
        replaced.reserveCapacity(normalized.count + 1)
        var lastWasBlank = false
        for ch in normalized {
            if ch.isWhitespace {
                if !lastWasBlank { replaced.append("▁") }
                lastWasBlank = true
            } else {
                replaced.append(ch)
                lastWasBlank = false
            }
        }
        if replaced.first != "▁" { replaced.insert("▁", at: 0) }

        var words: [[Character]] = []
        var current: [Character] = []
        for ch in replaced {
            if ch == "▁" {
                if !current.isEmpty { words.append(current) }
                current = ["▁"]
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: - Viterbi Unigram

    /// Segmentation de log-probabilité maximale d'un mot (▁ compris).
    /// Les positions inatteignables consomment un caractère en <unk> ;
    /// les <unk> consécutifs sont fusionnés (convention Hugging Face).
    private func viterbi(_ word: [Character]) -> [Int32] {
        let n = word.count
        guard n > 0 else { return [] }
        var bestScore = [Float](repeating: -.infinity, count: n + 1)
        var backLen = [Int](repeating: 0, count: n + 1)
        var backID = [Int32](repeating: 0, count: n + 1)
        bestScore[0] = 0
        for end in 1...n {
            let maxLen = min(maxPieceLength, end)
            for len in 1...maxLen {
                let start = end - len
                guard bestScore[start] > -.infinity else { continue }
                let piece = String(word[start..<end])
                guard let (id, score) = pieces[piece] else { continue }
                let candidate = bestScore[start] + score
                if candidate > bestScore[end] {
                    bestScore[end] = candidate
                    backLen[end] = len
                    backID[end] = id
                }
            }
            if bestScore[end] == -.infinity {
                // Caractère hors vocabulaire : <unk> d'un caractère.
                bestScore[end] = bestScore[end - 1] + unkScore
                backLen[end] = 1
                backID[end] = unkID
            }
        }
        var out: [Int32] = []
        var pos = n
        while pos > 0 {
            out.append(backID[pos])
            pos -= backLen[pos]
        }
        out.reverse()
        // Fusion des <unk> consécutifs.
        var merged: [Int32] = []
        merged.reserveCapacity(out.count)
        for id in out where !(id == unkID && merged.last == unkID) {
            merged.append(id)
        }
        return merged
    }
}

public enum FouineEmbedError: Error, CustomStringConvertible {
    case model(String)
    case inference(String)

    public var description: String {
        switch self {
        case .model(let m): return "embedding model: \(m)"
        case .inference(let m): return "inference: \(m)"
        }
    }
}
