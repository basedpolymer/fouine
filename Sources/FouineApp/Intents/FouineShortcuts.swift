// FouineShortcuts.swift — les actions proposées d'emblée (lot INT-R1).
// Propriété : A-App. SPEC §5.6.
//
// À QUOI SERT UN `AppShortcutsProvider`. Sans lui, les trois actions existent
// dans Raccourcis mais il faut aller les chercher : ouvrir Raccourcis, créer un
// raccourci, taper « Fouine ». Avec lui, macOS les affiche tout seul dans la
// galerie de Raccourcis dès l'installation, et — sur macOS 26 — les propose
// dans Spotlight quand on tape le nom de l'application.
//
// LES PHRASES TRADUITES VIVENT HORS DU CATALOGUE (lot L2, audit BU-35). Une
// phrase parlée localisée n'est pas une chaîne de plus dans `.xcstrings` :
// AppIntents la lit à l'exécution dans `<langue>.lproj/AppShortcuts.strings`,
// clé = la phrase source avec `${applicationName}`. Ces deux fichiers sont
// écrits à la main sous `Packaging/Resources/{en,fr}.lproj/` et copiés par
// `Packaging/bundle.sh` à côté des `.strings` compilés (échec dur si l'un
// manque ; `ci-bundle-i18n` compare leurs clés). `--no-app-shortcuts-localization`
// reste : le processeur de métadonnées ne doit pas les FABRIQUER, il
// exigerait un `--stringsdata-file` par langue que SwiftPM ne produit pas.
// Une phrase de plus ici = une clé de plus dans les deux `.strings`, sinon
// elle ne se dicte qu'en anglais (docs/i18n.md). Les TITRES et DESCRIPTIONS
// des actions, eux, passent par le catalogue de l'app comme tout le reste.

import AppIntents

struct FouineShortcuts: AppShortcutsProvider {

    /// La couleur de la tuile dans la galerie de Raccourcis.
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchFouineIntent(),
            // AUCUN PARAMÈTRE DANS UNE PHRASE. « Search for \(\.$query) in
            // \(.applicationName) » se compile, puis le processeur de
            // métadonnées refuse net le bundle : « Invalid parameter type.
            // AppEntity and AppEnum are the only allowed types for query »
            // (mesuré le 08/09/2026, Xcode 26.2). Seule une entité ou une
            // énumération peut être dictée — un texte libre ne s'énumère pas,
            // et Siri n'a donc rien à proposer. La phrase lance l'action, et
            // Raccourcis demande ensuite quoi chercher.
            phrases: [
                "Search \(.applicationName)",
                "Search my documents with \(.applicationName)",
            ],
            shortTitle: "Search in Fouine",
            systemImageName: "text.magnifyingglass")
    }
}
