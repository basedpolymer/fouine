// E5Encoder.swift — inférence CoreML de multilingual-e5-small. Propriété : A-Embed.
//
// Le réseau (E5Small.mlmodelc, converti par Tools/convert_e5.py) rend les états
// cachés [1, seq, dim] ; le mean pooling masqué et la normalisation L2 se font
// ici, conformément à l'usage e5. Les préfixes « query: » / « passage: » sont
// OBLIGATOIRES — le modèle a été entraîné avec, les omettre dégrade le rappel.

import Accelerate
import CoreML
import Foundation

/// Ce que le chargement a coûté, poste par poste (audit A1m-15).
///
/// « 8,8 s de chargement de modèle sur 11,7 s » ne dit pas QUOI optimiser :
/// `init` fait deux choses très différentes — lire un vocabulaire de 9,3 Mo et
/// faire ouvrir un réseau à CoreML —, et l'une des deux se répare, l'autre non.
/// Le banc les sépare.
public struct E5LoadTimings: Sendable {
    public let vocabularyMS: Double
    public let modelMS: Double
    public var totalMS: Double { vocabularyMS + modelMS }
}

public final class E5Encoder: EmbedEngine {

    private let model: MLModel
    private let tokenizer: UnigramTokenizer
    private let meta: EmbedModelMeta

    /// Publié par `fouine embed --bench` : la répartition, pas seulement le
    /// total.
    public let loadTimings: E5LoadTimings

    public var dimension: Int { meta.dim }
    public var modelID: String { meta.model_id }
    public var revision: Int { meta.revision }

    public init(modelDir: URL) throws {
        guard EmbedPaths.modelAvailable(at: modelDir) else {
            // Depuis le palier 3 (audit D6), le geste à faire n'est plus « montez
            // un venv Python et convertissez le modèle » mais une commande :
            // l'archive convertie est publiée en asset de release. Reconstruire
            // le modèle soi-même reste possible (Tools/convert_e5.py), ce n'est
            // simplement plus le chemin normal.
            throw FouineEmbedError.model(
                "model missing from \(modelDir.path) — install it with "
                + "`fouine model download`")
        }
        self.meta = try EmbedPaths.loadMeta(at: modelDir)
        let t0 = Date()
        self.tokenizer = try UnigramTokenizer(
            vocabURL: modelDir.appendingPathComponent("vocab.json"),
            revision: meta.revision)
        let t1 = Date()
        let config = MLModelConfiguration()
        config.computeUnits = Self.computeUnits()
        self.model = try MLModel(
            contentsOf: modelDir.appendingPathComponent("E5Small.mlmodelc"),
            configuration: config)
        let t2 = Date()
        self.loadTimings = E5LoadTimings(
            vocabularyMS: t1.timeIntervalSince(t0) * 1000.0,
            modelMS: t2.timeIntervalSince(t1) * 1000.0)
    }

    /// Back-end de calcul retenu, et son NOM.
    ///
    /// `FOUINE_EMBED_COMPUTE` = cpu | gpu | all (défaut all) : sur Mac Intel,
    /// le fp16 n'est natif que sur le GPU — l'écart se mesure au `--bench`. Le
    /// défaut reste `.all` : la contre-expertise D2 a mesuré la campagne réelle
    /// à 6,57 p/s contre 5,68 au banc CPU, et a donc INFIRMÉ la bascule que C2
    /// recommandait (C2-04). Ce qui manquait n'était pas un autre réglage,
    /// c'était de DIRE lequel tourne : `EmbedRun` le journalise en tête de
    /// campagne.
    public static func computeUnitsName(
        _ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        switch environment["FOUINE_EMBED_COMPUTE"] {
        case "cpu": return "cpu"
        case "gpu": return "cpu+gpu"
        default:    return "all"
        }
    }

    static func computeUnits(
        _ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MLComputeUnits {
        switch environment["FOUINE_EMBED_COMPUTE"] {
        case "cpu": return .cpuOnly
        case "gpu": return .cpuAndGPU
        default:    return .all
        }
    }

    public func embedPassages(_ texts: [String]) throws -> [[Float]] {
        try embedRaw(texts.map { meta.prefix_passage + $0 })
    }

    public func embedQuery(_ text: String) throws -> [Float] {
        guard let v = try embedRaw([meta.prefix_query + text]).first else {
            throw FouineEmbedError.inference("no vector returned for the query")
        }
        return v
    }

    // MARK: - Inférence

    /// Textes DÉJÀ préfixés (« query: » / « passage: »). Interne pour que les
    /// tests de parité comparent aux références Python sans double préfixe.
    func embedRaw(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var providers: [MLFeatureProvider] = []
        var masks: [[Int32]] = []
        providers.reserveCapacity(texts.count)
        for text in texts {
            let ids = tokenizer.encode(text, maxTokens: meta.seq,
                                       bos: meta.bos_id, eos: meta.eos_id)
            let idArray = try MLMultiArray(
                shape: [1, NSNumber(value: meta.seq)], dataType: .int32)
            let maskArray = try MLMultiArray(
                shape: [1, NSNumber(value: meta.seq)], dataType: .int32)
            let idPtr = idArray.dataPointer.bindMemory(to: Int32.self,
                                                       capacity: meta.seq)
            let maskPtr = maskArray.dataPointer.bindMemory(to: Int32.self,
                                                           capacity: meta.seq)
            var mask = [Int32](repeating: 0, count: meta.seq)
            for i in 0..<meta.seq {
                if i < ids.count {
                    idPtr[i] = ids[i]; maskPtr[i] = 1; mask[i] = 1
                } else {
                    idPtr[i] = meta.pad_id; maskPtr[i] = 0
                }
            }
            masks.append(mask)
            providers.append(try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: idArray),
                "attention_mask": MLFeatureValue(multiArray: maskArray),
            ]))
        }

        let batch = MLArrayBatchProvider(array: providers)
        let out = try model.predictions(fromBatch: batch)
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for i in 0..<out.count {
            guard let hidden = out.features(at: i)
                .featureValue(for: "hidden")?.multiArrayValue else {
                throw FouineEmbedError.inference("the “hidden” output is missing")
            }
            results.append(try pooled(hidden, mask: masks[i]))
        }
        return results
    }

    /// Mean pooling masqué + normalisation L2 (convention e5).
    private func pooled(_ hidden: MLMultiArray, mask: [Int32]) throws -> [Float] {
        let scalars = try Self.floats(of: hidden)            // [1, seq, dim] aplati
        let dim = meta.dim
        var acc = [Float](repeating: 0, count: dim)
        var count: Float = 0
        for t in 0..<meta.seq where mask[t] == 1 {
            let base = t * dim
            for d in 0..<dim { acc[d] += scalars[base + d] }
            count += 1
        }
        if count > 0 { for d in 0..<dim { acc[d] /= count } }
        var norm: Float = 0
        for d in 0..<dim { norm += acc[d] * acc[d] }
        norm = norm.squareRoot()
        if norm > 0 { for d in 0..<dim { acc[d] /= norm } }
        return acc
    }

    /// Scalaires d'un MLMultiArray en Float32. PAS de `MLShapedArray<Float>` :
    /// sa conversion depuis un tampon fp16 emprunte un chemin `Float16`
    /// indisponible sur x86_64 (SIGILL mesuré, Intel i5-8257U, macOS 15).
    /// Le fp16 est élargi par vImage, disponible partout.
    static func floats(of arr: MLMultiArray) throws -> [Float] {
        let count = arr.count
        switch arr.dataType {
        case .float32:
            return arr.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: Float.self),
                    count: count))
            }
        case .float16:
            return arr.withUnsafeBytes { raw in
                var out = [Float](repeating: 0, count: count)
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                    height: 1, width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<UInt16>.stride)
                out.withUnsafeMutableBytes { dstRaw in
                    var dst = vImage_Buffer(
                        data: dstRaw.baseAddress!,
                        height: 1, width: vImagePixelCount(count),
                        rowBytes: count * MemoryLayout<Float>.stride)
                    _ = vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                }
                return out
            }
        case .double:
            return arr.withUnsafeBytes { raw in
                UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: Double.self),
                    count: count).map(Float.init)
            }
        default:
            throw FouineEmbedError.inference(
                "unexpected output type: \(arr.dataType)")
        }
    }
}
