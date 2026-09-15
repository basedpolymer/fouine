// EmbedModel.swift — identité et emplacement du modèle d'embeddings (§12).
// Propriété : A-Embed (hybride, 01/09/2026).
//
// Le modèle N'EST PAS embarqué dans le binaire (235 Mo) : il vit dans
// ~/Library/Application Support/Fouine/models/<model_id>/ et se produit avec
// Tools/convert_e5.py. `meta.json` décrit ses dimensions et ses préfixes ;
// `vocab.json` porte le vocabulaire Unigram ; `E5Small.mlmodelc` le réseau.

import Foundation

/// meta.json du répertoire de modèle (écrit par Tools/convert_e5.py).
public struct EmbedModelMeta: Codable, Sendable {
    public let model_id: String
    public let revision: Int
    public let dim: Int
    public let seq: Int
    public let bos_id: Int32
    public let eos_id: Int32
    public let pad_id: Int32
    public let prefix_query: String
    public let prefix_passage: String
}

public enum EmbedPaths {
    /// Répertoire du modèle : `FOUINE_MODEL_DIR` (tests, recette) ou
    /// `~/Library/Application Support/Fouine/models/e5-small`.
    public static func modelDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["FOUINE_MODEL_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fouine/models/e5-small",
                                    isDirectory: true)
    }

    /// Vrai si le répertoire contient les trois pièces du modèle.
    public static func modelAvailable(at dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("E5Small.mlmodelc").path)
    }

    public static func loadMeta(at dir: URL) throws -> EmbedModelMeta {
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        return try JSONDecoder().decode(EmbedModelMeta.self, from: data)
    }

    /// Produit le cache binaire du vocabulaire (`vocab.bin`) à côté du modèle,
    /// et rend vrai s'il est bien là ensuite.
    ///
    /// POURQUOI À L'INSTALLATION (UX-13). Le cache est produit par le PREMIER
    /// chargement du tokenizer — c'est-à-dire, en pratique, par la première
    /// recherche par le sens de l'utilisateur, qui payait donc seule les ~5 s
    /// de lecture de `vocab.json` (audit A1m-15 : 250 000 `NSString` et
    /// 250 000 `NSNumber` matérialisés par `JSONSerialization`). Or personne
    /// n'attend qu'un téléchargement de 220 Mo soit instantané, et tout le
    /// monde attend qu'une recherche le soit : la seconde qu'on ajoute ici est
    /// invisible, celle qu'on retire là ne l'était pas.
    ///
    /// BEST-EFFORT, comme le cache lui-même : un répertoire en lecture seule ou
    /// un disque plein retombent sur le JSON, qui reste la source de vérité.
    /// Rien de ce qui se passe ici ne peut faire échouer une installation.
    ///
    /// N'exige PAS `modelAvailable` : le réseau CoreML n'entre pas en jeu, seuls
    /// `meta.json` (pour la révision, qui date le cache) et `vocab.json`.
    @discardableResult
    public static func warmVocabularyCache(at dir: URL) -> Bool {
        let vocabURL = dir.appendingPathComponent("vocab.json")
        guard let meta = try? loadMeta(at: dir),
              FileManager.default.fileExists(atPath: vocabURL.path)
        else { return false }
        guard (try? UnigramTokenizer(vocabURL: vocabURL,
                                     revision: meta.revision)) != nil
        else { return false }
        return FileManager.default.fileExists(
            atPath: UnigramTokenizer.cacheURL(besides: vocabURL).path)
    }
}

/// Moteur d'embeddings, abstrait pour que les tests substituent un moteur
/// déterministe (et qu'un futur modèle remplace e5-small sans toucher au reste).
public protocol EmbedEngine {
    var dimension: Int { get }
    /// Identité (modèle, révision) reflétée dans `vec_meta` : elle invalide les
    /// vecteurs existants quand elle change.
    var modelID: String { get }
    var revision: Int { get }
    /// Vecteurs UNITAIRES des passages (une entrée par texte).
    func embedPassages(_ texts: [String]) throws -> [[Float]]
    /// Vecteur UNITAIRE de la requête.
    func embedQuery(_ text: String) throws -> [Float]
}
