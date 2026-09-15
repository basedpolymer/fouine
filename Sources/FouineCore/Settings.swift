// Settings.swift — les réglages, lus par les TROIS exécutables. A-Core, audit U2.
//
// CE QUE CE FICHIER REMPLACE. Les réglages de l'agent étaient des variables
// d'environnement (`AgentPaths.extractJobs`, `ocrBudgetMinutes`, `pollSeconds`)
// à poser dans le plist d'un LaunchAgent enfoui dans le bundle : « des variables
// d'environnement que personne ne peut poser » (audit U2). Les langues de l'OCR,
// elles, étaient écrites en dur (`["fr-FR","en-US"]`, audit X2). Un utilisateur
// n'avait donc AUCUN moyen de changer quoi que ce soit sans recompiler.
//
// TROIS SOURCES, DANS CET ORDRE — la première qui répond gagne :
//
//   1. la VARIABLE D'ENVIRONNEMENT, quand la clé en déclare une. Elle reste
//      prioritaire sur la base, délibérément : c'est ce qui permet de dépanner
//      un agent qui ne démarre pas, et de forcer une valeur dans un test sans
//      écrire dans la base de personne. Les variables `FOUINE_AGENT_*` qui
//      existaient AVANT ce palier gardent leur nom, à l'octet près.
//   2. la table `settings` (schéma v4), écrite par la fenêtre de réglages de
//      l'app et par `fouine config set` ;
//   3. le DÉFAUT, qui est la valeur que le code appliquait jusqu'ici. Aucune
//      base neuve ne se comporte donc différemment d'avant ce palier.
//
// PAS DE CACHE INFINI. `Settings` garde un instantané pendant `ttl` secondes
// (5 par défaut), et chaque passe / chaque lot en redemande un au démarrage :
// un réglage changé dans l'app doit être vu par l'agent au tic suivant de
// `agent.pollSeconds`, sans quoi la fenêtre de réglages ne serait qu'un
// affichage. Un instantané est une VALEUR (`SettingsSnapshot`) : il traverse
// les fils sans verrou, et deux lectures de la même passe rendent forcément la
// même chose.
//
// UNE VALEUR INVALIDE NE FAIT JAMAIS TOMBER PERSONNE. Un `ocr.jobs = 99` en
// base — écrit à la main, ou par une version future — est ramené dans ses
// bornes ; un `agent.requireAC = peut-être` retombe sur le défaut, et
// l'anomalie part dans `warnings`, que l'appelant journalise une fois. Le
// contraire (un agent qui refuse de démarrer à cause d'une ligne de réglage)
// serait exactement le mode de panne que ce palier cherche à supprimer.

import Foundation

// MARK: - Erreur de réglage

/// Une valeur de réglage refusée.
///
/// PAS un `FouineError` : le contrat d'erreurs est GELÉ (§4.2,
/// `Contracts.swift` en lecture seule), et détourner `.extraction` ferait lire
/// « extraction : « abc » n'est pas un entier » à quelqu'un qui vient de taper
/// `fouine config set`. `LocalizedError` pour que `IndexText.describe`, qui
/// retombe sur `localizedDescription`, rende la phrase telle quelle.
public struct SettingsError: LocalizedError, Equatable {

    /// Le motif du refus, sous forme de DONNÉES (palier 3.2, audit U1).
    ///
    /// `message` reste la phrase anglaise que `fouine config set` imprime ;
    /// `reason` est ce dont l'application a besoin pour dire la MÊME chose
    /// dans la langue de l'utilisateur, sans relire du français. `unknown`
    /// couvre les refus qui n'ont pas (encore) de forme typée : le rendu
    /// retombe alors sur `message`.
    public enum Reason: Sendable, Equatable {
        case notABoolean(value: String, key: String)
        case notAnInteger(value: String, key: String, min: Int, max: Int)
        case notARootIdentifier(value: String, key: String)
        case unknownKey(String)
        case unknown
    }

    public let message: String
    public let reason: Reason

    public init(_ message: String, reason: Reason = .unknown) {
        self.message = message
        self.reason = reason
    }

    public var errorDescription: String? { message }
}

// MARK: - Description d'un réglage

/// Un réglage : sa clé, son type, son défaut, sa variable d'environnement.
///
/// Tout est ici et nulle part ailleurs — c'est ce qui permet à `fouine config
/// list`, à la fenêtre de réglages et à `fouine status` de parler des mêmes
/// clés sans qu'aucun des trois n'en tienne une liste de son côté.
public struct SettingSpec: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// `true`/`false` (aussi `1`/`0`, `oui`/`non`).
        case boolean
        /// Entier borné. Hors bornes : TRONQUÉ, jamais refusé — même règle que
        /// `JobsCap` (audit X1), pour la même raison.
        case integer(min: Int, max: Int)
        /// Liste de jetons séparés par des virgules. Vide = liste vide.
        case list
        /// Liste d'entiers positifs séparés par des virgules (identifiants de
        /// racines). Triée et dédoublonnée à l'écriture.
        case identifiers
    }

    public let key: String
    public let kind: Kind
    /// Valeur textuelle appliquée quand ni l'environnement ni la base ne disent
    /// rien. C'est, mot pour mot, ce que le code faisait avant ce palier.
    public let fallback: String
    /// Variable d'environnement qui l'emporte sur la base. `nil` = aucune.
    public let environmentVariable: String?
    /// Une phrase, affichée par `fouine config list` et par l'infobulle de la
    /// fenêtre de réglages.
    public let summary: String

    public init(key: String, kind: Kind, fallback: String,
                environmentVariable: String?, summary: String) {
        self.key = key
        self.kind = kind
        self.fallback = fallback
        self.environmentVariable = environmentVariable
        self.summary = summary
    }

    /// Analyse et NORMALISE une valeur textuelle.
    ///
    /// Rend la forme canonique (`"1,3"` pour `identifiers`, `"true"` pour un
    /// booléen) ou jette une `SettingsError` portant une phrase anglaise —
    /// `fouine config set` en fait son message d'erreur ; la fenêtre de réglages,
    /// elle, refait la sienne depuis `reason`.
    public func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .boolean:
            guard let value = Self.boolean(trimmed) else {
                throw SettingsError(
                    "“\(raw)” is not a boolean for \(key): "
                    + "expected true/false (or 1/0, yes/no)",
                    reason: .notABoolean(value: raw, key: key))
            }
            return value ? "true" : "false"

        case .integer(let low, let high):
            guard let value = Int(trimmed) else {
                throw SettingsError(
                    "“\(raw)” is not an integer for \(key): "
                    + "expected a number between \(low) and \(high)",
                    reason: .notAnInteger(value: raw, key: key,
                                          min: low, max: high))
            }
            return String(Swift.min(high, Swift.max(low, value)))

        case .list:
            return Self.tokens(trimmed).joined(separator: ",")

        case .identifiers:
            var ids: Set<Int64> = []
            for token in Self.tokens(trimmed) {
                guard let id = Int64(token), id > 0 else {
                    throw SettingsError(
                        "“\(token)” is not a root identifier for \(key): "
                        + "expected integers separated by commas "
                        + "(see `fouine root list`)",
                        reason: .notARootIdentifier(value: token, key: key))
                }
                ids.insert(id)
            }
            return ids.sorted().map(String.init).joined(separator: ",")
        }
    }

    /// Les bornes, en clair, pour les messages et l'interface.
    public var range: (min: Int, max: Int)? {
        if case .integer(let low, let high) = kind { return (low, high) }
        return nil
    }

    public static func boolean(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "vrai", "oui", "yes", "on": return true
        case "0", "false", "faux", "non", "no", "off": return false
        default: return nil
        }
    }

    public static func tokens(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Le catalogue

/// Toutes les clés du produit. Ajouter un réglage, c'est ajouter une ligne ici
/// — la CLI, `status` et la fenêtre de réglages suivent sans une modification.
public enum SettingKeys {

    // — OCR (audit X2) ------------------------------------------------------

    /// Langues passées à Vision. Filtrées, À L'EXÉCUTION, sur
    /// `supportedRecognitionLanguages` de la machine : une langue absente de
    /// cette révision de Vision fait échouer TOUTE la requête, elle est donc
    /// écartée avec un avertissement plutôt que transmise (§6.2, audit X2).
    public static let ocrLanguages = SettingSpec(
        key: "ocr.languages", kind: .list, fallback: "fr-FR,en-US",
        environmentVariable: "FOUINE_OCR_LANGUAGES",
        summary: "OCR recognition languages, in order of preference "
               + "(BCP-47 codes, separated by commas).")

    /// Fils de la pompe OCR. Plafond 4, IMPOSÉ : mesuré, 8 fils sont une
    /// régression (0,576 p/s contre 0,699, §6.3).
    public static let ocrJobs = SettingSpec(
        key: "ocr.jobs", kind: .integer(min: 1, max: 4), fallback: "4",
        environmentVariable: "FOUINE_OCR_JOBS",
        summary: "OCR recognition threads (1 to 4; beyond that, throughput DROPS).")

    // — Extraction ----------------------------------------------------------

    /// Fils d'extraction de la CLI et de l'app. Plafond 4 : l'extraction est
    /// bornée par la MÉMOIRE (279 Mo par fil PDFKit, audit X1).
    public static let extractJobs = SettingSpec(
        key: "extract.jobs", kind: .integer(min: 1, max: 4), fallback: "4",
        environmentVariable: "FOUINE_EXTRACT_JOBS",
        summary: "Text extraction threads for the command line and the "
               + "application (1 to 4; ~410 MB of peaks per thread).")

    // — Images seules (audit E4, D2 § 5.12) ----------------------------------

    /// Prise en charge des images seules — dix-neuf extensions depuis INT-F2
    /// (`ImageExtractor.supportedExtensions` : photos, scans, PSD, RAW).
    /// Désactivée par défaut : ne change rien pour un utilisateur existant.
    public static let extractImages = SettingSpec(
        key: "extract.images", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_EXTRACT_IMAGES",
        summary: "Index standalone images (photos, scans, Photoshop and camera RAW files) "
               + "and queue them for OCR (disabled by default).")

    // — Audio et vidéo (lot INT-F3) ------------------------------------------

    /// Prise en charge des fichiers son et vidéo. Éteinte par défaut pour la
    /// même raison que les images : une bibliothèque musicale de 20 000 titres
    /// n'est pas un fonds documentaire, et l'allumer sur un dossier
    /// « Musique » ferait entrer des dizaines de milliers de documents d'une
    /// ligne dans l'index de quelqu'un qui cherchait ses cours.
    public static let extractMedia = SettingSpec(
        key: "extract.media", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_EXTRACT_MEDIA",
        summary: "Index audio and video files: titles, artists, albums, "
               + "descriptions, lyrics and chapters (disabled by default).")

    /// Mise par écrit de la parole, SUR L'APPAREIL. Second étage, sous le
    /// premier : sans `extract.media`, ce réglage ne fait rien. Séparé parce
    /// que les deux coûts n'ont pas d'ordre de grandeur commun — lire les
    /// métadonnées d'un fichier coûte des millisecondes, transcrire une heure
    /// d'enregistrement coûte environ une heure de machine.
    public static let extractTranscribe = SettingSpec(
        key: "extract.transcribe", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_EXTRACT_TRANSCRIBE",
        summary: "Transcribe the speech of audio and video files on this Mac "
               + "(needs `extract.media`, a Dictation language installed and "
               + "Speech Recognition permission; nothing is ever sent out).")

    /// Plafond de durée d'un média à transcrire. Au-delà, seules les
    /// métadonnées sont indexées et `docs.meta` le dit. 120 minutes couvrent un
    /// cours, une réunion ou un film ; le plafond existe pour qu'un fichier de
    /// dix heures ne monopolise pas une passe entière.
    public static let transcribeMaxMinutes = SettingSpec(
        key: "transcribe.max_minutes", kind: .integer(min: 1, max: 600),
        fallback: "120", environmentVariable: "FOUINE_TRANSCRIBE_MAX_MINUTES",
        summary: "Longest recording that will be transcribed, in minutes. "
               + "Beyond it, only the metadata is indexed.")

    // — Agent d'arrière-plan (§5.7) -----------------------------------------

    /// L'agent a SON compteur d'extraction, et le défaut reste 2 : il travaille
    /// pendant que l'utilisateur se sert de la machine (§2.6, P6).
    public static let agentExtractJobs = SettingSpec(
        key: "agent.extractJobs", kind: .integer(min: 1, max: 4), fallback: "2",
        environmentVariable: "FOUINE_AGENT_JOBS",
        summary: "Text extraction threads of the background agent (2 by "
               + "default, not 4: it shares the machine with you).")

    public static let agentOCRBudgetMinutes = SettingSpec(
        key: "agent.ocrBudgetMinutes", kind: .integer(min: 1, max: 120),
        fallback: "10", environmentVariable: "FOUINE_AGENT_OCR_BUDGET_MINUTES",
        summary: "Length of one OCR batch of the agent, in minutes. The "
               + "conditions of §5.7 are decided again for every batch.")

    public static let agentPollSeconds = SettingSpec(
        key: "agent.pollSeconds", kind: .integer(min: 5, max: 3_600),
        fallback: "60", environmentVariable: "FOUINE_AGENT_POLL_SECONDS",
        summary: "How often the conditions, the readability of the roots and "
               + "the settings are checked again, in seconds.")

    /// Condition 1 du §5.7. Désarmable, mais ce n'est pas anodin : c'est ce qui
    /// empêche l'agent de vider la batterie d'un portable.
    public static let agentRequireAC = SettingSpec(
        key: "agent.requireAC", kind: .boolean, fallback: "true",
        environmentVariable: "FOUINE_AGENT_REQUIRE_AC",
        summary: "Only run OCR on AC power. Turned off, the agent also runs "
               + "OCR on battery — and drains it.")

    /// Condition 2 du §5.7.
    public static let agentPauseOnLowPower = SettingSpec(
        key: "agent.pauseOnLowPower", kind: .boolean, fallback: "true",
        environmentVariable: "FOUINE_AGENT_PAUSE_LOW_POWER",
        summary: "Suspend OCR while Low Power Mode is on.")

    /// Conditions 3 ET 4 du §5.7, sous une seule case : `CPU_Speed_Limit ≥ 70 %`
    /// et `thermalState ∈ {nominal, fair}` disent la même chose à l'utilisateur
    /// — « la machine chauffe » —, et les séparer donnerait un réglage que
    /// personne ne saurait régler. `thermalState` seul ne suffit pas (piège
    /// n°4 : il reste à `.fair` pendant que le CPU est bridé à 46 %), les deux
    /// vont donc ensemble.
    ///
    /// Les conditions 5 (verrou libre) et 6 (racines lisibles) ne sont PAS
    /// exposées : ce ne sont pas des préférences mais des conditions de
    /// correction — OCRiser sans le verrou corromprait la file, OCRiser une
    /// racine illisible ne produirait que des échecs.
    public static let agentPauseOnThermal = SettingSpec(
        key: "agent.pauseOnThermal", kind: .boolean, fallback: "true",
        environmentVariable: "FOUINE_AGENT_PAUSE_ON_THERMAL",
        summary: "Suspend OCR while the machine is hot (CPU_Speed_Limit "
               + "below 70%, or a degraded thermal state).")

    /// La campagne de vecteurs, confiée à l'agent (constat PR-21, lot AG1).
    ///
    /// VRAI PAR DÉFAUT, et c'est tout le constat : `fouine embed` était le SEUL
    /// chemin vers la recherche par le sens, en ligne de commande, sur un
    /// public qui n'ouvre pas de terminal. Un acheteur qui coche « Chercher
    /// aussi par le sens » le premier soir travaillait des semaines sur un
    /// fonds amputé, ou laissait sa machine chauffer huit heures d'un coup.
    /// L'agent sait déjà travailler par tranches sous les six conditions du
    /// §5.7 : c'est le même travail, à la même prudence.
    public static let agentPrepareMeaning = SettingSpec(
        key: "agent.prepareMeaning", kind: .boolean, fallback: "true",
        environmentVariable: "FOUINE_AGENT_PREPARE_MEANING",
        summary: "Let the background agent produce the semantic vectors "
               + "(what `fouine embed` does), once the OCR queue is empty and "
               + "under the same six conditions of §5.7.")

    /// Durée d'un lot de vecteurs de l'agent. Même plage et même défaut que
    /// `agent.ocrBudgetMinutes` : c'est la même promesse — dix minutes, puis on
    /// re-décide.
    public static let agentEmbedBudgetMinutes = SettingSpec(
        key: "agent.embedBudgetMinutes", kind: .integer(min: 1, max: 120),
        fallback: "10", environmentVariable: "FOUINE_AGENT_EMBED_BUDGET_MINUTES",
        summary: "Length of one vectorisation batch of the agent, in minutes. "
               + "The conditions of §5.7 are decided again for every batch.")

    /// Fin du dernier lot de vecteurs de l'agent, en secondes epoch. `0` =
    /// jamais.
    ///
    /// HORS DU CATALOGUE `all`, comme `spotlight.synced_at` et pour la même
    /// raison : ce n'est pas une préférence mais un état interne. Il existe
    /// parce que `fouine status` doit pouvoir répondre à « est-ce que ça
    /// avance ? » quand l'agent n'est pas en train de travailler à la seconde
    /// où on regarde — `agent_status` ne porte que l'instant présent.
    public static let agentLastEmbedBatchAt = SettingSpec(
        key: "agent.lastEmbedBatchAt", kind: .integer(min: 0, max: Int.max),
        fallback: "0", environmentVariable: nil,
        summary: "internal: end of the last vectorisation batch of the agent "
               + "(epoch seconds; 0 = never).")

    // — Recherche par le sens (lot MC3) -------------------------------------

    /// Laisser les tableurs hors de la vectorisation (constat PM-09).
    ///
    /// VRAI PAR DÉFAUT, et c'est une décision de QUALITÉ, pas d'espace disque.
    /// Sur la production mesurée, 24 420 des 31 986 pages d'une racine ont plus
    /// de chiffres que de lettres et 99,6 % d'entre elles sont des pages de
    /// tableur : le vecteur d'une colonne de nombres est proche de tous les
    /// autres tableaux du corpus et de rien d'utile, et il prend une place dans
    /// chaque résultat par le sens. Le disque, lui, n'y gagnerait que ~21 Mo
    /// sur un dépassement de 110 Mo déjà acquis. Les pages restent trouvables
    /// au mot près par le canal lexical, comme toute page à vecteur nul.
    public static let embedSkipSpreadsheets = SettingSpec(
        key: "embed.skip_spreadsheets", kind: .boolean, fallback: "true",
        environmentVariable: "FOUINE_EMBED_SKIP_SPREADSHEETS",
        summary: "Leave spreadsheets (csv, xlsx, ods…) out of the meaning "
               + "vectors: a column of numbers describes nothing, and it would "
               + "take a place in every result by meaning. They stay findable "
               + "word for word.")

    // — Racines (audit F4) --------------------------------------------------

    /// Racines épinglées : leurs pages passent en priorité 0, devant tout le
    /// reste (`OCRPriority.pinned`). Le paramètre existait depuis F4 ; il n'y
    /// avait simplement aucun endroit où le renseigner.
    public static let pinnedRoots = SettingSpec(
        key: "roots.pinned", kind: .identifiers, fallback: "",
        environmentVariable: "FOUINE_PINNED_ROOTS",
        summary: "Identifiers of the roots that come first for OCR (their "
               + "pages go ahead of every other page).")

    // — Notifications (audit F7) --------------------------------------------

    public static let notifyOnQueueDrained = SettingSpec(
        key: "notifications.onQueueDrained", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_NOTIFY_QUEUE_DRAINED",
        summary: "Send a notification when the OCR queue runs empty (the "
               + "application must be open).")

    // — Spotlight (lot INT-S1) ----------------------------------------------

    /// Donner les documents indexés à Spotlight (`CSSearchableIndex`).
    ///
    /// Allumé par défaut : c'est la promesse du produit — « Spotlight n'a
    /// jamais lu vos scans, Fouine si » — et elle ne vaut que si elle marche
    /// sans réglage. L'index de Spotlight est LOCAL, rien ne quitte le Mac.
    public static let spotlightEnabled = SettingSpec(
        key: "spotlight.enabled", kind: .boolean, fallback: "true",
        environmentVariable: "FOUINE_SPOTLIGHT",
        summary: "Hand the indexed documents to Spotlight so they can be found "
               + "from the magnifying glass of macOS (local index, nothing "
               + "leaves the Mac).")

    /// Portée : tout, ou seulement ce que Spotlight ne sait pas lire.
    ///
    /// Éteint par défaut, et c'est le choix de fond : donner un `.docx` que
    /// Spotlight lit déjà produirait DEUX résultats pour le même fichier, l'un
    /// sous le nom de Fouine. Ce qui manque à Spotlight — les pages scannées,
    /// les DjVu, les bandes dessinées (`SpotlightPolicy.blindExtensions`) —
    /// est donné ; le reste ne l'est que sur demande.
    public static let spotlightAllDocuments = SettingSpec(
        key: "spotlight.all_documents", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_SPOTLIGHT_ALL",
        summary: "Hand EVERY indexed document to Spotlight, not only the ones "
               + "Spotlight cannot read by itself (duplicates its own results).")

    /// Plafond du texte donné par document, en Kio. 1 Mio par défaut : au-delà,
    /// on recopie un corpus entier dans un second index sans rien gagner —
    /// Spotlight rend un fichier, Fouine rend une page.
    public static let spotlightTextKB = SettingSpec(
        key: "spotlight.text_kb", kind: .integer(min: 64, max: 4_096),
        fallback: "1024", environmentVariable: "FOUINE_SPOTLIGHT_TEXT_KB",
        summary: "Maximum text handed to Spotlight per document, in KiB "
               + "(64 to 4096; cut on a page boundary).")

    /// Marqueur de synchronisation : secondes epoch de la dernière remise.
    ///
    /// HORS DU CATALOGUE `all`, et c'est délibéré. Ce n'est pas une préférence
    /// mais un état interne : `fouine config list` et la fenêtre de réglages
    /// listent `all`, et personne n'a à régler « la date de la dernière remise
    /// à Spotlight » — la fenêtre a un bouton pour cela. Un test de l'app
    /// exige d'ailleurs que chaque clé de `all` ait une phrase TRADUITE, et
    /// traduire en français un marqueur que l'utilisateur ne verra jamais
    /// n'aurait aucun sens.
    ///
    /// Il vit tout de même dans la table `settings`, et pas dans
    /// `UserDefaults`, pour la raison qui vaut pour tout le reste : les trois
    /// exécutables partagent cette table, et un marqueur invisible à l'agent
    /// ferait redonner en boucle ce qu'il vient d'indexer. `0` = tout
    /// redonner, après avoir tout effacé.
    public static let spotlightSyncedAt = SettingSpec(
        key: "spotlight.synced_at", kind: .integer(min: 0, max: Int.max),
        fallback: "0", environmentVariable: nil,
        summary: "internal: last Spotlight sync (epoch seconds; 0 hands "
               + "everything over again).")

    /// Documents donnés par la dernière remise QUI A DONNÉ QUELQUE CHOSE.
    ///
    /// Hors catalogue `all`, comme le marqueur ci-dessus, et pour la même
    /// raison. Il existe parce qu'un don à Spotlight était invérifiable :
    /// `mdfind` n'interroge pas Core Spotlight, le journal ne dit rien, et le
    /// dossier de Spotlight est protégé — ni l'utilisateur ni un dépanneur ne
    /// pouvaient savoir si la fonction marchait (audit BU-26). La fenêtre de
    /// réglages en fait une ligne sous les deux boutons.
    ///
    /// « qui a donné quelque chose » : une remise qui ne trouve rien de neuf
    /// n'écrase pas le compte. Sans cela, la ligne dirait « 0 document » dès
    /// la première ouverture de Fouine suivant une remise complète, alors que
    /// des milliers de documents sont bel et bien dans Spotlight.
    public static let spotlightSyncedCount = SettingSpec(
        key: "spotlight.synced_count", kind: .integer(min: 0, max: Int.max),
        fallback: "0", environmentVariable: nil,
        summary: "internal: documents handed to Spotlight by the last "
               + "handover that gave something.")

    // — Sources applicatives (lot INT-F4) -----------------------------------

    /// Lire les notes d'Apple Notes et les recopier dans le dossier de Fouine.
    ///
    /// Éteint par défaut, comme les images et les médias : allumer copie des
    /// données personnelles d'une AUTRE application dans le dossier de Fouine,
    /// et cela ne se fait pas sans un geste. La copie est ce qui rend les
    /// notes cherchables sans nouveau chemin d'indexation : chaque note
    /// devient un fichier Markdown sous `FouinePaths.sourcesDirectory()`, et
    /// ce dossier est une racine ordinaire.
    ///
    /// La lecture exige « Accès complet au disque » : la base d'Apple Notes est
    /// protégée par TCC. Sans l'autorisation, la lecture échoue proprement
    /// (`SourceError.accessDenied`) et l'application dit le geste à faire.
    public static let sourceNotes = SettingSpec(
        key: "sources.notes", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_SOURCE_NOTES",
        summary: "Index the notes of Apple Notes: their text is copied into "
               + "Fouine's own folder (needs Full Disk Access; disabled by "
               + "default).")

    /// Idem pour Bear. Sa base n'est pas protégée par TCC de la même façon,
    /// mais le mécanisme est le même — une seule mécanique pour les deux.
    public static let sourceBear = SettingSpec(
        key: "sources.bear", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_SOURCE_BEAR",
        summary: "Index the notes of Bear: their text is copied into Fouine's "
               + "own folder (disabled by default).")

    /// Idem pour Anki (lot AN1) : un fichier par paquet, une page par carte.
    /// Pas de TCC : la collection vit sous `~/Library/Application Support`.
    public static let sourceAnki = SettingSpec(
        key: "sources.anki", kind: .boolean, fallback: "false",
        environmentVariable: "FOUINE_SOURCE_ANKI",
        summary: "Index the flashcards of Anki: the text of each card is copied "
               + "into Fouine's own folder, one file per deck (disabled by "
               + "default).")

    /// Le catalogue, dans l'ordre d'affichage.
    public static let all: [SettingSpec] = [
        ocrLanguages, ocrJobs, extractJobs, extractImages,
        extractMedia, extractTranscribe, transcribeMaxMinutes,
        agentExtractJobs, agentOCRBudgetMinutes, agentPollSeconds,
        agentRequireAC, agentPauseOnLowPower, agentPauseOnThermal,
        agentPrepareMeaning, agentEmbedBudgetMinutes,
        embedSkipSpreadsheets,
        pinnedRoots, notifyOnQueueDrained,
        spotlightEnabled, spotlightAllDocuments, spotlightTextKB,
        sourceNotes, sourceBear, sourceAnki,
    ]

    public static func spec(for key: String) -> SettingSpec? {
        all.first { $0.key == key }
    }
}

// MARK: - Instantané

/// D'où vient la valeur effective d'un réglage. Affiché par `fouine config
/// list` et par `fouine status` : sans cela, un utilisateur dont l'agent lit
/// `FOUINE_AGENT_JOBS=1` posé dans un plist ne comprendrait jamais pourquoi la
/// valeur qu'il a saisie dans la fenêtre de réglages ne s'applique pas.
public enum SettingSource: String, Sendable {
    case fallback     // le défaut du code
    case database     // la table `settings`
    case environment  // une variable d'environnement

    /// ANGLAIS, comme tout ce que la CLI imprime (palier 3.5) ; la fenêtre de
    /// réglages, elle, rend le sien depuis le catalogue.
    public var english: String {
        switch self {
        case .fallback:    return "default"
        case .database:    return "settings"
        case .environment: return "environment"
        }
    }
}

/// Les réglages effectifs, figés à un instant. VALEUR : franchit les fils sans
/// verrou, et deux lectures d'une même passe rendent la même chose.
public struct SettingsSnapshot: Sendable {

    /// Contenu de la table `settings`, tel quel.
    public let rows: [String: String]
    /// Environnement retenu (injectable, pour les tests).
    public let environment: [String: String]
    /// Valeurs illisibles rencontrées à la lecture. L'appelant les journalise
    /// UNE fois ; aucune ne fait échouer quoi que ce soit.
    public let warnings: [String]

    public init(rows: [String: String],
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(rows: rows, environment: environment, warnings: nil)
    }

    public init(rows: [String: String],
                environment: [String: String],
                warnings: [String]?) {
        if let warnings {
            self.rows = rows
            self.environment = environment
            self.warnings = warnings
            return
        }
        var computedWarnings: [String] = []
        // Les anomalies sont détectées à la CONSTRUCTION, pas à chaque lecture :
        // un `ocr.jobs = abc` en base ne doit pas produire une ligne de journal
        // par page OCRisée.
        for spec in SettingKeys.all {
            if let raw = rows[spec.key],
               (try? spec.normalize(raw)) == nil {
                computedWarnings.append("setting “\(spec.key)” is unreadable in the "
                                        + "database (“\(raw)”): default value applied")
            }
            if let name = spec.environmentVariable, let raw = environment[name],
               !raw.isEmpty, (try? spec.normalize(raw)) == nil {
                computedWarnings.append("variable \(name) is unreadable (“\(raw)”): "
                                        + "default value applied")
            }
        }
        self.rows = rows
        self.environment = environment
        self.warnings = computedWarnings
    }

    /// Charge les réglages depuis une source en signalant tout échec de lecture.
    /// Ne propage jamais d'erreur : en cas de panne, rend un snapshot par défaut
    /// (ou basé sur l'environnement) et un avertissement en anglais (audit C2-11).
    public static func load(
        from store: (any SettingsReadableStore)?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (snapshot: SettingsSnapshot, warning: String?) {
        guard let store else {
            return (SettingsSnapshot(rows: [:], environment: environment), nil)
        }
        do {
            let rows = try store.settingsRows()
            return (SettingsSnapshot(rows: rows, environment: environment), nil)
        } catch {
            let warning = "cannot read settings from the database: \(error.localizedDescription) — default settings applied"
            return (SettingsSnapshot(rows: [:], environment: environment), warning)
        }
    }

    /// Instantané SANS base : uniquement l'environnement et les défauts. Sert
    /// aux chemins qui n'ont pas de store sous la main (et aux tests).
    public static func environmentOnly(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SettingsSnapshot {
        SettingsSnapshot(rows: [:], environment: environment)
    }

    // MARK: Lecture

    /// La valeur textuelle effective et sa provenance.
    public func effective(_ spec: SettingSpec) -> (value: String, source: SettingSource) {
        if let name = spec.environmentVariable, let raw = environment[name],
           !raw.isEmpty, let value = try? spec.normalize(raw) {
            return (value, .environment)
        }
        if let raw = rows[spec.key], let value = try? spec.normalize(raw) {
            return (value, .database)
        }
        // Le défaut passe par `normalize` lui aussi : une faute de frappe dans
        // le catalogue se verrait au premier test plutôt qu'en production.
        return ((try? spec.normalize(spec.fallback)) ?? spec.fallback, .fallback)
    }

    public func string(_ spec: SettingSpec) -> String { effective(spec).value }

    public func int(_ spec: SettingSpec) -> Int {
        let raw = effective(spec).value
        guard let value = Int(raw) else {
            return Int(spec.fallback) ?? 0
        }
        guard let bounds = spec.range else { return value }
        return Swift.min(bounds.max, Swift.max(bounds.min, value))
    }

    public func bool(_ spec: SettingSpec) -> Bool {
        SettingSpec.boolean(effective(spec).value) ?? false
    }

    public func list(_ spec: SettingSpec) -> [String] {
        SettingSpec.tokens(effective(spec).value)
    }

    public func identifiers(_ spec: SettingSpec) -> Set<Int64> {
        Set(list(spec).compactMap(Int64.init))
    }

    /// Tout le catalogue, pour `fouine config list` et `fouine status`.
    public func table() -> [(spec: SettingSpec, value: String, source: SettingSource)] {
        SettingKeys.all.map { spec in
            let e = effective(spec)
            return (spec, e.value, e.source)
        }
    }

    // MARK: Raccourcis nommés

    /// Racines épinglées (audit F4).
    public var pinnedRoots: Set<Int64> { identifiers(SettingKeys.pinnedRoots) }
    public var ocrLanguages: [String] { list(SettingKeys.ocrLanguages) }
    public var ocrJobs: Int { int(SettingKeys.ocrJobs) }
    public var extractJobs: Int { int(SettingKeys.extractJobs) }
    public var extractImages: Bool { bool(SettingKeys.extractImages) }
    public var extractMedia: Bool { bool(SettingKeys.extractMedia) }
    /// La transcription N'EST JAMAIS armée seule : sans `extract.media`, aucun
    /// fichier son ou vidéo n'entre dans l'index, et un `extract.transcribe`
    /// vrai n'aurait rien à transcrire. Le « et » est ici plutôt que chez
    /// chaque appelant, pour qu'il n'y ait qu'un endroit à lire.
    public var extractTranscribe: Bool {
        bool(SettingKeys.extractMedia) && bool(SettingKeys.extractTranscribe)
    }
    public var transcribeMaxMinutes: Int { int(SettingKeys.transcribeMaxMinutes) }
    public var agentExtractJobs: Int { int(SettingKeys.agentExtractJobs) }
    public var agentOCRBudgetMinutes: Int { int(SettingKeys.agentOCRBudgetMinutes) }
    public var agentPollSeconds: Int { int(SettingKeys.agentPollSeconds) }
    public var agentRequireAC: Bool { bool(SettingKeys.agentRequireAC) }
    public var agentPauseOnLowPower: Bool { bool(SettingKeys.agentPauseOnLowPower) }
    public var agentPauseOnThermal: Bool { bool(SettingKeys.agentPauseOnThermal) }
    public var notifyOnQueueDrained: Bool { bool(SettingKeys.notifyOnQueueDrained) }
    /// Préparation de la recherche par le sens en arrière-plan (lot AG1).
    public var agentPrepareMeaning: Bool { bool(SettingKeys.agentPrepareMeaning) }
    public var agentEmbedBudgetMinutes: Int { int(SettingKeys.agentEmbedBudgetMinutes) }
    /// Tableurs hors vectorisation (lot MC3, constat PM-09).
    public var embedSkipSpreadsheets: Bool { bool(SettingKeys.embedSkipSpreadsheets) }
    /// Fin du dernier lot de vecteurs de l'agent, en secondes epoch. `0` = jamais.
    public var agentLastEmbedBatchAt: Double {
        Double(int(SettingKeys.agentLastEmbedBatchAt))
    }

    /// Spotlight (lot INT-S1).
    public var spotlightEnabled: Bool { bool(SettingKeys.spotlightEnabled) }
    public var spotlightAllDocuments: Bool { bool(SettingKeys.spotlightAllDocuments) }
    public var spotlightTextKB: Int { int(SettingKeys.spotlightTextKB) }
    /// Dernière remise à Spotlight, en secondes epoch. `0` = jamais.
    public var spotlightSyncedAt: Double {
        Double(int(SettingKeys.spotlightSyncedAt))
    }

    /// Sources applicatives (lot INT-F4).
    public var sourceNotes: Bool { bool(SettingKeys.sourceNotes) }
    public var sourceBear: Bool { bool(SettingKeys.sourceBear) }
    public var sourceAnki: Bool { bool(SettingKeys.sourceAnki) }
    /// Vrai dès qu'UNE source est allumée. C'est le booléen que la passe
    /// d'indexation lit en premier : source éteinte, coût nul.
    public var anySourceEnabled: Bool { sourceNotes || sourceBear || sourceAnki }
}

// MARK: - Source des réglages

/// Ce qu'un porteur de réglages doit savoir faire. `GRDBStore` s'y conforme ;
/// le protocole existe pour que `IndexPass` et les tests n'aient pas à ouvrir
/// une vraie base pour lire trois clés.
/// Ce qu'un lecteur de réglages doit savoir faire (audit C2-11).
public protocol SettingsReadableStore: Sendable {
    /// Toute la table `settings`, en une requête.
    func settingsRows() throws -> [String: String]
}

public protocol SettingsStore: SettingsReadableStore, AnyObject, Sendable {
    /// Écrit (ou remplace) un réglage DÉJÀ normalisé.
    func writeSetting(_ key: String, _ value: String) throws
    /// Supprime un réglage : la valeur redevient le défaut du code.
    func removeSetting(_ key: String) throws
}

// MARK: - Lecteur avec cache court

/// Lecteur de réglages à cache borné.
///
/// `snapshot()` rend l'instantané courant, en le rafraîchissant s'il a plus de
/// `ttl` secondes. Cinq secondes par défaut : assez pour qu'une passe
/// d'indexation ne rouvre pas la table à chaque document, trop peu pour qu'un
/// changement fait dans l'app se perde — l'agent, lui, force un rafraîchissement
/// au démarrage de chaque lot et à chaque tic de `agent.pollSeconds`.
public final class Settings: @unchecked Sendable {

    public static let defaultTTL: TimeInterval = 5

    private let store: any SettingsStore
    private let ttl: TimeInterval
    private let environment: [String: String]
    private let mutex = NSLock()
    private var cached: SettingsSnapshot?
    private var cachedAt = Date.distantPast

    public init(store: any SettingsStore, ttl: TimeInterval = Settings.defaultTTL,
                environment: [String: String]
                    = ProcessInfo.processInfo.environment) {
        self.store = store
        self.ttl = ttl
        self.environment = environment
    }

    /// L'instantané courant. Une panne de lecture rend le DERNIER instantané
    /// connu, ou celui des défauts : un réglage illisible ne doit pas arrêter
    /// une passe d'indexation.
    public func snapshot() -> SettingsSnapshot {
        mutex.lock()
        if let cached, Date().timeIntervalSince(cachedAt) < ttl {
            mutex.unlock()
            return cached
        }
        mutex.unlock()
        return reload()
    }

    @discardableResult
    public func reload() -> SettingsSnapshot {
        let (fresh, warning) = SettingsSnapshot.load(from: store, environment: environment)
        let finalSnapshot: SettingsSnapshot
        if let warning {
            var combined = fresh.warnings
            combined.append(warning)
            finalSnapshot = SettingsSnapshot(rows: fresh.rows, environment: fresh.environment, warnings: combined)
        } else {
            finalSnapshot = fresh
        }
        mutex.lock()
        cached = finalSnapshot
        cachedAt = Date()
        mutex.unlock()
        return finalSnapshot
    }

    // MARK: Écriture

    /// Valide puis écrit. Rend la valeur normalisée telle qu'elle a été posée.
    @discardableResult
    public func set(_ key: String, _ raw: String) throws -> String {
        guard let spec = SettingKeys.spec(for: key) else {
            throw SettingsError(Self.unknownKeyMessage(key),
                                reason: .unknownKey(key))
        }
        let value = try spec.normalize(raw)
        try store.writeSetting(key, value)
        invalidate()
        return value
    }

    /// Efface le réglage : la valeur redevient celle du code (ou celle de
    /// l'environnement, s'il y en a une).
    public func reset(_ key: String) throws {
        guard SettingKeys.spec(for: key) != nil else {
            throw SettingsError(Self.unknownKeyMessage(key),
                                reason: .unknownKey(key))
        }
        try store.removeSetting(key)
        invalidate()
    }

    public func invalidate() {
        mutex.lock(); cached = nil; cachedAt = .distantPast; mutex.unlock()
    }

    /// « clé inconnue » avec la liste des clés valides : sans elle, une faute de
    /// frappe dans `fouine config set` ne laisse rien à faire qu'ouvrir le code.
    public static func unknownKeyMessage(_ key: String) -> String {
        "unknown setting: “\(key)”. Valid keys: "
        + SettingKeys.all.map(\.key).joined(separator: ", ")
    }
}
