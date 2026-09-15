// CreemReplies.swift — ce que Creem a VRAIMENT répondu (lot LC2).
//
// Corps recopiés tels quels, octet pour octet, du premier aller-retour réel
// joué le 14/09/2026 dans le bac à sable Creem, à travers le vrai relais
// `api/fouine/license.js` servi en local :
// `~/Fouine-verif/session-2026-09-14-soir/mesures-licence/aller-retour-test.log`.
//
// Le client L1C avait été écrit sans réponse réelle, et quatre écarts en sont
// sortis — une limite en 400 et non en 409, un `message` tantôt chaîne tantôt
// tableau à côté d'un `error` inutile, une instance libérée qui valide en 200.
// Un double inventé prouve ce qu'on croit ; celui-ci prouve ce qui arrive. Clé
// de bac à sable : rien de réel.

enum CreemReplies {

    /// ① Activation acceptée — HTTP 200.
    static let activated = #"{"object":"license","id":"lk_3Bkq8BGQ2DGRSkQ9OuFqXq","product_id":"prod_1OiconyhdjZKiMpWMaoJEB","status":"active","key":"JKV88-3USJ9-7F5DX-M770U-E9EKC","activation":1,"activation_limit":3,"expires_at":null,"created_at":"2026-09-14T12:09:21.795Z","instance":{"object":"license-instance","id":"lki_1gAoG4SalItdXZHUYWMraB","name":"MacBook A","status":"active","created_at":"2026-09-14T12:36:03.610Z","mode":"test"},"mode":"test"}"#

    /// ⑤ Un quatrième Mac — HTTP **400**, `message` en CHAÎNE.
    static let activationLimitReached = #"{"trace_id":"38fc4633-683b-4514-9414-7aaf786f883c","status":400,"error":"Bad Request","message":"Activation limit reached","timestamp":1789389364622}"#

    /// ⑥ Validation d'une instance que Creem ne connaît pas — HTTP **404**,
    /// `message` en TABLEAU.
    static let instanceNotFound = #"{"trace_id":"2b26641a-9d2b-4bdd-889c-9902121de4bb","status":404,"error":"Bad Request","message":["License key instance not found"],"timestamp":1789389364809}"#

    /// ⑧ Validation d'un Mac libéré — HTTP **200** : la CLÉ est `active` (elle
    /// sert sur deux autres Mac), l'INSTANCE est `deactivated`.
    static let validatedAfterRelease = #"{"object":"license","id":"lk_3Bkq8BGQ2DGRSkQ9OuFqXq","product_id":"prod_1OiconyhdjZKiMpWMaoJEB","status":"active","key":"JKV88-3USJ9-7F5DX-M770U-E9EKC","activation":2,"activation_limit":3,"expires_at":null,"created_at":"2026-09-14T12:09:21.795Z","instance":{"object":"license-instance","id":"lki_1gAoG4SalItdXZHUYWMraB","name":"MacBook A","status":"deactivated","created_at":"2026-09-14T12:36:03.610Z","mode":"test"},"mode":"test"}"#

    /// ⑩ Désactiver une seconde fois — HTTP **400**. La faute « instnace » est
    /// de Creem, gardée telle quelle.
    static let alreadyDeactivated = #"{"trace_id":"5b93faf6-c1fe-4823-874c-d7ff37ea0cdf","status":400,"error":"Bad Request","message":"License key instnace is already deactivated","timestamp":1789389365629}"#

    /// ⑪ La dernière instance libérée — HTTP 200 : la clé passe `inactive`,
    /// l'instance `deactivated`.
    static let lastInstanceDeactivated = #"{"object":"license","id":"lk_3Bkq8BGQ2DGRSkQ9OuFqXq","product_id":"prod_1OiconyhdjZKiMpWMaoJEB","status":"inactive","key":"JKV88-3USJ9-7F5DX-M770U-E9EKC","activation":0,"activation_limit":3,"expires_at":null,"created_at":"2026-09-14T12:09:21.795Z","instance":{"object":"license-instance","id":"lki_7078jjbjv0sWFCjchFPix9","name":"MacBook D","status":"deactivated","created_at":"2026-09-14T12:36:05.369Z","mode":"test"},"mode":"test"}"#
}
