// SpotlightPolicy.swift — QUELS documents Fouine donne à Spotlight (lot INT-S1).
// Propriété : A-Core.
//
// LA PROMESSE DU PRODUIT EST UNE SOUSTRACTION. « Spotlight n'a jamais lu vos
// scans, Fouine si » ne vaut que si Fouine donne à Spotlight ce qu'il ne sait
// PAS lire — et rien d'autre. Donner un `.docx` que l'importateur de macOS lit
// déjà produirait deux résultats pour un seul fichier, dont l'un sous le nom
// de Fouine : l'utilisateur y verrait un doublon, pas un service. D'où la
// portée par défaut, « seulement ce que Spotlight ne lit pas lui-même », et
// l'ensemble ci-dessous, qui est MESURÉ et non deviné.
//
// COMMENT L'ENSEMBLE A ÉTÉ MESURÉ (08/09/2026, macOS 15.6 / Darwin 24.6).
// `mdimport -t -d2 <fichier>` imprime ce que les importateurs Spotlight
// tirent d'un fichier : une extension est AVEUGLE quand aucun
// `kMDItemTextContent` n'apparaît, ou qu'il annonce « 0 characters ». La
// mesure a porté sur les 37 fixtures de `Tests/Fixtures/corpus` PUIS, pour
// chaque refus, sur un VRAI fichier du Mac trouvé par `mdfind` : les fixtures
// sont fabriquées à la main, et un importateur qui refuse un `.docx`
// synthétique de 523 octets lit parfaitement un vrai document Word (4 797
// caractères rendus). Sans cette seconde passe, `docx`, `xlsx`, `pptx`, `ppt`
// et `xls` seraient entrés ici par erreur, et Fouine doublerait la moitié des
// résultats de Spotlight.
//
// Résultat, avec le nombre de caractères rendus par macOS :
//   · AVEUGLES  : djvu (0), cbz (0), cbr (0), epub (0), ai (0), sketch (0),
//                 fig (0), indd (0) ;
//   · LUS       : docx 4 797 · xlsx 761 · pptx 26 827 · ppt 2 750 · doc 3 457 ·
//                 odt 357 · rtf · pdf 12 347 · html · md · txt · csv · json ·
//                 xml · tex · log · py · plist · webarchive · mbox · emlx ·
//                 olk15msgsource ;
//   · iWork (`pages`, `numbers`, `key`) : refusés par les fixtures, aucun vrai
//     document sous la main pour trancher. NON inscrits : un doublon est pire
//     qu'un document que Spotlight trouvait déjà.
//   · Un PDF SCANNÉ (`notes-scannees.pdf`) rend « 0 characters » alors qu'un
//     PDF ordinaire en rend 1 770 : ce n'est donc pas l'extension qui décide
//     pour lui, mais la PROVENANCE de son texte — c'est tout l'objet de
//     `isScanned` ci-dessous, et le cœur du sujet.

import Foundation
import FouineCore

/// Ce que Fouine donne à Spotlight, et jusqu'où.
public struct SpotlightPolicy: Sendable, Equatable {

    /// Donner, ou ne rien donner du tout (`spotlight.enabled`).
    public let enabled: Bool
    /// Tout donner, y compris ce que Spotlight lit déjà
    /// (`spotlight.all_documents`).
    public let allDocuments: Bool
    /// Plafond du texte donné par document, en Kio (`spotlight.text_kb`).
    public let textKB: Int

    public init(enabled: Bool = true, allDocuments: Bool = false,
                textKB: Int = 1_024) {
        self.enabled = enabled
        self.allDocuments = allDocuments
        self.textKB = textKB
    }

    /// La politique telle que les réglages la disent. Les trois exécutables la
    /// construisent ainsi, et pas autrement.
    public init(_ snapshot: SettingsSnapshot) {
        self.init(enabled: snapshot.spotlightEnabled,
                  allDocuments: snapshot.spotlightAllDocuments,
                  textKB: snapshot.spotlightTextKB)
    }

    /// Le plafond en OCTETS UTF-8 : c'est la taille que Spotlight recopiera
    /// dans son index, pas un nombre de caractères.
    public var textLimitBytes: Int { textKB * 1_024 }

    /// Les extensions dont macOS ne tire aucun texte (voir l'en-tête : mesuré,
    /// le 08/09/2026, sur de vrais fichiers).
    public static let blindExtensions: Set<String> = [
        "djvu", "cbz", "cbr", "epub", "ai", "sketch", "fig", "indd",
    ]

    /// Le texte de ce document vient-il d'une reconnaissance de caractères ?
    ///
    /// Deux signes, et le second sauve le premier : `ocr_state` dit ce que la
    /// file OCR sait du document, mais retombe à `notNeeded` quand `upsertDoc`
    /// voit le fichier changer. Une page de provenance scannée
    /// (`scannedPages`) reste, elle, la trace factuelle qu'au moins une page a
    /// été OCRisée.
    public static func isScanned(_ doc: DocumentChange) -> Bool {
        doc.scannedPages > 0 || doc.ocrState != .notNeeded
    }

    /// Le texte de ce document a-t-il été mis par écrit depuis un son ?
    ///
    /// Spotlight lit le titre et l'artiste d'un enregistrement, jamais ce qui
    /// s'y dit : une transcription est donc, comme un scan, un texte qu'il n'a
    /// pas. Elle partait déjà vers Spotlight, mais PAR ACCIDENT — le compte des
    /// pages scannées filtrait sur `src != 0`. Depuis IX2 les deux comptes sont
    /// séparés, et la décision est écrite ici plutôt que cachée dans un SQL.
    /// Le même enregistrement sans transcription (titres, chapitres : `src =
    /// 0`) ne part pas : macOS lit déjà ses métadonnées.
    public static func isTranscribed(_ doc: DocumentChange) -> Bool {
        doc.transcribedPages > 0
    }

    /// Ce document doit-il être donné à Spotlight ?
    ///
    /// La condition « au moins une page de texte » n'est PAS ici : elle se
    /// prouve en lisant les pages, ce que fait `SpotlightSync` juste après —
    /// un document sans texte ne produit pas d'élément. Ce qui se décide ici
    /// est la PORTÉE, et elle se décide sans lire une seule page.
    public func includes(_ doc: DocumentChange) -> Bool {
        guard enabled, doc.state == .extracted else { return false }
        if allDocuments { return true }
        return Self.isScanned(doc) || Self.isTranscribed(doc)
            || Self.blindExtensions.contains(doc.ext.lowercased())
    }
}
