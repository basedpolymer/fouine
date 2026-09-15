// UpdatesSettingsView.swift — onglet « Mises à jour » des réglages (D13).
// Propriété : A-Pack. Vue AUTONOME : elle ne dépend que d'`UpdatesController`,
// et se pose telle quelle dans la fenêtre de réglages de l'app.
//
// Le parti pris de cet écran : dire, en toutes lettres et sans avoir à lire une
// documentation, ce qui est contacté et quand. Une app qui annonce « rien ne
// sort de votre Mac » doit montrer l'unique exception à la seule page où
// l'utilisateur va la chercher, et l'y montrer ÉTEINTE.

import SwiftUI

struct UpdatesSettingsView: View {
    @ObservedObject var updates: UpdatesController

    /// Les seuls intervalles que Sparkle expose dans son interface standard.
    /// On ne fabrique pas de valeurs exotiques : un intervalle plus court ne
    /// sert à personne, un plus long est un « jamais » déguisé.
    private static let intervals: [(LocalizedStringKey, TimeInterval)] = [
        ("Once a day", 86_400),
        ("Once a week", 604_800),
        ("Once a month", 2_629_800),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically",
                       isOn: Binding(get: { updates.automaticallyChecks },
                                     set: { updates.automaticallyChecks = $0 }))
                    .disabled(!updates.isSupported)

                Picker("Frequency", selection: Binding(
                    get: { closestInterval },
                    set: { updates.checkInterval = $0 })) {
                    ForEach(Self.intervals, id: \.1) { label, seconds in
                        Text(label).tag(seconds)
                    }
                }
                .disabled(!updates.isSupported || !updates.automaticallyChecks)

                LabeledContent("Last check") {
                    Text(verbatim: lastCheckLabel)
                        .foregroundStyle(updates.lastCheckFailed
                                         ? Color.orange : Color.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                // Le pourquoi de tout l'écran : la phrase qui rend la promesse
                // de vie privée vérifiable.
                // Alignés À GAUCHE, explicitement : dans un `Form` groupé, le
                // pied de section hérite d'un alignement centré que le mode
                // sombre rendait visible — les trois paragraphes s'affichaient
                // alignés à droite (audit du 09/09, § 8.1). L'alignement d'un
                // texte ne doit pas dépendre du thème.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fouine connects to nothing until you ask it to. This switch is off to begin with, and while it is off nothing goes out unless you click “Check now”.")
                    Text(verbatim: feedSentence)
                    Text("That request carries no identifier, nothing about this Mac and nothing about your documents: Fouine downloads a file and compares a version number.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Check now") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckNow)
                        if let reason = updates.unavailableReason {
                            Text(verbatim: reason)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Ce que la boîte de Sparkle ne dit pas : que Fouine
                    // continue de marcher, et qu'il n'y a rien à annuler
                    // (audit BU-22).
                    if updates.lastCheckFailed {
                        Text(verbatim: updates.failureMessage)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // `revision` change à chaque geste : sans cette lecture, SwiftUI ne
        // redessine pas, car les réglages vivent dans Sparkle et non dans un
        // `@Published` à nous.
        .id(updates.revision)
    }

    // MARK: - Habillage

    /// L'intervalle courant ramené à la valeur proposée la plus proche : le
    /// `Picker` n'affiche rien si la sélection ne correspond à aucun tag, et
    /// une valeur héritée d'un autre réglage ne doit pas vider le menu.
    private var closestInterval: TimeInterval {
        let current = updates.checkInterval
        return Self.intervals
            .min(by: { abs($0.1 - current) < abs($1.1 - current) })?.1 ?? 86_400
    }

    private var lastCheckLabel: String {
        // L'échec passe AVANT la date : une date sans mention d'échec ferait
        // croire que la vérification a abouti (audit BU-22).
        if updates.lastCheckFailed {
            return String(localized: "could not reach the server")
        }
        guard let date = updates.lastCheckDate else {
            return String(localized: "never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var feedSentence: String {
        guard let feed = updates.feedURL else {
            return String(localized: "No update address is configured in this copy of Fouine.")
        }
        return String(localized: "The address contacted, and the only one, is \(feed.absoluteString).")
    }
}
