// CrawlExclusions.swift — exclusions OBLIGATOIRES du crawl (SPEC §5.2, test T8,
// audit F5/V16). Propriété : A-Ingest.
//
// Le §5.2 impose dix nuisances + « ._* » + les paquets .pages/.key. C'était la
// liste d'un corpus de LIVRES, tenu à la main : le premier utilisateur qui
// désigne ~/Documents ou ~ y ajoute une bibliothèque Photos de 200 Go, trois
// `node_modules`, un `~/Library` entier et le `.app` d'un logiciel rangé là.
// Trois familles s'ajoutent donc, dans UNE seule table :
//
//   · les PAQUETS — un dossier que macOS présente comme un fichier. On ne
//     descend jamais dedans : LaunchServices en connaît tous les types
//     (`URLResourceKey.isPackageKey`), et `packageExtensions` prend le relais là
//     où il ne répond pas (disque réseau, volume sans base LaunchServices) ;
//   · les DÉPENDANCES ET CACHES — `node_modules`, `.venv`, `Pods`, `DerivedData`
//     … : des dizaines de milliers de fichiers, aucun document ;
//   · `$HOME/Library` — exclu par CHEMIN, jamais par nom (voir `isHomeLibrary`).
//
// Le quatrième garde-fou n'est pas ici mais dans l'énumérateur
// (`FouineCrawler`) : `.skipsHiddenFiles`. Un document CACHÉ n'est pas un
// document que l'utilisateur cherche, et cette seule option couvre d'un coup
// tous les `.dossier` qu'aucune liste ne peut épuiser.

import Foundation

public enum CrawlExclusions {

    // MARK: - Composants exclus

    /// UNE table, par familles. Comparaison en minuscules : `Thumbs.db` et
    /// `THUMBS.DB` désignent la même nuisance, et HFS+/APFS sont insensibles à
    /// la casse par défaut.
    ///
    /// Beaucoup de ces noms commencent par un point et seraient déjà écartés par
    /// `.skipsHiddenFiles` : ils restent listés parce que le filtre s'exerce
    /// AUSSI hors énumérateur (`FouineCrawler.firstFile`, FSEvents) et parce
    /// qu'une entrée nommée est une entrée qu'un test peut vérifier.
    public static let excludedComponents: Set<String> = [
        // — Métadonnées, index et corbeilles (SPEC §5.2) ————————————————
        ".ds_store",
        ".trashes",
        ".trash",                       // corbeille du dossier de départ
        ".temporaryitems",
        ".fseventsd",
        ".spotlight-v100",
        ".documentrevisions-v100",      // versions d'auto-enregistrement macOS
        "$recycle.bin",                 // volumes Windows/ExFAT
        "system volume information",
        "thumbs.db",
        "desktop.ini",

        // — Gestion de versions ————————————————————————————————————————
        // Un dépôt de 10 000 objets sous ~/Documents ne contient aucun document,
        // et `.git/objects` est du binaire zlib qu'aucun extracteur ne lit.
        ".git",
        ".svn",
        ".hg",

        // — Dépendances, caches et sorties de construction ——————————————
        // Mesuré ailleurs, mais l'ordre de grandeur ne se discute pas : un seul
        // `node_modules` dépasse couramment 30 000 fichiers, dont des milliers
        // de .md et de .json — tous indexables par extension, tous du bruit.
        "node_modules",
        ".venv", "venv",                // environnements Python
        ".build",                       // SwiftPM
        "deriveddata",                  // Xcode
        "pods", "carthage",             // CocoaPods, Carthage
        ".tox", "__pycache__",
        ".cache", ".npm", ".cargo", ".gradle", ".m2",
    ]

    /// Paquets Apple traités comme des FICHIERS opaques, jamais parcourus, et
    /// dont aucun extracteur ne tire de texte directement depuis les protobuf
    /// (22 `.pages` dans le corpus voisin — ZIP de protobuf `Index/*.iwa`).
    /// L'extension E4 (audit D2 § 5.12) extrait leur texte via QuickLook/Preview.pdf.
    public static let opaqueBundleExtensions: Set<String> = [
        "pages", "key", "numbers",
    ]

    /// Paquets-documents : répertoires reconnus comme UN document (et non un dossier
    /// à parcourir) par le crawler (SPEC §5.2, audit E4, D2 § 5.12).
    /// Le texte provient de leurs sous-fichiers (QuickLook/Preview.pdf pour iWork, TXT.rtf pour rtfd).
    /// `mbox` s'y est ajouté (lot INT-F1) : « Exporter la boîte aux lettres »
    /// d'Apple Mail rend un dossier `Nom.mbox/` qui porte un fichier `mbox` et
    /// un dossier `Messages/` de `.emlx`. C'est UNE boîte, donc UN document —
    /// pas un dossier de milliers de fichiers à parcourir.
    public static let documentPackageExtensions: Set<String> = [
        "rtfd", "pages", "numbers", "key", "mbox",
    ]

    /// REPLI de `URLResourceKey.isPackageKey`.
    ///
    /// `isPackage` est calculé par LaunchServices : il est juste, il connaît les
    /// types installés par les applications de l'utilisateur, et il rend `false`
    /// là où il n'a pas de réponse — un volume réseau monté en SMB, un disque
    /// externe formaté ailleurs, un `.app` copié depuis une sauvegarde. Cette
    /// liste couvre ce cas : elle n'a pas à être exhaustive, seulement à tenir
    /// les paquets qui pèsent (une photothèque, une bibliothèque Musique et un
    /// projet Final Cut se comptent en centaines de milliers de fichiers).
    public static let packageExtensions: Set<String> = [
        // Code exécutable et greffons
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc",
        "qlgenerator", "mdimporter", "prefpane", "component", "saver",
        // Bibliothèques média — les plus gros paquets d'un dossier personnel
        "photoslibrary", "aplibrary", "migratedaperturelibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "theater",
        "fcpbundle", "band", "logicx", "pkpass",
        // Développement
        "xcodeproj", "xcworkspace", "xcarchive", "dsym", "playground", "docset",
        // Images disque et machines virtuelles montées comme dossiers
        "sparsebundle", "vmwarevm", "pvm", "utm",
        // Divers
        "scptd", "download", "webhistory",
    ]

    // MARK: - Dossiers de construction, SOUS un projet logiciel (lot INT-F1)

    /// Fichiers dont la présence dans un dossier en fait un PROJET LOGICIEL.
    /// Comparaison en minuscules (`Package.swift`, `Gemfile`, `Cargo.toml`
    /// portent des majuscules et les volumes macOS sont insensibles à la casse).
    public static let projectMarkers: Set<String> = [
        "package.json", "cargo.toml", "pom.xml",
        "build.gradle", "build.gradle.kts", "pyproject.toml", "setup.py",
        "go.mod", "package.swift", "gemfile", "composer.json", ".git",
    ]

    /// Dossiers de SORTIE : ce qu'un outil de construction fabrique et refait à
    /// l'identique. Ils ne sont exclus que SOUS un projet — et c'est tout
    /// l'intérêt de la règle. `~/Documents/Maison/build` (le dossier des
    /// travaux de la maison), `~/Cours/target` ou un dossier `vendor` de
    /// fournisseurs sont des dossiers de documents ordinaires, que personne ne
    /// comprendrait de voir disparaître de l'index.
    public static let buildFolderComponents: Set<String> = [
        "dist", "build", "out", "target", ".next", ".nuxt", "coverage",
        "vendor", "bower_components", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".dart_tool", ".terraform", "site-packages",
        "__snapshots__",
    ]

    /// `true` si ce NOM peut être un dossier de construction : le crawler s'en
    /// sert pour n'aller lire le contenu du dossier parent que dans ce cas
    /// (un `contentsOfDirectory` par parent, mémorisé).
    public static func mightBeBuildFolder(component: String) -> Bool {
        buildFolderComponents.contains(component.lowercased())
    }

    /// `true` si ce nom de fichier fait de son dossier un projet logiciel.
    public static func isProjectMarker(component: String) -> Bool {
        projectMarkers.contains(component.lowercased())
    }

    /// LA décision, PURE : ce dossier est-il une sortie de construction à
    /// écarter ? Elle demande les deux moitiés — le nom, et le fait que le
    /// dossier PARENT porte un marqueur de projet.
    public static func isExcludedBuildFolder(component: String,
                                             parentContainsProjectMarker: Bool)
        -> Bool {
        parentContainsProjectMarker && mightBeBuildFolder(component: component)
    }

    /// `true` si le composant doit être écarté sur son seul NOM.
    public static func isExcluded(component: String) -> Bool {
        if component.hasPrefix("._") { return true }        // AppleDouble
        let lower = component.lowercased()
        if lower == ".noindex" || lower.hasSuffix(".noindex") { return true }
        return excludedComponents.contains(lower)
    }

    /// `true` si le composant est un paquet opaque (voir `opaqueBundleExtensions`).
    public static func isOpaqueBundle(component: String) -> Bool {
        let ext = (component as NSString).pathExtension.lowercased()
        return opaqueBundleExtensions.contains(ext)
    }

    /// `true` si un RÉPERTOIRE doit être traité comme un fichier opaque.
    ///
    /// `declaredByLaunchServices` est la valeur de `URLResourceKey.isPackageKey`,
    /// `nil` si la lecture des attributs a échoué. Elle FAIT AUTORITÉ quand elle
    /// vaut `true` ; sinon on retombe sur l'extension.
    public static func isPackage(extension ext: String,
                                 declaredByLaunchServices: Bool?) -> Bool {
        if declaredByLaunchServices == true { return true }
        let lower = ext.lowercased()
        return packageExtensions.contains(lower)
            || opaqueBundleExtensions.contains(lower)
            || documentPackageExtensions.contains(lower)
    }

    // MARK: - $HOME/Library

    /// `$HOME` du processus, résolu UNE fois et canonicalisé — sans quoi une
    /// racine passée en `/var/…` (qui devient `/private/var/…` sous
    /// l'énumérateur) ne se comparerait jamais au home.
    public static let homeDirectory: String =
        FouineCrawler.canonicalPath(NSHomeDirectory())

    /// `true` si ce chemin EST `$HOME/Library`.
    ///
    /// Exclu par CHEMIN et jamais par nom : `~/Library` fait couramment 20 à
    /// 50 Go de caches, de conteneurs d'applications et de bases de données —
    /// dont `~/Library/Mail`, `~/Library/Containers`, et la base de Fouine
    /// elle-même —, alors qu'un dossier nommé « Library » DANS un corpus
    /// (bibliothèque de partitions, de références, de PDF) est un dossier
    /// légitime que personne ne comprendrait de voir disparaître.
    ///
    /// Le refus de `~` et de `~/Library` comme RACINE est un autre garde-fou,
    /// tenu ailleurs (`RootPolicy`) : ici on ne fait que ne pas y descendre
    /// quand la racine est `~` ou un de ses parents.
    public static func isHomeLibrary(path: String,
                                     home: String = homeDirectory) -> Bool {
        guard !home.isEmpty, home != "/" else { return false }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.lowercased() == (base + "/Library").lowercased()
    }
}
