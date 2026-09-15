// SpotlightItemBuilder.swift — l'élément que Fouine remet à Spotlight
// (lot INT-S1). Propriété : A-Core.
//
// PUR, ET SANS CORESPOTLIGHT. Ce fichier fabrique une VALEUR ; c'est
// `SpotlightDonor` qui la traduit en `CSSearchableItem` et la remet au
// système. La séparation n'est pas décorative : `CSSearchableIndex` exige un
// bundle, donc rien de ce qu'il touche ne se teste — alors que le découpage
// du texte, lui, est exactement ce qui peut être faux.
//
// L'IDENTIFIANT EST « doc:<id> », ET C'EST UN CHOIX DISCUTABLE ASSUMÉ.
// `docs.id` est un rowid SQLite : une base reconstruite le réattribue, et un
// élément Spotlight resté en place ouvrirait alors le mauvais document (c'est
// tout le raisonnement de `DeepLink`, qui préfère le chemin). Mais un élément
// Spotlight n'est pas une citation collée dans un mémoire : il vit DANS l'index
// local, à côté de la base qui l'a produit, et la remise complète qui suit une
// reconstruction le remplace. Le chemin, lui, ferait un identifiant qui change
// à chaque `mv` — donc un doublon par déplacement, ce que le schéma v6 avait
// justement supprimé.
//
// LE TEXTE EST COUPÉ SUR UNE FRONTIÈRE DE PAGE. Couper au milieu d'une page
// donnerait à Spotlight un mot tronqué à la jointure — « électro » — qui ne
// correspond à rien, et un extrait affiché qui s'arrête en plein milieu d'un
// mot. On empile donc des pages ENTIÈRES tant qu'elles tiennent, et jamais
// moins d'une : un document dont la première page dépasse à elle seule le
// plafond serait sinon donné sans un mot de texte, c'est-à-dire introuvable.

import Foundation
import FouineCore
import UniformTypeIdentifiers

/// Ce que Fouine donne à Spotlight pour un document.
public struct SpotlightItem: Sendable, Equatable {
    /// « doc:<id> ». Rendu par `CSSearchableItemActivityIdentifier` au clic.
    public let identifier: String
    /// Le nom du fichier — ce que l'utilisateur reconnaît dans une liste.
    public let title: String
    /// Les premiers caractères du texte, sous le titre.
    public let contentDescription: String
    /// Le texte cherchable, pages entières séparées par une ligne vide.
    public let textContent: String
    /// Étiquette de racine et extension : deux mots que l'on tape volontiers.
    public let keywords: [String]
    /// Le fichier lui-même, quand son volume est monté.
    public let contentURL: URL?
    /// Identifiant de type (UTI), pour l'icône.
    public let contentTypeIdentifier: String?
    /// Le domaine, qui permet de tout retirer d'un geste.
    public let domainIdentifier: String

    public init(identifier: String, title: String, contentDescription: String,
                textContent: String, keywords: [String], contentURL: URL?,
                contentTypeIdentifier: String?, domainIdentifier: String) {
        self.identifier = identifier
        self.title = title
        self.contentDescription = contentDescription
        self.textContent = textContent
        self.keywords = keywords
        self.contentURL = contentURL
        self.contentTypeIdentifier = contentTypeIdentifier
        self.domainIdentifier = domainIdentifier
    }
}

public enum SpotlightItemBuilder {

    /// Le domaine de TOUS les éléments de Fouine : `deleteAll` s'en sert, et
    /// c'est ce qui garantit qu'une désinstallation ne laisse rien derrière.
    public static let domain = "io.github.basedpolymer.fouine.documents"

    /// Longueur de l'extrait affiché sous le titre.
    public static let descriptionCharacters = 300

    /// Le séparateur entre deux pages. Une ligne vide, comme dans un aperçu :
    /// Spotlight n'a pas de notion de page, et coller deux pages bout à bout
    /// fabriquerait des mots qui n'existent pas à la jointure.
    public static let pageSeparator = "\n\n"

    public static func identifier(docID: Int64) -> String { "doc:\(docID)" }

    /// L'identifiant inverse. `nil` pour tout ce qui n'est pas à nous : un
    /// autre programme peut avoir posé des éléments dans l'index de macOS.
    public static func docID(fromIdentifier identifier: String) -> Int64? {
        guard identifier.hasPrefix("doc:") else { return nil }
        return Int64(identifier.dropFirst(4))
    }

    /// Ce qu'un clic sur un résultat Spotlight demande d'ouvrir.
    ///
    /// PAR LE MÊME CHEMIN QUE LES LIENS `fouine://` (lot INT-L1) : le routeur,
    /// la fenêtre d'aperçu et la reprise « base pas encore ouverte » existent
    /// déjà et sont éprouvés. Un clic Spotlight n'est qu'une autre façon de
    /// produire un `DeepLink` — l'application n'apprend rien de nouveau.
    ///
    /// La requête que Spotlight transmet (`CSSearchQueryString`) est celle que
    /// l'utilisateur venait de taper : la reposer dans le champ de recherche
    /// remet les surlignages sur ses mots et amène la bonne page en tête.
    /// Absente, on ouvre le document à sa première page.
    public static func link(identifier: String?, query: String?) -> DeepLink? {
        guard let identifier, let id = docID(fromIdentifier: identifier)
        else { return nil }
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .open(target: .doc(id), page: nil,
                     query: (text?.isEmpty ?? true) ? nil : text)
    }

    /// L'élément d'un document. `nil` quand il n'y a aucun texte à donner —
    /// Fouine n'indexe pas les noms de fichiers (SPEC §5.3 (e)), mais elle
    /// n'a rien à dire à Spotlight d'un document dont elle n'a pas lu une
    /// ligne.
    ///
    /// - Parameter title: le nom à montrer quand ce n'est pas celui du fichier
    ///   — une carte Anki ou une note recopiée par Fouine s'appelle comme dans
    ///   son application, pas « Paquet.md » (lot AN2).
    public static func item(document: DocumentChange,
                            absolutePath: String?,
                            pages: [IndexedPage],
                            limitBytes: Int,
                            title: String? = nil) -> SpotlightItem? {
        let kept = truncate(pages: pages, limitBytes: limitBytes)
        guard !kept.isEmpty else { return nil }
        let text = kept.map(\.text).joined(separator: pageSeparator)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let name = (document.relPath as NSString).lastPathComponent
        let ext = document.ext.lowercased()
        return SpotlightItem(
            identifier: identifier(docID: document.id),
            title: title ?? name,
            contentDescription: description(of: text),
            textContent: text,
            // L'étiquette de racine (« Cours », « Thèse ») est le mot par
            // lequel l'utilisateur désigne lui-même ses dossiers ; l'extension
            // sert le « pdf » qu'on tape par réflexe.
            keywords: [document.topFolder, ext].filter { !$0.isEmpty },
            contentURL: absolutePath.map { URL(fileURLWithPath: $0) },
            contentTypeIdentifier: contentType(forExtension: ext),
            domainIdentifier: domain)
    }

    /// Les N premières pages ENTIÈRES qui tiennent sous le plafond, au moins
    /// une. Le compte est en octets UTF-8 : c'est ce que Spotlight recopie.
    static func truncate(pages: [IndexedPage], limitBytes: Int) -> [IndexedPage] {
        guard let first = pages.first else { return [] }
        var kept: [IndexedPage] = [first]
        var used = first.text.utf8.count
        for page in pages.dropFirst() {
            let cost = pageSeparator.utf8.count + page.text.utf8.count
            guard used + cost <= limitBytes else { break }
            kept.append(page)
            used += cost
        }
        return kept
    }

    /// Les 300 premiers caractères, sur une seule ligne : une description qui
    /// contient des retours à la ligne s'affiche coupée dans le résultat.
    ///
    /// LE PRÉFIXE D'ABORD, LE NETTOYAGE ENSUITE. Aplatir tout le texte pour
    /// n'en garder que trois cents caractères coûtait, sur un document d'un
    /// mégaoctet, une reconstruction complète de la chaîne — payée pour chaque
    /// document d'une remise complète. On ne nettoie donc qu'un préfixe
    /// généreux : quatre caractères par caractère rendu couvrent le pire cas
    /// réaliste, un texte fait surtout de retours à la ligne.
    static func description(of text: String) -> String {
        let head = text.prefix(descriptionCharacters * 4)
        let flat = head.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > descriptionCharacters else {
            // Le texte entier tenait dans le préfixe : rien n'a été coupé.
            return text.count <= head.count ? flat : flat + "…"
        }
        return String(flat.prefix(descriptionCharacters)) + "…"
    }

    /// L'UTI du fichier, pour que Spotlight montre l'icône du format. `data`
    /// en dernier recours : une extension inconnue vaut mieux qu'aucun type,
    /// qui donnerait une icône vide.
    static func contentType(forExtension ext: String) -> String? {
        guard !ext.isEmpty else { return UTType.data.identifier }
        return (UTType(filenameExtension: ext) ?? .data).identifier
    }
}
