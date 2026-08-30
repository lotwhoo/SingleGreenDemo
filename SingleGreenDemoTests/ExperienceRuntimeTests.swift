import Foundation
import SingleGreenGlassesKit
import SwiftUI
import UIKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class ExperienceRuntimeTests: XCTestCase {
    func testDefaultExperienceIsSystemStatus() {
        let runtime = ExperienceRuntime()

        XCTAssertEqual(runtime.selectedKind, .systemStatus)
        XCTAssertEqual(runtime.scene.presentation, .compact)
        XCTAssertEqual(runtime.availableKinds.count, 4)
        XCTAssertFalse(runtime.availableKinds.contains(.conversation))
    }

    func testAppCompositionPublishesBuiltInsThenTextAdventureAndTeleprompter() {
        let controller = VoiceConversationController(dependencies: missingAIConfiguration())
        let runtime = ExperienceRuntime(
            sessions: DemoExperienceComposition.sessions(controller: controller)
        )

        XCTAssertEqual(
            runtime.availableDescriptors.map(\.kind),
            ExperienceKind.allCases + [
                TextAdventureExperience.kind,
                TeleprompterExperience.kind
            ]
        )
        XCTAssertEqual(
            runtime.availableDescriptors.first(where: { $0.kind == .conversation })?.detail,
            DemoExperienceComposition.aiProviderDetail
        )
        XCTAssertEqual(
            runtime.availableDescriptors.first(where: { $0.kind == .conversation })?.capabilities,
            [.network, .microphone, .backgroundUpdates]
        )
        XCTAssertEqual(
            runtime.availableDescriptors.first(where: { $0.kind == .notification })?.actions.map(\.id),
            ["primary", "tap", "swipe_down"]
        )
        XCTAssertEqual(
            runtime.availableDescriptors.first(where: { $0.kind == TeleprompterExperience.kind })?.actions.map(\.id),
            ["left", "right", "up", "down"]
        )
    }

    func testHostFacingMetadataAndActionsAcceptRegisteredFixtureWithoutViewKindBranches() async {
        let customKind = ExperienceKind("test.hostCatalog")
        let customAction = ExperienceActionEvent("test.runHostFixture")
        let fixture = HostCatalogFixtureExperience(
            descriptor: ExperienceDescriptor(
                kind: customKind,
                displayName: "Host fixture",
                detail: "Descriptor supplies UI data",
                systemImageName: "sparkles",
                capabilities: [.camera],
                actions: [
                    ExperienceActionDescriptor(
                        id: "custom_action",
                        event: customAction,
                        placement: .secondary,
                        titleSource: .fixed("Run fixture"),
                        iconSource: .fixed("bolt.fill"),
                        accessibilityLabel: "Run host fixture"
                    )
                ]
            )
        )
        let runtime = ExperienceRuntime(sessions: [fixture])

        XCTAssertEqual(runtime.selectedKind, customKind)
        XCTAssertEqual(runtime.selectedDescriptor.displayName, "Host fixture")
        XCTAssertEqual(runtime.selectedDescriptor.detail, "Descriptor supplies UI data")
        XCTAssertEqual(runtime.selectedDescriptor.systemImageName, "sparkles")
        XCTAssertEqual(runtime.activeActions.map(\.id), ["custom_action"])
        XCTAssertEqual(runtime.activeActions.first?.title, "Run fixture")
        XCTAssertEqual(runtime.activeActions.first?.systemImageName, "bolt.fill")

        await runtime.performAction(id: "custom_action")
        XCTAssertEqual(fixture.receivedActions, [customAction])
        XCTAssertEqual(fixture.receivedEvents, [])
    }

    func testSecondaryActionGridWrapsMoreThanThreeActionsAndPreservesDescriptorOrder() {
        let actions = (1...5).map { index in
            ExperienceActionDescriptor(
                id: "action_\(index)",
                event: .tap,
                placement: .secondary,
                titleSource: .fixed("Action \(index)"),
                iconSource: .fixed("circle"),
                accessibilityLabel: "Action \(index)"
            )
        }
        let descriptor = ExperienceDescriptor(
            kind: .caption,
            displayName: "Grid fixture",
            detail: "More than three secondary actions",
            systemImageName: "square.grid.3x3",
            actions: actions
        )
        let runtime = ExperienceRuntime(sessions: [
            HostCatalogFixtureExperience(descriptor: descriptor)
        ])
        let preferredColumns = SecondaryActionGridPolicy.preferredColumnCount(
            actionCount: runtime.activeActions.count
        )
        let normalWidthRows = SecondaryActionGridPolicy.rows(
            runtime.activeActions,
            columnCount: preferredColumns
        )
        let constrainedRows = SecondaryActionGridPolicy.rows(
            runtime.activeActions,
            columnCount: 2
        )

        XCTAssertEqual(preferredColumns, 3)
        XCTAssertEqual(normalWidthRows.map { $0.map(\.id) }, [
            ["action_1", "action_2", "action_3"],
            ["action_4", "action_5"]
        ])
        XCTAssertEqual(constrainedRows.map { $0.map(\.id) }, [
            ["action_1", "action_2"],
            ["action_3", "action_4"],
            ["action_5"]
        ])
        XCTAssertEqual(SecondaryActionGridPolicy.preferredColumnCount(actionCount: 1), 1)
        XCTAssertEqual(SecondaryActionGridPolicy.preferredColumnCount(actionCount: 3), 3)
    }

    func testNavigationMovesForwardAndResetsWhenReactivated() async {
        let runtime = ExperienceRuntime()
        await runtime.activate(.navigation)
        let firstSceneID = runtime.scene.sceneID

        await runtime.handle(.swipeDown)
        XCTAssertNotEqual(runtime.scene.sceneID, firstSceneID)

        await runtime.activate(.systemStatus)
        await runtime.activate(.navigation)
        XCTAssertEqual(runtime.scene.sceneID, firstSceneID)
    }

    func testNotificationCanBeTriggeredAndDismissed() async {
        let runtime = ExperienceRuntime()
        await runtime.activate(.notification)

        await runtime.handle(.triggerAlert)
        XCTAssertEqual(runtime.scene.presentation, .alert)

        await runtime.handle(.tap)
        XCTAssertEqual(runtime.scene.presentation, .compact)
    }

    func testActivatingAnotherExperienceAwaitsConversationCleanup() async {
        let controller = VoiceConversationController(dependencies: missingAIConfiguration())
        let conversation = AIConversationExperience(
            controller: controller,
            providerDetail: "Test providers"
        )
        let runtime = ExperienceRuntime(sessions: [conversation, NavigationExperience()])

        await conversation.handle(.tap)
        XCTAssertEqual(controller.state, .failed)

        await runtime.activate(.navigation)

        XCTAssertEqual(runtime.selectedKind, .navigation)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testRuntimeReceivesBackgroundConversationSnapshot() async {
        let controller = VoiceConversationController(dependencies: missingAIConfiguration())
        let conversation = AIConversationExperience(
            controller: controller,
            providerDetail: "Test providers"
        )
        let runtime = ExperienceRuntime(sessions: [conversation])

        await controller.toggleConversation()
        await waitUntil { runtime.scene.revision == controller.scene.revision }

        XCTAssertEqual(runtime.scene, controller.scene)
        XCTAssertEqual(runtime.primaryActionTitle, controller.primaryActionTitle)
        XCTAssertEqual(runtime.lastEventDescription, controller.lastEventDescription)
        XCTAssertEqual(runtime.lastEventDescription, VoiceConversationState.failed.rawValue)
    }

    func testBuiltInCatalogPreservesApprovedSimulatorDefaultV2() {
        let profile = DisplayProfileCatalog.builtIn.defaultProfile

        XCTAssertEqual(profile.id, "simulator.default.v2")
        XCTAssertEqual(profile.displayName, "默认单绿")
        XCTAssertEqual(profile.visibleAspectRatio, 8.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(profile.surfaceWidthFraction, 0.90)
        XCTAssertEqual(profile.alignment, .center)
        XCTAssertEqual(profile.verticalOffsetFraction, -0.20)
        XCTAssertEqual(profile.viewport, NormalizedRect(x: 0.08, y: 0.12, width: 0.84, height: 0.60))
        XCTAssertEqual(
            profile.safeArea,
            NormalizedEdgeInsets(top: 0.10, leading: 0.08, bottom: 0.10, trailing: 0.08)
        )
        XCTAssertEqual(profile.color.red, 109.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(profile.color.green, 1.0)
        XCTAssertEqual(profile.color.blue, 135.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(profile.textScale, 1.0)
        XCTAssertEqual(profile.lineScale, 1.0)
    }

    func testBuiltInCatalogIncludesDeterministicNonProductionCalibrationFixture() throws {
        let fixture = try DisplayProfileCatalog.builtIn.profile(
            id: "calibration.fixture.non-production.v1"
        )

        XCTAssertEqual(fixture.displayName, "标定测试（非生产）")
        XCTAssertEqual(fixture.visibleAspectRatio, 2.0)
        XCTAssertEqual(fixture.surfaceWidthFraction, 0.72)
        XCTAssertEqual(fixture.alignment, .topLeading)
        XCTAssertEqual(fixture.verticalOffsetFraction, 0.08)
        XCTAssertEqual(fixture.viewport, NormalizedRect(x: 0.10, y: 0.08, width: 0.76, height: 0.70))
        XCTAssertEqual(
            fixture.safeArea,
            NormalizedEdgeInsets(top: 0.05, leading: 0.12, bottom: 0.17, trailing: 0.06)
        )
        XCTAssertEqual(fixture.textScale, 0.90)
        XCTAssertEqual(fixture.lineScale, 1.40)
        XCTAssertEqual(fixture.color, DisplayColorComponents(red: 0.20, green: 0.80, blue: 0.40))
    }

    func testCatalogRejectsEmptyDuplicateMissingDefaultAndUnknownProfile() throws {
        XCTAssertThrowsError(try DisplayProfileCatalog(profiles: [], defaultProfileID: "default")) {
            XCTAssertEqual($0 as? DisplayProfileCatalogError, .emptyCatalog)
        }

        let profile = try makeDisplayProfile(id: "one")
        XCTAssertThrowsError(
            try DisplayProfileCatalog(profiles: [profile, profile], defaultProfileID: profile.id)
        ) {
            XCTAssertEqual($0 as? DisplayProfileCatalogError, .duplicateIdentifier("one"))
        }
        XCTAssertThrowsError(
            try DisplayProfileCatalog(profiles: [profile], defaultProfileID: "missing")
        ) {
            XCTAssertEqual($0 as? DisplayProfileCatalogError, .missingDefaultProfile("missing"))
        }

        let catalog = try DisplayProfileCatalog(profiles: [profile], defaultProfileID: profile.id)
        XCTAssertThrowsError(try catalog.profile(id: "unknown")) {
            XCTAssertEqual($0 as? DisplayProfileCatalogError, .unknownProfile("unknown"))
        }
    }

    func testStoreRejectsUnknownSelectionWithoutChangingActiveProfile() {
        let store = DisplayProfileStore()
        let original = store.activeProfile

        XCTAssertThrowsError(try store.selectProfile(id: "unknown.profile")) {
            XCTAssertEqual($0 as? DisplayProfileCatalogError, .unknownProfile("unknown.profile"))
        }
        XCTAssertEqual(store.activeProfile, original)
    }

    func testSelectingProfileDoesNotMutateOrResetExperienceRuntime() async throws {
        let runtime = ExperienceRuntime()
        await runtime.activate(.navigation)
        await runtime.handle(.swipeDown)
        let selectedKind = runtime.selectedKind
        let snapshot = runtime.snapshot
        let store = DisplayProfileStore()

        try store.selectProfile(id: "calibration.fixture.non-production.v1")

        XCTAssertEqual(runtime.selectedKind, selectedKind)
        XCTAssertEqual(runtime.snapshot, snapshot)
    }

    func testSelectingProfileDoesNotMutateAIController() async throws {
        let controller = VoiceConversationController(dependencies: missingAIConfiguration())
        let runtime = ExperienceRuntime(sessions: [AIConversationExperience(
            controller: controller,
            providerDetail: "Test providers"
        )])
        await runtime.handle(.tap)
        let controllerSnapshot = controller.snapshot
        let conversation = controller.conversation
        let runtimeSnapshot = runtime.snapshot
        let store = DisplayProfileStore()

        try store.selectProfile(id: "calibration.fixture.non-production.v1")

        XCTAssertEqual(controller.snapshot, controllerSnapshot)
        XCTAssertEqual(controller.conversation, conversation)
        XCTAssertEqual(runtime.snapshot, runtimeSnapshot)
    }

    func testSelectingProfileDuringActiveAgentStreamDoesNotCancelOrResetConversation() async throws {
        let speechSession = ProfileSelectionSpeechSession()
        let agent = ProfileSelectionControlledAgent()
        let controller = VoiceConversationController(
            dependencies: activeStreamDependencies(session: speechSession, agent: agent)
        )
        let runtime = ExperienceRuntime(sessions: [AIConversationExperience(
            controller: controller,
            providerDetail: "Test providers"
        )])
        let store = DisplayProfileStore()

        await runtime.handle(.tap)
        speechSession.emit(.transcript("正在回答的问题"))
        speechSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("前半"))
        await waitUntil {
            controller.state == .streaming
                && controller.assistantReply == "前半"
                && runtime.snapshot == controller.snapshot
        }

        let controllerSnapshotBeforeSelection = controller.snapshot
        let conversationBeforeSelection = controller.conversation
        let runtimeSnapshotBeforeSelection = runtime.snapshot
        let revisionBeforeSelection = controller.revision

        try store.selectProfile(id: "calibration.fixture.non-production.v1")

        XCTAssertEqual(store.activeProfileID, "calibration.fixture.non-production.v1")
        XCTAssertEqual(controller.snapshot, controllerSnapshotBeforeSelection)
        XCTAssertEqual(controller.conversation, conversationBeforeSelection)
        XCTAssertEqual(controller.revision, revisionBeforeSelection)
        XCTAssertEqual(runtime.snapshot, runtimeSnapshotBeforeSelection)
        XCTAssertEqual(speechSession.cancelCount, 0)
        XCTAssertFalse(agent.wasCancelled)
        XCTAssertEqual(agent.clearCount, 0)
        XCTAssertEqual(agent.receivedTexts, ["正在回答的问题"])

        agent.emit(.contentDelta("后半"))
        agent.complete(with: "前半后半")
        await waitUntil {
            controller.state == .completed
                && controller.assistantReply == "前半后半"
                && runtime.snapshot == controller.snapshot
        }

        XCTAssertEqual(controller.messages.map(\.text), ["正在回答的问题", "前半后半"])
        XCTAssertEqual(controller.messages.last?.status, .completed)
        XCTAssertEqual(speechSession.cancelCount, 0)
        XCTAssertFalse(agent.wasCancelled)
        XCTAssertEqual(agent.clearCount, 0)
    }

    func testDefaultPreviewProjectionPreservesApprovedVisualMath() {
        let profile = DisplayProfileCatalog.builtIn.defaultProfile
        let projection = HUDPreviewProjection(profile: profile)
        let container = CGSize(width: 1_000, height: 2_000)
        let surface = projection.surfaceSize(in: container)
        let visibleAspectRatio = projection.containerAspectRatio
            * profile.visibleWidthFraction / profile.visibleHeightFraction

        XCTAssertEqual(projection.surfaceWidthFraction, 0.90)
        XCTAssertEqual(projection.containerAspectRatio, profile.presentationContainerAspectRatio)
        XCTAssertEqual(projection.alignment, .center)
        XCTAssertEqual(projection.verticalOffsetFraction, -0.20)
        XCTAssertEqual(surface.width, 900)
        XCTAssertEqual(surface.height, 900 / profile.presentationContainerAspectRatio, accuracy: 0.000_001)
        XCTAssertEqual(projection.verticalOffset(in: container), -400)
        XCTAssertEqual(visibleAspectRatio, 8.0 / 3.0, accuracy: 0.000_001)
    }

    func testFloatingHeaderDoesNotDoubleApplySafeAreaInset() {
        XCTAssertEqual(AppShellLayout.headerTopPadding, 0)
    }

    func testControlPanelHeightIsContentIndependentAndBounded() {
        XCTAssertEqual(
            AppShellLayout.controlPanelHeight(in: 667),
            AppShellLayout.minimumControlPanelHeight
        )
        XCTAssertEqual(
            AppShellLayout.controlPanelHeight(in: 874),
            874 * AppShellLayout.controlPanelHeightFraction,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            AppShellLayout.controlPanelHeight(in: 956),
            AppShellLayout.maximumControlPanelHeight
        )
        XCTAssertEqual(
            AppShellLayout.controlPanelHeight(in: 1_366),
            AppShellLayout.maximumControlPanelHeight
        )
    }

    func testThinkingMotionPolicyUsesApprovedTimingAndReduceMotionFallback() {
        XCTAssertEqual(
            HUDMotionPolicy.thinkingDotOpacities(elapsed: 10, reduceMotion: true),
            [0.70, 0.70, 0.70]
        )
        XCTAssertEqual(
            HUDMotionPolicy.thinkingGroupOpacity(elapsed: 0, reduceMotion: false),
            0
        )
        XCTAssertEqual(
            HUDMotionPolicy.thinkingGroupOpacity(elapsed: 0.22, reduceMotion: false),
            1,
            accuracy: 0.000_001
        )

        let firstPeak = HUDMotionPolicy.thinkingDotOpacities(
            elapsed: HUDMotionPolicy.thinkingLoopStartDelay
                + HUDMotionPolicy.thinkingCycleDuration / 2,
            reduceMotion: false
        )
        XCTAssertEqual(firstPeak[0], 0.90, accuracy: 0.000_001)
        XCTAssertLessThan(firstPeak[1], firstPeak[0])
        XCTAssertLessThan(firstPeak[2], firstPeak[1])

        let secondPeak = HUDMotionPolicy.thinkingDotOpacities(
            elapsed: HUDMotionPolicy.thinkingLoopStartDelay
                + HUDMotionPolicy.thinkingCycleDuration / 2
                + HUDMotionPolicy.thinkingPhaseOffset,
            reduceMotion: false
        )
        XCTAssertEqual(secondPeak[1], 0.90, accuracy: 0.000_001)
        XCTAssertEqual(
            HUDMotionPolicy.cursorOpacity(elapsed: 10, reduceMotion: true),
            0.75
        )
        XCTAssertEqual(
            HUDMotionPolicy.transition(for: .rule(.vertical, progress: 1)),
            .init(duration: 0.20, curve: .linear)
        )
        XCTAssertEqual(
            HUDMotionPolicy.transition(for: .text("正在思考", .caption)),
            .init(duration: 0.12, curve: .easeInOut)
        )
        XCTAssertEqual(
            HUDMotionPolicy.transition(for: .styledFlowingText(
                "回答",
                isStreaming: true,
                footer: nil,
                style: .title
            )),
            .init(duration: 0.12, curve: .easeOut)
        )
        XCTAssertEqual(
            HUDMotionPolicy.transition(for: .styledFlowingTextRuns(
                [HUDTextRun(text: "回答", opacity: 0.68)],
                isStreaming: false,
                footer: nil,
                style: .detail
            )),
            .init(duration: 0.12, curve: .easeOut)
        )
    }

    func testMinimalConversationHUDRendersReferenceStateAtEightToThree() async throws {
        let scene = ConversationHUDMapper.makeScene(
            revision: 1,
            state: .streaming,
            transcript: "如何安排一次产品评审？",
            assistantReply: "先明确目标，再聚焦关键流程，最后记录结论与下一步。",
            audioLevel: 0.58,
            error: nil
        )
        let profile = DisplayProfileCatalog.builtIn.defaultProfile
        let projection = HUDPreviewProjection(profile: profile)
        let width: CGFloat = 400
        let height = (width / projection.containerAspectRatio).rounded(.up)
        let image = try await renderConversationHUD(
            scene: scene,
            filename: "SingleGreenDemo-MinimalHUD-implementation.png"
        )

        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, height, accuracy: 0.5)
        XCTAssertEqual(image.cgImage?.width, 1_600)
        XCTAssertEqual(
            profile.visibleAspectRatio,
            8.0 / 3.0,
            accuracy: 0.000_001
        )
    }

    func testTeleprompterHUDRendersThreeDepthReadingStateAtEightToThree() async throws {
        let script = try TeleprompterScript(
            "已经读过的内容留作定位。当前正在朗读的内容保持最亮。接下来还没有读到的内容使用中等亮度。"
        )
        let scene = TeleprompterHUDMapper.scene(
            for: TeleprompterState(script: script, sentenceIndex: 1, phase: .listening),
            revision: 1
        )
        let image = try await renderConversationHUD(
            scene: scene,
            filename: "SingleGreenDemo-TeleprompterHUD-depth.png"
        )
        let profile = DisplayProfileCatalog.builtIn.defaultProfile
        let projection = HUDPreviewProjection(profile: profile)
        let expectedHeight = (400 / projection.containerAspectRatio).rounded(.up) * 4

        XCTAssertEqual(image.cgImage?.width, 1_600)
        XCTAssertEqual(image.cgImage?.height, Int(expectedHeight))
    }

    func testAnswerViewportUsesExactlyTwoCompleteLineHeights() {
        XCTAssertEqual(HUDFlowingTextViewportPolicy.answerVisibleLineCount, 2)
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.answerOverflowAnimationDuration,
            0.30,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.viewportHeight(
                availableHeight: 80,
                visibleLineCount: 2,
                lineHeight: 24
            ),
            48,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.viewportHeight(
                availableHeight: 40,
                visibleLineCount: 2,
                lineHeight: 24
            ),
            40,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.viewportHeight(
                availableHeight: 80,
                visibleLineCount: nil,
                lineHeight: nil
            ),
            80,
            accuracy: 0.000_001
        )
    }

    func testTeleprompterViewportUsesExactlyThreeMeasuredCompleteLines() {
        XCTAssertEqual(HUDFlowingTextViewportPolicy.teleprompterVisibleLineCount, 3)
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.teleprompterFollowAnimationDuration,
            0.18,
            accuracy: 0.000_001
        )
        XCTAssertTrue(HUDFlowingTextViewportPolicy.usesCompleteLineTail(
            sceneID: "teleprompter.asr",
            elementID: "teleprompter_body"
        ))
        XCTAssertTrue(HUDFlowingTextViewportPolicy.alignsCompleteLinesToTop(
            sceneID: "teleprompter.asr",
            elementID: "teleprompter_body"
        ))
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.completeLineViewportHeight(
                availableHeight: 91,
                lineHeight: 24,
                maximumLineCount: 3
            ),
            72,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.completeLineViewportHeight(
                availableHeight: 65,
                lineHeight: 24,
                maximumLineCount: 3
            ),
            48,
            accuracy: 0.000_001
        )
        XCTAssertFalse(HUDFlowingTextViewportPolicy.usesCompleteLineTail(
            sceneID: "teleprompter.asr",
            elementID: "teleprompter_footer"
        ))
        XCTAssertEqual(
            HUDFlowingTextViewportPolicy.completeLineFocusUTF16Offset(
                runs: [
                    HUDTextRun(text: "▸ 当前句", isFocused: true),
                    HUDTextRun(text: "\n  下一句", opacity: 0.68)
                ],
                sceneID: "teleprompter.asr",
                elementID: "teleprompter_body"
            ),
            0
        )
    }

    func testCompleteLinePolicyReturnsOnlyWholeUnicodeTailFragments() {
        let font = UIFont.systemFont(ofSize: 17, weight: .medium)
        let text = "第一行\n第二行👨‍👩‍👧‍👦\n第三行e\u{301}\n第四行"

        let visible = HUDCompleteLineTextPolicy.visibleText(
            text,
            width: 500,
            font: font,
            maximumLineCount: 2,
            alignsToTop: false
        )

        XCTAssertFalse(visible.contains("第二行"))
        XCTAssertTrue(visible.contains("第三行e\u{301}"))
        XCTAssertTrue(visible.contains("第四行"))
        XCTAssertTrue(visible.unicodeScalars.contains("\u{301}"))
    }

    func testCompleteLineRunSelectionPreservesGreenDepthAndUnicodeBoundaries() {
        let runs = [
            HUDTextRun(text: "  已读👨‍👩‍👧‍👦\n", opacity: 0.32),
            HUDTextRun(text: "▸ 当前e\u{301}\n", opacity: 1),
            HUDTextRun(text: "  未读", opacity: 0.68)
        ]
        let fullText = runs.map(\.text).joined()
        let previousLength = (runs[0].text as NSString).length
        let selected = NSRange(
            location: previousLength,
            length: (fullText as NSString).length - previousLength
        )

        let visibleRuns = HUDTextRunSelectionPolicy.visibleRuns(
            runs,
            fullText: fullText,
            selectedUTF16Range: selected
        )

        XCTAssertEqual(visibleRuns.map(\.text).joined(), "▸ 当前e\u{301}\n  未读")
        XCTAssertEqual(visibleRuns.map(\.opacity), [1, 0.68])
        XCTAssertTrue(visibleRuns[0].text.unicodeScalars.contains("\u{301}"))

        XCTAssertEqual(
            HUDTextRunSelectionPolicy.visibleRuns(
                [HUDTextRun(text: "错误组合")],
                fullText: "安全回退",
                selectedUTF16Range: NSRange(location: 0, length: 4)
            ),
            [HUDTextRun(text: "安全回退")]
        )
    }

    func testTeleprompterThreeLineWindowAssignsReadCurrentAndUnreadDepths() throws {
        let font = UIFont.systemFont(ofSize: 17, weight: .medium)
        let text = "已经读过\n▸正在朗读\n接下来未读"
        let firstBreak = (text as NSString).range(of: "\n")
        let focusOffset = NSMaxRange(firstBreak)
        let selection = HUDCompleteLineTextPolicy.visibleSelection(
            text,
            width: 500,
            font: font,
            maximumLineCount: 3,
            maximumHeight: font.lineHeight * 3,
            alignsToTop: true,
            focusUTF16Offset: focusOffset
        )
        let runs = HUDTeleprompterLineRunPolicy.visibleRuns(
            fullText: text,
            selectedLineUTF16Ranges: selection.lineUTF16Ranges,
            focusUTF16Offset: focusOffset
        )

        XCTAssertEqual(selection.lineUTF16Ranges.count, 3)
        XCTAssertEqual(runs.map(\.opacity), [0.32, 1, 0.68])
        XCTAssertEqual(runs.map(\.isFocused), [false, true, false])
        XCTAssertEqual(runs.map(\.text).joined(), selection.text)
    }

    func testCompleteLinePolicyUsesStructuralParagraphOffsetInsteadOfAuthoredMarker() {
        let font = UIFont.systemFont(ofSize: 17, weight: .medium)
        let text = "  用户正文包含 ▸ 符号\n▸ 当前行\n  下一行\n  不应出现"
        let focusOffset = try! XCTUnwrap(
            HUDFlowingTextViewportPolicy.completeLineFocusUTF16Offset(
                text: text,
                sceneID: "teleprompter.asr",
                elementID: "teleprompter_body"
            )
        )

        let visible = HUDCompleteLineTextPolicy.visibleText(
            text,
            width: 500,
            font: font,
            maximumLineCount: 3,
            maximumHeight: font.lineHeight * 3,
            alignsToTop: true,
            focusUTF16Offset: focusOffset
        )

        XCTAssertTrue(visible.contains("用户正文包含 ▸ 符号"))
        XCTAssertTrue(visible.contains("▸ 当前行"))
        XCTAssertTrue(visible.contains("下一行"))
        XCTAssertFalse(visible.contains("不应出现"))
    }

    func testNarrowTeleprompterViewportIgnoresAuthoredMarkerAtWrappedPreviousLine() throws {
        let font = UIFont.systemFont(ofSize: 17, weight: .medium)
        let text = "  上一句很长很长很长 ▸ 用户原文\n▸ 当前句\n  下一句"
        let focusOffset = try XCTUnwrap(
            HUDFlowingTextViewportPolicy.completeLineFocusUTF16Offset(
                text: text,
                sceneID: "teleprompter.asr",
                elementID: "teleprompter_body"
            )
        )

        let visible = HUDCompleteLineTextPolicy.visibleText(
            text,
            width: 74,
            font: font,
            maximumLineCount: 3,
            maximumHeight: font.lineHeight * 3,
            alignsToTop: true,
            focusUTF16Offset: focusOffset
        )

        XCTAssertTrue(visible.contains("▸ 当前句"))
        XCTAssertFalse(visible.contains("▸ 用户原文"))
    }

    func testTeleprompterViewportFollowsIntraSentenceUnreadFocus() throws {
        let font = UIFont.systemFont(ofSize: 17, weight: .medium)
        let runs = [
            HUDTextRun(text: "  已经读过的第一段很长很长很长", opacity: 0.32),
            HUDTextRun(
                text: " ▸ 从这里继续显示还没有读到的内容直到结束",
                opacity: 1,
                isFocused: true
            ),
            HUDTextRun(text: "\n  下一句仍然未读", opacity: 0.68)
        ]
        let text = runs.map(\.text).joined()
        let focusOffset = try XCTUnwrap(
            HUDFlowingTextViewportPolicy.completeLineFocusUTF16Offset(
                runs: runs,
                sceneID: "teleprompter.asr",
                elementID: "teleprompter_body"
            )
        )
        let selection = HUDCompleteLineTextPolicy.visibleSelection(
            text,
            width: 86,
            font: font,
            maximumLineCount: 3,
            maximumHeight: font.lineHeight * 3,
            alignsToTop: true,
            focusUTF16Offset: focusOffset
        )

        XCTAssertGreaterThan(selection.utf16Range.location, 0)
        XCTAssertTrue(selection.text.contains("▸") || selection.text.contains("从这里"))
        XCTAssertFalse(selection.text.contains("已经读过的第一段"))
    }

    func testCompleteLinePolicyNeverSelectsFragmentsTallerThanMeasuredViewport() {
        let font = UIFont.systemFont(ofSize: 20, weight: .medium)
        let text = "第一行\n第二行\n第三行"

        let visible = HUDCompleteLineTextPolicy.visibleText(
            text,
            width: 500,
            font: font,
            maximumLineCount: 3,
            maximumHeight: font.lineHeight * 2 + 0.5,
            alignsToTop: true
        )

        XCTAssertFalse(visible.contains("第一行"))
        XCTAssertTrue(visible.contains("第二行"))
        XCTAssertTrue(visible.contains("第三行"))
    }

    func testConversationHUDRendersLongStreamingAnswerInsideTwoLineViewport() async throws {
        let finalReply = "先明确目标，再聚焦关键流程，然后邀请关键角色评审，最后记录结论、负责人和下一步安排。"
        let model = ConversationHUDStreamingTestModel(
            reply: "先明确目标，再聚焦关键流程。"
        )
        let image = try await renderHUDView(
            ConversationHUDStreamingTestHarness(model: model),
            filename: "SingleGreenDemo-TwoLineHUD-implementation.png",
            settleMilliseconds: 480,
            updateBeforeCapture: { model.reply = finalReply }
        )
        let profile = DisplayProfileCatalog.builtIn.defaultProfile
        let projection = HUDPreviewProjection(profile: profile)
        let expectedHeight = (400 / projection.containerAspectRatio).rounded(.up) * 4

        XCTAssertEqual(image.cgImage?.width, 1_600)
        XCTAssertEqual(image.cgImage?.height, Int(expectedHeight))
    }

    func testHostProjectsNormalizedViewportAndAsymmetricSafeAreaIntoCGRect() throws {
        let profile = try makeDisplayProfile(
            viewport: NormalizedRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            safeArea: NormalizedEdgeInsets(top: 0.10, leading: 0.20, bottom: 0.15, trailing: 0.05)
        )
        let viewport = profile.viewport.rect(in: CGRect(x: 10, y: 20, width: 200, height: 100))
        let safeRect = profile.safeArea.inset(viewport)

        XCTAssertEqual(viewport, CGRect(x: 30, y: 40, width: 160, height: 60))
        XCTAssertEqual(safeRect.origin.x, 62, accuracy: 0.000_001)
        XCTAssertEqual(safeRect.origin.y, 46, accuracy: 0.000_001)
        XCTAssertEqual(safeRect.width, 120, accuracy: 0.000_001)
        XCTAssertEqual(safeRect.height, 45, accuracy: 0.000_001)
    }

    func testConversationControllerStartsWithActionableHUD() {
        let settings = AISettings()
        let controller = VoiceConversationController(dependencies: .live(settings: settings))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.primaryActionTitle, "开始对话")
        XCTAssertTrue(controller.allowsPrimaryAction)
        XCTAssertEqual(controller.scene.sceneID, "ai_conversation")
        XCTAssertNotNil(controller.scene.elements.first { $0.id == "user_transcript" })
        XCTAssertNotNil(controller.scene.elements.first { $0.id == "assistant_reply" })
    }

    func testConversationBusyStatesDisableRepeatedPrimaryAction() {
        XCTAssertFalse(VoiceConversationState.connecting.allowsPrimaryAction)
        XCTAssertFalse(VoiceConversationState.recognizing.allowsPrimaryAction)
        XCTAssertTrue(VoiceConversationState.thinking.allowsPrimaryAction)
        XCTAssertTrue(VoiceConversationState.searching.allowsPrimaryAction)
        XCTAssertTrue(VoiceConversationState.listening.allowsPrimaryAction)
    }

    func testConversationIncludesSearchingPresentationState() {
        XCTAssertTrue(VoiceConversationState.searching.allowsPrimaryAction)
        XCTAssertEqual(VoiceConversationState.searching.displayName, "AI 正在联网搜索")
        XCTAssertEqual(VoiceConversationState.searching.systemImage, "globe")
    }

    func testSearchConfigurationOnlyRequiresKeyWhenEnabled() {
        let settings = AISettings()
        let originalEnabled = settings.enableSearch
        let originalKey = settings.bochaAPIKey
        defer {
            settings.enableSearch = originalEnabled
            settings.bochaAPIKey = originalKey
        }

        settings.enableSearch = false
        settings.bochaAPIKey = ""
        XCTAssertTrue(settings.isSearchConfigured)

        settings.enableSearch = true
        XCTAssertFalse(settings.isSearchConfigured)

        settings.bochaAPIKey = "bocha-test-key"
        XCTAssertTrue(settings.isSearchConfigured)
    }

    func testAISettingsParsesHotwordsFromCommonSeparators() {
        let settings = AISettings()
        let original = settings.hotwordsText
        defer { settings.hotwordsText = original }

        settings.hotwordsText = "单绿眼镜，豆包 DeepSeek\n产品经理"

        XCTAssertEqual(settings.hotwords, ["单绿眼镜", "豆包", "DeepSeek", "产品经理"])
    }

    func testKeychainHelperRoundTripsSecret() {
        let key = "tests.\(UUID().uuidString)"
        defer { KeychainHelper.delete(key) }

        XCTAssertTrue(KeychainHelper.save("test-secret", forKey: key))
        XCTAssertEqual(KeychainHelper.load(key), "test-secret")
        XCTAssertTrue(KeychainHelper.delete(key))
        XCTAssertNil(KeychainHelper.load(key))
    }

    func testServerCredentialProviderCoalescesConcurrentRefreshAndCachesLease() async throws {
        let lease = ConversationCredentialLease(
            speechAPIKey: "speech-value",
            llmAPIKey: "llm-value",
            searchAPIKey: "search-value",
            agentAccountScope: .init(opaqueID: "account-fixture"),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let transport = CountingCredentialTransport(leases: [lease])
        let provider = ServerIssuedCredentialProvider(
            transport: transport,
            now: { Date(timeIntervalSince1970: 0) }
        )

        async let first = provider.lease()
        async let second = provider.lease()
        let values = try await [first, second]
        let cached = try await provider.lease()

        XCTAssertEqual(values, [lease, lease])
        XCTAssertEqual(cached, lease)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testServerCredentialProviderRefreshesNearExpiryAndRejectsExpiredLease() async throws {
        let clock = ThreadSafeDateClock(Date(timeIntervalSince1970: 0))
        let first = ConversationCredentialLease(
            speechAPIKey: "speech-one",
            llmAPIKey: "llm-one",
            searchAPIKey: "",
            agentAccountScope: .init(opaqueID: "account-fixture"),
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let second = ConversationCredentialLease(
            speechAPIKey: "speech-two",
            llmAPIKey: "llm-two",
            searchAPIKey: "",
            agentAccountScope: .init(opaqueID: "account-fixture"),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        let transport = CountingCredentialTransport(leases: [first, second])
        let provider = ServerIssuedCredentialProvider(
            transport: transport,
            now: { clock.value },
            minimumRemainingLifetime: 30
        )

        let initialLease = try await provider.lease()
        XCTAssertEqual(initialLease, first)
        clock.value = Date(timeIntervalSince1970: 80)
        let refreshedLease = try await provider.lease()
        XCTAssertEqual(refreshedLease, second)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 2)

        let expiredTransport = CountingCredentialTransport(leases: [first])
        let expiredProvider = ServerIssuedCredentialProvider(
            transport: expiredTransport,
            now: { Date(timeIntervalSince1970: 100) }
        )
        do {
            _ = try await expiredProvider.lease()
            XCTFail("Expected expired lease rejection")
        } catch let error as ServerCredentialError {
            XCTAssertEqual(error, .expiredLease)
            XCTAssertFalse(error.description.contains("speech-one"))
        }
    }

    func testServerCredentialProviderCoalescesInvalidLeaseValidationForEveryWaiter() async {
        let now = Date(timeIntervalSince1970: 100)
        for expiresAt in [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 120)
        ] {
            let invalid = ConversationCredentialLease(
                speechAPIKey: "speech-invalid",
                llmAPIKey: "llm-invalid",
                searchAPIKey: "",
                agentAccountScope: .init(opaqueID: "account-fixture"),
                expiresAt: expiresAt
            )
            let transport = SuspendedCredentialTransport()
            let joinCounter = ThreadSafeCounter()
            let provider = ServerIssuedCredentialProvider(
                transport: transport,
                now: { now },
                minimumRemainingLifetime: 30,
                onJoinInFlight: { joinCounter.increment() }
            )

            let first = Task { await credentialError(from: provider) }
            let firstFetchStarted = await waitForFetchCount(1, transport: transport)
            XCTAssertTrue(firstFetchStarted)
            let second = Task { await credentialError(from: provider) }
            await waitUntil { joinCounter.value == 1 }
            await transport.resolve(with: invalid)
            let concurrentErrors = await [first.value, second.value]

            XCTAssertEqual(concurrentErrors, [.expiredLease, .expiredLease])
            let concurrentFetchCount = await transport.fetchCount
            XCTAssertEqual(concurrentFetchCount, 1)

            let later = Task { await credentialError(from: provider) }
            let secondFetchStarted = await waitForFetchCount(2, transport: transport)
            XCTAssertTrue(secondFetchStarted)
            await transport.resolve(with: invalid)
            let laterError = await later.value
            let totalFetchCount = await transport.fetchCount
            XCTAssertEqual(laterError, .expiredLease)
            XCTAssertEqual(totalFetchCount, 2)
        }
    }

    func testUnauthorizedSpeechFailureRecordsOneRedactedInputFailure() async {
        let session = HostSpeechRecognitionSession()
        let telemetry = ConversationTelemetryStore()
        let controller = VoiceConversationController(dependencies: VoiceConversationDependencies(
            inputMode: { .pushToTalk },
            voiceActivatedInputAvailable: { false },
            prepareSpeechInput: { _ in .pushToTalk(session) },
            prepareAgent: {
                preconditionFailure("ASR failure must not prepare an Agent")
            },
            requestMicrophonePermission: { true },
            sleep: { _ in },
            telemetry: telemetry,
            presentationCopy: .singleGreenDemo
        ))

        await controller.toggleConversation()
        await session.emit(.failed(.init(
            code: .unauthorized,
            userSafeMessage: "语音服务凭证未通过验证。"
        )))
        await waitUntil { controller.state == .failed }

        let terminalInputEvents = telemetry.events.filter {
            $0.phase == .input && $0.outcome != .started
        }
        XCTAssertEqual(terminalInputEvents.count, 1)
        XCTAssertEqual(terminalInputEvents.first?.outcome, .failed)
        XCTAssertEqual(terminalInputEvents.first?.failureCode, .unauthorized)
        XCTAssertEqual(controller.lastError, "语音服务凭证未通过验证。")
        XCTAssertFalse(controller.lastError?.contains("private-provider-detail") == true)
        await controller.shutdown()
    }

    func testReleaseCredentialTransportFailsClosedWithoutBackend() async {
        do {
            _ = try await FailClosedServerCredentialTransport().fetchLease()
            XCTFail("Expected fail-closed transport")
        } catch let error as ServerCredentialError {
            XCTAssertEqual(error, .transportNotConfigured)
            XCTAssertEqual(error.description, "ServerCredentialError.transportNotConfigured(redacted)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTelemetryStoreIsBoundedAndContainsOnlyTypedSafeEvents() {
        let store = ConversationTelemetryStore(capacity: 2)
        store.record(.init(phase: .input, outcome: .started, elapsedMilliseconds: 0))
        store.record(.init(phase: .reply, outcome: .failed, elapsedMilliseconds: 50, failureCode: .unauthorized))
        store.record(.init(phase: .lifecycle, outcome: .suspended, elapsedMilliseconds: 0))

        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.first?.failureCode, .unauthorized)
        XCTAssertEqual(store.events.last?.phase, .lifecycle)
    }

    func testDiagnosticsExportMatchesBuildCapability() throws {
        let store = ConversationTelemetryStore(capacity: 2)
        store.record(category: "test", message: "safe-code-only")

        #if INTERNAL_DIAGNOSTICS
        let url = try store.makeExportURL()
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("safe-code-only"))
        XCTAssertFalse(contents.contains("apiKey"))
        #else
        XCTAssertThrowsError(try store.makeExportURL())
        XCTAssertTrue(store.diagnosticLines.isEmpty)
        #endif
    }

    private func missingAIConfiguration() -> VoiceConversationDependencies {
        VoiceConversationDependencies(
            inputMode: { .pushToTalk },
            voiceActivatedInputAvailable: { false },
            prepareSpeechInput: { _ in
                throw ConversationPreparationFailure(
                    userSafeMessage: "对话配置缺失。",
                    failureCode: .configurationMissing
                )
            },
            prepareAgent: {
                throw ConversationPreparationFailure(
                    userSafeMessage: "对话配置缺失。",
                    failureCode: .configurationMissing
                )
            },
            requestMicrophonePermission: { false },
            sleep: { _ in },
            presentationCopy: .singleGreenDemo
        )
    }

    private func renderConversationHUD(
        scene: HUDScene,
        filename: String
    ) async throws -> UIImage {
        let profile = DisplayProfileCatalog.builtIn.defaultProfile
        return try await renderHUDView(
            HUDOverlayView(
                scene: scene,
                profile: profile,
                intensity: 1,
                showsSafeArea: false
            ),
            filename: filename
        )
    }

    private func renderHUDView<Content: View>(
        _ content: Content,
        filename: String,
        settleMilliseconds: Int64 = 180,
        updateBeforeCapture: (() -> Void)? = nil
    ) async throws -> UIImage {
        let profile = DisplayProfileCatalog.builtIn.defaultProfile
        let projection = HUDPreviewProjection(profile: profile)
        let width: CGFloat = 400
        let height = (width / projection.containerAspectRatio).rounded(.up)
        let view = content
            .frame(width: width, height: height)
            .background(Color.black)

        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.backgroundColor = .black
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        if let updateBeforeCapture {
            try await Task.sleep(for: .milliseconds(80))
            updateBeforeCapture()
        }
        try await Task.sleep(for: .milliseconds(settleMilliseconds))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        let renderer = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try data.write(to: outputURL, options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func activeStreamDependencies(
        session: ProfileSelectionSpeechSession,
        agent: ProfileSelectionControlledAgent
    ) -> VoiceConversationDependencies {
        VoiceConversationDependencies(
            inputMode: { .pushToTalk },
            voiceActivatedInputAvailable: { false },
            prepareSpeechInput: { _ in .pushToTalk(session) },
            prepareAgent: {
                PreparedConversationAgent(
                    contextIdentity: ConversationAgentContextIdentity(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
                    ),
                    agent: agent
                )
            },
            requestMicrophonePermission: { true },
            sleep: { _ in await Task.yield() },
            reduceMotion: { true },
            presentationCopy: .singleGreenDemo
        )
    }

    private func makeDisplayProfile(
        id: String = "tests.profile",
        viewport: NormalizedRect = .init(x: 0, y: 0, width: 1, height: 1),
        safeArea: NormalizedEdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
    ) throws -> DisplayProfile {
        try DisplayProfile(
            id: id,
            displayName: "Tests",
            visibleAspectRatio: 2,
            surfaceWidthFraction: 0.8,
            alignment: .center,
            verticalOffsetFraction: 0,
            viewport: viewport,
            safeArea: safeArea,
            textScale: 1,
            lineScale: 1,
            color: DisplayColorComponents(red: 0, green: 1, blue: 0)
        )
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }
}

private struct ConversationHUDStreamingTestHarness: View {
    @ObservedObject var model: ConversationHUDStreamingTestModel

    var body: some View {
        HUDOverlayView(
            scene: ConversationHUDMapper.makeScene(
                revision: 1,
                state: .streaming,
                transcript: "如何安排一次产品评审？",
                assistantReply: model.reply,
                audioLevel: 0.58,
                error: nil
            ),
            profile: DisplayProfileCatalog.builtIn.defaultProfile,
            intensity: 1,
            showsSafeArea: false
        )
    }
}

@MainActor
private final class ConversationHUDStreamingTestModel: ObservableObject {
    @Published var reply: String

    init(reply: String) {
        self.reply = reply
    }
}

private actor CountingCredentialTransport: ServerCredentialTransport {
    private var leases: [ConversationCredentialLease]
    private(set) var fetchCount = 0

    init(leases: [ConversationCredentialLease]) {
        self.leases = leases
    }

    func fetchLease() async throws -> ConversationCredentialLease {
        fetchCount += 1
        await Task.yield()
        guard !leases.isEmpty else { throw ServerCredentialError.transportNotConfigured }
        return leases.removeFirst()
    }
}

private actor SuspendedCredentialTransport: ServerCredentialTransport {
    private var continuations: [CheckedContinuation<ConversationCredentialLease, Never>] = []
    private(set) var fetchCount = 0

    func fetchLease() async throws -> ConversationCredentialLease {
        fetchCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolve(with lease: ConversationCredentialLease) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: lease)
    }
}

private actor HostSpeechRecognitionSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation

    init() {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: SpeechRecognitionEvent) {
        continuation.yield(event)
    }

    func start() async throws {}
    func finish() async {}
    func cancel() async {}
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private func waitForFetchCount(
    _ expected: Int,
    transport: SuspendedCredentialTransport,
    iterations: Int = 1_000
) async -> Bool {
    for _ in 0..<iterations {
        if await transport.fetchCount == expected { return true }
        await Task.yield()
    }
    return false
}

private func credentialError(
    from provider: ServerIssuedCredentialProvider
) async -> ServerCredentialError? {
    do {
        _ = try await provider.lease()
        return nil
    } catch {
        return error as? ServerCredentialError
    }
}

private final class ThreadSafeDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) { storage = value }

    var value: Date {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

@MainActor
private final class HostCatalogFixtureExperience: ExperienceSession {
    let descriptor: ExperienceDescriptor
    let scene = HUDScene(
        sceneID: "host_fixture",
        revision: 0,
        presentation: .compact,
        elements: []
    )
    let primaryActionTitle = "Unused snapshot title"
    private(set) var receivedEvents: [DemoEvent] = []
    private(set) var receivedActions: [ExperienceActionEvent] = []

    init(descriptor: ExperienceDescriptor = ExperienceDescriptor(
        kind: .caption,
        displayName: "Host fixture",
        detail: "Descriptor supplies UI data",
        systemImageName: "sparkles",
        capabilities: [.camera],
        actions: [
            ExperienceActionDescriptor(
                id: "custom_action",
                event: .swipeUp,
                placement: .secondary,
                titleSource: .fixed("Run fixture"),
                iconSource: .fixed("bolt.fill"),
                accessibilityLabel: "Run host fixture"
            )
        ]
    )) {
        self.descriptor = descriptor
    }

    func handle(_ event: DemoEvent) async {
        receivedEvents.append(event)
    }

    func handle(_ action: ExperienceActionEvent) async {
        receivedActions.append(action)
    }

    func reset() async {}
}

@MainActor
private final class ProfileSelectionSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation
    private var cancellations = 0

    var cancelCount: Int { cancellations }

    init() {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: SpeechRecognitionEvent) {
        continuation.yield(event)
    }

    func start() async throws {}
    func finish() async {}
    func cancel() async { cancellations += 1 }
}

@MainActor
private final class ProfileSelectionControlledAgent: ConversationAgent {
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private var cancellationObserved = false
    private var contextClearCount = 0
    private var texts: [String] = []

    var isWaiting: Bool { continuation != nil }
    var wasCancelled: Bool { cancellationObserved }
    var clearCount: Int { contextClearCount }
    var receivedTexts: [String] { texts }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        texts.append(userText)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { @MainActor in
                    self?.cancellationObserved = true
                    self?.continuation = nil
                }
            }
        }
    }

    func emit(_ event: ConversationAgentEvent) {
        continuation?.yield(event)
    }

    func complete(with text: String) {
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.completed(text))
        continuation?.finish()
    }

    func clearContext() async {
        contextClearCount += 1
    }
}
