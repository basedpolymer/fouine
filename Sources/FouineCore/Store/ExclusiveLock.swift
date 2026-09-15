// ExclusiveLock.swift — verrou d'écriture inter-processus (SPEC §5.1, §3).
// Propriété : A-Core.
//
// « Toutes les écritures d'indexation passent par un verrou exclusif flock() sur
//   fouine.lock, pour que la CLI et l'agent d'arrière-plan ne se marchent pas
//   dessus. Les lectures (recherche) ne prennent pas le verrou. » (§5.1)
//
// Le verrou est pris PARESSEUSEMENT, à la première écriture : flock() est un
// verrou de descripteur, il protège les processus entre eux, pas les fils d'un
// même processus (ceux-là sont sérialisés par le DatabasePool de GRDB).
//
// Il est RENDU par `release()` aux points de repos de l'appelant, et repris
// paresseusement à l'écriture suivante. Sans cela l'agent d'arrière-plan, qui
// écrit dans la seconde qui suit son démarrage, garderait `fouine.lock` jusqu'à
// sa mort : la CLI et l'app ne pourraient plus JAMAIS indexer, avec un message
// d'erreur trompeur (« arrêtez l'indexation en cours ») alors que l'agent est
// parfaitement au repos. Depuis l'audit F3, c'est `IndexPass` (FouineIndex) qui
// prend le verrou en début de passe et le rend en `defer` — pour les TROIS
// pipelines, l'app comprise, qui le confisquait jusqu'à sa fermeture.
//
// DÉTENTEUR NOMMÉ (audit F3). Le fichier ne servait que de support à flock() :
// il restait vide, et « arrêtez l'indexation en cours » était la seule chose
// qu'un utilisateur bloqué pouvait lire — sans savoir QUI écrivait, ni depuis
// quand, ni s'il devait attendre dix secondes ou fermer l'app. Le détenteur y
// écrit désormais UNE ligne de texte, et l'efface en rendant le verrou.

import Foundation

/// Qui écrit. Sert à nommer le détenteur de `fouine.lock` dans les messages
/// d'occupation ; c'est un renseignement, jamais un droit.
public enum LockRole: String, Sendable {
    case app, agent, cli

    /// Le groupe nominal employé dans les phrases : « … by the agent (pid 42) ».
    /// ANGLAIS, comme tout ce que le cœur écrit (palier 3.5) ; l'application
    /// refait le sien depuis le cas (`LockRoleText`).
    public var english: String {
        switch self {
        case .app:   return "the app"
        case .agent: return "the agent"
        case .cli:   return "the fouine command"
        }
    }

    /// Rôle déduit du nom de l'exécutable, pour les acquisitions PARESSEUSES
    /// (`fouine root add`, `fouine embed`…) qui ne passent pas par une passe
    /// d'indexation et n'ont donc personne pour déclarer leur rôle.
    public static func forCurrentProcess() -> LockRole {
        let name = ProcessInfo.processInfo.processName
        if name.contains("Agent") { return .agent }
        if name.contains("App") { return .app }
        return .cli
    }
}

/// Ce que `fouine.lock` contient pendant qu'il est tenu.
///
/// FORMAT — une seule ligne de texte ASCII, terminée par un saut de ligne :
///
///     fouine-lock 1 pid=<entier> role=<app|agent|cli> since=<ISO-8601>
///
/// Le jeton de version (`1`) ouvre la porte à un champ supplémentaire sans
/// casser un binaire plus ancien : l'analyse ignore ce qu'elle ne connaît pas
/// et exige seulement `pid`. Le fichier est TRONQUÉ à la libération : un
/// `fouine.lock` vide veut dire « libre », et un `cat` suffit à diagnostiquer.
public struct LockHolder: Sendable, Equatable {
    public let pid: pid_t
    public let role: LockRole
    public let since: Date

    public init(pid: pid_t, role: LockRole, since: Date) {
        self.pid = pid
        self.role = role
        self.since = since
    }

    public static func current(role: LockRole, since: Date = Date()) -> LockHolder {
        LockHolder(pid: getpid(), role: role, since: since)
    }

    static let magic = "fouine-lock"
    static let formatVersion = "1"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// L'heure du détenteur, telle qu'elle est RECOMPOSÉE pour l'affichage.
    /// `dateFormat = "HH:mm"` faisait lire `17:25` à un utilisateur `en_US`
    /// dont le système écrit `5:25 PM` — et c'est le `%3$@` du message que
    /// l'application montre le plus souvent (audit B1-23). Le gabarit `jm`
    /// laisse la locale choisir l'ordre, le séparateur et la présence d'un
    /// AM/PM ; `autoupdatingCurrent` suit un changement de réglage sans
    /// relancer le processus.
    ///
    /// Ce formateur ne touche PAS le contrat : la ligne de `fouine.lock` et
    /// l'enregistrement `fouine-lock-busy` portent une date ISO 8601
    /// (`Self.iso`), sans langue et sans locale. Seul l'affichage change.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()

    /// La ligne écrite dans `fouine.lock`.
    public var line: String {
        "\(Self.magic) \(Self.formatVersion) pid=\(pid) role=\(role.rawValue) "
        + "since=\(Self.iso.string(from: since))\n"
    }

    /// Relit une ligne. `nil` si le fichier est vide, tronqué, ou d'un format
    /// qu'on ne sait pas lire : on ne nomme JAMAIS un détenteur incertain.
    public static func parse(_ text: String) -> LockHolder? {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        var fields: [String: String] = [:]
        var sawMagic = false
        for token in line.split(separator: " ") {
            if token == magic { sawMagic = true; continue }
            guard let equals = token.firstIndex(of: "=") else { continue }
            fields[String(token[token.startIndex..<equals])] =
                String(token[token.index(after: equals)...])
        }
        guard sawMagic, let raw = fields["pid"], let pid = pid_t(raw), pid > 0
        else { return nil }
        return LockHolder(
            pid: pid,
            role: fields["role"].flatMap(LockRole.init(rawValue:)) ?? .cli,
            since: fields["since"].flatMap(iso.date(from:)) ?? Date())
    }

    /// Le processus nommé existe-t-il encore ?
    ///
    /// `kill(pid, 0)` ne tue rien : il ne fait que la vérification de droits.
    /// Seul `ESRCH` prouve l'absence — `EPERM` signale un processus BIEN VIVANT
    /// appartenant à quelqu'un d'autre, et le prendre pour un mort ferait
    /// reprendre un verrou légitimement tenu.
    public var isAlive: Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// « the database is being written by the agent (pid 1234) since 10:32 »
    ///
    /// Phrase ANGLAISE, pour la CLI, l'agent et `docs.err`. L'app, elle, ne la
    /// lit pas : elle refait la même phrase dans sa langue à partir de `role`,
    /// `pid` et `clockText` (palier 3.2, audit U1).
    public var phrase: String {
        "the database is being written by \(role.english) (pid \(pid)) "
        + "since \(Self.clock.string(from: since))"
    }

    /// L'heure de prise du verrou, « 10:32 » — le seul morceau de `phrase` qui
    /// ne soit ni un nombre ni un rôle, et donc le seul qu'un rendu localisé
    /// doive redemander plutôt que reformater.
    public var clockText: String { Self.clock.string(from: since) }
}

/// Diagnostic PUBLIC d'une panne d'écriture : distinguer « le verrou est tenu
/// par un autre processus » — il faut ATTENDRE, l'agent le rend entre deux lots
/// OCR — de toute autre panne — disque plein, base corrompue, schéma cassé —,
/// qu'il faut REMONTER.
///
/// Motif (audit X3, `EmbedRun.swift:83`) : la pompe à vecteurs avalait toute
/// erreur d'écriture par un `try?`, puis réessayait pendant 15 min. Une base
/// corrompue était donc indiscernable d'un verrou tenu, et se soldait par un
/// abandon silencieux au bout d'un quart d'heure — après avoir jeté les
/// vecteurs déjà inférés.
///
/// La classification passe par le MESSAGE parce que `FouineError` est un
/// contrat gelé (§4.2) — on ne peut pas lui ajouter un cas sans casser les
/// `switch` exhaustifs de FouineOCR et de la CLI. Le message n'est donc plus
/// une phrase mais un ENREGISTREMENT (`busyToken`), que `busy(_:)` rend sous
/// forme de données : c'est l'équivalent d'un cas typé, sans toucher au
/// contrat (palier 3.2, audit U1).
public enum WriteLock {

    /// Ce que l'on sait d'une occupation, sous forme de DONNÉES.
    ///
    /// C'est ce type, et non une phrase, que lisent les rendus : la CLI et
    /// l'agent en font la phrase française du §4.3, l'application en fait la
    /// phrase de la langue de l'utilisateur (palier 3.2, audit U1). Un
    /// `holder` nul veut dire « le fichier ne nommait personne » — un verrou
    /// tenu par un binaire plus ancien, ou repris entre la lecture et l'écriture.
    public struct Busy: Sendable, Equatable {
        public let holder: LockHolder?
        public let path: String

        public init(holder: LockHolder?, path: String) {
            self.holder = holder
            self.path = path
        }
    }

    /// Marqueur de tête du message d'`ExclusiveLock.acquire` quand `flock` rend
    /// `EWOULDBLOCK` jusqu'à l'échéance.
    ///
    /// POURQUOI UN JETON ET PLUS UNE PHRASE. `isBusy` décidait sur le préfixe
    /// « base verrouillée par un autre processus » — c'est-à-dire sur du
    /// FRANÇAIS. Trois boucles de reprise en dépendent (`EmbedRun`,
    /// `AgentStatusWriter`, `GRDBStore+Settings`) : le jour où les messages du
    /// cœur passent à l'anglais, elles auraient cessé de distinguer un verrou
    /// tenu d'une base corrompue et réessayé un quart d'heure sur un disque
    /// plein. Le message porte donc les DONNÉES, dans un format à nous, stable
    /// et sans langue :
    ///
    ///     fouine-lock-busy 1 path=<chemin> pid=<entier> role=<app|agent|cli>
    ///                        since=<ISO-8601>
    ///
    /// Ce n'est pas ce que l'utilisateur lit : `IndexText.describe` (CLI,
    /// agent, `docs.err`) et `ErrorText.describe` (app) le rendent en phrase.
    /// Là où il apparaîtrait tel quel — une ligne de journal d'un chemin qui
    /// n'est pas passé par l'un des deux —, il reste diagnostique : le pid et
    /// l'heure y sont, ce que la prose ne disait pas mieux.
    public static let busyToken = "fouine-lock-busy"
    static let busyFormatVersion = "1"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Vrai si l'erreur est « verrou d'écriture tenu par un autre processus ».
    public static func isBusy(_ error: Error) -> Bool {
        busy(error) != nil
    }

    /// L'occupation, sous forme de données, ou `nil` si l'erreur est autre
    /// chose. C'est l'unique porte d'entrée des rendus localisés.
    public static func busy(_ error: Error) -> Busy? {
        guard case .databaseFailure(let message)? = error as? FouineError,
              message.hasPrefix(busyToken) else { return nil }
        var fields: [String: String] = [:]
        for token in message.split(separator: " ") {
            guard let equals = token.firstIndex(of: "=") else { continue }
            fields[String(token[token.startIndex..<equals])] =
                String(token[token.index(after: equals)...])
        }
        let path = fields["path"] ?? ""
        guard let raw = fields["pid"], let pid = pid_t(raw), pid > 0 else {
            return Busy(holder: nil, path: path)
        }
        return Busy(
            holder: LockHolder(
                pid: pid,
                role: fields["role"].flatMap(LockRole.init(rawValue:)) ?? .cli,
                since: fields["since"].flatMap(iso.date(from:)) ?? Date()),
            path: path)
    }

    /// Le message d'occupation : les DONNÉES, pas la phrase (voir `busyToken`).
    ///
    /// Un détenteur mort ou non nommé ne part pas dans le message — on ne
    /// nomme jamais un détenteur incertain (même règle que `LockHolder.parse`).
    public static func busyMessage(holder: LockHolder?, path: String) -> String {
        var line = "\(busyToken) \(busyFormatVersion) path=\(path)"
        if let holder, holder.isAlive {
            line += " pid=\(holder.pid) role=\(holder.role.rawValue)"
                + " since=\(iso.string(from: holder.since))"
        }
        return line
    }

    /// État d'un fichier de verrou lu sans attendre.
    public enum LockStatus: Sendable, Equatable {
        case free
        case held(LockHolder)
        case stale(LockHolder)

        public var isHeld: Bool { if case .held = self { return true }; return false }
        public var isStale: Bool { if case .stale = self { return true }; return false }
        public var isFree: Bool { if case .free = self { return true }; return false }
    }

    /// Gestionnaire d'annonce d'attente de verrou (B1-26).
    /// Appelé dès le premier blocage avec le détenteur et le délai d'attente.
    public typealias WaitHandler = @Sendable (LockHolder, TimeInterval) -> Void

    /// Lit le détenteur inscrit dans le fichier de verrou à `path`.
    /// `nil` si le fichier n'existe pas, est vide ou illisible.
    public static func readHolder(path: String) -> LockHolder? {
        guard let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else { return nil }
        return LockHolder.parse(String(decoding: data, as: UTF8.self))
    }

    /// Diagnostique immédiatement l'état du verrou sans attendre ni bloquer.
    ///
    /// UNE VRAIE SONDE, PAS UNE LECTURE DE FICHIER (audit A1m-03). La version
    /// d'avant lisait `fouine.lock` et faisait `kill(pid, 0)` : elle ne
    /// regardait JAMAIS le `flock`, c'est-à-dire la seule chose qui bloque
    /// réellement un écrivain. Deux mensonges en découlaient, et le second est
    /// celui qui se voit. ① Un `fouine.lock` périmé n'était jamais nettoyé :
    /// un processus tué ne passe ni par `release()` ni par `stamp()`, et
    /// `doctor` répondait « stale (…) » indéfiniment — c'était le cas de cette
    /// machine depuis le 03/09/2026 19:06, pour un `pid=1048` mort. ② Le jour
    /// où macOS recycle ce pid (il boucle à 99 999), `doctor` bascule en « held
    /// by cli pid 1048 » et l'application annonce « L'index se met à jour —
    /// patientez… » avant chaque indexation manuelle, pour toujours. Pour le
    /// public visé, c'est un mensonge permanent sur l'état de son index.
    ///
    /// Le `flock` tranche : on ouvre le fichier en `O_RDONLY` (jamais
    /// `O_CREAT` — diagnostiquer ne crée rien) et on tente
    /// `flock(LOCK_EX | LOCK_NB)`.
    ///
    ///   · il passe        -> personne ne tient le verrou : il est LIBRE, et le
    ///     nom qu'on vient de lire est périmé. On tronque le fichier TANT QU'ON
    ///     TIENT le flock — entre les deux, personne d'autre ne peut prendre le
    ///     verrou, donc personne ne peut lire un nom qui ne vaut plus (même
    ///     règle que `release()`). La troncature passe par `truncate(2)` et non
    ///     `ftruncate` : le descripteur est en lecture seule.
    ///   · EWOULDBLOCK     -> il est réellement tenu, et le nom lu est le bon.
    ///
    /// Coût : un `open` et deux `flock`. Le seul risque est de retarder de
    /// 50 ms au plus un acquéreur qui attendait pile à cet instant — `acquire`
    /// boucle en `usleep(50_000)` jusqu'à son échéance de 5 s.
    ///
    /// FENÊTRE ANONYME. Entre le `flock` d'`acquire()` et le `stamp()` qui
    /// suit, le verrou est tenu et le fichier encore vide : la sonde rend
    /// alors `.free`. C'est quelques microsecondes, c'est ce que faisait déjà
    /// la version d'avant (un fichier vide rendait `.free`), et on ne fabrique
    /// pas un détenteur qu'on ne sait pas nommer — même règle que
    /// `busyMessage`.
    public static func inspect(path: String) -> LockStatus {
        let holder = readHolder(path: path)
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else {
            // Pas de fichier (ou illisible) : rien ne tient le verrou.
            return .free
        }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            if holder != nil { _ = Darwin.truncate(path, 0) }
            _ = flock(fd, LOCK_UN)
            return .free
        }
        guard let holder else { return .free }
        // Tenu. Un nom dont le pid est mort veut dire que le détenteur du
        // descripteur n'est pas celui que le fichier nomme (un fils qui a
        // hérité du descripteur, par exemple) : le verrou est bien pris, mais
        // le nom ne vaut rien — c'est exactement ce que `.stale` raconte.
        return holder.isAlive ? .held(holder) : .stale(holder)
    }
}

final class ExclusiveLock: @unchecked Sendable {
    private let path: String
    private let mutex = NSLock()
    private var fd: Int32 = -1
    private var role: LockRole = .forCurrentProcess()
    private var log: (@Sendable (String) -> Void)?
    private var onWait: WriteLock.WaitHandler?

    init(path: String) { self.path = path }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Rôle inscrit dans `fouine.lock`. Posé par la passe d'indexation ; à
    /// défaut, le nom de l'exécutable tranche.
    ///
    /// Si le verrou est DÉJÀ tenu — pris paresseusement par une écriture
    /// antérieure, un `root add` par exemple —, la ligne est réécrite sur place.
    /// Sans cela le fichier continuerait de nommer le rôle deviné au démarrage,
    /// et l'horodatage d'une passe terminée depuis longtemps.
    func setRole(_ role: LockRole) {
        mutex.lock()
        defer { mutex.unlock() }
        guard self.role != role else { return }
        self.role = role
        if fd >= 0 { stamp() }
    }

    /// Journal des reprises de verrou périmé. Branché par la passe sur son
    /// observateur ; nil ailleurs, où personne n'a d'endroit où l'écrire.
    func setLog(_ log: @escaping @Sendable (String) -> Void) {
        mutex.lock(); self.log = log; mutex.unlock()
    }

    func setWaitHandler(_ handler: @escaping WriteLock.WaitHandler) {
        mutex.lock(); self.onWait = handler; mutex.unlock()
    }

    /// Prend le verrou s'il ne l'est pas déjà. Idempotent.
    /// Attend au plus `timeout` secondes avant d'abandonner en `databaseFailure`
    /// (SPEC §4.3 : sortie 3 = « base verrouillée ou corrompue »).
    func acquire(timeout: TimeInterval = 5) throws {
        mutex.lock()
        defer { mutex.unlock() }
        if fd >= 0 { return }

        // 0600 À LA CRÉATION (audit A1-06) : `fouine.lock` nomme le processus
        // qui écrit, son pid et l'heure — c'est un renseignement sur l'activité
        // de l'utilisateur, pas un fichier public. `fchmod` derrière, en
        // RATTRAPAGE des installations existantes créées en 0644 ; best-effort,
        // un échec ne doit jamais empêcher de prendre le verrou (D2-09).
        let f = Darwin.open(path, O_CREAT | O_RDWR, FilePermissions.file)
        guard f >= 0 else {
            throw FouineError.databaseFailure(
                "lock \(path): \(String(cString: strerror(errno)))")
        }
        _ = fchmod(f, FilePermissions.file)

        // B1-26 : annoncer le verrou AVANT d'attendre.
        var announced = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(f, LOCK_EX | LOCK_NB) == 0 {
                fd = f
                stamp()
                return
            }
            let err = errno
            if err != EWOULDBLOCK {
                Darwin.close(f)
                throw FouineError.databaseFailure(
                    "lock \(path): \(String(cString: strerror(err)))")
            }
            if !announced {
                announced = true
                if let holder = Self.readHolder(path: path), holder.isAlive {
                    onWait?(holder, timeout)
                }
            }
            if Date() >= deadline {
                // Le détenteur est lu MAINTENANT, pas au démarrage : sur une
                // attente de 5 s il a pu changer.
                let holder = Self.readHolder(path: path)
                Darwin.close(f)
                throw FouineError.databaseFailure(
                    WriteLock.busyMessage(holder: holder, path: path))
            }
            usleep(50_000)
        }
    }

    /// Inscrit le détenteur, après avoir signalé un éventuel verrou PÉRIMÉ.
    ///
    /// flock() est rendu par le noyau à la mort du processus : si l'on vient de
    /// l'obtenir alors que le fichier nomme encore quelqu'un, ce quelqu'un a
    /// disparu sans passer par `release()` — plantage, `kill -9`, coupure. Le
    /// verrou n'est donc jamais « bloqué » ; ce qui traînait, c'est le NOM, et
    /// c'est lui qui aurait accusé un processus mort dans le message suivant.
    /// La reprise est silencieuse pour le contenu, tracée dans le journal.
    private func stamp() {
        if let stale = Self.readHolder(path: path), stale.pid != getpid() {
            let state = stale.isAlive ? "abandoned" : "stale"
            log?("took over the \(state) lock of \(stale.role.english) "
                 + "(pid \(stale.pid)) — \(path)")
        }
        let line = LockHolder.current(role: role).line
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        line.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
    }

    static func readHolder(path: String) -> LockHolder? {
        WriteLock.readHolder(path: path)
    }

    /// Rend le verrou s'il est détenu. Idempotent : appelé sans verrou, no-op.
    /// Sous le MÊME `NSLock` qu'`acquire()`, pour qu'une reprise concurrente ne
    /// puisse pas s'intercaler entre le `LOCK_UN` et la remise à -1.
    ///
    /// Le nom du détenteur part AVANT le `LOCK_UN` : entre les deux, personne
    /// d'autre ne peut prendre le verrou, donc personne ne peut lire un nom qui
    /// ne vaut plus.
    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }
}
