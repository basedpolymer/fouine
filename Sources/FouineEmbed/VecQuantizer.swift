// VecQuantizer.swift — quantification int8 des vecteurs unitaires.
// Propriété : A-Embed.
//
// Les vecteurs sont UNITAIRES avant quantification : chaque composante vit dans
// [-1, 1], `round(v·127)` la loge dans un octet signé, et le produit scalaire
// int8 divisé par 127² approxime le cosinus (erreur < 0,01 mesurée en test).
// 384 octets par page au lieu de 1 536 : c'est ce qui garde `page_vec` sous les
// 150 Mo et le balayage complet sous les 10 ms (bench du 01/09).

import Foundation

public enum VecQuantizer {

    public static let scale: Float = 127

    /// Vecteur unitaire -> blob int8 de `page_vec.vec`.
    public static func quantize(_ v: [Float]) -> Data {
        var out = Data(count: v.count)
        out.withUnsafeMutableBytes { buf in
            let p = buf.bindMemory(to: Int8.self)
            for i in 0..<v.count {
                p[i] = Int8(max(-scale, min(scale, (v[i] * scale).rounded())))
            }
        }
        return out
    }

    /// Vecteur unitaire de requête -> int8 pour le balayage.
    public static func quantizeQuery(_ v: [Float]) -> [Int8] {
        v.map { Int8(max(-scale, min(scale, ($0 * scale).rounded()))) }
    }

    /// Produit scalaire int8 -> cosinus approché.
    public static func cosine(fromDot dot: Int32) -> Float {
        Float(dot) / (scale * scale)
    }
}
