// Wiring.swift — les QUATRE fabriques de câblage. Propriété : A-Core.
//
// Fichier volontairement MINUSCULE et sans logique : l'orchestrateur remplace
// les corps à l'intégration (A-Ingest en vague 1, A-OCR en vague 2) sans toucher
// au reste de la CLI.

import Foundation
import FouineCore
import FouineCrawl
import FouineExtract
import FouineOCR

// Câblé par l'orchestrateur à l'intégration de la vague 1.
// Le crawler ne retient que les extensions que le registre sait traiter.
func makeCrawler(store: (any IndexStore)? = nil) -> any Crawler {
    var extensions = DefaultExtractorRegistry.supportedExtensions
    if let settingsStore = store as? (any SettingsStore) {
        let (snapshot, warning) = SettingsSnapshot.load(from: settingsStore)
        if let warning { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        if snapshot.extractImages {
            extensions.formUnion(DefaultExtractorRegistry.imageExtensions)
        }
        if snapshot.extractMedia {
            extensions.formUnion(DefaultExtractorRegistry.mediaExtensions)
        }
    } else {
        let environment = ProcessInfo.processInfo.environment
        func armed(_ variable: String) -> Bool {
            guard let raw = environment[variable] else { return false }
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        if armed("FOUINE_EXTRACT_IMAGES") {
            extensions.formUnion(DefaultExtractorRegistry.imageExtensions)
        }
        if armed("FOUINE_EXTRACT_MEDIA") {
            extensions.formUnion(DefaultExtractorRegistry.mediaExtensions)
        }
    }
    return FouineCrawler(store: store, indexableExtensions: extensions)
}

/// Même réglage `extract.images` que `makeCrawler` : un registre qui ignore
/// les images pendant que le crawler les ramasse les ferait toutes refuser.
func makeExtractorRegistry(store: (any IndexStore)? = nil) -> any ExtractorRegistry {
    if let settingsStore = store as? (any SettingsStore) {
        let (snapshot, warning) = SettingsSnapshot.load(from: settingsStore)
        if let warning { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        return DefaultExtractorRegistry(extractImages: snapshot.extractImages,
                                        extractMedia: snapshot.extractMedia,
                                        media: MediaOptions(snapshot: snapshot))
    }
    return DefaultExtractorRegistry()
}

func ocrAvailable() -> Bool { true }

// Câblé par l'orchestrateur à l'intégration de la vague 2.
func runOCRCommand(store: GRDBStore, jobs: Int, budgetMinutes: Int?,
                   prioFolder: String?, only: String?) throws {
    let outcome = try OCRRun.run(store: store, jobs: jobs, budgetMinutes: budgetMinutes,
                                 prioFolder: prioFolder, only: only)
    if case .budgetExhausted = outcome {
        // Idem (C2-03) : seule la file est demandée ici.
        throw FouineError.budgetExhausted(
            remaining: (try? store.ocrQueueLength()) ?? 0)
    }
}
