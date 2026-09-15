// VocabularyCacheTests.swift — le cache binaire du vocabulaire (audit A1m-15).
// Propriété : A-Embed.
//
// Lire `vocab.json` pesait 4,9 à 7,0 s sur les ~6 s d'ouverture du moteur —
// plus de 80 % du temps d'une recherche hybride en ligne de commande. Ce n'est
// pas la taille du fichier (9,3 Mo) mais sa FORME : `JSONSerialization`
// matérialise 250 000 `NSString` et 250 000 `NSNumber` avant qu'on n'en garde
// qu'une chaîne et un flottant. Le cache doit être RIGOUREUSEMENT équivalent —
// un tokenizer qui dérive casse la parité avec le modèle — et il doit se taire
// dès qu'il n'est plus sûr de lui.

import Foundation
import XCTest
@testable import FouineEmbed

final class VocabularyCacheTests: XCTestCase {

    private var directory: URL!
    private var vocabURL: URL!
    private var cacheURL: URL!

    /// Un vocabulaire minuscule mais représentatif : ASCII, accents, ▁ de
    /// Metaspace, et une pièce multi-octets qui éprouve l'encodage UTF-8 du
    /// cache.
    private static let pieces: [(String, Float)] = [
        ("<unk>", -0.0), ("<s>", -0.0), ("</s>", -0.0),
        ("▁", -3.5), ("▁le", -4.25), ("▁catalyseur", -9.5),
        ("é", -6.75), ("▁énergie", -8.125), ("氧", -12.5), ("ur", -7.0),
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-vocab-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        vocabURL = directory.appendingPathComponent("vocab.json")
        cacheURL = UnigramTokenizer.cacheURL(besides: vocabURL)
        try writeVocabulary(Self.pieces)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeVocabulary(_ entries: [(String, Float)]) throws {
        let root: [String: Any] = [
            "vocab": entries.map { [$0.0, Double($0.1)] as [Any] },
            "unk_id": 0,
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: vocabURL)
    }

    private func encode(_ tokenizer: UnigramTokenizer, _ text: String) -> [Int32] {
        tokenizer.encode(text, maxTokens: 32, bos: 1, eos: 2)
    }

    // MARK: - Équivalence

    func testTheCacheIsWrittenOnceAndReadBackIdentically() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        let fromJSON = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path),
                      "le premier chargement pose le cache")

        let fromCache = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        for text in ["le catalyseur", "énergie", "氧 ur", "", "  le   ",
                     "catalyseur inconnu ☃"] {
            XCTAssertEqual(encode(fromCache, text), encode(fromJSON, text),
                           "le cache doit être RIGOUREUSEMENT équivalent au "
                           + "JSON — texte : « \(text) »")
        }
    }

    /// `revision: nil` n'écrit ni ne lit : c'est le chemin JSON pur, celui que
    /// le test de parité avec Hugging Face doit continuer d'éprouver.
    func testNoRevisionMeansNoCacheAtAll() throws {
        _ = try UnigramTokenizer(vocabURL: vocabURL, revision: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    // MARK: - Invalidation

    func testADifferentModelRevisionIgnoresTheCache() throws {
        _ = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        let stamp = try Data(contentsOf: cacheURL)

        // Nouveau vocabulaire, nouvelle révision : le cache est refait, et le
        // tokenizer suit le NOUVEAU fichier.
        try writeVocabulary(Self.pieces + [("▁inédit", -5.0)])
        let tokenizer = try UnigramTokenizer(vocabURL: vocabURL, revision: 2)
        XCTAssertNotEqual(try Data(contentsOf: cacheURL), stamp)
        XCTAssertEqual(encode(tokenizer, "inédit").count, 3,
                       "<s> + ▁inédit + </s> : la nouvelle pièce est connue")
    }

    /// Un vocabulaire remplacé SANS changer de révision — un modèle reconstruit
    /// à la main par `Tools/convert_e5.py` — ne doit pas ressusciter l'ancien
    /// vocabulaire. La taille du fichier source est donc dans l'empreinte.
    func testAReplacedVocabularyAtTheSameRevisionInvalidatesTheCache() throws {
        _ = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        try writeVocabulary(Self.pieces + [("▁substitution", -5.0)])
        let tokenizer = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        XCTAssertEqual(encode(tokenizer, "substitution").count, 3)
    }

    /// Un cache tronqué (disque plein), d'un autre format, ou du bruit : on
    /// retombe sur le JSON, qui reste la seule source de vérité. Jamais une
    /// exception, jamais un vocabulaire à moitié lu.
    func testACorruptedCacheFallsBackToTheJSON() throws {
        let reference = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        let good = try Data(contentsOf: cacheURL)

        for corrupted in [Data(good.prefix(40)),
                          Data(good.prefix(good.count - 3)),
                          Data(repeating: 0x2A, count: good.count),
                          Data()] {
            try corrupted.write(to: cacheURL)
            let tokenizer = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
            XCTAssertEqual(encode(tokenizer, "le catalyseur"),
                           encode(reference, "le catalyseur"))
        }
    }

    // MARK: - Production à l'installation (UX-13)

    /// Le cache était produit par le PREMIER chargement du tokenizer,
    /// c'est-à-dire par la première recherche par le sens de l'utilisateur :
    /// c'est elle, et elle seule, qui payait les ~5 s de lecture de
    /// `vocab.json`. `warmVocabularyCache` le produit à l'installation du
    /// modèle, où personne ne compte les secondes.
    func testWarmingProducesTheCacheFromAModelDirectory() throws {
        try writeMeta(revision: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        XCTAssertTrue(EmbedPaths.warmVocabularyCache(at: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // Et il est BON : un tokenizer qui le relit encode comme le JSON.
        let fromCache = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        let fromJSON = try UnigramTokenizer(vocabURL: vocabURL, revision: nil)
        XCTAssertEqual(encode(fromCache, "le catalyseur"),
                       encode(fromJSON, "le catalyseur"))
    }

    /// La révision vient de `meta.json` : sans lui, on ne sait pas dater le
    /// cache, donc on n'en écrit pas — plutôt que d'en écrire un qu'on ne
    /// saurait pas invalider.
    func testWarmingWithoutMetaDoesNothing() throws {
        XCTAssertFalse(EmbedPaths.warmVocabularyCache(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    /// BEST-EFFORT : un répertoire en lecture seule rend `false` et ne jette
    /// rien. Une installation de 220 Mo ne doit pas échouer pour un confort.
    func testWarmingAReadOnlyDirectoryFailsQuietly() throws {
        try writeMeta(revision: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
        }
        XCTAssertFalse(EmbedPaths.warmVocabularyCache(at: directory))
    }

    /// Un `meta.json` minimal, celui qu'écrit `Tools/convert_e5.py`.
    private func writeMeta(revision: Int) throws {
        let meta: [String: Any] = [
            "model_id": "e5-small-test", "revision": revision, "dim": 8,
            "seq": 32, "bos_id": 1, "eos_id": 2, "pad_id": 3,
            "prefix_query": "query: ", "prefix_passage": "passage: ",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: directory.appendingPathComponent("meta.json"))
    }

    /// Un répertoire de modèle en lecture seule ne doit pas faire échouer le
    /// chargement : le cache est un confort, pas une dépendance.
    func testAReadOnlyModelDirectoryStillLoads() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
        }
        let tokenizer = try UnigramTokenizer(vocabURL: vocabURL, revision: 1)
        XCTAssertEqual(encode(tokenizer, "le catalyseur").count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
