// LicenseSettingsTab.swift — onglet « Licence » des réglages (lot L1C).
// Propriété : A-App.
//
// Le parti pris est celui de l'onglet « Mises à jour », et pour la même
// raison : une application qui annonce « rien ne sort de votre Mac » doit
// montrer chaque exception à l'endroit où l'utilisateur va la chercher, en
// disant ce qui part et quand. Ici, trois exceptions de plus — activer,
// vérifier, désactiver —, toutes à la demande sauf une vérification mensuelle
// silencieuse, et le pied de section les nomme.
//
// LE CHAMP ACCEPTE CE QU'ON COLLE. Espaces, retours à la ligne, minuscules :
// `LicenseState.normalize` nettoie. Refuser une clé pour un espace de trop
// serait punir quelqu'un d'un détail — et c'est le premier geste qu'il fait
// après avoir payé.

import SwiftUI
import FouineLicense

struct LicenseSettingsTab: View {
    @ObservedObject var license: LicenseModel

    @State private var typedKey = ""
    @State private var confirmingDeactivation = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: LicenseStatusText.headline(license.state))
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = LicenseStatusText.detail(license.state) {
                        Text(verbatim: detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Your licence")
            }

            if case .licensed = license.state {
                licensedSection
            } else {
                activationSection
            }
        }
        .formStyle(.grouped)
        .onAppear { license.refresh() }
    }

    // MARK: - Pas encore de clé

    private var activationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Licence key", text: $typedKey,
                          prompt: Text(verbatim: "ABC123-XYZ456-XYZ456-XYZ456"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(license.busy)
                    .accessibilityIdentifier("licence.key")
                    .onSubmit { activate() }

                HStack(spacing: 10) {
                    Button("Activate") { activate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(license.busy || cleanedKey.isEmpty)
                        .accessibilityIdentifier("licence.activate")
                    Button(buyLabel) { license.buy() }
                        .accessibilityIdentifier("licence.buy")
                    if license.busy {
                        ProgressView().controlSize(.small)
                    }
                }

                if let message = license.errorMessage {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("licence.error")
                }
            }
        } footer: {
            connectionFootnote
        }
    }

    // MARK: - Une clé activée

    private var licensedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("Deactivate this Mac") { confirmingDeactivation = true }
                        .disabled(license.busy)
                        .accessibilityIdentifier("licence.deactivate")
                    if license.busy {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = license.errorMessage {
                    Text(verbatim: message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .alert("Deactivate this Mac?", isPresented: $confirmingDeactivation) {
                Button("Cancel", role: .cancel) {}
                Button("Deactivate", role: .destructive) {
                    Task { await license.deactivate() }
                }
            } message: {
                Text(verbatim: String(localized: "This Mac will stop counting toward your \(LicenseTerms.activationLimit) activations. You can activate it again later."))
            }
        } footer: {
            connectionFootnote
        }
    }

    // MARK: - Le pied de section, identique dans les deux cas

    /// Ce qui part, et quand. Aligné À GAUCHE explicitement : dans un `Form`
    /// groupé, un pied de section hérite d'un alignement centré que le mode
    /// sombre rend visible (même correction que l'onglet « Mises à jour »).
    private var connectionFootnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fouine contacts the shop at three moments only: when you activate this Mac, when you release it, and once a month to check that your key is still valid. It sends your key and the name of this Mac, so you can tell your Macs apart the day you want to free one.")
            Text("Nothing about your documents ever leaves this Mac, and nothing is sent while Fouine indexes or searches.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: -

    private var cleanedKey: String { LicenseState.normalize(typedKey) }

    private var buyLabel: String {
        String(localized: "Buy Fouine — \(LicenseTerms.priceDisplay)")
    }

    private func activate() {
        guard !cleanedKey.isEmpty, !license.busy else { return }
        let key = typedKey
        Task {
            await license.activate(key: key)
            if case .licensed = license.state { typedKey = "" }
        }
    }
}

/// Les phrases d'état, hors de la vue pour être lisibles — et pour que la
/// carte « Index » et « À propos » disent EXACTEMENT les mêmes (lot L1C).
enum LicenseStatusText {

    static func headline(_ state: LicenseState) -> String {
        switch state {
        case .trial(let left):
            return String(localized: "Trial: \(left) days left")
        case .trialOver:
            return String(localized: "Your trial is over: searching still works, the index is no longer updated")
        case .licensed(let masked, _):
            return String(localized: "Licensed — key ending in \(masked)")
        case .revoked:
            return String(localized: "This key was disabled by the seller")
        case .released:
            // Pas « révoqué » : la personne a libéré ce Mac elle-même, depuis
            // son espace client. On dit ce qui s'est passé et le geste (LC2).
            return String(localized: "This Mac was released from your customer portal. Enter your key again to use it here.")
        }
    }

    /// La seconde ligne, quand il y en a une.
    static func detail(_ state: LicenseState) -> String? {
        switch state {
        case .trial:
            return String(localized: "Everything works during the trial. A key costs \(LicenseTerms.priceDisplay), once, and covers \(LicenseTerms.activationLimit) Macs.")
        case .trialOver:
            return String(localized: "Enter your key below, or buy one. Everything you have already indexed stays searchable.")
        case .licensed(_, let checked):
            guard let checked else { return nil }
            return String(localized: "Checked on \(checked.formatted(date: .long, time: .omitted))")
        case .revoked:
            return String(localized: "Enter another key below, or contact the seller with the e-mail you used to buy it.")
        case .released(let left):
            // La première ligne porte déjà le geste ; la seconde ne rappelle
            // que ce qui reste de l'essai, quand il en reste.
            return left > 0 ? detail(.trial(daysLeft: left)) : nil
        }
    }

    /// La ligne discrète de la carte « Index » pendant l'essai.
    static func cardTrialLine(daysLeft: Int) -> String {
        String(localized: "Trial: \(daysLeft) days left")
    }
}
