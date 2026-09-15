// GRDBStore+IgnoreRules.swift — les règles d'exclusion gardées par Fouine, une
// ligne de `roots` à la fois (lot IG2). Propriété : A-Core.
//
// POURQUOI DANS LA BASE, ET PAS DANS LE DOSSIER. Décision du 14/09/2026 : l'app
// n'écrit pas dans les dossiers de l'utilisateur, nulle part — le corpus est en
// lecture seule stricte. Ce que l'utilisateur exclut depuis les réglages vit
// donc ici, et le crawl l'unit au fichier `.fouineignore` quand il existe
// (`IgnoreRules.load(root:stored:)`, FouineCrawl). Le prix, assumé : une règle
// gardée ici part avec la racine (`root remove --purge`), là où le fichier
// suivait le dossier.
//
// UNE COLONNE, SANS CHANGER `Schema.version`. `roots.ignore_rules` porte un
// texte JSON (`["Santé/","*.md"]`) ou NULL. Une base neuve la reçoit de
// `Schema.ddl` ; une base v9 créée AVANT ce lot ne l'a pas, et la reçoit par un
// `ALTER TABLE … ADD COLUMN` — à la PREMIÈRE ÉCRITURE d'une règle, et pas à
// l'ouverture. Trois raisons :
//
//   · une ouverture d'une base à jour n'écrit rien et ne prend aucun verrou
//     (`testOpeningAnUpToDateDatabaseTakesNoLock`) : elle ne se met pas à
//     écrire pour une fonction que la plupart des index n'utiliseront jamais ;
//   · les ouvertures en LECTURE SEULE (MCP, `search`, `status`, `root list`)
//     ne peuvent pas ajouter la colonne de toute façon : les lectures doivent
//     donc tolérer son absence, et une fois qu'elles la tolèrent, l'ajouter à
//     l'ouverture n'apporte rien ;
//   · le garde-fou « base d'un autre schéma » reste celui de `open(at:)`, au
//     caractère près : il compare `meta.schema_version`, que rien ici ne touche.
//
// PAS DE `fouine.lock`, et c'est un écart délibéré à la consigne (qui disait
// « verrou d'écriture comme `root add` ») — même régime que `writeSetting`,
// pour les mêmes raisons (voir l'en-tête de `GRDBStore+Settings.swift`) :
//
//   · aucune passe d'indexation n'ÉCRIT cette colonne ; le crawl la LIT au
//     début de chaque racine. La sérialisation de SQLite suffit ;
//   · `writeLocked` prend le verrou PARESSEUSEMENT et ne le rend pas : l'app
//     qui enregistrerait une règle garderait `fouine.lock` jusqu'à sa prochaine
//     passe, et l'agent d'arrière-plan resterait bloqué tout ce temps ;
//   · l'agent tient ce verrou pendant tout un lot d'OCR (dix minutes par
//     défaut) : la feuille « Ce que Fouine ignore » échouerait précisément
//     quand l'index travaille.

import Foundation
import GRDB

extension GRDBStore {

    /// Le texte JSON des règles gardées pour cette racine, tel qu'il est en
    /// base. `nil` : aucune règle, racine inconnue, ou base v9 d'avant IG2 (la
    /// colonne n'existe pas encore).
    ///
    /// Le store ne lit ni ne valide la syntaxe des règles : elle appartient à
    /// FouineCrawl (`IgnoreRuleSet`), qui les compile. Ici, un texte par racine.
    public func ignoreRulesJSON(rootID: Int64) throws -> String? {
        try read { db in
            guard try Self.rootsCarryIgnoreRules(db) else { return nil }
            return try String.fetchOne(
                db, sql: "SELECT ignore_rules FROM roots WHERE id = ?",
                arguments: [rootID])
        }
    }

    /// Les règles gardées de TOUTES les racines qui en portent, en une
    /// lecture : c'est ce que l'agent compare d'un tic à l'autre pour savoir
    /// quelle racine reparcourir (une règle gardée ne remonte aucun événement
    /// FSEvents, contrairement au fichier).
    public func ignoreRulesJSONByRoot() throws -> [Int64: String] {
        try read { db in
            guard try Self.rootsCarryIgnoreRules(db) else { return [:] }
            var out: [Int64: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, ignore_rules FROM roots WHERE ignore_rules IS NOT NULL
                """) {
                out[row["id"]] = row["ignore_rules"]
            }
            return out
        }
    }

    /// Remplace les règles gardées d'une racine. `nil` les efface (la colonne
    /// repasse à NULL, jamais à `[]` : une seule forme pour « aucune règle »).
    ///
    /// Transaction IMMÉDIATE : la question « la colonne existe-t-elle ? » et
    /// l'`ALTER TABLE` qui y répond doivent tenir sous le même verrou SQLite.
    /// En transaction différée, deux processus qui lisent « absente » ensemble
    /// se disputent l'ALTER, et le second échoue en « duplicate column ».
    public func setIgnoreRulesJSON(rootID: Int64, _ json: String?) throws {
        try mapped {
            try pool.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    guard try Int64.fetchOne(
                        db, sql: "SELECT id FROM roots WHERE id = ?",
                        arguments: [rootID]) != nil else {
                        throw FouineError.databaseFailure("unknown root \(rootID)")
                    }
                    if try !Self.rootsCarryIgnoreRules(db) {
                        try db.execute(sql: Self.addIgnoreRulesColumn)
                    }
                    try db.execute(
                        sql: "UPDATE roots SET ignore_rules = ? WHERE id = ?",
                        arguments: [json, rootID])
                    return .commit
                }
            }
        }
    }

    /// Nommé pour que le test d'une base « d'avant » puisse la reproduire au
    /// mot près, en retirant ce que cette phrase ajoute.
    static let addIgnoreRulesColumn = "ALTER TABLE roots ADD COLUMN ignore_rules TEXT"

    /// `pragma_table_info` et pas `db.columns(in:)` : GRDB met ce dernier en
    /// cache par connexion, et la colonne peut apparaître sous nos pieds —
    /// ajoutée par un AUTRE processus (l'app) pendant que celui-ci (l'agent)
    /// garde sa connexion ouverte des semaines.
    static func rootsCarryIgnoreRules(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT count(*) > 0 FROM pragma_table_info('roots')
            WHERE name = 'ignore_rules'
            """) ?? false
    }
}
