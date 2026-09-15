// QueryDiagnosis.swift — ce qui cloche dans ce qui vient d'être tapé (BU-33).
// Propriété : A-App.
//
// TROIS FAUTES DE FRAPPE ORDINAIRES rendaient « 0 page trouvée dans 0
// document », sans un mot : un guillemet ouvert et jamais refermé, `pres:`
// laissé seul, une requête qui ne fait qu'exclure. Le produit sait dire
// « pourquoi ce résultat » pour un succès ; il ne disait rien pour un échec.
//
// POURQUOI CE DIAGNOSTIC VIT DANS L'APP ET NON DANS `QueryParser`. Il porte sur
// le texte TAPÉ, à la frappe, avant toute exécution — il doit donc parler d'une
// requête que le moteur n'a pas encore vue, et ne rien casser quand elle est
// incomplète (on tape « "azo » avant « "azote" »). Le parseur, lui, refuse ou
// accepte une requête finie ; ses erreurs partent en anglais dans la CLI. Deux
// publics, deux endroits.
//
// LA RÈGLE : `nil` dans le doute. Une phrase affichée sous le champ à chaque
// frappe se lit comme un reproche ; elle ne paraît que sur les trois cas
// exactement reconnus, et jamais pour une requête simplement infructueuse.

import Foundation
import FouineCore

enum QueryDiagnosis {

    /// Ce qu'il y a à dire sous le champ, ou `nil` — le cas ordinaire.
    static func describe(text: String) -> String? {
        // Les guillemets typographiques comptent comme l'analyseur les lit
        // (lot QP1) : macOS écrit `« catalyse` pendant la frappe.
        let trimmed = QueryParser.normalizingQuotes(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Un guillemet sur deux : la phrase exacte n'est pas fermée. Le
        // moteur, lui, l'ignore en silence et cherche les mots séparément —
        // c'est le cas le plus trompeur des trois, parce qu'il REND des
        // résultats, mais pas ceux qu'on demandait.
        if trimmed.filter({ $0 == "\"" }).count % 2 == 1 {
            return String(localized: "A quote is not closed.")
        }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        // UN FAUX FILTRE (`type:pdf`, `dans:Livres`) : le moteur en fait un mot
        // ordinaire, qu'aucun document ne porte — zéro résultat sans un mot
        // (PR-04). La RÈGLE vient du cœur (`QueryParser.unknownPrefix`) : deux
        // implémentations de la même grammaire finiraient par diverger, et
        // celle-ci doit dire exactement ce que le parseur refusera.
        if let prefix = words.compactMap({ QueryParser.unknownPrefix(in: $0) }).first {
            return ErrorText.describe(QueryError.unknownPrefix(prefix, known: []))
        }

        if let index = words.firstIndex(where: { isProximity($0) }) {
            // Les mots NUS qui suivent l'opérateur : c'est ce que le parseur
            // absorbe, et il lui en faut deux pour chercher une proximité.
            let members = words[(index + 1)...].prefix { word in
                !word.hasPrefix("-") && !isProximity(word) && !word.contains(":")
            }
            if members.count < 2 {
                return String(localized: "`near:` expects two words.")
            }
        }

        // Ne rester que des exclusions, c'est demander « tout sauf » : ni FTS5
        // ni l'arbitrage T5 (l'exclusion écarte le document entier) n'ont de
        // réponse à cela.
        let excluded = words.filter { $0.hasPrefix("-") && $0.count > 1 }
        if !excluded.isEmpty, excluded.count == words.count {
            return String(localized: "A search that only excludes finds nothing.")
        }
        return nil
    }

    /// `pres:` est le jeton que le parseur connaît ; `near:` est celui que
    /// l'aide du champ annonce en anglais. Les deux se diagnostiquent, sans
    /// quoi la moitié des lecteurs de l'aide n'auraient rien en retour.
    private static func isProximity(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.hasPrefix("pres:") || lower.hasPrefix("near:")
    }
}
