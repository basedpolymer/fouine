// AppPaths.swift — emplacements et préférences (SPEC §10). Propriété : A-App.

import Foundation
import FouineCore

enum AppPaths {

    /// `~/Library/Application Support/Fouine/fouine.db`, ou `FOUINE_DB`
    /// (chemin complet du .db). MÊME variable que la CLI : les deux doivent
    /// toujours regarder la même base (§10).
    static func databaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FOUINE_DB"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fouine",
                                    isDirectory: true)
            .appendingPathComponent("fouine.db")
    }

    /// La place libre sur le volume qui porte l'index, telle que macOS la
    /// promet à une écriture importante (`volumeAvailableCapacityForImportantUsage` :
    /// le système compte dedans ce qu'il peut purger lui-même, c'est le chiffre
    /// du Finder). `nil` si la base n'existe pas encore ou si le volume ne
    /// répond pas — la carte « Index » se tait alors (`DiskSpaceNotice`).
    static func freeDiskBytes() -> Int? {
        let values = try? databaseURL()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(clamping: free)
    }

    /// AUCUNE racine par défaut (audit produit du 01/09, D1). L'app enregistrait
    /// `~/Livres` et `~/Documents/Cours` — des dossiers d'exemple — sur toute
    /// base neuve, et les sautait en silence chez tous les autres : la fenêtre
    /// s'ouvrait vide, sans un geste possible. Les racines s'ajoutent maintenant
    /// depuis l'écran d'accueil et la barre latérale.

    /// Emplacement de la CLI dans le bundle (§11.2) : `Contents/Helpers/fouine`.
    ///
    /// PAS `Contents/MacOS/fouine` : le disque de démarrage d'un Mac est
    /// insensible à la casse par défaut, et `fouine` y désigne le même fichier
    /// que `Fouine`, l'exécutable de l'app (`CFBundleExecutable`). Une copie
    /// dans `Contents/MacOS` écrase donc l'app par la CLI, en silence.
    ///
    /// `nil` hors bundle (`swift run FouineApp`), où l'élément de menu
    /// « Installer l'outil en ligne de commande… » n'a pas de sens. Le test
    /// vérifie que c'est bien un exécutable ET que ce n'est pas l'app elle-même
    /// — sur un disque insensible à la casse, `Contents/MacOS/fouine` répondrait
    /// « oui » en désignant `Contents/MacOS/Fouine`.
    static func bundledCLI() -> URL? {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/fouine")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return nil
        }
        return helper
    }

    /// Cible du lien symbolique proposé par « Installer l'outil en ligne de
    /// commande… ». `/usr/local/bin` est dans le `PATH` par défaut de zsh et
    /// n'est pas protégé par la SIP, contrairement à `/usr/bin`.
    static let cliLinkURL = URL(fileURLWithPath: "/usr/local/bin/fouine")

    /// Nom du plist de l'agent, tel qu'attendu par `SMAppService` (§5.7, §11.2).
    /// A-Pack le déposera dans `Fouine.app/Contents/Library/LaunchAgents/`.
    static let agentPlistName = FouinePaths.agentPlistName

    /// La page « Privacy » du site, en ligne : le texte de `docs/privacy.md`.
    ///
    /// La documentation n'est PAS embarquée dans le bundle (elle vit dans le
    /// dépôt, et un utilisateur qui lit « ce que Fouine envoie » a tout intérêt
    /// à lire la version publiée, datée, plutôt qu'une copie figée au jour de
    /// la compilation). Le 14/09/2026 le bouton pointait sur GitHub : 404 tant
    /// que le dépôt est privé, et Creem a refusé la boutique pour cette raison.
    /// Le site sert la même page à une adresse qui ne dépend pas du dépôt.
    static let privacyDocumentURL = URL(
        string: "https://basedpolymer.eu/fouine/privacy")!

    /// Volet « Fichiers et dossiers » des réglages de confidentialité (§7.1).
    static let privacyFilesPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security"
                + "?Privacy_FilesAndFolders")!

    /// Volet « Accès complet au disque » (lot INT-F4).
    ///
    /// C'est un volet DIFFÉRENT de « Fichiers et dossiers », et c'est celui-là
    /// qu'il faut pour lire les notes d'Apple Notes : sa base vit sous
    /// `~/Library/Group Containers`, que « Fichiers et dossiers » ne couvre
    /// pas. Envoyer quelqu'un dans le mauvais volet, c'est lui faire chercher
    /// une case qui n'y est pas.
    static let privacyFullDiskPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security"
                + "?Privacy_AllFiles")!
}

/// Préférences. Le domaine est forcé à `io.github.basedpolymer.fouine` pour écrire dans
/// `~/Library/Preferences/io.github.basedpolymer.fouine.plist` (§10) aussi bien depuis le
/// bundle signé que depuis `swift run FouineApp`, qui n'a pas d'identifiant.
enum Prefs {
    static let suite = "io.github.basedpolymer.fouine"
    /// `var`, et non `let`, pour UNE raison : les tests y substituent un domaine
    /// jetable par processus (`TestPrefs.isolate`). Mesuré le 05/09/2026 :
    /// `make ci-unit` (`--parallel`, un processus xctest par test) faisait
    /// écrire tous les tests dans le VRAI fichier de préférences de
    /// l'utilisateur — la dernière session d'un test écrasait celle qu'un autre
    /// venait de mémoriser (`QuickFiltersSessionTests`, échecs aléatoires), et
    /// l'historique de recherche de la machine se remplissait de requêtes de
    /// test. L'application ne réassigne jamais cette valeur.
    ///
    /// DANS LE BUNDLE, C'EST `.standard` (BU-29). Une suite qui porte
    /// l'identifiant du bundle qui la demande n'a pas de sens pour macOS :
    /// `UserDefaults(suiteName:)` rend `nil`, le `?? .standard` rattrape — et
    /// le système écrit à chaque lancement « Using your own bundle identifier
    /// as an NSUserDefaults suite name does not make sense and will not work ».
    /// Le domaine visé est le même dans les deux cas ; seule la ligne mentait.
    /// Hors bundle (`swift run FouineApp`, qui n'a pas d'identifiant), la suite
    /// reste indispensable : c'est elle qui fait écrire dans le fichier de
    /// préférences de Fouine et non dans celui du binaire de développement.
    static var defaults: UserDefaults = {
        Bundle.main.bundleIdentifier == suite
            ? .standard
            : UserDefaults(suiteName: suite) ?? .standard
    }()

    static let history = "search.history"
    static let historyLimit = 40
    /// Recherches enregistrées (PR-17), en JSON — voir `SavedSearches`. À côté
    /// de l'historique : c'est la même matière, gardée pour de bon.
    static let savedSearches = "search.saved"
    static let fuzzyMode = "search.fuzzy.mode"
    static let fuzzyScope = "search.fuzzy.scope"
    /// Interrupteur « Sémantique » (§12). Absent = éteint : le chemin lexical
    /// reste celui par défaut.
    static let semantic = "search.semantic"
    static let firstRunProbeDone = "tcc.firstRunProbeDone"
    /// « Garder Fouine dans la barre des menus » (UX-07). ABSENTE = allumée :
    /// `bool(forKey:)` rendrait `false` sur une installation neuve, et la
    /// première fermeture de fenêtre tuerait l'app alors que tout le reste de
    /// l'interface (fermer sans quitter, « Ouvrir Fouine ») est bâti sur
    /// l'icône. C'est le seul défaut « vrai » du fichier de préférences, et il
    /// se lit ici, en un endroit.
    static let menuBarIcon = "ui.menuBarIcon"
    static var showsMenuBarIcon: Bool {
        get { defaults.object(forKey: menuBarIcon) as? Bool ?? true }
        set { defaults.set(newValue, forKey: menuBarIcon) }
    }
    /// « Chercher pendant que je tape » (AP1, demande du propriétaire du
    /// 13/09/2026). ABSENTE = allumée, pour la même raison que l'icône :
    /// `bool(forKey:)` rendrait `false` et éteindrait, à la première mise à
    /// jour, le comportement que Fouine a depuis toujours sur toutes les
    /// installations. Éteinte, la frappe ne lance plus rien — c'est ⏎ qui
    /// cherche.
    static let searchAsYouType = "search.asYouType"
    static var searchesAsYouType: Bool {
        get { defaults.object(forKey: searchAsYouType) as? Bool ?? true }
        set { defaults.set(newValue, forKey: searchAsYouType) }
    }
    // `agent.backgroundIndexing` a été retirée (audit A12) : jamais lue, jamais
    // écrite. L'état de l'agent est celui que rend `SMAppService.status`, seule
    // source de vérité — une préférence parallèle n'aurait pu que mentir.
}

// `ErrorText` a déménagé dans `App/LocalizedText.swift` (palier 3.2, audit
// U1) : il ne renvoie plus à `IndexText.describe`, qui produit la phrase
// FRANÇAISE du §4.3 pour la CLI, l'agent et `docs.err`, mais rend chaque cas
// d'erreur depuis ses DONNÉES, dans la langue de l'utilisateur.

/// Formatage des nombres affichés.
///
/// Les formateurs sont PARTAGÉS, pas réalloués à chaque appel (audit A10.11) :
/// `integer` est appelé depuis une quinzaine de sites de `body` — dont une fois
/// par ligne de facette (`SidebarView`) et par ligne de résultat — et allouer un
/// `NumberFormatter` (objet lourd, chargement de la locale) à chaque
/// rafraîchissement d'interface se paie à chaque frappe.
///
/// Concurrence : les deux formateurs sont configurés une fois, ici, et plus
/// jamais mutés — `NumberFormatter` est documenté sûr en lecture concurrente
/// depuis macOS 10.9, et `Format.integer` est justement appelé aussi bien depuis
/// le fil principal que depuis les fils d'`IndexingService`. `bytes` n'a, lui,
/// que des appelants sur le fil principal.
enum Format {

    /// `numberStyle = .decimal` prend le séparateur de groupement de la locale
    /// courante — U+202F en français, la virgule en anglais. Jusqu'au
    /// 02/09/2026, la ligne suivante l'ÉCRASAIT par l'espace fine insécable
    /// pour toutes les langues, et un anglophone lisait `1 486 739 pages` au
    /// lieu de `1,486,739`, partout : pied de barre latérale, compteurs de
    /// facettes, feuille d'indexation, ligne d'état des résultats, file OCR.
    /// Le chemin d'accessibilité, lui, avait déjà été rendu multilocale
    /// (`AccessibilityText.bare`), ce qui rendait l'incohérence interne.
    /// Ne la remettez pas : la locale fait le bon choix (audit B1-13).
    private static let integerFormatter = makeIntegerFormatter(
        locale: .autoupdatingCurrent)

    /// LE GROUPEMENT EST EXIGÉ DÈS QUATRE CHIFFRES (BU-07). Le pied de la
    /// carte « Index » a été photographié affichant « 1527 documents ·
    /// 408 951 pages » : deux nombres de la même ligne, groupés différemment,
    /// se lisent comme une coquille — et un compte de documents est presque
    /// toujours à quatre chiffres, un compte de pages presque jamais.
    ///
    /// Certaines locales ne groupent qu'à partir de cinq chiffres
    /// (`minimumGroupingDigits` vaut 2 chez elles) ; la propriété qui le règle
    /// n'existe qu'à partir de macOS 15, d'où la garde. En dessous, c'est le
    /// choix de la locale qui s'applique — mesuré le 10/09/2026 sur macOS 15 :
    /// `fr_FR`, `fr_CH`, `fr_US` et `fr` groupent déjà 1 527 d'elles-mêmes.
    ///
    /// Le SÉPARATEUR, lui, reste celui de la locale — espace fine insécable en
    /// français, virgule en anglais (audit B1-13) : ne le forcez pas.
    ///
    /// Fabriquée à part pour être éprouvée dans les deux langues sans dépendre
    /// de la locale du processus de test.
    static func makeIntegerFormatter(locale: Locale) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        f.usesGroupingSeparator = true
        if #available(macOS 15.0, *) { f.minimumGroupingDigits = 1 }
        return f
    }

    /// Pourcentages parlés et affichés. Le symbole VIENT DE LA LOCALE : le
    /// français met une espace insécable avant le « % », l'anglais non. Une
    /// chaîne « \(n)% » posée en dur dans une clé de catalogue aurait été fausse
    /// dans une des deux langues — et un « % » littéral dans une clé de String
    /// Catalog est de toute façon un spécificateur de format à échapper.
    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func integer(_ n: Int) -> String {
        integerFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Formatage des totaux approchés (C2-09b) : « 50 k+ » pour 50 000, « N k+ » ou « N+ ».
    static func approximate(_ n: Int) -> String {
        if n >= 1000 {
            if n % 1000 == 0 {
                return "\(n / 1000) k+"
            } else {
                return "\(integer(n))+"
            }
        } else {
            return "\(n)+"
        }
    }

    /// `fraction` va de 0 à 1.
    static func percent(_ fraction: Double) -> String {
        percentFormatter.string(from: NSNumber(value: fraction))
            ?? String(Int((fraction * 100).rounded()))
    }

    /// `locale: .current` n'est pas un ornement : sans lui, `String(format:)`
    /// travaille en POSIX et un francophone lit `12.3 ms` au lieu de `12,3 ms`
    /// à CHAQUE recherche, à l'écran comme sous VoiceOver (audit B1-23).
    static func milliseconds(_ ms: Double) -> String {
        ms < 10
            ? String(format: "%.1f ms", locale: .current, ms)
            : String(format: "%.0f ms", locale: .current, ms)
    }

    static func bytes(_ n: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(n))
    }
}
