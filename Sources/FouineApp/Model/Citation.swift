// Citation.swift — citer une page trouvée (lot INT-L1). Propriété : A-App.
//
// CE QUE LA RÉFÉRENCE DOIT RÉUSSIR. Elle est collée dans un mémoire, un
// courriel, une note — trois endroits où l'on ne contrôle rien de la mise en
// forme. D'où deux lignes et rien d'autre :
//
//     Chimie organique — CAPES tome 2.pdf, page 87
//     fouine://open?path=/Users/…/Chimie%20organique.pdf&page=87
//
// Le lien est SEUL sur sa ligne, et c'est la décision du fichier : Mail, Notes,
// Word et Pages détectent une URL en fin de ligne et la rendent cliquable ; la
// même URL collée au milieu d'une phrase est le plus souvent coupée au premier
// espace ou avalée par la ponctuation qui la suit.
//
// Le NOM DU FICHIER, pas le chemin : la personne qui lit la citation reconnaît
// son document par son nom, et un chemin absolu dans un mémoire livre en prime
// le nom de session de son auteur.

import Foundation
import AppKit

enum Citation {

    /// Les deux lignes à coller. `page` est traduit ; le lien ne l'est pas —
    /// c'est une adresse.
    static func reference(fileName: String, page: Int, unit: PageUnit = .page,
                          link: URL) -> String {
        label(fileName: fileName, page: page, unit: unit) + "\n" + linkOnly(link)
    }

    /// Les deux lignes d'une page d'ENREGISTREMENT (lot PV1) : le moment prend
    /// la place du numéro de page. Une page de son ou de vidéo est une fenêtre
    /// de dix minutes, et « page 2 » ne dit rien à qui reçoit la citation — le
    /// lien, lui, rouvre Fouine au même endroit (`&t=`).
    static func reference(fileName: String, timestamp: String, link: URL) -> String {
        label(fileName: fileName, timestamp: timestamp) + "\n" + linkOnly(link)
    }

    static func label(fileName: String, timestamp: String) -> String {
        String(localized: "\(fileName), \(timestamp)")
    }

    /// La PREMIÈRE ligne seule — « nom.pdf, page 87 ».
    ///
    /// Extraite de `reference` pour l'export Markdown (PR-19), où elle devient
    /// le texte cliquable d'un lien : un libellé de lien Markdown ne peut pas
    /// tenir sur deux lignes. Une seconde formulation écrite à côté aurait
    /// divergé — le carnet et le presse-papiers doivent dire le même nom, à la
    /// virgule près.
    ///
    /// Une carte d'un paquet Anki se cite comme une carte (lot AN2) :
    /// « Organique, carte 12 ».
    static func label(fileName: String, page: Int, unit: PageUnit = .page) -> String {
        switch unit {
        case .page: return String(localized: "\(fileName), page \(page)")
        case .card: return String(localized: "\(fileName), card \(page)")
        }
    }

    /// Le lien seul, pour qui veut le poser dans un champ « adresse ».
    ///
    /// LES PARENTHÈSES SONT ÉCHAPPÉES (AP-26). `urlQueryAllowed` les laisse
    /// passer, et un chemin réel en porte souvent — un ouvrage universitaire
    /// sur deux range son année entre parenthèses : « … cristallographie
    /// (2003).pdf ». Or les détecteurs d'adresses de Mail, Notes, Pages et
    /// Word coupent fréquemment une URL sur une parenthèse fermante, et
    /// Markdown la casse toujours. Le lien collé cessait donc d'être cliquable
    /// pour la moitié du fonds. `URL(string:)` et `URLComponents` relisent
    /// `%28`/`%29` sans rien changer : l'aller-retour est intact, et c'est ce
    /// que `CitationTests` vérifie.
    static func linkOnly(_ link: URL) -> String {
        linkOnly(link.absoluteString)
    }

    /// La même règle sur une adresse DÉJÀ sous forme de texte : l'export tient
    /// ses liens en `String` (`ResultExport.Row.link`), et un lien Markdown
    /// dont le chemin porte une parenthèse se casserait deux fois plutôt
    /// qu'une — le détecteur d'adresses d'abord, la syntaxe `[…](…)` ensuite.
    static func linkOnly(_ absoluteString: String) -> String {
        absoluteString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Le presse-papiers. `clearContents()` d'abord : sans lui, un contenu
    /// d'un autre type déjà présent (une image, un fichier) resterait, et le
    /// collage rendrait l'ancien.
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
