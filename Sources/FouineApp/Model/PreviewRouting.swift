// PreviewRouting.swift — par quelle voie un format se montre (lot PV1).
// Propriété : A-App.
//
// CE QUI MANQUAIT. Le PDF avait son lecteur, les archives de bandes dessinées
// et les documents Office leur page rendue en image, et TOUT LE RESTE — epub,
// Pages, rtf, html, courriels, sous-titres, sons, vidéos — montrait le TEXTE
// INDEXÉ. Utile (audit U4 : mieux vaut le texte qu'un panneau vide), mais ce
// n'est pas le document : une lettre mise en page, un tableau, une note
// manuscrite recopiée perdent tout ce qui n'est pas des lettres.
//
// macOS sait dessiner la plupart de ces formats : c'est le Coup d'œil, celui
// de la barre d'espace du Finder. `QLPreviewView` l'apporte DANS la fenêtre,
// sans ouvrir l'application d'origine et sans copier le fichier.
//
// LA DÉCISION EST PURE, ET ELLE EST ICI. `PreviewModel.resolveFile` enchaînait
// six conditions imbriquées qu'aucun test ne pouvait interroger sans base ni
// fichier ; la voie d'un format est maintenant une fonction d'une ligne, et
// c'est elle que `PreviewRoutingTests` éprouve.

import Foundation
import FouineExtract

/// Par quelle voie un document se montre.
enum PreviewRoute: Equatable {
    /// Le lecteur PDF, seul à savoir surligner sur la page elle-même.
    case pdf
    /// Une page RENDUE en image depuis le fichier (`FouinePageRenderer`).
    case image
    /// Un lecteur, et la transcription horodatée en dessous.
    case media
    /// Le Coup d'œil du système, qui DESSINE ce format.
    case quickLook
    /// Le texte indexé : le système ne dessine pas ce format, ou n'en montrerait
    /// que les mêmes caractères.
    case text

    /// Le mode proposé d'emblée. Le sélecteur « Document | Texte » de l'en-tête
    /// laisse passer de l'un à l'autre dans les deux cas.
    var showsDocumentFirst: Bool { self == .quickLook }
}

/// Ce que le Coup d'œil de macOS sait faire des formats que Fouine indexe.
enum QuickLookPreview {

    /// Les formats dont le Coup d'œil montre LE DOCUMENT — sa mise en page, ses
    /// images, ses couleurs — et pas seulement les caractères que l'aperçu
    /// texte affiche déjà.
    ///
    /// COMMENT CETTE LISTE A ÉTÉ ÉTABLIE (13/09/2026, lot PV1) : `qlmanage -p`
    /// sur chaque fichier de `Tests/Fixtures/corpus`, doublé d'une demande de
    /// vignette de CONTENU (`QLThumbnailGenerator`, `representationTypes:
    /// .thumbnail`), et recoupé avec la liste des générateurs installés
    /// (`qlmanage -m plugins`) — plusieurs fixtures sont des coquilles
    /// synthétiques que le générateur refuse alors qu'il sait lire les vrais
    /// fichiers (`.xls` : « Unsupported encryption method », `.docx` : « No
    /// package relationships »). C'est donc l'UTI réclamé par un générateur qui
    /// tranche, pas le sort d'une fixture.
    ///
    /// CE QUI N'Y EST PAS, ET POURQUOI :
    ///   · `txt`, `md`, `json`, `xml`, `plist`, `csv` de code, sources : le
    ///     Coup d'œil y montre les MÊMES caractères que l'aperçu texte, sans
    ///     les mots de la requête mis en évidence. En faire le mode par défaut
    ///     ne changerait que ça, en moins bien ;
    ///   · `epub` : aucun générateur ne réclame `org.idpf.epub-container` et
    ///     Livres n'apporte pas d'extension d'aperçu — le Coup d'œil n'en rend
    ///     que l'icône ;
    ///   · `djvu`, `sketch`, `mbox`, `ipynb`, `srt`, `vtt`, `tex`, `eml` : pas
    ///     de générateur (les cinq premiers n'ont même pas d'UTI déclaré) ;
    ///   · `docx`, `xlsx`, `pptx`, `cbz`, `cbr`, `fig`, `indd` et les images :
    ///     ils ont déjà leur page rendue en image, qui sait aller à LA page
    ///     trouvée — ce que le Coup d'œil ne sait pas faire.
    static let rendersNatively: Set<String> = [
        // Texte mis en page (Text.qlgenerator, Office.qlgenerator)
        "rtf", "rtfd", "doc", "odt",
        // Tableaux et présentations d'avant OOXML
        "xls", "ppt",
        // iWork : le PDF d'aperçu que Pages, Numbers et Keynote embarquent
        "pages", "numbers", "key",
        // Pages web et dessins vectoriels (Web.qlgenerator)
        "html", "htm", "webarchive", "svg",
        // Tableaux séparés par des virgules ou des tabulations : le Coup d'œil
        // en fait un TABLEAU, là où le texte indexé n'est qu'une suite de
        // lignes ponctuées de virgules
        "csv", "tsv",
        // Illustrator : la couche PDF du fichier (Illustrator.qlgenerator)
        "ai",
    ]
}

enum PreviewRouting {

    /// Les formats dont l'aperçu est une IMAGE rendue depuis le fichier.
    ///
    /// Les images seules et les maquettes Figma/InDesign s'y ajoutent (INT-F2) :
    /// pour elles, le texte en base est celui de la reconnaissance — le montrer
    /// à la place de la page reviendrait à cacher le document derrière sa
    /// transcription. `sketch` n'y est PAS : ses pages portent du texte natif,
    /// et c'est ce texte qui se lit.
    static let renderedAsImage: Set<String> =
        Set(["cbz", "cbr", "docx", "pptx", "xlsx"])
            .union(ImageExtractor.supportedExtensions)
            .union(DesignPreviewExtractor.supportedExtensions)

    /// Sons et vidéos.
    static let media: Set<String> = MediaExtractor.supportedExtensions

    /// La voie d'un format. `ext` est comparée en minuscules.
    static func route(ext: String) -> PreviewRoute {
        let ext = ext.lowercased()
        if ext == "pdf" { return .pdf }
        if media.contains(ext) { return .media }
        if renderedAsImage.contains(ext) { return .image }
        return QuickLookPreview.rendersNatively.contains(ext) ? .quickLook : .text
    }
}

/// Ce que le panneau montre d'un document que le Coup d'œil sait dessiner.
enum PreviewMode: String, CaseIterable, Identifiable {
    /// Le document tel que macOS le dessine.
    case document
    /// Le texte indexé, où les mots cherchés sont mis en évidence.
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .document: return String(localized: "Document")
        case .text:     return String(localized: "Text")
        }
    }
}

/// Le dernier mode choisi, POUR CETTE SESSION seulement.
///
/// PAS DANS LES PRÉFÉRENCES, et c'est délibéré : un réglage d'affichage qui
/// survit à l'extinction sans figurer nulle part dans les Réglages est une
/// surprise — on rouvre Fouine un mois plus tard, tous les documents
/// s'affichent autrement, et rien ne dit pourquoi. Tant que l'application est
/// ouverte, en revanche, quelqu'un qui vient de passer à « Texte » ne veut pas
/// le redemander au résultat suivant.
///
/// `nil` = personne n'a encore choisi : chaque format ouvre alors sur ce qui
/// lui va (`PreviewRoute.showsDocumentFirst`).
@MainActor
final class PreviewModeMemory: ObservableObject {
    static let shared = PreviewModeMemory()
    @Published var choice: PreviewMode?

    /// Le mode à montrer pour un document dont la voie est `route`.
    func mode(for route: PreviewRoute) -> PreviewMode {
        choice ?? (route.showsDocumentFirst ? .document : .text)
    }
}
