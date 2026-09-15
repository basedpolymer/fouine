// NotesProtobuf.swift — le texte d'une note d'Apple Notes, sans dépendance
// (lot INT-F4). Propriété : A-Ingest.
//
// CE QU'IL Y A DANS `ZICNOTEDATA.ZDATA` : un protobuf, compressé en gzip.
// Le schéma (relevé par `threeplanetssoftware/apple_cloud_notes_parser`,
// `proto/notestore.proto`) tient en trois messages :
//
//     NoteStoreProto { Document document = 2 }
//     Document       { int32 version = 2 ; Note note = 3 }
//     Note           { string note_text = 2 ; repeated AttributeRun … = 5 }
//
// Le texte de la note est donc au chemin 2 → 3 → 2. Le reste du message décrit
// la MISE EN FORME (polices, gras, listes, pièces jointes) sous forme de
// « runs » posés sur ce même texte : rien à indexer.
//
// POURQUOI PAS SwiftProtobuf. Le §2.2 de SPEC.md fixe deux dépendances et pas
// une de plus, et ce qu'il faut lire ici est un unique champ de chaîne à trois
// niveaux de profondeur. Un lecteur de varints tient en trente lignes, ne
// dépend de rien, et — c'est ce qui compte — IGNORE ce qu'il ne comprend pas :
// une version future d'Apple Notes qui ajoute des champs ne le cassera pas.
//
// LE REPLI. Si le chemin documenté ne rend rien (schéma changé, note d'une
// autre époque), on redescend l'arbre à la recherche de la plus longue chaîne
// UTF-8 plausible. C'est délibérément grossier : mieux vaut indexer le texte
// d'une note dont le format a bougé que de rendre un fichier vide sans un mot.

import Foundation
import Compression

/// Décompression gzip / zlib / deflat brut, sur la libcompression du système.
///
/// `Store/ZlibBlob.swift` (FouineCore) fait déjà la même chose pour les
/// dispositions OCR, mais il est `internal` à sa cible ET n'accepte que le
/// flux DEFLATE nu : `ZDATA` porte, lui, un en-tête gzip. Les deux en-têtes
/// sont retirés ici, puis le corps passe par `COMPRESSION_ZLIB`, qui est le
/// DEFLATE nu d'Apple malgré son nom.
public enum SourceGzip {

    public enum Failure: Error, Equatable {
        case truncated
        case invalidStream
        /// Le flux rend plus que le plafond : on s'arrête là (constat CM-14).
        case tooLarge(limit: Int)
    }

    /// Plafond de la sortie décompressée. LA MÊME VALEUR que
    /// `Bsdtar.maxDecompressedBytes`, et pour la même raison : ce blob vient
    /// d'ailleurs (une base d'Apple Notes, une base Bear, éventuellement une
    /// note partagée par iCloud), rien ne borne son taux de compression, et
    /// 1 Mio de gzip rend 1 Gio de zéros (ratio 1 028, mesuré). Le processus qui
    /// décompresse est l'application ou l'agent : un dépassement mémoire y
    /// emporte tout.
    public static let maxDecompressedBytes = 128 << 20

    /// Motif lisible du refus, tel qu'il remonte dans le rapport de
    /// matérialisation.
    public static func tooLargeReason(limit: Int) -> String {
        "note too large after decompression (limit \(limit >> 20) MiB)"
    }

    /// Décompresse un blob gzip (`1f 8b`), zlib (`78 …`) ou DEFLATE nu.
    public static func inflate(_ input: Data,
                               maxBytes: Int = maxDecompressedBytes) throws -> Data {
        guard input.count > 2 else { throw Failure.truncated }
        return try inflateRaw(try body(of: input), maxBytes: maxBytes)
    }

    /// Retire l'en-tête, quel qu'il soit, et rend le DEFLATE nu.
    static func body(of input: Data) throws -> Data {
        let bytes = [UInt8](input)
        // gzip : 1f 8b 08 <flags> <mtime×4> <xfl> <os>, puis les champs
        // optionnels que les drapeaux annoncent.
        if bytes.count > 10, bytes[0] == 0x1f, bytes[1] == 0x8b {
            let flags = bytes[3]
            var offset = 10
            if flags & 0x04 != 0 {                       // FEXTRA
                guard offset + 2 <= bytes.count else { throw Failure.truncated }
                let length = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                offset += 2 + length
            }
            if flags & 0x08 != 0 { offset = try skipCString(bytes, from: offset) }
            if flags & 0x10 != 0 { offset = try skipCString(bytes, from: offset) }
            if flags & 0x02 != 0 { offset += 2 }         // FHCRC
            guard offset < bytes.count else { throw Failure.truncated }
            return input.subdata(in: offset..<input.count)
        }
        // zlib : premier octet 0x78 dans la quasi-totalité des cas, et le
        // couple (CMF, FLG) est un multiple de 31.
        if bytes.count > 2, bytes[0] & 0x0f == 8,
           (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 {
            return input.subdata(in: 2..<input.count)
        }
        return input
    }

    private static func skipCString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { throw Failure.truncated }
        return index + 1
    }

    /// DEFLATE nu -> octets. Boucle de flux : la taille de sortie n'est pas
    /// connue d'avance (le pied gzip la porte, mais on ne s'y fie pas) — d'où
    /// le plafond, VÉRIFIÉ AVANT chaque ajout et non après : mesurer le dégât
    /// une fois qu'il est en mémoire ne servirait à rien.
    static func inflateRaw(_ input: Data,
                           maxBytes: Int = maxDecompressedBytes) throws -> Data {
        guard !input.isEmpty else { return Data() }
        let bufferSize = 64 * 1024
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        var status = compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE,
                                             COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw Failure.invalidStream }
        defer { compression_stream_destroy(streamPtr) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        var output = Data()

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = raw.count
            streamPtr.pointee.dst_ptr = destination
            streamPtr.pointee.dst_size = bufferSize

            repeat {
                status = compression_stream_process(
                    streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - streamPtr.pointee.dst_size
                    guard output.count + produced <= maxBytes else {
                        throw Failure.tooLarge(limit: maxBytes)
                    }
                    if produced > 0 { output.append(destination, count: produced) }
                    streamPtr.pointee.dst_ptr = destination
                    streamPtr.pointee.dst_size = bufferSize
                default:
                    throw Failure.invalidStream
                }
            } while status != COMPRESSION_STATUS_END
        }
        return output
    }
}

/// Un lecteur de protobuf minimal : varints, champs `length-delimited`, et
/// rien d'autre.
public enum NotesProtobuf {

    /// Un champ, tel qu'il est encodé.
    public struct Field: Equatable {
        public let number: Int
        public let wire: Int
        /// Charge utile des champs `length-delimited` (wire 2).
        public let payload: Data?
        /// Valeur des varints (wire 0).
        public let varint: UInt64?
    }

    /// Les champs de PREMIER niveau d'un message. Ne descend pas : c'est
    /// l'appelant qui choisit où descendre, et c'est ce qui rend le chemin
    /// documenté lisible.
    public static func fields(in data: Data) -> [Field] {
        var out: [Field] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let (key, afterKey) = varint(data, at: index) else { return out }
            let number = Int(key >> 3)
            let wire = Int(key & 0x07)
            guard number > 0 else { return out }
            switch wire {
            case 0:
                guard let (value, next) = varint(data, at: afterKey) else { return out }
                out.append(Field(number: number, wire: wire, payload: nil,
                                 varint: value))
                index = next
            case 1:
                guard afterKey + 8 <= data.endIndex else { return out }
                index = afterKey + 8
                out.append(Field(number: number, wire: wire, payload: nil, varint: nil))
            case 2:
                guard let (length, afterLength) = varint(data, at: afterKey),
                      let end = data.index(afterLength, offsetBy: Int(length),
                                           limitedBy: data.endIndex) else { return out }
                out.append(Field(number: number, wire: wire,
                                 payload: data.subdata(in: afterLength..<end),
                                 varint: nil))
                index = end
            case 5:
                guard afterKey + 4 <= data.endIndex else { return out }
                index = afterKey + 4
                out.append(Field(number: number, wire: wire, payload: nil, varint: nil))
            default:
                // Groupes (3, 4) et wires inconnus : on s'arrête. Apple Notes
                // n'en émet pas, et deviner ferait rendre n'importe quoi.
                return out
            }
        }
        return out
    }

    /// La charge utile du premier champ `number` de ce message.
    public static func message(_ number: Int, in data: Data) -> Data? {
        fields(in: data).first { $0.number == number && $0.wire == 2 }?.payload
    }

    /// Le texte d'une note, depuis le blob DÉCOMPRESSÉ.
    ///
    /// Chemin documenté : `NoteStoreProto.document` (2) →
    /// `Document.note` (3) → `Note.note_text` (2).
    public static func noteText(inProtobuf data: Data) -> String? {
        if let document = message(2, in: data),
           let note = message(3, in: document),
           let text = message(2, in: note),
           let string = String(data: text, encoding: .utf8), !string.isEmpty {
            return string
        }
        return longestPlausibleString(in: data, depth: 0)
    }

    /// Le texte d'une note depuis le blob BRUT (gzip) de `ZICNOTEDATA.ZDATA`.
    public static func noteText(inCompressed blob: Data) -> String? {
        readNote(inCompressed: blob).text
    }

    /// La même lecture, mais qui DIT ce qui l'a empêchée quand cela mérite
    /// d'être dit.
    ///
    /// Des octets qui ne sont pas un protobuf ne sont PAS un motif : c'est le
    /// cas ordinaire d'une note vide ou d'un schéma qu'on ne connaît pas, et le
    /// repli s'en charge. Un blob qui dépasse le plafond de décompression, si :
    /// c'est le seul cas où l'on renonce à une note qui avait quelque chose à
    /// dire, et la synchronisation continue avec les autres (CM-14).
    public static func readNote(inCompressed blob: Data)
        -> (text: String?, problem: String?) {
        do {
            return (noteText(inProtobuf: try SourceGzip.inflate(blob)), nil)
        } catch SourceGzip.Failure.tooLarge(let limit) {
            return (nil, SourceGzip.tooLargeReason(limit: limit))
        } catch {
            return (nil, nil)
        }
    }

    /// REPLI : la plus longue chaîne UTF-8 « de prose » trouvée dans l'arbre.
    ///
    /// Les chaînes de mise en forme (noms de polices, identifiants, UUID) sont
    /// courtes ; le texte d'une note ne l'est presque jamais. Le seuil est bas
    /// (4 caractères) parce qu'une note d'un mot reste une note, et le
    /// « plus long » tranche les cas où plusieurs candidats se présentent.
    private static func longestPlausibleString(in data: Data,
                                               depth: Int) -> String? {
        guard depth < 6 else { return nil }
        var best: String?
        for field in fields(in: data) where field.wire == 2 {
            guard let payload = field.payload, !payload.isEmpty else { continue }
            // LA DESCENTE D'ABORD. Un message imbriqué est souvent, par
            // accident, de l'UTF-8 valide : le prendre pour une chaîne rendrait
            // le texte de la note NOYÉ dans les octets de sa mise en forme. Un
            // champ dont on sait descendre n'est donc jamais une chaîne.
            if let deeper = longestPlausibleString(in: payload, depth: depth + 1) {
                if deeper.count > (best?.count ?? 0) { best = deeper }
                continue
            }
            if let string = String(data: payload, encoding: .utf8),
               string.unicodeScalars.allSatisfy({ $0 == "\n" || $0 == "\t"
                                                  || $0.value >= 32 }),
               string.count >= 4, string.count > (best?.count ?? 0) {
                best = string
            }
        }
        return best
    }

    /// Lecture d'un varint. Rend la valeur et l'index qui suit.
    static func varint(_ data: Data, at start: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            value |= UInt64(byte & 0x7f) << shift
            index = data.index(after: index)
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
