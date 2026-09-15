// AgentEmbedTests.swift — la préparation de la recherche par le sens, décidée
// par l'agent (constat PR-21, lot AG1). Propriété : A-Recette.
//
// Comme `AgentTests` : la décision est PURE, elle se prouve sans base, sans
// modèle CoreML et sans launchd.

import Foundation
import XCTest
import FouineCore
@testable import FouineAgent

final class AgentEmbedTests: XCTestCase {

    private func settings(prepare: Bool = true, embedBudget: Int = 10,
                          pollSeconds: Int = 60) -> SettingsSnapshot {
        SettingsSnapshot(
            rows: [
                "agent.prepareMeaning": prepare ? "true" : "false",
                "agent.embedBudgetMinutes": String(embedBudget),
                "agent.pollSeconds": String(pollSeconds),
            ],
            environment: [:])
    }

    private var conditionsMet: AgentConditions.Verdict {
        AgentConditions.Verdict(ok: true, blockers: [])
    }

    private func ready(pagesLeft: Int = 1_200) -> AgentEmbedSituation {
        AgentEmbedSituation(enabled: true, modelInstalled: true,
                            campaignHeldByAnother: false, pagesLeft: pagesLeft)
    }

    // MARK: - La décision

    /// L'OCR D'ABORD : `completeOCR` invalide les vecteurs de la page qu'il
    /// réécrit, une page vectorisée avant sa reconnaissance le serait deux fois.
    func testAFullOCRQueueDefersThePreparationOfMeaning() {
        let (action, _) = Agent.tick(
            state: AgentState(), conditions: conditionsMet,
            settings: settings(), ocrQueueLength: 42, embed: ready())
        XCTAssertFalse(Agent.leadsToEmbedBatch(action),
                       "un lot de vecteurs est parti alors que des pages "
                       + "attendent encore la reconnaissance de texte")
    }

    /// File vide, pages à préparer, conditions réunies : un lot part, budgété.
    func testAnEmptyQueueAndMetConditionsStartOneBatch() {
        let (action, state) = Agent.tick(
            state: AgentState(hasNotifiedQueueDrained: true),
            conditions: conditionsMet,
            settings: settings(embedBudget: 7), ocrQueueLength: 0,
            embed: ready(pagesLeft: 900))
        XCTAssertEqual(action, .sequence([
            .publishStatus(phase: .preparingMeaning,
                           detail: AgentStatusDetail.pagesLeft(900),
                           done: 0, total: 900),
            .runEmbedBatch(budgetMinutes: 7, pagesLeft: 900),
        ]))
        // Le lot ÉCRIT : le drapeau du §5.7 (condition 5) doit le dire, sans
        // quoi l'agent se refuserait le verrou à lui-même au tic suivant.
        XCTAssertTrue(state.lockHeldBySelf)
    }

    /// La notification « toutes les pages scannées sont lues » part quand même :
    /// la file d'OCR EST vide, et ce n'est pas parce qu'on enchaîne sur autre
    /// chose que l'utilisateur ne doit pas l'apprendre.
    func testTheQueueDrainedNoticeStillGoesOutBeforeTheFirstBatch() {
        let (action, state) = Agent.tick(
            state: AgentState(hasNotifiedQueueDrained: false),
            conditions: conditionsMet, settings: settings(),
            ocrQueueLength: 0, embed: ready())
        guard case .sequence(let actions) = action else {
            return XCTFail("séquence attendue")
        }
        XCTAssertEqual(actions.first, .notifyQueueDrained)
        XCTAssertTrue(state.hasNotifiedQueueDrained)
    }

    /// Réglage éteint : rien, et rien à dire non plus.
    func testTheSettingOffPreparesNothing() {
        let (action, state) = Agent.tick(
            state: AgentState(hasNotifiedQueueDrained: true),
            conditions: conditionsMet,
            settings: settings(prepare: false), ocrQueueLength: 0,
            embed: AgentEmbedSituation(enabled: false, modelInstalled: true,
                                       pagesLeft: 1_000))
        XCTAssertFalse(Agent.leadsToEmbedBatch(action))
        XCTAssertNil(Agent.meaningVerdict(
            embed: AgentEmbedSituation(enabled: false), conditions: conditionsMet).note)
        XCTAssertNotEqual(state.lastVerdict, "meaning: the six conditions of §5.7 are met")
    }

    /// Modèle absent : rien, mais le refus PORTE SON NOM — sans quoi un agent
    /// dont le modèle manque ne préparerait rien sans que rien ne le dise.
    func testAMissingModelIsNamed() {
        let embed = AgentEmbedSituation(enabled: true, modelInstalled: false)
        XCTAssertEqual(Agent.meaningVerdict(embed: embed, conditions: conditionsMet),
                       .noModel)
        let (action, state) = Agent.tick(
            state: AgentState(hasNotifiedQueueDrained: true),
            conditions: conditionsMet, settings: settings(),
            ocrQueueLength: 0, embed: embed)
        XCTAssertFalse(Agent.leadsToEmbedBatch(action))
        XCTAssertEqual(state.lastVerdict, AgentEmbedVerdict.noModel.note)
    }

    /// Verrou de campagne pris par quelqu'un d'autre : l'agent se tait et
    /// réessaie au tic suivant (il ne DOUBLE jamais une campagne, C2-11).
    func testACampaignAlreadyRunningIsNamedAndNothingStarts() {
        var embed = ready()
        embed.campaignHeldByAnother = true
        XCTAssertEqual(Agent.meaningVerdict(embed: embed, conditions: conditionsMet),
                       .campaignBusy)
        let (action, state) = Agent.tick(
            state: AgentState(hasNotifiedQueueDrained: true),
            conditions: conditionsMet, settings: settings(),
            ocrQueueLength: 0, embed: embed)
        XCTAssertFalse(Agent.leadsToEmbedBatch(action))
        XCTAssertEqual(state.lastVerdict, AgentEmbedVerdict.campaignBusy.note)
    }

    /// Les six conditions du §5.7 valent pour les vecteurs comme pour l'OCR :
    /// sur batterie, rien ne part.
    func testTheSixConditionsGuardTheVectorsToo() {
        let blocked = AgentConditions.Verdict(ok: false, blockers: ["no AC power"])
        let (action, state) = Agent.tick(
            state: AgentState(hasNotifiedQueueDrained: true),
            conditions: blocked, settings: settings(),
            ocrQueueLength: 0, embed: ready())
        XCTAssertFalse(Agent.leadsToEmbedBatch(action))
        XCTAssertEqual(state.lastVerdict, "meaning waiting — no AC power")
    }

    /// Plus une page à préparer : rien ne part, et on n'en parle pas.
    func testNothingLeftToPrepareStartsNothing() {
        let embed = AgentEmbedSituation(enabled: true, modelInstalled: true,
                                        pagesLeft: 0)
        XCTAssertEqual(Agent.meaningVerdict(embed: embed, conditions: conditionsMet),
                       .nothingToDo)
    }

    // MARK: - Après le lot

    /// File vidée : retour au repos, et l'horloge reprend sa période.
    func testPostBatchWithNothingLeftGoesBackToIdle() {
        let (action, state) = Agent.postEmbedBatchTick(
            state: AgentState(phase: .preparingMeaning, lockHeldBySelf: true),
            outcome: .completed, remainingPages: 0,
            settings: settings(pollSeconds: 45))
        XCTAssertEqual(action, .sequence([
            .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained,
                           done: nil, total: nil),
            .sleep(seconds: 45),
        ]))
        XCTAssertFalse(state.lockHeldBySelf)
        XCTAssertEqual(state.lastVerdict, "meaning: every indexed page is ready")
    }

    /// Budget épuisé : RIEN n'est publié, parce que le tic suivant re-décide
    /// tout — conditions comprises. C'est le contrat des lots courts.
    func testPostBatchWithBudgetExhaustedLeavesTheDecisionToTheNextTick() {
        let (action, state) = Agent.postEmbedBatchTick(
            state: AgentState(phase: .preparingMeaning, lockHeldBySelf: true),
            outcome: .budgetExhausted, remainingPages: 4_000,
            settings: settings())
        XCTAssertEqual(action, .none)
        XCTAssertFalse(state.lockHeldBySelf)
    }

    /// Arrêt demandé pendant le lot : on ne publie rien de plus, l'agent sort.
    func testAStoppingAgentPublishesNothingAfterItsBatch() {
        let (action, _) = Agent.postEmbedBatchTick(
            state: AgentState(isStopping: true), outcome: .stopped,
            remainingPages: 10, settings: settings())
        XCTAssertEqual(action, .none)
    }
}
