// LocalizedText.swift — ce que l'app dit des erreurs et de l'agent, DANS LA
// LANGUE DE L'UTILISATEUR (palier 3.2, audit U1). Propriété : A-App.
//
// L'app rendait ses erreurs par `IndexText.describe` (FouineIndex), qui produit
// la phrase FRANÇAISE du §4.3 — celle de la CLI, de l'agent et de `docs.err`.
// C'était le bon choix tant que Fouine ne parlait qu'une langue ; ça ne l'est
// plus : un anglophone lisait « racine illisible : … — Réglages Système ▸ … »
// dans une fenêtre par ailleurs anglaise.
//
// LA RÈGLE, ET ELLE N'EST PAS NÉGOCIABLE : rien ici ne lit une phrase venue du
// cœur pour en déduire quoi que ce soit. Chaque rendu part des DONNÉES de
// l'erreur — le cas de l'enum, ses valeurs associées — et rien d'autre. C'est
// ce qui fait que le passage de la CLI à l'anglais (vague suivante de ce
// palier) ne cassera rien ici : `IndexText` peut changer toutes ses phrases,
// `ErrorText` n'en dépend plus.
//
// Ce qui reste opaque est ASSUMÉ et nommé : `.extraction(m)`, `.ocr(m)` et
// `.databaseFailure(m)` transportent un détail TECHNIQUE (nom d'outil, message
// système, ligne de SQLite) qu'aucun catalogue ne peut traduire. L'app préfixe
// alors d'un libellé localisé — « extraction : », « OCR : », « base : » — et
// laisse le détail tel quel, ce qui est exactement ce qu'on veut d'un message
// destiné à être recopié dans un rapport de bogue.

import Foundation
import FouineCore
import FouineCrawl
import FouineEmbed

/// Le nom des phases de l'agent, tel que la barre latérale les affiche.
///
/// `AgentStatusRecord.Phase.french` reste la source du journal et de `fouine
/// status` ; l'app, elle, part du CAS et non de la phrase.
enum AgentPhaseText {
    static func name(_ phase: AgentStatusRecord.Phase) -> String {
        switch phase {
        case .idle:    return String(localized: "idle")
        case .crawl:   return String(localized: "walking the folders")
        case .extract: return String(localized: "extracting text")
        case .ocr:     return String(localized: "text recognition (OCR)")
        case .waiting: return String(localized: "waiting")
        case .stopped: return String(localized: "stopped")
        // La MÊME phrase que l'activité de la carte « Index » (AG1) : c'est le
        // même travail, qu'il vienne de l'application ou de l'arrière-plan.
        case .preparingMeaning:
            return String(localized: "Preparing search by meaning")
        }
    }
}

/// Le geste TCC du §7.1, dans la langue de l'utilisateur.
///
/// `RootProbe.tccGuidance` (FouineCore) est la phrase ANGLAISE du cœur, celle
/// que la CLI, l'agent et `docs.err` impriment ; l'app compose la sienne.
enum TCCText {
    static var guidance: String {
        String(localized: "System Settings ▸ Privacy & Security ▸ Files and Folders ▸ Fouine ▸ Documents Folder (or “Full Disk Access” if Fouine must keep the index up to date while it is closed).")
    }
}

/// Le texte du bandeau d'autorisation de la fenêtre principale (§7.1), ou
/// `nil` quand il n'a rien à dire.
///
/// Seules les racines actives, montées et REFUSÉES par macOS comptent : le
/// bandeau porte « Open Settings », et un disque débranché, un dossier
/// déplacé ou vide ne s'y réparent pas. Le motif de chaque racine (« disk not
/// plugged in », « read denied (…) ») est un sous-titre de barre latérale :
/// collé après une phrase, il faisait un fragment en minuscules.
enum PermissionBannerText {
    static func make(_ roots: [RootStatus]) -> String? {
        let denied = roots.filter {
            $0.record.enabled && $0.mounted && !$0.readable
                && $0.probeReason == .permissionDenied
        }
        guard !denied.isEmpty else { return nil }
        let names = denied
            .map { String(localized: "“\($0.label)”") }
            .joined(separator: ", ")
        return String(localized: "Fouine is not allowed to read \(names). Results already indexed stay searchable, but preview and indexing are impossible. To allow it: \(TCCText.guidance)")
    }
}

/// Pourquoi une racine ne se lit pas, dans la langue de l'utilisateur.
///
/// `RootProbe.Reason` (palier 3.5) porte le motif sous forme de DONNÉES : la
/// CLI en tire sa phrase anglaise, l'app la sienne. Un motif `.system` porte un
/// message du système, déjà localisé par macOS — il passe tel quel, comme
/// `.extraction(m)` dans `ErrorText`.
enum RootProbeText {
    static func describe(_ reason: RootProbe.Reason) -> String {
        switch reason {
        case .permissionDenied:
            // « TCC » est un sigle interne à Apple : il n'apparaît nulle part
            // dans macOS, et l'utilisateur qui le lit ne sait pas quoi en
            // faire. Le motif nomme le panneau des Réglages Système, celui
            // qu'il doit ouvrir (audit B1-25).
            return String(localized: "read denied (privacy settings or file permissions)")
        case .missing:
            return String(localized: "folder not found (moved, renamed or deleted)")
        case .noReadableFile:
            return String(localized: "no readable file in this folder")
        case .system(let detail):
            return detail
        }
    }

    /// Le motif d'un `FouineError.rootUnreadable`, relu depuis son
    /// enregistrement. `nil` quand il n'y en a pas.
    static func describe(raw: String?) -> String? {
        RootProbe.reason(raw).map(describe)
    }
}

/// Pourquoi un dossier ne peut pas devenir une racine, dans la langue de
/// l'utilisateur (`RootPolicy.Refusal`, palier 3.5).
///
/// Les phrases françaises sont celles du palier 2, recopiées MOT POUR MOT dans
/// le catalogue : un utilisateur français doit lire exactement ce qu'il lisait.
enum RootPolicyText {
    static func describe(_ refusal: RootPolicy.Refusal) -> String {
        switch refusal {
        case .missing(let path):
            return String(localized: "“\(path)” cannot be found (folder moved, renamed or deleted).")
        case .notADirectory(let path):
            return String(localized: "“\(path)” is a file, not a folder. Choose the folder that contains it.")
        case .wholeDisk:
            return String(localized: "A whole disk cannot be added: Fouine would index the system, the caches and its own database. Choose a folder of documents.")
        case .homeDirectory:
            return String(localized: "Your whole home folder cannot be added: it holds your system files, the caches and Fouine's own index. Choose a folder inside it: Documents, Desktop, a folder of books…")
        case .privateFolder:
            return String(localized: "“/private” is a system folder: it only holds the system's temporary files.")
        case .systemTree(let path):
            return String(localized: "“\(path)” is a system folder: it holds no documents to index.")
        case .applicationData(_, let application):
            // Sans chemin : la personne a choisi le dossier pour ses cartes ou
            // ses notes, c'est d'elles qu'on lui parle, et du geste à faire.
            switch application {
            case .anki:
                return String(localized: "Your Anki cards are not added as a folder: turn on Anki in Settings ▸ Folders, under “Applications”. Fouine then finds every card and keeps up with the new ones.")
            case .notes:
                return String(localized: "Your Apple Notes are not added as a folder: turn on Apple Notes in Settings ▸ Folders, under “Applications”. Fouine then finds every note and keeps up with the new ones.")
            case .bear:
                return String(localized: "Your Bear notes are not added as a folder: turn on Bear in Settings ▸ Folders, under “Applications”. Fouine then finds every note and keeps up with the new ones.")
            }
        case .permissionDenied(let path):
            return String(localized: "“\(path)” is not readable by Fouine. \(TCCText.guidance)")
        case .unreadable(let path, let detail):
            // `detail` vient du système : macOS l'a déjà localisé.
            return String(localized: "“\(path)” is not readable: \(detail)")
        }
    }

    static func describe(_ advisory: RootPolicy.Advisory) -> String {
        switch advisory {
        case .downloads:
            return String(localized: "The Downloads folder needs a specific macOS permission: if indexing turns up nothing, grant it to Fouine in System Settings ▸ Privacy & Security ▸ Files and Folders.")
        }
    }
}

/// Les étapes de l'installation du modèle sémantique (audit D6).
///
/// `ModelDownloadPhase.label` reste le libellé FRANÇAIS du moteur, celui que
/// `fouine model download` imprime dans son journal de progression ; l'app part
/// du CAS, comme partout ailleurs depuis le palier 3.2.
/// Ce que l'agent DIT qu'il fait, dans la langue de l'utilisateur.
///
/// Le `detail` publié par l'agent est un JETON SANS LANGUE
/// (`AgentStatusDetail`) : la CLI et le serveur MCP le rendent en anglais, la
/// barre latérale ici. Jusqu'au lot K5, seul `queue-drained` était traduit et
/// tout le reste — « starting up », « 20226 page(s) queued », « 315 page(s)
/// left » — s'affichait EN ANGLAIS dans une interface française (audit A1m-10).
///
/// Deux choses passent telles quelles, et c'est voulu : un NOM (document,
/// dossier — un nom de fichier ne se traduit pas) et un jeton INCONNU, écrit
/// par un agent d'une autre version. Lire quelque chose vaut mieux que rien.
enum AgentDetailText {
    static func text(_ detail: String) -> String {
        switch AgentStatusDetail.parse(detail) {
        case .queueDrained:
            return String(localized: "Every scanned page has been read")
        case .starting:
            return String(localized: "starting up")
        case .signalReceived:
            // Le NOM du signal reste dans la CLI et le journal : ici, on dit ce
            // qui se passe, pas le moyen technique par lequel il se passe.
            return String(localized: "stopping")
        case .pagesQueued(let n):
            return String(localized: "\(n) scanned page(s) to read")
        case .pagesLeft(let n):
            return String(localized: "\(n) page(s) still to recognise")
        case .document(let name):
            return name
        case .free(let text):
            return text
        }
    }
}

enum ModelPhaseText {
    static func name(_ phase: ModelDownloadPhase) -> String {
        switch phase {
        case .downloading: return String(localized: "downloading")
        case .verifying:   return String(localized: "checking the fingerprint")
        case .extracting:  return String(localized: "unpacking")
        case .installing:  return String(localized: "installing")
        }
    }
}

/// Ce que FAIT le détenteur du verrou, tel que l'écran d'échec d'ouverture le
/// dit : « background indexing, since 10:32 ». Ni « verrou », ni « pid » : le
/// public n'est pas technicien, et l'heure suffit à décider d'attendre.
enum LockActivityText {
    static func describe(_ holder: LockHolder) -> String {
        switch holder.role {
        case .agent: return String(localized: "background indexing, since \(holder.clockText)")
        case .cli:   return String(localized: "command line, since \(holder.clockText)")
        case .app:   return String(localized: "this application, since \(holder.clockText)")
        }
    }
}

/// La marge sémantique d'une page, DITE et non chiffrée (lot J2).
///
/// `HybridInfo.z` vaut `(cos − μ) / σ` : le nombre d'écarts-types qui séparent
/// cette page de la page moyenne balayée par la requête. C'est la bonne mesure
/// — le cosinus brut se lisait comme un pourcentage de pertinence (C2-01) —
/// mais « +2,4 σ » est illisible pour qui ne connaît pas l'écart-type, c'est-à-
/// dire pour le public de Fouine.
///
/// Les paliers sont calibrés sur le corpus de référence, où les marges
/// s'étalent de +0,3 à +3,5 : au-delà de 2,5 la page est manifestement à part,
/// en dessous de 0,75 elle n'est qu'un peu au-dessus de la moyenne.
enum SemanticMarginText {
    static func describe(_ z: Double) -> String {
        if z >= 2.5 {
            return String(localized: "It is far closer to the meaning of your search than the other pages.")
        }
        if z >= 1.5 {
            return String(localized: "It is clearly closer to the meaning of your search than the other pages.")
        }
        if z >= 0.75 {
            return String(localized: "It is closer to the meaning of your search than the other pages.")
        }
        return String(localized: "It is a little closer to the meaning of your search than the other pages.")
    }
}

/// Le nom d'une langue et le libellé d'une fenêtre de date, tels que la barre
/// latérale et les pastilles de filtre les affichent (lot U2, R-07 et R-10).
///
/// `docs.lang` porte un code ISO 639-1 (« fr », « en ») : c'est le vocabulaire
/// du moteur, pas celui du lecteur. `Locale.localizedString(forLanguageCode:)`
/// le rend dans la langue de l'utilisateur — « Français », « Anglais » pour un
/// Mac en français, « French », « English » pour un Mac en anglais — sans qu'il
/// y ait un seul nom de langue à traduire dans le catalogue.
///
/// Deux cas où le système ne sait rien dire : le jeton « und » des documents
/// dont la langue n'a pas été déterminée (phrase à nous), et un code que
/// `Locale` ne connaît pas — on rend alors le code lui-même, majuscule, plutôt
/// qu'une ligne vide.
enum LanguageNames {

    static func label(_ code: String) -> String {
        if code == FacetKey.undeterminedLanguage || code.isEmpty {
            return String(localized: "language not determined")
        }
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            // « français » sort en minuscule d'une locale française : une
            // valeur de facette s'affiche capitalisée, comme « Livres ».
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code.uppercased()
    }

    /// La provenance d'une page, en mots. Les étiquettes brutes viennent de
    /// `GRDBStore.sourceLabel` : « ocr_accurate » n'est pas une phrase, et le
    /// mot « scanné » est le seul que le public de Fouine reconnaisse.
    /// Partagée entre la facette « Origine du texte » et la puce de filtre
    /// actif, qui ne doivent pas nommer la même chose de deux façons.
    /// LA MÊME TABLE POUR LES QUATRE SURFACES (AP-03). La facette disait
    /// « texte tapé » quand l'en-tête de l'aperçu, le pictogramme d'une ligne
    /// de résultat et le libellé parlé disaient « texte natif » — pour la MÊME
    /// page, sur le MÊME écran. Trois autres paires divergeaient de la même
    /// façon (« OCR rapide (hérité) », « OCR importé » / « texte OCR
    /// importé »). Toute surface qui nomme une provenance passe par ici ; ce
    /// que la vue connaît, c'est `(PageSource, OCREngineID)`, et c'est donc à
    /// cette table de faire la traduction vers l'étiquette du moteur.
    static func sourceLabel(_ source: PageSource, engine: OCREngineID) -> String {
        // La couche texte VENAIT AVEC LE FICHIER : ni Fouine ni sa
        // reconnaissance n'y sont pour rien, et c'est ce qu'il faut dire à qui
        // juge la fiabilité de ce qu'il lit. Le moteur, lui, ne distingue pas
        // ce cas — sa facette ne connaît que `page_src.src` —, d'où le seul
        // libellé qui ne vienne pas de sa table.
        if engine == .external, source != .native, source != .transcript {
            return String(localized: "scanned, recognised before Fouine")
        }
        // L'étiquette du MOTEUR (`GRDBStore.sourceLabel`), celle-là même que
        // la facette « Origine du texte » affiche : passer par elle est ce qui
        // rend une divergence impossible.
        return sourceLabel(GRDBStore.sourceLabel(source.rawValue))
    }

    static func sourceLabel(_ raw: String) -> String {
        switch raw {
        case "native": return String(localized: "typed text")
        case "ocr_accurate": return String(localized: "scanned, recognised by Fouine")
        // Ni « transcription » ni « reconnaissance vocale » : la phrase dit ce
        // qui s'est passé, avec les mots de tout le monde (INT-F3).
        case "transcript": return String(localized: "transcribed from the audio")
        default: return raw
        }
    }

    /// Les deux puces de date portent sur `docs.mtime` — la date de dernière
    /// modification du FICHIER (AP-06). « Cette année » se lisait comme
    /// l'année de l'ouvrage ; le verbe lève l'ambiguïté en un mot, ici comme
    /// dans le titre de la facette « Modifié en ».
    static func dateLabel(_ filter: DateFilter) -> String {
        switch filter {
        case .any: return String(localized: "any date")
        case .thisYear: return String(localized: "Modified this year")
        case .lastFiveYears: return String(localized: "Modified in the last 5 years")
        }
    }
}

/// « Pourquoi ce résultat », en une phrase (lot U1, R-06).
///
/// L'audit A2 le relevait : `HybridInfo.z`, `Hit.fuzzyDistance`, l'insigne
/// « ≈ » et le pourcentage vivaient dans des infobulles que personne ne
/// survole. Tout était calculé, rien n'était DIT — et une page trouvée par le
/// seul canal sémantique restait indiscernable d'une page qui porte les mots.
///
/// LA RÈGLE DE CETTE PHRASE : aucun nombre. Ni la distance, ni la marge, ni un
/// pourcentage. Le public de Fouine ne sait pas ce qu'est un écart-type, et
/// « ≈2 » ne dit rien de plus que « une orthographe proche » ; les infobulles
/// existantes gardent les chiffres pour qui les cherche. On cite en revanche
/// LES MOTS DE L'UTILISATEUR, entre les guillemets de sa langue — c'est ce
/// qu'il reconnaît, et c'est ce qui rend la phrase vérifiable d'un coup d'œil.
enum HitExplanationText {

    /// Un mot cité, entre les guillemets typographiques de la langue. La clé
    /// porte les guillemets : le français met « … » avec ses espaces fines,
    /// l'anglais “ … ”, et ce n'est pas au code de le savoir.
    static func quoted(_ term: String) -> String {
        String(localized: "“\(term)”")
    }

    /// Une énumération dans la langue de l'utilisateur (« a, b et c »).
    /// `ListFormatter` connaît la conjonction et la ponctuation de chaque
    /// langue ; les recoller à la main donnerait « a, b and c » en français.
    private static func list(_ terms: [String]) -> String {
        let quoted = terms.map(Self.quoted)
        return ListFormatter.localizedString(byJoining: quoted)
    }

    static func sentence(_ explanation: HitExplanation) -> String {
        switch explanation {
        case .exact(let terms):
            return String(localized: "Found because this page contains \(list(terms)).")
        case .partial(let found, let missing):
            // DEUX clés plutôt qu'un pluriel : une variation de pluriel se
            // gouverne par un `%lld`, et il n'y a pas de nombre dans cette
            // phrase — seulement un verbe à accorder avec une liste de mots.
            if missing.count == 1 {
                return String(localized: "Found because this page contains \(list(found)); \(list(missing)) is not on it.")
            }
            return String(localized: "Found because this page contains \(list(found)); \(list(missing)) are not on it.")
        case .fuzzy(let typed, let found, _):
            // La DISTANCE ne se dit pas : « 1 lettre d'écart » n'ajoute rien à
            // deux mots mis côte à côte, qui se comparent tout seuls.
            return String(localized: "Found with a close spelling: \(quoted(typed)) → \(quoted(found)).")
        case .semanticOnly:
            return String(localized: "None of your words is on this page, but it deals with the same subject.")
        case .both:
            return String(localized: "Found by your words and by meaning.")
        }
    }
}

/// Pourquoi l'indexation en arrière-plan ne peut pas s'armer depuis CETTE
/// copie de Fouine (lot J2, `AppInstallationCheck`).
///
/// Public non technicien : ni « LaunchServices », ni « bundle », ni « chemin ».
/// On dit où l'application doit être, et le geste. Les chemins des autres
/// copies ne s'affichent pas : l'utilisateur les retrouve dans le Finder par
/// une recherche sur « Fouine », et une liste de chemins n'aiderait personne.
enum AppInstallationText {
    static func describe(_ decision: AppInstallationDecision) -> String? {
        switch decision {
        case .canRegister:
            return nil
        case .notInApplications:
            return String(localized: "Fouine must be in the Applications folder to index in the background. Move it there, open it from there, then try again.")
        case .severalCopies:
            return String(localized: "There are several copies of Fouine on this Mac. Keep only the one in the Applications folder, delete the others, then try again.")
        case .notTheDefaultCopy:
            return String(localized: "Another copy of Fouine is the one macOS opens. Keep only the copy in the Applications folder, delete the other, then try again.")
        }
    }
}

/// Les erreurs, rendues depuis leurs CAS — jamais depuis une phrase du cœur.
enum ErrorText {

    static func describe(_ error: Error) -> String {
        if let e = error as? FouineError { return describe(e) }
        if let e = error as? QueryError { return describe(e) }
        if let e = error as? SettingsError { return describe(e) }
        if let e = error as? FouineEmbedError { return describe(e) }
        if let e = error as? ModelDownloadError { return describe(e) }
        // Tout le reste vient du système (Foundation, PDFKit, Vision) : macOS
        // localise déjà `localizedDescription`, il n'y a rien à faire de plus.
        return (error as NSError).localizedDescription
    }

    // MARK: - FouineError (§4.2)

    static func describe(_ error: FouineError) -> String {
        switch error {
        case .volumeNotMounted:
            // L'UUID du volume reste dans la CLI et le journal : à l'écran, il
            // ne dit rien à personne (CLAUDE.md, public cible).
            return String(localized: "the disk is not plugged in: plug it back in and try again")

        case .rootUnreadable(let path, let raw):
            // Le motif est un ENREGISTREMENT sans langue depuis le palier 3.5
            // (`RootProbe.Reason`) : la phrase se refait ici, elle ne se
            // recopie pas. Le geste TCC n'accompagne QUE le refus de lecture ;
            // un dossier disparu dit « déplacé ou supprimé » sans parler de TCC
            // (recette tranche A, observation 5).
            let motive = RootProbe.reason(raw)
            let reason = motive.map(RootProbeText.describe) ?? raw
            if motive == .permissionDenied {
                return String(localized: "unreadable folder: \(path) — \(reason). \(TCCText.guidance)")
            }
            return String(localized: "unreadable folder: \(path) — \(reason)")

        case .databaseFailure(let message):
            // Le verrou occupé arrive ici sous forme de DONNÉES (audit F3 +
            // palier 3.2) : détenteur, pid, heure. La phrase se refait, elle
            // ne se recopie pas.
            if let busy = WriteLock.busy(error) { return describe(busy) }
            return String(localized: "database: \(message)")

        case .budgetExhausted(let remaining):
            return String(localized: "budget exhausted, \(remaining) item(s) left in the queue")

        case .unsupported(let ext):
            return String(localized: "unsupported format: .\(ext)")

        case .fileTooLarge(let bytes):
            return String(localized: "file too large (\(bytes) B)")

        case .extraction(let message):
            return String(localized: "extraction: \(message)")

        case .ocr(let message):
            return String(localized: "OCR: \(message)")

        case .cancelled:
            // Ne s'affiche jamais dans le cours normal des choses (ST1) : le
            // document arrêté en cours de lecture n'est pas marqué, il reste à
            // faire. La phrase existe pour que rien ne sorte en anglais si un
            // chemin l'affichait un jour.
            return String(localized: "the update was stopped before this document was read")
        }
    }

    /// « l'index se met à jour (indexation en arrière-plan, depuis 10:32) —
    /// réessayez quand ce sera fini ».
    ///
    /// Le message est DÉJÀ une phrase complète : il n'est pas préfixé de
    /// « base : ». Ni pid ni chemin du verrou (lot I1) : ils restent dans la
    /// CLI et le journal, où quelqu'un sait quoi en faire.
    static func describe(_ busy: WriteLock.Busy) -> String {
        guard let holder = busy.holder else {
            return String(localized: "the index is being updated by another program — try again in a moment")
        }
        return String(localized: "the index is being updated (\(LockActivityText.describe(holder))) — try again when it is finished")
    }

    // MARK: - QueryError (analyse de la requête)

    static func describe(_ error: QueryError) -> String {
        switch error {
        case .prefixTooShort:
            return String(localized: "prefix too short, give at least 4 letters")
        case .emptyQuery:
            return String(localized: "empty query: give at least one term to search for")
        case .exclusionOnly:
            return String(localized: "exclusion alone (-term): add at least one term to search for")
        case .ftsOperator(let word):
            // PAS la phrase du cœur (audit A1m-07). La CLI dit « Fouine
            // combines words with AND by default » : « AND » y est le nom d'un
            // opérateur, que son public connaît. Ici on dit ce qui se passe
            // (Fouine cherche déjà tous les mots) et le geste (les majuscules),
            // sans nommer d'opérateur ni de syntaxe.
            return String(localized: "“\(word)” in capitals is an instruction, not a word: Fouine already searches for all the words you type; to exclude one, write -word.")
        case .unknownFolder(let asked, let known):
            // Les étiquettes existantes sont NOMMÉES : le public ne connaît pas
            // la liste de ses dossiers par cœur, et la facette « Dossiers » ne
            // s'affiche qu'après une recherche qui a rendu quelque chose.
            // `known` n'est jamais vide — `FolderCheck` ne refuse rien quand il
            // n'a rien à confronter.
            return String(localized: "no folder is called “\(asked)”. Yours are: \(known.joined(separator: ", "))")
        case .unknownPrefix(let asked, _):
            // LES CINQ PRÉFIXES SONT NOMMÉS (lot QP1), sans les alias : ils se
            // tapent dans les deux langues (`folder:` vaut `dossier:`), mais
            // afficher dix jetons à quelqu'un qui vient d'en écrire un faux serait lui
            // demander de choisir au lieu de lui dire quoi taper (PR-04).
            return String(localized: "“\(asked)” is not a filter: the filters are dossier:, ext:, pres:, nom: and texte:.")
        case .notExcludable(let asked, let excludable):
            // Les filtres qui s'excluent viennent du cœur, SANS leurs alias
            // (même règle que ci-dessus) : `dossier:/folder:` se dit `dossier:`.
            let names = excludable.map { String($0.split(separator: "/").first ?? Substring($0)) }
            return String(localized: "“\(asked)” cannot be excluded. The filters that can are \(names.joined(separator: ", ")). To leave out a word, write -word.")
        }
    }

    // MARK: - SettingsError (fenêtre de réglages, `fouine config set`)

    static func describe(_ error: SettingsError) -> String {
        switch error.reason {
        case .notABoolean(let value, let key):
            return String(localized: "“\(value)” is not a boolean for \(key): expected true/false (or 1/0, yes/no)")
        case .notAnInteger(let value, let key, let min, let max):
            return String(localized: "“\(value)” is not an integer for \(key): expected a number between \(min) and \(max)")
        case .notARootIdentifier(let value, let key):
            return String(localized: "“\(value)” is not a folder identifier for \(key): expected integers separated by commas")
        case .unknownKey(let key):
            return String(localized: "unknown setting key: \(key)")
        case .unknown:
            // Un refus sans forme typée : la phrase du cœur vaut mieux que rien.
            return error.message
        }
    }

    // MARK: - FouineEmbedError (§12)

    /// AUCUN MOT DE TECHNICIEN ICI (A2-05, SPEC §5.6 amendé du 03/09/2026 :
    /// « aucun texte … ne dit “verrou”, “pid”, “vecteur” »). Cette phrase
    /// s'affiche sous les résultats et dans la barre latérale, entre
    /// parenthèses de « Recherche sémantique indisponible (…) » : elle disait
    /// « modèle d'embeddings : aucun vecteur en base — lancez “fouine embed” »,
    /// soit trois mots que le public ne connaît pas et une commande qu'il ne
    /// sait pas lancer.
    static func describe(_ error: FouineEmbedError) -> String {
        switch error {
        case .model(let message):
            // « Aucune page prête » est une phrase COMPLÈTE : elle ne se
            // préfixe pas, comme le verrou occupé du `databaseFailure`.
            if message == SemanticService.noVectorsDetail {
                return String(localized: "no page is ready for meaning search yet — Settings ▸ Search by meaning prepares them")
            }
            return String(localized: "meaning-search model: \(localizedEmbedDetail(message))")
        case .inference(let message):
            return String(localized: "inference: \(message)")
        }
    }

    /// Le seul détail de `.model` restant que l'APP fabrique elle-même
    /// (`SemanticService.load`) : c'est une phrase, pas un message système, et
    /// elle se traduit. Tout autre détail vient de CoreML et passe tel quel.
    private static func localizedEmbedDetail(_ message: String) -> String {
        switch message {
        case SemanticService.indexNotLoadedDetail:
            return String(localized: "the meaning search is not ready yet")
        default:
            return message
        }
    }

    // MARK: - ModelDownloadError (installation du modèle, audit D6)

    /// Le `description` de `ModelDownloadError` est la phrase FRANÇAISE que
    /// `fouine model download` imprime. L'app ne la recopie pas : elle refait la
    /// sienne depuis le cas et ses valeurs — même règle que partout ici.
    ///
    /// Les seuls détails laissés tels quels sont ceux qui viennent du SYSTÈME
    /// (message d'URLSession, sortie de `ditto`, erreur de `FileManager`) :
    /// aucun catalogue ne les traduit, et ce sont eux qu'on recopie dans un
    /// rapport de bogue.
    static func describe(_ error: ModelDownloadError) -> String {
        switch error {
        case .badURL(let raw):
            return String(localized: "unreadable model address: “\(raw)”")

        case .unsupportedScheme(let raw):
            return String(localized: "model address not supported: “\(raw)” — https:// or file:// only")

        case .notFound:
            // 404. Le cas ARRIVE en usage normal : l'asset de release est publié
            // séparément de l'application (RELEASING.md § 5 bis), et une version
            // peut donc être installée avant que son modèle ne soit en ligne.
            return String(localized: "the model archive is not published yet for this version of Fouine (404): try again later, or install it from a local copy.")

        case .httpStatus(let code, _):
            return String(localized: "the server answered \(String(code)) — try again later.")

        case .transport(let message):
            return String(localized: "download interrupted: \(message)")

        case .cancelled:
            return String(localized: "download cancelled")

        case .notEnoughSpace(let needed, let available, let path):
            return String(localized: "not enough space on \(path): \(Format.bytes(Int(needed))) needed, \(Format.bytes(Int(available))) free")

        case .sizeMismatch(let expected, let got):
            return String(localized: "unexpected size: \(Format.bytes(Int(got))) received, \(Format.bytes(Int(expected))) expected. The transfer stopped early.")

        case .hashMismatch(let expected, let got):
            return String(localized: "wrong SHA-256 fingerprint: the archive was refused and deleted. Expected \(expected), got \(got).")

        case .extraction(let message):
            return String(localized: "unpacking failed: \(message)")

        case .badLayout(let message):
            return String(localized: "malformed archive: \(message)")

        case .badIdentity(let gotID, let gotRevision, let wantID, let wantRevision):
            return String(localized: "unexpected model: the archive carries \(gotID) r\(String(gotRevision)), this version of Fouine expects \(wantID) r\(String(wantRevision))")

        case .install(let message):
            return String(localized: "installation failed: \(message)")

        case .alreadyInstalled(let revision):
            return String(localized: "the model is already installed (revision \(String(revision)))")
        }
    }
}

/// Le bandeau de santé dans la langue de l'utilisateur (audit H4, registre I1).
///
/// Une seule `String(localized:)` par cas : la ligne se rend depuis le CAS de
/// `HealthRow.Message` et ses valeurs, jamais depuis une clé anglaise relue.
/// Le public n'est pas technicien : on dit ce qui se passe et le geste à faire,
/// sans « verrou », « pid » ni « vecteur » (CLAUDE.md).
extension HealthRow.Message {
    var localizedText: String {
        switch self {
        case .backgroundIndexingOn:
            return String(localized: "Background indexing: on")
        case .backgroundIndexingStarting:
            return String(localized: "Background indexing: starting…")
        case .backgroundIndexingOff:
            return String(localized: "Background indexing: off")
        case .backgroundIndexingNotStarting:
            return String(localized: "Background indexing is not starting.")
        case .backgroundIndexingSeveralCopies:
            return String(localized: "Background indexing is not starting: there are several copies of Fouine on this Mac. Keep only the one in the Applications folder, delete the others, then re-register.")
        case .backgroundIndexingAwaitingApproval:
            return String(localized: "Background indexing is waiting for your approval in System Settings.")
        case .backgroundIndexingServiceMissing:
            return String(localized: "Background indexing: the background service was not found.")
        case .backgroundIndexingUnknown:
            return String(localized: "Background indexing: state unknown")

        case .indexAvailable:
            return String(localized: "Index available")
        case .indexUpdating(let role, let since, let ownProcess):
            // `since` est déjà l'heure en langage courant (`LockHolder.clockText`).
            // Sa propre écriture se dit « cette application », quel que soit le
            // rôle inscrit dans le fichier de verrou (BU-31).
            if ownProcess {
                return String(localized: "The index is being updated (this application, since \(since))")
            }
            switch role {
            case .agent: return String(localized: "The index is being updated (background indexing, since \(since))")
            case .cli:   return String(localized: "The index is being updated (command line, since \(since))")
            case .app:   return String(localized: "The index is being updated (this application, since \(since))")
            }

        case .semanticReady:
            return String(localized: "Search by meaning: ready")
        case .semanticPreparing:
            return String(localized: "Search by meaning: being prepared")
        case .semanticNotInstalled:
            return String(localized: "Search by meaning: not installed")

        case .noFolders:
            return String(localized: "No folder to index")
        case .diskNotPluggedIn(let folder):
            return String(localized: "The disk holding “\(folder)” is not plugged in")
        case .folderNotAllowed(let folder):
            return String(localized: "Fouine is not allowed to read “\(folder)”")
        case .foldersAllAccessible:
            return String(localized: "All folders are accessible")
        }
    }
}

extension HealthRow {
    var localizedText: String { message.localizedText }
}

// `HealthAction.localizedLabel` a été retiré (UX-03) : plus aucun bouton ne se
// rend depuis une ligne du bandeau de santé. Les gestes de santé sont
// désormais proposés par la carte « Index », dont les libellés viennent
// d'`IndexStatusText.label(_:)` — un seul jeu de phrases pour un seul bouton.
// `HealthAction` reste : c'est ce que `AppModel.performHealthAction` exécute.

/// Le libellé et l'identifiant d'accessibilité d'un geste d'aperçu (A2-11).
extension PreviewAction {
    var localizedLabel: String {
        switch self {
        case .openPrivacySettings:    return String(localized: "Open System Settings")
        case .retestRoots:            return String(localized: "Check the folders again")
        case .indexNow:               return String(localized: "Update now")
        case .revealExpectedLocation: return String(localized: "Show the expected location")
        }
    }

    /// Stable, pour les tests d'interface : jamais la phrase, qui est traduite.
    var identifier: String {
        switch self {
        case .openPrivacySettings:    return "settings"
        case .retestRoots:            return "retry"
        case .indexNow:               return "index"
        case .revealExpectedLocation: return "reveal"
        }
    }
}

// `HealthText.everythingWorking` a été retiré (UX-03) : la pastille verte
// « Tout fonctionne » disait à la fois moins et plus que la carte « Index »,
// qui nomme l'état réel. Le rapport de santé, lui, reste — il est l'une des
// entrées d'`IndexStatusEvaluator`.


// MARK: - La carte « Index » et la barre des menus (session UX du 04/09/2026)

/// Les phrases de la carte « Index » (barre latérale) et de la fenêtre « Votre
/// index », rendues depuis le CAS d'`IndexStatus`. La barre des menus n'en lit
/// plus aucune depuis IX2. Une phrase par état, un geste par
/// bouton. Le public n'est pas technicien : aucune ne dit « agent », « OCR »,
/// « verrou », « ré-enregistrer » (CLAUDE.md) — on dit « mise à jour
/// automatique », « pages scannées », « relancer ».
enum IndexStatusText {

    /// La ligne principale de la carte.
    static func headline(_ status: IndexStatus) -> String {
        switch status {
        case .checking:
            return String(localized: "Checking…")
        case .noFolders:
            return String(localized: "No folder to index")
        case .needsAttention(let attention):
            return Self.headline(attention)
        case .working(let activity, _, _, _):
            return Self.name(activity)
        case .paused(_, let scans):
            return scans > 0
                ? String(localized: "Up to date — \(scans) scanned page(s) to read")
                : String(localized: "Up to date")
        case .idle(let automatic, let scans, _):
            switch (automatic, scans > 0) {
            case (true, false):  return String(localized: "Up to date")
            case (true, true):   return String(localized: "Up to date — \(scans) scanned page(s) to read")
            case (false, false): return String(localized: "Manual updates")
            case (false, true):  return String(localized: "Manual updates — \(scans) scanned page(s) to read")
            }
        }
    }

    /// La ligne secondaire : le geste attendu, la raison d'une attente, la
    /// fraîcheur. `nil` quand il n'y a rien à ajouter.
    static func detail(_ status: IndexStatus, now: Date = Date()) -> String? {
        switch status {
        case .checking, .noFolders:
            return nil
        case .needsAttention(let attention):
            return Self.detail(attention)
        case .working(let activity, _, let detail, _):
            if let detail { return detail }
            return activity == .externalWrite ? anotherProgramWriting : nil
        case .paused(let reason, _):
            return Self.pauseSentence(reason)
        case .idle(let automatic, let scans, let lastUpdate):
            if automatic, scans > 0 {
                return String(localized: "They are read automatically when the Mac is plugged in and idle.")
            }
            if !automatic {
                return String(localized: "Fouine only updates the index when you ask.")
            }
            if let lastUpdate {
                return String(localized: "Updated \(Self.age(since: lastUpdate, now: now)) ago")
            }
            return nil
        }
    }

    /// La précision de l'état « un autre programme écrit ». À part parce que la
    /// carte la garde alors qu'elle ne montre plus rien d'autre d'un travail
    /// en cours (IX2, `IndexCardSummary`).
    static var anotherProgramWriting: String {
        String(localized: "Another program is writing to the index; searching still works.")
    }

    static func name(_ activity: IndexActivity) -> String {
        switch activity {
        case .updating:         return String(localized: "Updating the index")
        case .readingScans:     return String(localized: "Reading scanned pages")
        case .preparingMeaning: return String(localized: "Preparing search by meaning")
        case .externalWrite:    return String(localized: "The index is being updated")
        }
    }

    static func label(_ action: IndexAction) -> String {
        switch action {
        case .updateNow:               return String(localized: "Update now")
        case .stop:                    return String(localized: "Stop")
        case .readScans:               return String(localized: "Read scanned pages…")
        case .addFolder:               return String(localized: "Add a folder…")
        case .openLoginItems:          return String(localized: "Open System Settings")
        case .openPrivacySettings:     return String(localized: "Allow access…")
        case .revealInstalledCopy:     return String(localized: "Show in the Finder")
        case .restartAutomaticUpdates: return String(localized: "Restart automatic updates")
        case .retestFolders:           return String(localized: "Check again")
        }
    }

    /// « 312 / 1 200 pages · about 2 h left ». La barre est un dessin ; cette
    /// ligne est ce que l'on lit. Dans la fenêtre « Votre index » seulement :
    /// la carte ne la montre plus (IX2).
    static func progressLine(_ progress: IndexProgress) -> String {
        var line = String(localized: "\(Format.integer(progress.done)) / \(Format.integer(progress.total)) pages")
        if let seconds = progress.remainingSeconds {
            line += " · " + remaining(seconds)
        }
        return line
    }

    /// « about 2 h left ». Jamais de secondes : personne ne les lit, et elles
    /// bougent trop.
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 2 { return String(localized: "less than two minutes left") }
        if minutes < 90 { return String(localized: "about \(minutes) min left") }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return String(localized: "about \(hours) h left") }
        return String(localized: "about \(hours / 24) day(s) left")
    }

    /// « environ 30 h de travail » — la DURÉE d'un travail qu'on va lancer, à
    /// distinguer de `remaining(_:)`, qui dit ce qu'il reste d'un travail en
    /// cours. La feuille « Préparer la recherche par le sens » annonce l'une,
    /// la carte « Index » affiche l'autre (UX-12).
    static func workload(hours: Double) -> String {
        if hours < 1 { return String(localized: "less than an hour of work") }
        let rounded = Int(hours.rounded())
        if rounded < 48 { return String(localized: "about \(rounded) h of work") }
        return String(localized: "about \(rounded / 24) day(s) of work")
    }

    static func pauseSentence(_ reason: IndexPauseReason) -> String {
        switch reason {
        case .onBattery:
            return String(localized: "They will be read once the Mac is plugged in.")
        case .lowPowerMode:
            return String(localized: "They will be read once Low Power Mode is off.")
        case .machineHot:
            return String(localized: "They will be read once the Mac has cooled down.")
        case .anotherProgramWriting:
            return String(localized: "They will be read once the other program has finished.")
        case .folderUnreadable:
            return String(localized: "They will be read once every folder can be read again.")
        case .other(let text):
            return String(localized: "Waiting: \(text)")
        }
    }

    private static func headline(_ attention: IndexAttention) -> String {
        switch attention {
        case .folderNotAllowed(let folder):
            return String(localized: "Fouine is not allowed to read “\(folder)”")
        case .diskNotPluggedIn(let folder):
            return String(localized: "The disk holding “\(folder)” is not plugged in")
        case .awaitingApproval:
            return String(localized: "Automatic updates are waiting for your approval")
        case .automaticUpdatesNotStarting:
            return String(localized: "Automatic updates are not starting")
        case .severalCopies:
            return String(localized: "Several copies of Fouine are installed")
        case .serviceMissing:
            return String(localized: "Automatic updates are unavailable")
        }
    }

    private static func detail(_ attention: IndexAttention) -> String {
        switch attention {
        case .folderNotAllowed:
            return String(localized: "Its documents stay searchable. Allow Fouine in System Settings ▸ Privacy & Security ▸ Files and Folders to keep them up to date.")
        case .diskNotPluggedIn:
            return String(localized: "Its documents stay searchable. Plug the disk in to keep them up to date.")
        case .awaitingApproval:
            return String(localized: "Allow Fouine in System Settings ▸ General ▸ Login Items & Extensions.")
        case .automaticUpdatesNotStarting:
            return String(localized: "Restarting them usually fixes it. If not, quit and reopen Fouine.")
        case .severalCopies:
            return String(localized: "Keep only the one in the Applications folder, delete the others, then restart automatic updates.")
        case .serviceMissing:
            return String(localized: "Fouine must be installed in the Applications folder for automatic updates to work.")
        }
    }

    /// « 3 min », « 2 h », « 4 days » — l'âge d'une nouvelle, sans secondes.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return String(localized: "a moment") }
        if seconds < 5_400 { return String(localized: "\(Int(seconds / 60)) min") }
        if seconds < 172_800 { return String(localized: "\(Int(seconds / 3_600)) h") }
        return String(localized: "\(Int(seconds / 86_400)) day(s)")
    }
}

/// Pourquoi Fouine n'a pas pu lire un document, EN LANGAGE COURANT (UX-16).
///
/// La règle de ce fichier — partir des données, jamais d'une phrase du cœur —
/// souffre ici son unique exception, et `UnreadableDocumentsModel` dit pourquoi
/// en tête : `docs.err` est un texte en base, pas un cas d'énumération. La
/// reconnaissance du motif est faite AILLEURS (`UnreadableReason.classify`,
/// pure et testée) ; il ne reste ici que la phrase.
///
/// Un motif inconnu rend le TEXTE BRUT. C'est délibéré : mieux vaut une phrase
/// anglaise incompréhensible mais vraie — recopiable dans un message d'aide —
/// qu'un « erreur inconnue » qui ne dit rien à personne.
enum UnreadableReasonText {

    static func describe(raw: String?) -> String {
        guard let reason = UnreadableReason.classify(raw) else {
            guard let raw, !raw.isEmpty else {
                return String(localized: "Fouine could not read this file, without saying why.")
            }
            return raw
        }
        return phrase(reason)
    }

    static func phrase(_ reason: UnreadableReason) -> String {
        switch reason {
        case .unsupportedFormat:
            return String(localized: "Fouine does not know how to read this kind of file.")
        case .legacyOfficeFormat:
            // Motif d'un index antérieur au lot INT-F1 : Fouine lit ces
            // fichiers désormais, et le crawl les reprend de lui-même.
            return String(localized: "Old Excel or PowerPoint file set aside by an earlier version of Fouine. It will be read at the next update.")
        case .missingTool:
            return String(localized: "A tool Fouine needs to read this file is not installed on this Mac.")
        case .iWorkWithoutPreview:
            return String(localized: "Pages, Numbers or Keynote file saved without a preview. Open it once in its application and save it again.")
        case .fileTooLarge:
            return String(localized: "File too big to be read.")
        case .tooManyPages:
            return String(localized: "Document with too many pages to be read.")
        case .imageTooSmall:
            return String(localized: "Image too small to hold readable text.")
        case .imageFileTooLight:
            return String(localized: "Image file too light to hold a document")
        case .scanWithoutTextLayer:
            return String(localized: "This scanned document holds only pictures of its pages. Fouine cannot read DjVu pictures yet: export it as PDF.")
        case .transcriptionEmpty:
            // « Index this file again » envoyait chercher un geste que l'app
            // n'offre pas : un document en échec est repris quand son fichier
            // change, ou quand une mise à jour change la transcription (BT2).
            return String(localized: "Nothing could be written down from this recording. Fouine will try again if the file changes, or when an update improves speech recognition.")
        case .transcriptionStopped:
            return String(localized: "Writing down this recording was interrupted: speech recognition stopped responding. Fouine will try again if the file changes, or when an update improves speech recognition.")
        case .notDownloaded:
            return String(localized: "Not downloaded to this Mac yet. It will be read as soon as it is here.")
        case .passwordProtected:
            return String(localized: "Protected by a password.")
        case .readDenied:
            return String(localized: "macOS did not allow Fouine to read this file.")
        case .fileMissing:
            return String(localized: "The file was no longer there when Fouine tried to read it.")
        case .tookTooLong:
            return String(localized: "Reading it took too long and was stopped.")
        case .damagedFile:
            return String(localized: "The file looks damaged: nothing readable could be found in it.")
        case .scannedPagesUnreadable:
            return String(localized: "The scanned pages of this document could not be read.")
        case .nothingToIndex:
            return String(localized: "Nothing to search in this file: it holds no readable text.")
        case .dataDump:
            return String(localized: "This file is a stream of data, not a readable text.")
        case .notAMailbox:
            return String(localized: "This file is named like a mailbox but holds no e-mail message.")
        case .recordingNotWrittenDown:
            return String(localized: "This recording has no title or description, and what is said in it is not written down. Tick “Also write down what is said in them” in Settings ▸ Indexing to search it.")
        case .recordingTooLong:
            return String(localized: "This recording is longer than the longest one Fouine writes down, and has no title or description. Raise “Longest recording to write down (minutes)” in Settings ▸ Indexing.")
        }
    }
}
