// FouineHitEntity.swift — une page trouvée, telle que Raccourcis la manipule
// (lot INT-R1). Propriété : A-App. SPEC §5.6.
//
// CE QUE RACCOURCIS ATTEND D'UNE ENTITÉ. Une action rend des « éléments » que
// l'on glisse dans l'action suivante : « Choisir dans la liste », « Répéter
// chaque élément », « Obtenir le texte d'une page ». Pour cela, Raccourcis a
// besoin de trois choses et de rien d'autre : un IDENTIFIANT stable, une façon
// de le RÉAFFICHER (`DisplayRepresentation`), et une façon de le RELIRE plus
// tard depuis cet identifiant (`EntityQuery`). Les propriétés `@Property`
// deviennent, elles, les variables que l'on pioche dans l'interface de
// Raccourcis (« Nom du fichier de Résultat Fouine »).
//
// LECTURE SEULE, ET SA PROPRE OUVERTURE. Raccourcis lance Fouine EN ARRIÈRE-PLAN
// pour exécuter une action : `AppModel.start()` n'a pas tourné, `StoreService`
// n'existe pas encore, et rien ne garantit qu'il existera avant la fin de
// l'action. Chaque intention ouvre donc sa propre lecture par
// `GRDBStore.openReadOnly` — qui ne prend PAS `fouine.lock` (§5.1) et laisse
// donc l'agent d'arrière-plan continuer d'indexer pendant qu'un raccourci
// cherche.

import Foundation
import AppIntents
import FouineCore

/// Une page trouvée par Fouine, vue de Raccourcis.
struct FouineHitEntity: AppEntity {

    /// Le nom du type dans l'interface de Raccourcis (« Résultat Fouine »).
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Fouine result")
    }

    static var defaultQuery = FouineHitQuery()

    /// `<docID>:<page>` — voir `IntentSupport.entityID`.
    var id: String

    @Property(title: "File name")
    var fileName: String

    @Property(title: "Page")
    var page: Int

    @Property(title: "Excerpt")
    var snippet: String

    /// Le chemin complet du fichier, pour qui enchaîne sur une action de
    /// Fichiers. Séparé du nom : c'est le nom que l'on lit, et le chemin livre
    /// en prime le nom de session de son auteur quand il est collé ailleurs.
    @Property(title: "File path")
    var path: String

    /// L'étiquette de la racine (« Cours », « Thèse ») : le mot par lequel la
    /// personne désigne elle-même ses dossiers.
    @Property(title: "Folder")
    var folder: String

    /// Le lien `fouine://` de cette page (lot INT-L1) — celui que
    /// « Ouvrir dans Fouine » ouvre, et que l'on peut aussi coller dans une
    /// note pour y revenir plus tard.
    @Property(title: "Fouine link")
    var link: URL

    init(id: String, fileName: String, page: Int, snippet: String,
         path: String, folder: String, link: URL) {
        self.id = id
        self.fileName = fileName
        self.page = page
        self.snippet = snippet
        self.path = path
        self.folder = folder
        self.link = link
    }

    /// « Chimie organique.pdf, page 87 », l'extrait en sous-titre.
    ///
    /// Le titre passe par la clé `%@, page %lld` du catalogue — la même que la
    /// citation collée par ⌘C (INT-L1) : les deux surfaces nomment une page de
    /// la même façon, dans les deux langues.
    ///
    /// Le sous-titre, lui, n'a PAS de clé de catalogue : c'est l'extrait du
    /// document, du texte de l'utilisateur. D'où `stringLiteral:` — la
    /// ressource porte l'extrait comme clé, la recherche au catalogue échoue,
    /// et Foundation rend la clé, c'est-à-dire l'extrait. Écrire
    /// `subtitle: "\(snippet)"` aurait fabriqué la clé « %@ », que le garde-fou
    /// `l10n-lint` réclame alors au catalogue (il voit « title: » dans
    /// « subtitle: ») : une entrée qui ne veut rien dire dans les deux langues.
    var displayRepresentation: DisplayRepresentation {
        let excerpt = LocalizedStringResource(stringLiteral: snippet)
        return DisplayRepresentation(title: "\(fileName), page \(page)",
                                     subtitle: excerpt)
    }
}

/// Relit un résultat depuis son identifiant.
///
/// Raccourcis GARDE les identifiants : un raccourci enregistré aujourd'hui avec
/// « Ouvrir dans Fouine » sur une page précise se rejoue dans six mois. Le
/// résultat introuvable est SILENCIEUSEMENT écarté (le contrat d'`entities(for:)`
/// est de rendre ce qui existe) ; c'est l'action qui, ne recevant rien,
/// remonte `resultUnavailable` avec le geste à faire.
struct FouineHitQuery: EntityQuery {

    func entities(for identifiers: [FouineHitEntity.ID]) async throws
        -> [FouineHitEntity] {
        let keys = identifiers.compactMap { id in
            IntentSupport.key(fromEntityID: id).map { (id: id, key: $0) }
        }
        guard !keys.isEmpty else { return [] }

        let url = AppPaths.databaseURL()
        try IntentSupport.checkIndex(at: url)
        let store = GRDBStore()
        try store.openReadOnly(at: url)

        return try keys.compactMap { entry in
            guard let row = try store.docRow(id: entry.key.docID) else { return nil }
            // L'extrait vient du TEXTE DE LA PAGE : il n'y a pas de requête ici,
            // donc rien à surligner ni à centrer sur un mot.
            let text = (try? store.pageText(docID: entry.key.docID,
                                            page: entry.key.page)) ?? nil
            return FouineHitEntity.make(docID: entry.key.docID,
                                        page: entry.key.page,
                                        row: row,
                                        rawSnippet: text ?? "")
        }
    }
}

extension FouineHitEntity {

    /// Le seul endroit qui fabrique une entité depuis la base.
    ///
    /// Le lien passe par `DeepLink.link(absolutePath:docID:page:)`, point unique
    /// de l'arbitrage chemin/document partagé avec la CLI, le serveur MCP et la
    /// citation de l'application : deux surfaces qui citeraient la même page
    /// autrement produiraient deux citations qu'on ne peut pas rapprocher.
    static func make(docID: Int64, page: Int, row: DocRow,
                     rawSnippet: String) -> FouineHitEntity {
        let absolute = try? VolumeResolver.absolutePath(
            volUUID: row.record.volUUID, relPath: row.record.relPath)
        return FouineHitEntity(
            id: IntentSupport.entityID(docID: docID, page: page),
            fileName: IntentSupport.fileName(relPath: row.record.relPath),
            page: page,
            snippet: IntentSupport.snippet(rawSnippet),
            path: absolute?.path ?? row.record.relPath,
            folder: row.record.topFolder,
            link: DeepLink.link(absolutePath: absolute?.path, docID: docID,
                                page: page))
    }
}
