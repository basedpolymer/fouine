// EntrySort.swift — tri naturel des entrées d'archive (SPEC §5.3).
// Propriété : A-Ingest.
//
// « une image = une page », donc l'ORDRE DES ENTRÉES EST L'ORDRE DES PAGES.
// Un tri lexical mettrait img10 avant img2 : la numérotation des pages d'une BD
// serait fausse, et avec elle tout ce qui s'y raccroche (file OCR, navigation).
// Comparateur écrit à la main pour être indépendant de la locale : le résultat
// doit être le même sur toutes les machines et à tous les appels.

import Foundation

enum EntrySort {
    /// Extensions d'image reconnues dans les archives BD (§5.3).
    static let comicImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp",
    ]

    /// Extensions d'image des médias embarqués OOXML (§5.3).
    ///
    /// `webp` manquait (A11.11) alors que `comicImageExtensions` l'accepte déjà :
    /// un .docx à illustrations webp perdait ses images, qui ne partaient donc
    /// jamais en OCR. Le critère d'admission est UNIQUE — ce que `GrayRaster`
    /// sait décoder, c'est-à-dire ce qu'ImageIO lit. Relevé sur cette machine
    /// (`CGImageSourceCopyTypeIdentifiers`) : png, jpeg, gif, tiff, bmp, webp,
    /// heic sont lus ; **emf, wmf et svg ne le sont pas**, et les inscrire ici
    /// ne ferait qu'envoyer en file OCR des pages qu'aucun rendu ne produirait —
    /// exactement ce que le §6.1 interdit. Ils restent donc dehors tant que
    /// `GrayRaster` ne sait pas les tramer.
    static let ooxmlImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp",
    ]

    /// Ordre naturel : les suites de chiffres se comparent numériquement.
    /// img2 < img10, page-09 < page-10.
    static func naturalLess(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        var i = 0, j = 0
        while i < x.count && j < y.count {
            if x[i].isNumber && y[j].isNumber {
                var iEnd = i, jEnd = j
                while iEnd < x.count && x[iEnd].isNumber { iEnd += 1 }
                while jEnd < y.count && y[jEnd].isNumber { jEnd += 1 }
                let xs = String(x[i..<iEnd]).drop(while: { $0 == "0" })
                let ys = String(y[j..<jEnd]).drop(while: { $0 == "0" })
                if xs.count != ys.count { return xs.count < ys.count }
                if xs != ys { return xs.lexicographicallyPrecedes(ys) }
                i = iEnd; j = jEnd
            } else {
                if x[i] != y[j] { return x[i] < y[j] }
                i += 1; j += 1
            }
        }
        // DÉPARTAGE SUR LE RESTE, pas sur la longueur totale (A11.11).
        // `i` et `j` n'avancent PAS du même pas : une suite de chiffres égale en
        // valeur peut être plus longue d'un côté (« 007 » contre « 7 »), et les
        // deux curseurs divergent alors définitivement. Comparer `x.count` à
        // `y.count` revient à compter les zéros de tête comme du contenu :
        // « page007 » (épuisé) passait APRÈS « page7x » (une lettre restante),
        // alors que le préfixe doit venir en premier. Mesuré sur ce cas exact.
        if x.count - i != y.count - j { return x.count - i < y.count - j }
        return a < b        // départage stable des égalités de casse
    }

    static func sortedNaturally(_ entries: [String]) -> [String] {
        entries.sorted(by: naturalLess)
    }

    /// Extension en minuscules, sans point, d'une entrée d'archive.
    static func ext(of entry: String) -> String {
        (entry as NSString).pathExtension.lowercased()
    }

    /// Entrées d'image d'une archive, triées naturellement. Les entrées de
    /// dossier et les ressources macOS (`__MACOSX/`, `._*`) sont écartées.
    static func imageEntries(_ entries: [String], allowed: Set<String>) -> [String] {
        let kept = entries.filter { entry in
            guard !entry.hasSuffix("/") else { return false }
            let name = (entry as NSString).lastPathComponent
            guard !name.hasPrefix("._"), name != ".DS_Store" else { return false }
            guard !entry.hasPrefix("__MACOSX/") else { return false }
            return allowed.contains(ext(of: entry))
        }
        return sortedNaturally(kept)
    }
}
