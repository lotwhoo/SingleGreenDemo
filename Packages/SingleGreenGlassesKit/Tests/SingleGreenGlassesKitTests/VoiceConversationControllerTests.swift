import Combine
import StreamingTextKit
import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class VoiceConversationControllerTests: XCTestCase {
    func testControllerDeallocationCancelsActiveInputSession() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        var controller: VoiceConversationController? = makeController(session: session, agent: agent)
        weak let weakController = controller

        await controller?.toggleConversation()
        XCTAssertEqual(session.startCount, 1)

        controller = nil

        await waitUntil { weakController == nil && session.cancelCount == 1 }
    }

    func testControllerDeallocationCancelsActiveReplyStream() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        var controller: VoiceConversationController? = makeController(session: session, agent: agent)
        weak let weakController = controller

        await controller?.toggleConversation()
        session.emit(.transcript("释放测试"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }

        controller = nil

        await waitUntil { weakController == nil && agent.wasCancelled }
    }

    func testControllerDeallocationCancelsActiveDisplaySleep() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let sleeper = CancellationTrackingSleeper()
        var controller: VoiceConversationController? = VoiceConversationController(
            dependencies: makeDependencies(
                session: session,
                agent: agent,
                sleep: { _ in try await sleeper.sleep() },
                reduceMotion: { false }
            )
        )
        weak let weakController = controller

        await controller?.toggleConversation()
        session.emit(.transcript("显示释放"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("需要继续播放的长文字"))
        await waitUntil { sleeper.isSleeping }

        controller = nil

        await waitUntil { weakController == nil && sleeper.cancellationCount == 1 }
    }

    func testExplicitShutdownCancelsAllActiveResources() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        await controller.shutdown()

        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertFalse(agent.isWaiting)
    }

    func testUpstreamFinalizedTransactionIsAbortedWhenResetInterruptsDisplayCatchUp() async {
        let session = FakeSpeechSession()
        let agent = TransactionalControlledAgent()
        let sleeper = ManualSleeper()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: agent,
            sleep: { _ in try await sleeper.sleep() },
            reduceMotion: { false }
        ))

        await controller.toggleConversation()
        session.emit(.transcript("上游已完成"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "尚未完成展示的回答")
        await waitUntil {
            controller.state == .streaming && !controller.assistantReply.isEmpty
        }

        await controller.resetConversation()

        XCTAssertEqual(agent.committed, [])
        XCTAssertEqual(agent.aborted, [agent.token])
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testReplyRemainsPendingUntilContextCommitAcknowledgementSucceeds() async {
        let session = FakeSpeechSession()
        let agent = SuspendedCommitConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("提交顺序"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "完整可见回答")
        await waitUntil { agent.isCommitSuspended }

        XCTAssertEqual(controller.assistantReply, "完整可见回答")
        XCTAssertEqual(controller.state, .streaming)
        XCTAssertEqual(controller.messages.last?.status, .pending)

        agent.resolveCommitSuccessfully()
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(controller.messages.last?.status, .completed)
        XCTAssertEqual(agent.committedContext, ["提交顺序", "完整可见回答"])
    }

    func testCommitFailurePreservesVisibleAnswerAndFailsReplyWithoutContext() async {
        let session = FakeSpeechSession()
        let agent = SuspendedCommitConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("保存失败"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "已经完整显示的可信回答")
        await waitUntil { agent.isCommitSuspended }
        agent.resolveCommitFailure()

        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "已经完整显示的可信回答")
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertEqual(
            controller.lastError,
            "回答已显示，但对话上下文保存失败，请重试。"
        )
        XCTAssertTrue(agent.committedContext.isEmpty)
        XCTAssertEqual(agent.clearCount, 0, "one failed transaction must not erase earlier history")
    }

    func testAcceptedPostCommitGatePublishesDomainAndAgentContextTogether() async {
        let session = FakeSpeechSession()
        let agent = PostCommitGateConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("接受门禁"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "已接受回答")
        await waitUntil { agent.isCommitAppliedButNotReturned }

        agent.allowAcceptance()
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(controller.messages.last?.status, .completed)
        XCTAssertEqual(agent.committedContext, ["接受门禁", "已接受回答"])
    }

    func testBackgroundAtPostCommitGateRollsBackDomainAndAgentContextTogether() async {
        let session = FakeSpeechSession()
        let agent = PostCommitGateConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("后台竞态"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "不应被接受")
        await waitUntil { agent.isCommitAppliedButNotReturned }

        await controller.suspendForBackground()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(agent.committedContext.isEmpty)
        XCTAssertEqual(agent.aborted, [agent.token])
    }

    func testResetAtPostCommitGateRollsBackDomainAndAgentContextTogether() async {
        let session = FakeSpeechSession()
        let agent = PostCommitGateConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("重置竞态"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "不应留下")
        await waitUntil { agent.isCommitAppliedButNotReturned }

        await controller.resetConversation()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(agent.committedContext.isEmpty)
    }

    func testNewInputAtPostCommitGateRollsBackUnacceptedTurnContext() async {
        let firstSession = FakeSpeechSession()
        let secondSession = FakeSpeechSession()
        var sessions = [firstSession, secondSession]
        let agent = PostCommitGateConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: firstSession,
            agent: agent,
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        firstSession.emit(.transcript("旧输入"))
        firstSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "旧回答")
        await waitUntil { agent.isCommitAppliedButNotReturned }

        await controller.toggleConversation()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(agent.committedContext.isEmpty)
        XCTAssertFalse(controller.messages.contains { !$0.isUser && $0.status == .completed })
    }

    func testResetDuringSuspendedCommitRejectsStaleSuccessAndClearsContext() async {
        let session = FakeSpeechSession()
        let agent = SuspendedCommitConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("重置竞态"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "不应该留在上下文的回答")
        await waitUntil { agent.isCommitSuspended }

        let reset = Task { await controller.resetConversation() }
        await waitUntil { !agent.aborted.isEmpty }
        agent.resolveCommitSuccessfully()
        await reset.value
        await Task.yield()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(agent.committedContext.isEmpty)
    }

    func testNewInputDuringSuspendedCommitRejectsStaleFailureAndNextTurnHasNoAbandonedContext() async {
        let firstSession = FakeSpeechSession()
        let secondSession = FakeSpeechSession()
        var sessions = [firstSession, secondSession]
        let agent = SuspendedCommitConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: firstSession,
            agent: agent,
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        firstSession.emit(.transcript("旧问题"))
        firstSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "应该被放弃的旧回答")
        await waitUntil { agent.isCommitSuspended }

        let newInput = Task { await controller.toggleConversation() }
        await waitUntil { !agent.aborted.isEmpty }
        agent.resolveCommitFailure()
        await newInput.value
        XCTAssertEqual(controller.state, .listening)
        XCTAssertNil(controller.lastError)

        secondSession.emit(.transcript("新问题"))
        await waitUntil { controller.liveText == "新问题" }
        secondSession.emit(.finished)
        await waitUntil { agent.contextSnapshotsAtStreamStart.count == 2 }

        XCTAssertEqual(agent.contextSnapshotsAtStreamStart[1], [])
        XCTAssertEqual(
            controller.messages.filter(\.isUser).map(\.text),
            ["旧问题", "新问题"]
        )
    }

    func testInitialSnapshotIsCoherentAndMatchesSynchronousFacade() {
        let controller = makeController(
            session: FakeSpeechSession(),
            agent: FakeConversationAgent(reply: "")
        )
        let expectedControlState = ExperienceControlState(
            statusTitle: "AI 对话待命",
            statusDetail: "语音识别 → 多轮 Agent → 按需联网搜索",
            errorMessage: nil,
            primaryActionSystemImage: "waveform",
            allowsPrimaryAction: true
        )

        XCTAssertEqual(controller.snapshot.scene.revision, 0)
        XCTAssertEqual(controller.snapshot.scene, ConversationHUDMapper.makeScene(
            revision: 0,
            state: .idle,
            transcript: "",
            assistantReply: "",
            audioLevel: 0,
            error: nil
        ))
        XCTAssertEqual(controller.snapshot.primaryActionTitle, "开始对话")
        XCTAssertEqual(controller.snapshot.eventDescription, "idle")
        XCTAssertEqual(controller.snapshot.controlState, expectedControlState)
        XCTAssertEqual(controller.scene, controller.snapshot.scene)
        XCTAssertEqual(controller.primaryActionTitle, controller.snapshot.primaryActionTitle)
        XCTAssertEqual(controller.lastEventDescription, controller.snapshot.eventDescription)
        XCTAssertEqual(controller.controlState, controller.snapshot.controlState)
    }

    func testFailurePublishesOneCoherentPresentationSnapshot() async {
        let session = FakeSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: ""),
            configuration: { .missingASR }
        ))
        var emittedSnapshots: [ExperienceSnapshot] = []
        let observation = controller.$snapshot
            .dropFirst()
            .sink { emittedSnapshots.append($0) }

        await controller.toggleConversation()

        let error = "请先在设置中填写豆包 ASR API Key 和资源 ID。"
        XCTAssertEqual(controller.snapshot.scene, ConversationHUDMapper.makeScene(
            revision: 1,
            state: .failed,
            transcript: "",
            assistantReply: "",
            audioLevel: 0,
            error: error
        ))
        XCTAssertEqual(controller.snapshot.primaryActionTitle, "开始对话")
        XCTAssertEqual(controller.snapshot.eventDescription, "failed")
        XCTAssertEqual(controller.snapshot.controlState, ExperienceControlState(
            statusTitle: "AI 对话失败",
            statusDetail: error,
            errorMessage: error,
            primaryActionSystemImage: "waveform",
            allowsPrimaryAction: true
        ))
        XCTAssertEqual(emittedSnapshots, [controller.snapshot])
        withExtendedLifetime(observation) {}
    }

    func testAIConversationExperienceForwardsControllerSnapshotExactly() async {
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: FakeConversationAgent(reply: ""),
            configuration: { .missingASR }
        ))
        let experience = AIConversationExperience(controller: controller, providerDetail: "Test providers")
        var iterator = experience.updates().makeAsyncIterator()

        let initialForwardedUpdate = await iterator.next()
        XCTAssertEqual(initialForwardedUpdate?.snapshot, controller.snapshot)
        XCTAssertEqual(initialForwardedUpdate?.provenance, .spontaneous)

        await controller.toggleConversation()
        let expectedFailure = controller.snapshot
        let forwardedFailure = await iterator.next()

        XCTAssertEqual(forwardedFailure?.snapshot, expectedFailure)
        XCTAssertEqual(forwardedFailure?.provenance, .spontaneous)
        XCTAssertEqual(experience.scene, expectedFailure.scene)
        XCTAssertEqual(experience.primaryActionTitle, expectedFailure.primaryActionTitle)
        XCTAssertEqual(experience.controlState, expectedFailure.controlState)
    }

    func testRuntimePublishesOneCoherentAIControllerSnapshotWithoutTapOverwrite() async {
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: FakeConversationAgent(reply: ""),
            configuration: { .missingASR }
        ))
        let runtime = ExperienceRuntime(sessions: [
            AIConversationExperience(controller: controller, providerDetail: "Test providers")
        ])
        var emittedSnapshots: [ExperienceSnapshot] = []
        let observation = runtime.$snapshot
            .dropFirst()
            .sink { emittedSnapshots.append($0) }

        await runtime.handle(.tap)
        await waitUntil { runtime.snapshot == controller.snapshot }

        XCTAssertEqual(runtime.snapshot, controller.snapshot)
        XCTAssertEqual(runtime.lastEventDescription, "failed")
        XCTAssertEqual(emittedSnapshots, [controller.snapshot])
        withExtendedLifetime(observation) {}
    }

    func testRuntimeManualStopRebasesASRAndReplyUpdatesToNewCommandProvenance() async {
        let session = FakeSpeechSession()
        let controller = makeController(
            session: session,
            agent: FakeConversationAgent(reply: "这是回答")
        )
        let runtime = ExperienceRuntime(sessions: [
            AIConversationExperience(controller: controller, providerDetail: "Test providers")
        ])

        await runtime.handle(.tap)
        XCTAssertEqual(controller.state, .listening)
        await runtime.handle(.tap)
        XCTAssertEqual(controller.state, .recognizing)

        session.emit(.transcript("手动结束后的问题"))
        session.emit(.finished)
        await waitUntil { controller.state == .completed && runtime.snapshot == controller.snapshot }

        XCTAssertEqual(runtime.lastEventDescription, VoiceConversationState.completed.rawValue)
        XCTAssertEqual(controller.messages.map(\.text), ["手动结束后的问题", "这是回答"])
    }

    func testResetDuringSuspendedPermissionCannotCreateOrStartStaleSession() async {
        let permission = SuspendedPermissionRequest()
        let session = FakeSpeechSession()
        var makeSessionCount = 0
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: ""),
            makeSpeechSession: { _ in
                makeSessionCount += 1
                return session
            },
            requestMicrophonePermission: { await permission.request() }
        ))

        let staleStart = Task { await controller.toggleConversation() }
        await waitUntil { permission.isSuspended }
        XCTAssertEqual(controller.state, .connecting)

        await controller.resetConversation()
        let resetSnapshot = controller.snapshot
        permission.resolve(true)
        await staleStart.value

        XCTAssertEqual(makeSessionCount, 1)
        XCTAssertEqual(session.startCount, 0)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.snapshot, resetSnapshot)
    }

    func testResetDuringSuspendedSessionStartCannotPublishRecording() async {
        let session = SuspendedStartSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "")
        ))

        let staleStart = Task { await controller.toggleConversation() }
        await waitUntil { session.isStartSuspended }

        await controller.resetConversation()
        let resetSnapshot = controller.snapshot
        session.resolveStart()
        await staleStart.value

        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(session.cancelCount, 2)
        XCTAssertFalse(session.isResourceActive)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.snapshot, resetSnapshot)
    }

    func testResetDuringSuspendedThrowingSessionStartCleansResourceWithoutPublishingFailure() async {
        let session = SuspendedStartSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "")
        ))

        let staleStart = Task { await controller.toggleConversation() }
        await waitUntil { session.isStartSuspended }

        await controller.resetConversation()
        let resetSnapshot = controller.snapshot
        session.resolveStart(throwing: SuspendedStartError.failed)
        await staleStart.value

        XCTAssertEqual(session.cancelCount, 2)
        XCTAssertFalse(session.isResourceActive)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.snapshot, resetSnapshot)
    }

    func testEventsFromCancelledSessionCannotMutateNewRecording() async {
        let oldSession = FakeSpeechSession()
        let newSession = FakeSpeechSession()
        var sessions: [FakeSpeechSession] = [oldSession, newSession]
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: oldSession,
            agent: FakeConversationAgent(reply: ""),
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        XCTAssertEqual(controller.state, .listening)
        await controller.resetConversation()
        await controller.toggleConversation()
        XCTAssertEqual(controller.state, .listening)

        oldSession.emit(.transcript("旧问题"))
        oldSession.emit(.level(1))
        oldSession.emit(.failed(.init(code: .connectionLost)))
        oldSession.emit(.finished)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.liveText.isEmpty)
        XCTAssertEqual(controller.audioLevel, 0)
        XCTAssertNil(controller.lastError)

        newSession.emit(.transcript("新问题"))
        await waitUntil { controller.liveText == "新问题" }
    }

    func testASRToAgentUsesCumulativeTranscriptInsteadOfLastUtterance() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "这是回答")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        XCTAssertEqual(controller.state, .listening)

        session.emit(.transcript("这是完整的问题"))
        session.emit(.utterance("问题"))
        session.emit(.finished)

        await waitUntil { controller.state == .completed }
        XCTAssertEqual(agent.receivedTexts, ["这是完整的问题"])
        XCTAssertEqual(controller.messages.map(\.text), ["这是完整的问题", "这是回答"])
        XCTAssertEqual(controller.assistantReply, "这是回答")
    }

    func testWebSearchToolUpdatesStateBeforeFinalReply() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent(toolName: "web_search")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("今天有什么新闻"))
        session.emit(.finished)

        await waitUntil { controller.state == .searching }
        await waitUntil { agent.isWaiting }
        XCTAssertEqual(controller.state, .searching)

        agent.complete(with: "联网回答")
        await waitUntil { controller.state == .completed }
        XCTAssertEqual(controller.assistantReply, "联网回答")
    }

    func testDuplicateFinishedEventCreatesOnlyOneAgentRequest() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "一次回答")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("只问一次"))
        session.emit(.finished)
        session.emit(.finished)

        await waitUntil { controller.state == .completed }
        XCTAssertEqual(agent.receivedTexts, ["只问一次"])
        XCTAssertEqual(controller.messages.filter { !$0.isUser }.count, 1)
    }

    func testMissingASRConfigurationFailsBeforeCreatingSession() async {
        let session = FakeSpeechSession()
        var makeSessionCount = 0
        let dependencies = makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: ""),
            configuration: { .missingASR },
            makeSpeechSession: { _ in
                makeSessionCount += 1
                return session
            }
        )
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(makeSessionCount, 0)
        XCTAssertEqual(controller.lastError, "请先在设置中填写豆包 ASR API Key 和资源 ID。")
    }

    func testDeniedPermissionFailsWithoutStartingASR() async {
        let session = FakeSpeechSession()
        let dependencies = makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: ""),
            requestMicrophonePermission: { false }
        )
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(session.startCount, 0)
        XCTAssertEqual(controller.lastError, "未获得麦克风权限，请在系统设置中允许访问。")
    }

    func testASRFailureCancelsSessionAndPublishesError() async {
        let session = FakeSpeechSession()
        let controller = makeController(session: session, agent: FakeConversationAgent(reply: ""))

        await controller.toggleConversation()
        session.emit(.failed(.init(code: .connectionLost)))

        await waitUntil { controller.state == .failed }
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.lastError, "语音识别暂时不可用，请稍后重试。")
    }

    func testUnknownAgentFailureUsesReviewedCopyAndDoesNotLeakProviderPayload() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(error: TestFailure.agent)
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("失败问题"))
        session.emit(.finished)

        await waitUntil { controller.state == .failed }
        XCTAssertEqual(controller.messages.map(\.text), ["失败问题"])
        XCTAssertEqual(controller.lastError, "AI 回复失败：回答流程暂时中断。")
        XCTAssertFalse(controller.lastError?.contains("SENTINEL_PRIVATE_PROVIDER_PAYLOAD") == true)
    }

    func testResetCancelsSuspendedReplyAndClearsAgentContext() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("等待中的问题"))
        session.emit(.finished)
        await waitUntil { controller.state == .thinking }
        await waitUntil { agent.isWaiting }

        await controller.resetConversation()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(agent.clearCount, 1)
        XCTAssertTrue(agent.wasCancelled)
    }

    func testLegacyHandsFreeConfigurationMapsToVoiceActivatedMode() {
        let enabled = AIConversationConfiguration.valid(handsFree: true)
        let disabled = AIConversationConfiguration.valid(handsFree: false)

        XCTAssertEqual(enabled.inputMode, .voiceActivated)
        XCTAssertTrue(enabled.handsFree)
        XCTAssertEqual(disabled.inputMode, .pushToTalk)
        XCTAssertFalse(disabled.handsFree)
    }

    func testVoiceActivatedModeWithoutFactoryFailsBeforePermissionOrSpeechFactory() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "unused")
        let credentialProvider = CountingCredentialProvider()
        var permissionRequestCount = 0
        var speechFactoryCount = 0
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeSpeechSession: { _ in
                speechFactoryCount += 1
                return session
            },
            credentialProvider: credentialProvider,
            requestMicrophonePermission: {
                permissionRequestCount += 1
                return true
            }
        ))

        await controller.toggleConversation()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(
            controller.lastError,
            "本地语音检测暂不可用，请切换到手动语音输入。"
        )
        XCTAssertEqual(permissionRequestCount, 0)
        XCTAssertEqual(speechFactoryCount, 0)
        XCTAssertEqual(session.startCount, 0)
        XCTAssertTrue(agent.receivedTexts.isEmpty)
        let credentialRequestCount = await credentialProvider.requestCount
        XCTAssertEqual(credentialRequestCount, 0)
    }

    func testVoiceActivatedModeSelectsDedicatedFactoryAndProjectsArmedState() async {
        let pushToTalkSession = FakeSpeechSession()
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: pushToTalkSession,
            agent: FakeConversationAgent(reply: "unused"),
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in voiceSession }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.armed))
        await waitUntil { controller.state == .armed }

        XCTAssertEqual(voiceSession.armCount, 1)
        XCTAssertEqual(pushToTalkSession.startCount, 0)
        XCTAssertEqual(controller.conversation.inputState, .armed)
        XCTAssertEqual(controller.primaryActionTitle, "停止聆听")
        XCTAssertEqual(controller.primaryActionSystemImage, "stop.fill")
        XCTAssertEqual(controller.snapshot.controlState?.statusTitle, "本地聆听中")
    }

    func testVoiceActivatedManualStopBeforeOnsetReturnsIdleWithoutAgentRequest() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let agent = FakeConversationAgent(reply: "must not run")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.armed))
        await waitUntil { controller.state == .armed }

        await controller.toggleConversation()
        XCTAssertEqual(voiceSession.finishCount, 1)
        voiceSession.emit(.noSpeech)
        voiceSession.emit(.finished)
        await waitUntil { controller.state == .idle }

        XCTAssertTrue(agent.receivedTexts.isEmpty)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
    }

    func testVoiceActivatedNoSpeechTimeoutDisablesContinuousRun() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let agent = FakeConversationAgent(reply: "must not run")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.armed))
        await waitUntil { controller.state == .armed }
        voiceSession.emit(.noSpeech)
        await waitUntil { controller.state == .idle }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(voiceSession.finishCount, 0)
        XCTAssertTrue(agent.receivedTexts.isEmpty)
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
    }

    func testVoiceActivatedCompletionRequestsAgentExactlyOnce() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let rearmedSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, rearmedSession]
        let agent = FakeConversationAgent(reply: "回答")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.armed))
        voiceSession.emit(.phase(.speechStarted))
        voiceSession.emit(.transcript("唯一问题"))
        voiceSession.emit(.phase(.finalizing(.silence)))
        voiceSession.emit(.finished)
        voiceSession.emit(.finished)

        await waitUntil { rearmedSession.armCount == 1 }
        XCTAssertEqual(agent.receivedTexts, ["唯一问题"])
        XCTAssertEqual(voiceSession.armCount, 1)
    }

    func testContinuousVoiceActivationRearmsAcrossSuccessfulTurns() async {
        let firstSession = FakeVoiceActivatedSpeechSession()
        let secondSession = FakeVoiceActivatedSpeechSession()
        let thirdSession = FakeVoiceActivatedSpeechSession()
        var sessions = [firstSession, secondSession, thirdSession]
        let agent = FakeConversationAgent(reply: "回答")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        firstSession.emit(.phase(.speechStarted))
        firstSession.emit(.transcript("第一轮"))
        firstSession.emit(.finished)
        await waitUntil { secondSession.armCount == 1 }

        secondSession.emit(.phase(.speechStarted))
        secondSession.emit(.transcript("第二轮"))
        secondSession.emit(.finished)
        await waitUntil { thirdSession.armCount == 1 }

        XCTAssertEqual(agent.receivedTexts, ["第一轮", "第二轮"])
        XCTAssertEqual(controller.messages.filter(\.isUser).map(\.text), ["第一轮", "第二轮"])
    }

    func testVoiceActivatedManualFinishAfterOnsetWaitsForSessionFinalizingEvent() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let agent = FakeConversationAgent(reply: "回答")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in voiceSession }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        await waitUntil { controller.state == .listening }
        await controller.toggleConversation()

        XCTAssertEqual(voiceSession.finishCount, 1)
        XCTAssertEqual(controller.state, .listening)

        voiceSession.emit(.phase(.finalizing(.manual)))
        await waitUntil { controller.state == .recognizing }
        voiceSession.emit(.transcript("手动结束"))
        voiceSession.emit(.finished)
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(agent.receivedTexts, ["手动结束"])
    }

    func testBackgroundCancelsVoiceActivatedInputAndRejectsLateEvents() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let agent = FakeConversationAgent(reply: "must not run")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in voiceSession }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.armed))
        await waitUntil { controller.state == .armed }
        await controller.suspendForBackground()

        voiceSession.emit(.phase(.speechStarted))
        voiceSession.emit(.transcript("迟到问题"))
        voiceSession.emit(.finished)
        await Task.yield()

        XCTAssertEqual(voiceSession.cancelCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(agent.receivedTexts.isEmpty)
    }

    func testResetCancelsVoiceActivatedInputAndRejectsLateEvents() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let agent = FakeConversationAgent(reply: "must not run")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in voiceSession }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        await waitUntil { controller.state == .listening }
        await controller.resetConversation()

        voiceSession.emit(.transcript("重置后的迟到问题"))
        voiceSession.emit(.finished)
        await Task.yield()

        XCTAssertEqual(voiceSession.cancelCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(agent.receivedTexts.isEmpty)
    }

    func testVoiceActivatedSessionRearmsOnlyAfterReplyContextIsAccepted() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let rearmedSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, rearmedSession]
        let agent = SuspendedCommitConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        voiceSession.emit(.transcript("接受后再启动"))
        voiceSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "已接受回答")
        await waitUntil { agent.isCommitSuspended }

        XCTAssertEqual(controller.state, .streaming)
        XCTAssertEqual(rearmedSession.armCount, 0)

        agent.resolveCommitSuccessfully()
        await waitUntil { rearmedSession.armCount == 1 }
        rearmedSession.emit(.phase(.armed))
        await waitUntil { controller.state == .armed }

        XCTAssertEqual(agent.committedContext, ["接受后再启动", "已接受回答"])
    }

    func testVoiceActivatedSessionDoesNotRearmWhileTypewriterIsBehind() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let rearmedSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, rearmedSession]
        let agent = ControlledConversationAgent()
        let sleeper = ManualSleeper()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() },
            sleep: { _ in try await sleeper.sleep() },
            reduceMotion: { false }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        voiceSession.emit(.transcript("等待逐字显示"))
        voiceSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("完整"))
        agent.complete(with: "完整")
        await waitUntil { controller.assistantReply == "完" }

        XCTAssertEqual(controller.state, .streaming)
        XCTAssertEqual(rearmedSession.armCount, 0)

        sleeper.advance()
        await waitUntil { rearmedSession.armCount == 1 }
    }

    func testExplicitStopAfterSpeechDisablesAutomaticRearm() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let agent = FakeConversationAgent(reply: "回答")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        await waitUntil { controller.state == .listening }
        await controller.toggleConversation()
        voiceSession.emit(.phase(.finalizing(.manual)))
        voiceSession.emit(.transcript("显式停止"))
        voiceSession.emit(.finished)
        await waitUntil { controller.state == .completed }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(agent.receivedTexts, ["显式停止"])
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
    }

    func testVoiceActivatedFailureDisablesAutomaticRearm() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: FakeConversationAgent(reply: "unused"),
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.failed(.init(code: .voiceActivityProcessingFailed)))
        await waitUntil { controller.state == .failed }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
    }

    func testResetDuringVoiceReplyCommitRejectsStaleAutomaticRearm() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let agent = SuspendedCommitConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        voiceSession.emit(.transcript("重置前问题"))
        voiceSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "不应重启")
        await waitUntil { agent.isCommitSuspended }

        let reset = Task { await controller.resetConversation() }
        await waitUntil { !agent.aborted.isEmpty }
        agent.resolveCommitSuccessfully()
        await reset.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
    }

    func testBackgroundDuringVoiceReplyCommitRejectsStaleAutomaticRearm() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let agent = SuspendedCommitConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: agent,
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        voiceSession.emit(.phase(.speechStarted))
        voiceSession.emit(.transcript("后台前问题"))
        voiceSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "不应在后台重启")
        await waitUntil { agent.isCommitSuspended }

        let suspend = Task { await controller.suspendForBackground() }
        await waitUntil { !agent.aborted.isEmpty }
        agent.resolveCommitSuccessfully()
        await suspend.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
    }

    func testPushToTalkCompletionDoesNotStartAnotherSession() async {
        let firstSession = FakeSpeechSession()
        let unexpectedSession = FakeSpeechSession()
        var sessions = [firstSession, unexpectedSession]
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: firstSession,
            agent: FakeConversationAgent(reply: "回答"),
            configuration: { .valid(inputMode: .pushToTalk) },
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        firstSession.emit(.transcript("手动模式"))
        firstSession.emit(.finished)
        await waitUntil { controller.state == .completed }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(firstSession.startCount, 1)
        XCTAssertEqual(unexpectedSession.startCount, 0)
    }

    func testAgentFactoryReceivesSearchConfigurationSnapshot() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "回答")
        var captured: ConversationAgentConfiguration?
        let dependencies = makeDependencies(
            session: session,
            agent: agent,
            makeAgent: { configuration in
                captured = configuration
                return agent
            }
        )
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()
        session.emit(.transcript("需要搜索"))
        session.emit(.finished)
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(captured?.model, "deepseek-v4-flash")
        XCTAssertEqual(captured?.enableSearch, true)
        XCTAssertEqual(captured?.bochaAPIKey, "bocha-key")
        XCTAssertFalse(captured?.systemPrompt.isEmpty ?? true)
    }

    func testStreamingDeltasAppearInOrderAndCompleteOnlyAfterVisibleTextCatchesUp() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("流式问题"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }

        agent.emit(.contentDelta("你"))
        agent.emit(.contentDelta("好"))
        agent.emit(.contentDelta("，世界"))
        await waitUntil { controller.assistantReply == "你好，世界" }
        XCTAssertEqual(controller.state, .streaming)
        XCTAssertEqual(controller.messages.last?.status, .pending)

        agent.complete(with: "你好，世界")
        await waitUntil { controller.state == .completed }
        XCTAssertEqual(controller.messages.last?.text, "你好，世界")
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testPartialFailureKeepsVisibleTextAndDoesNotCompleteMessage() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("会失败的问题"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("已有部分"))
        await waitUntil { controller.assistantReply == "已有部分" }

        agent.fail(TestFailure.agent)
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "已有部分")
        XCTAssertEqual(controller.messages.last?.text, "已有部分")
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertTrue(controller.lastError?.hasPrefix("回答中断，请重试") == true)
    }

    func testResetRejectsLateStreamingEvents() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("旧问题"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("旧"))
        await waitUntil { controller.assistantReply == "旧" }

        await controller.resetConversation()
        let resetSnapshot = controller.snapshot
        agent.emit(.contentDelta("迟到"))
        agent.complete(with: "旧迟到")
        await Task.yield()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.snapshot, resetSnapshot)
    }

    func testIncompleteStreamAfterPartialTextPreservesPartialAndFails() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("未完整流"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("已显示"))
        await waitUntil { controller.assistantReply == "已显示" }

        agent.finishWithoutCompletion()
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "已显示")
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertTrue(controller.lastError?.contains("模型流未正常完成") == true)
    }

    func testWhitespaceOnlyCompletionFailsWithoutKeepingAssistantMessage() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("空回答"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.complete(with: "  \n")
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.messages.map(\.text), ["空回答"])
        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.lastError, "AI 回复失败：模型返回了空回答")
    }

    func testInconsistentCompletedAnswerFailsWithoutOverwritingPartialText() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("不一致流"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("前缀"))
        await waitUntil { controller.assistantReply == "前缀" }

        agent.complete(with: "不同答案")
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "前缀")
        XCTAssertEqual(controller.messages.last?.text, "前缀")
        XCTAssertTrue(controller.lastError?.contains("增量与完整回答不一致") == true)
    }

    func testMixedContentThenToolFailureDiscardsVisiblePseudoAnswer() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("混合响应"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("伪正文"))
        await waitUntil { controller.assistantReply == "伪正文" }

        agent.fail(ConversationAgentStreamError.discardPartial("混合 content/tool_call"))
        await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.messages.map(\.text), ["混合响应"])
        XCTAssertFalse(controller.scene.elements.contains { element in
            guard case .flowingText(let text, _, _) = element.content else { return false }
            return text.contains("伪正文")
        })
    }

    func testCompletionReconcilesCombiningScalarSuffixWithoutCharacterIndexing() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("组合字符"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("e"))
        await waitUntil { controller.assistantReply == "e" }

        agent.complete(with: "e\u{301}")
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(controller.assistantReply.unicodeScalars.map(\.value), [0x65, 0x301])
        XCTAssertEqual(controller.messages.last?.text.unicodeScalars.map(\.value), [0x65, 0x301])
    }

    func testWhitespaceDeltaThenFailureClearsVisibleAndDomainPartial() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("空白失败"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("  \n"))
        await waitUntil { !controller.assistantReply.isEmpty }

        agent.fail(TestFailure.agent)
        await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.messages.map(\.text), ["空白失败"])
    }

    func testWhitespaceDeltaThenEmptyCompletionClearsVisibleAndDomainPartial() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("空白完成"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta(" \n"))
        await waitUntil { !controller.assistantReply.isEmpty }

        agent.complete(with: " \n")
        await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.messages.map(\.text), ["空白完成"])
        XCTAssertTrue(controller.lastError?.contains("空回答") == true)
    }

    func testNormalMotionDoesNotCompleteUntilTypewriterCatchesUp() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let sleeper = ManualSleeper()
        let dependencies = makeDependencies(
            session: session,
            agent: agent,
            sleep: { _ in try await sleeper.sleep() },
            reduceMotion: { false }
        )
        let controller = VoiceConversationController(dependencies: dependencies)
        let answer = String(repeating: "流", count: 40)

        await controller.toggleConversation()
        session.emit(.transcript("打字机追平"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta(answer))
        agent.complete(with: answer)
        await waitUntil { !controller.assistantReply.isEmpty }

        XCTAssertEqual(controller.state, .streaming)
        XCTAssertLessThan(controller.assistantReply.count, answer.count)
        XCTAssertEqual(controller.messages.last?.status, .pending)

        for _ in 0..<(answer.count + 2) where controller.state != .completed {
            let previousVisibleCount = controller.assistantReply.count
            sleeper.advance()
            await waitUntil {
                controller.state == .completed
                    || controller.assistantReply.count > previousVisibleCount
            }
        }
        await waitUntil { controller.state == .completed }
        XCTAssertEqual(controller.assistantReply, answer)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testReduceMotionFlushesWholeDeltaWithoutTypewriterFrames() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)
        let answer = "中文👨‍👩‍👧‍👦e\u{301}\nEnglish"

        await controller.toggleConversation()
        session.emit(.transcript("减少动效"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta(answer))

        await waitUntil { controller.assistantReply == answer }
        XCTAssertEqual(controller.state, .streaming)
    }

    func testControllerUsesInjectedStreamingTextTickPolicy() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let recorder = DurationRecorder()
        let dependencies = makeDependencies(
            session: session,
            agent: agent,
            sleep: { duration in
                recorder.record(duration)
                throw CancellationError()
            },
            reduceMotion: { false },
            streamingTextPolicy: TypewriterPolicy(tickIntervalMilliseconds: 77)
        )
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()
        session.emit(.transcript("节奏策略"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("两字"))
        await waitUntil { recorder.value != nil }

        XCTAssertEqual(recorder.value, .milliseconds(77))
        XCTAssertEqual(controller.assistantReply, "两")
        XCTAssertEqual(controller.state, .streaming)
    }

    func testDefaultStreamingTextPolicyUsesComfortableReadingCadence() {
        let policy = TypewriterPolicy.comfortableReading

        XCTAssertEqual(policy.tickIntervalMilliseconds, 150)
        XCTAssertEqual(policy.shortBacklogLimit, 2_000)
        XCTAssertEqual(policy.mediumBacklogLimit, 2_000)
        XCTAssertEqual(policy.mediumBatchSize, 1)
        XCTAssertEqual(policy.minimumLargeBatchSize, 1)
    }

    func testConversationHUDUsesDedicatedLargeFlowingTextViewport() {
        let scene = ConversationHUDMapper.makeScene(
            revision: 1,
            state: .streaming,
            transcript: "问题",
            assistantReply: "回答",
            audioLevel: 0,
            error: nil
        )
        let reply = scene.elements.first { $0.id == "assistant_reply" }

        XCTAssertEqual(reply?.frame.height, 0.61)
        XCTAssertGreaterThanOrEqual(reply?.frame.height ?? 0, 0.55)
        guard let content = reply?.content,
              case .flowingText(let text, let isStreaming, let footer) = content else {
            return XCTFail("应使用 AI 专用流式文本")
        }
        XCTAssertEqual(text, "回答")
        XCTAssertTrue(isStreaming)
        XCTAssertNil(footer)
    }

    func testBackgroundSuspendsInputAndForegroundDoesNotAutoResume() async {
        let session = FakeSpeechSession()
        let controller = makeController(session: session, agent: ControlledConversationAgent())

        await controller.toggleConversation()
        XCTAssertEqual(controller.state, .listening)

        await controller.suspendForBackground()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.cancelCount, 1)

        controller.resumeFromForeground()
        await Task.yield()
        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testBackgroundDuringBlockedSpeechCredentialLeaseCannotCreateSession() async {
        let session = FakeSpeechSession()
        let credentials = SuspendedCredentialProvider()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent(),
            credentialProvider: credentials
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        await controller.suspendForBackground()
        await credentials.resolve(0)
        await start.value

        XCTAssertEqual(session.startCount, 0)
        XCTAssertEqual(controller.state, .idle)
    }

    func testResetDuringBlockedSpeechCredentialLeaseCannotCreateSession() async {
        let session = FakeSpeechSession()
        let credentials = SuspendedCredentialProvider()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent(),
            credentialProvider: credentials
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        await controller.resetConversation()
        await credentials.resolve(0)
        await start.value

        XCTAssertEqual(session.startCount, 0)
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testNewInputDuringBlockedSpeechCredentialLeaseSupersedesOldLease() async {
        let session = FakeSpeechSession()
        let credentials = SuspendedCredentialProvider()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent(),
            credentialProvider: credentials
        ))

        let first = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        let second = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 2 }
        await credentials.resolve(0)
        await credentials.resolve(1)
        await first.value
        await second.value

        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testBackgroundDuringBlockedReplyCredentialLeaseLeavesNoTurn() async {
        let session = FakeSpeechSession()
        let credentials = SuspendedCredentialProvider()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent(),
            credentialProvider: credentials
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        await credentials.resolve(0)
        await start.value
        session.emit(.transcript("不应提交"))
        session.emit(.finished)
        await waitUntilAsync { await credentials.requestCount == 2 }

        await controller.suspendForBackground()
        await credentials.resolve(1)
        await Task.yield()

        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func testResetDuringBlockedReplyCredentialLeaseLeavesNoTurn() async {
        let session = FakeSpeechSession()
        let credentials = SuspendedCredentialProvider()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent(),
            credentialProvider: credentials
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        await credentials.resolve(0)
        await start.value
        session.emit(.transcript("重置旧问题"))
        session.emit(.finished)
        await waitUntilAsync { await credentials.requestCount == 2 }

        await controller.resetConversation()
        await credentials.resolve(1)
        await Task.yield()

        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func testNewInputDuringBlockedReplyCredentialLeaseRejectsOldTurn() async {
        let firstSession = FakeSpeechSession()
        let secondSession = FakeSpeechSession()
        var sessions = [firstSession, secondSession]
        let credentials = SuspendedCredentialProvider()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: firstSession,
            agent: ControlledConversationAgent(),
            makeSpeechSession: { _ in sessions.removeFirst() },
            credentialProvider: credentials
        ))

        let firstStart = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        await credentials.resolve(0)
        await firstStart.value
        firstSession.emit(.transcript("旧问题"))
        firstSession.emit(.finished)
        await waitUntilAsync { await credentials.requestCount == 2 }

        let newInput = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 3 }
        await credentials.resolve(1)
        await credentials.resolve(2)
        await newInput.value

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(secondSession.startCount, 1)
    }

    func testRapidBackgroundForegroundAndNewInputRejectsStaleBackgroundCleanup() async {
        let firstSession = SuspendedCancelSpeechSession()
        let secondSession = FakeSpeechSession()
        var sessions: [any SpeechRecognitionSession] = [firstSession, secondSession]
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: firstSession,
            agent: ControlledConversationAgent(),
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        controller.updateHostLifecycle(.background)
        await waitUntil { firstSession.isCancelSuspended }
        controller.updateHostLifecycle(.active)
        await controller.waitForPendingHostLifecycleTransition()
        await controller.toggleConversation()
        firstSession.resolveCancel()
        await Task.yield()

        XCTAssertEqual(secondSession.startCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testRapidBackgroundForegroundStillCompletesCapturedBackgroundCleanup() async {
        let session = SuspendedCancelSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent()
        ))

        await controller.toggleConversation()
        controller.updateHostLifecycle(.background)
        await waitUntil { session.isCancelSuspended }

        controller.updateHostLifecycle(.active)
        await controller.waitForPendingHostLifecycleTransition()
        session.resolveCancel()
        await waitUntil { !session.isCancelSuspended }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testBackgroundAbortsUncommittedReplyAndRejectsLateContent() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let telemetry = RecordingTelemetry()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: agent,
            telemetry: telemetry
        ))

        await controller.toggleConversation()
        session.emit(.transcript("不应保留的本轮"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }

        await controller.suspendForBackground()
        agent.emit(.contentDelta("迟到内容"))
        await Task.yield()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertTrue(agent.wasCancelled)
        XCTAssertTrue(telemetry.events.contains {
            $0.phase == .display && $0.outcome == .suspended
        })
        XCTAssertTrue(telemetry.events.contains {
            $0.phase == .reply && $0.outcome == .suspended
        })
    }

    func testTelemetryUsesTypedPrivacySafeFieldsAndMonotonicDuration() async {
        let telemetry = RecordingTelemetry()
        var ticks: [UInt64] = [
            1_000_000_000,
            1_100_000_000,
            1_200_000_000,
            1_250_000_000,
            1_300_000_000
        ]
        let session = FakeSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: ControlledConversationAgent(),
            telemetry: telemetry,
            monotonicNow: { ticks.removeFirst() }
        ))

        await controller.toggleConversation()
        await controller.suspendForBackground()

        XCTAssertEqual(telemetry.events, [
            .init(phase: .input, outcome: .started, elapsedMilliseconds: 0),
            .init(phase: .preparation, outcome: .started, elapsedMilliseconds: 0),
            .init(phase: .preparation, outcome: .succeeded, elapsedMilliseconds: 100),
            .init(phase: .input, outcome: .suspended, elapsedMilliseconds: 250),
            .init(phase: .lifecycle, outcome: .suspended, elapsedMilliseconds: 0)
        ])
        let labels = Mirror(reflecting: telemetry.events.last!).children.compactMap(\.label)
        XCTAssertTrue(Set(labels).isDisjoint(with: ["transcript", "answer", "credential", "payload", "userID"]))
    }

    func testTelemetryRecordsOneTypedTerminalForEachFailurePath() async {
        let configurationTelemetry = RecordingTelemetry()
        let configurationController = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: ControlledConversationAgent(),
            configuration: { .missingASR },
            telemetry: configurationTelemetry
        ))
        await configurationController.toggleConversation()
        XCTAssertEqual(
            configurationTelemetry.terminals(for: .input),
            [.init(
                phase: .input,
                outcome: .failed,
                elapsedMilliseconds: 0,
                failureCode: .configurationMissing
            )]
        )

        let credentialTelemetry = RecordingTelemetry()
        let credentialController = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: ControlledConversationAgent(),
            credentialProvider: FailingCredentialProvider(),
            telemetry: credentialTelemetry
        ))
        await credentialController.toggleConversation()
        XCTAssertEqual(credentialTelemetry.terminals(for: .input).map(\.failureCode), [
            .preparationUnavailable
        ])

        let networkTelemetry = RecordingTelemetry()
        let networkSession = FakeSpeechSession()
        let networkAgent = ControlledConversationAgent()
        let networkController = VoiceConversationController(dependencies: makeDependencies(
            session: networkSession,
            agent: networkAgent,
            telemetry: networkTelemetry
        ))
        await networkController.toggleConversation()
        networkSession.emit(.transcript("网络失败"))
        networkSession.emit(.finished)
        await waitUntil { networkAgent.isWaiting }
        networkAgent.fail(ConversationAgentStreamError.failed("网络不可用", .networkUnavailable))
        await waitUntil { networkController.state == .failed }
        XCTAssertEqual(networkTelemetry.terminals(for: .reply).map(\.failureCode), [
            .networkUnavailable
        ])

        let incompleteTelemetry = RecordingTelemetry()
        let incompleteSession = FakeSpeechSession()
        let incompleteAgent = ControlledConversationAgent()
        let incompleteController = VoiceConversationController(dependencies: makeDependencies(
            session: incompleteSession,
            agent: incompleteAgent,
            telemetry: incompleteTelemetry
        ))
        await incompleteController.toggleConversation()
        incompleteSession.emit(.transcript("不完整"))
        incompleteSession.emit(.finished)
        await waitUntil { incompleteAgent.isWaiting }
        incompleteAgent.finishWithoutCompletion()
        await waitUntil { incompleteController.state == .failed }
        XCTAssertEqual(incompleteTelemetry.terminals(for: .reply).map(\.failureCode), [
            .incompleteStream
        ])
    }

    func testTypedASRFailuresRecordOneExactInputTerminal() async {
        let cases: [(SpeechRecognitionFailure.Code, ConversationFailureCode)] = [
            (.unauthorized, .unauthorized),
            (.networkUnavailable, .networkUnavailable),
            (.timeout, .timeout),
            (.connectionLost, .connectionLost),
            (.audioInterrupted, .audioInterrupted),
            (.audioUnavailable, .audioUnavailable),
            (.voiceActivityUnavailable, .audioUnavailable),
            (.voiceActivityProcessingFailed, .protocolFailure),
            (.audioCaptureOverrun, .protocolFailure),
            (.uploadBackpressureExceeded, .protocolFailure),
            (.protocolFailure, .protocolFailure),
            (.unknown, .unknown)
        ]

        for (speechCode, telemetryCode) in cases {
            let telemetry = RecordingTelemetry()
            let session = FakeSpeechSession()
            let controller = VoiceConversationController(dependencies: makeDependencies(
                session: session,
                agent: ControlledConversationAgent(),
                telemetry: telemetry
            ))

            await controller.toggleConversation()
            session.emit(.failed(.init(code: speechCode)))
            await waitUntil { controller.state == .failed }

            XCTAssertEqual(telemetry.terminals(for: .input).map(\.failureCode), [telemetryCode])
            XCTAssertEqual(controller.lastError, "语音识别暂时不可用，请稍后重试。")
        }
    }

    func testCredentialLeaseDescriptionNeverContainsSecrets() {
        let lease = ConversationCredentialLease(
            speechAPIKey: "speech-secret-value",
            llmAPIKey: "llm-secret-value",
            searchAPIKey: "search-secret-value",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertFalse(lease.description.contains("speech-secret-value"))
        XCTAssertFalse(lease.description.contains("llm-secret-value"))
        XCTAssertFalse(lease.description.contains("search-secret-value"))
        XCTAssertTrue(lease.description.contains("redacted"))
    }

    private func makeController(
        session: FakeSpeechSession,
        agent: any ConversationAgent
    ) -> VoiceConversationController {
        VoiceConversationController(dependencies: makeDependencies(session: session, agent: agent))
    }

    private func makeDependencies(
        session: any SpeechRecognitionSession,
        agent: any ConversationAgent,
        configuration: @escaping () -> AIConversationConfiguration = { .valid },
        makeSpeechSession: ((SpeechRecognitionConfiguration) -> any SpeechRecognitionSession)? = nil,
        makeVoiceActivatedSpeechSession:
            ((SpeechRecognitionConfiguration) -> any VoiceActivatedSpeechRecognitionSession)? = nil,
        makeAgent: ((ConversationAgentConfiguration) -> any ConversationAgent)? = nil,
        credentialProvider: (any ConversationCredentialProvider)? = nil,
        requestMicrophonePermission: @escaping () async -> Bool = { true },
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 100) },
        sleep: @escaping (Duration) async throws -> Void = { _ in await Task.yield() },
        reduceMotion: @escaping () -> Bool = { true },
        streamingTextPolicy: TypewriterPolicy = .comfortableReading,
        telemetry: any ConversationTelemetrySink = NoopConversationTelemetry(),
        monotonicNow: @escaping () -> UInt64 = { 0 }
    ) -> VoiceConversationDependencies {
        let contextIdentity = ConversationAgentContextIdentity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        return VoiceConversationDependencies(
            inputMode: { configuration().inputMode },
            voiceActivatedInputAvailable: {
                configuration().inputMode != .voiceActivated
                    || makeVoiceActivatedSpeechSession != nil
            },
            prepareSpeechInput: { mode in
                let current = configuration()
                let lease = try await credentialProvider?.lease() ?? .init(
                    speechAPIKey: current.speechAPIKey,
                    llmAPIKey: current.llmAPIKey,
                    searchAPIKey: current.bochaAPIKey,
                    expiresAt: .distantFuture
                )
                guard !lease.speechAPIKey.isEmpty, !current.asrResourceID.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "请先在设置中填写豆包 ASR API Key 和资源 ID。",
                        failureCode: .configurationMissing
                    )
                }
                let speechConfiguration = SpeechRecognitionConfiguration(
                    apiKey: lease.speechAPIKey,
                    resourceID: current.asrResourceID,
                    language: current.asrLanguage,
                    hotwords: current.hotwords
                )
                switch mode {
                case .pushToTalk:
                    return .pushToTalk((makeSpeechSession ?? { _ in session })(speechConfiguration))
                case .voiceActivated:
                    guard let makeVoiceActivatedSpeechSession else {
                        throw ConversationPreparationFailure(
                            userSafeMessage: Self.testPresentationCopy.voiceActivatedUnavailable,
                            failureCode: .configurationMissing
                        )
                    }
                    return .voiceActivated(makeVoiceActivatedSpeechSession(speechConfiguration))
                }
            },
            prepareAgent: {
                let current = configuration()
                let lease = try await credentialProvider?.lease() ?? .init(
                    speechAPIKey: current.speechAPIKey,
                    llmAPIKey: current.llmAPIKey,
                    searchAPIKey: current.bochaAPIKey,
                    expiresAt: .distantFuture
                )
                guard !lease.llmAPIKey.isEmpty, !current.llmModel.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "请先在设置中填写 DeepSeek API Key 和模型。",
                        failureCode: .configurationMissing
                    )
                }
                guard !current.enableSearch || !lease.searchAPIKey.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "已开启联网搜索，请先填写博查搜索 API Key。",
                        failureCode: .configurationMissing
                    )
                }
                let agentConfiguration = ConversationAgentConfiguration(
                    apiKey: lease.llmAPIKey,
                    model: current.llmModel,
                    enableSearch: current.enableSearch,
                    bochaAPIKey: lease.searchAPIKey,
                    systemPrompt: "test-system-prompt"
                )
                return PreparedConversationAgent(
                    contextIdentity: contextIdentity,
                    agent: (makeAgent ?? { _ in agent })(agentConfiguration)
                )
            },
            requestMicrophonePermission: requestMicrophonePermission,
            sleep: sleep,
            reduceMotion: reduceMotion,
            streamingTextPolicy: streamingTextPolicy,
            telemetry: telemetry,
            presentationCopy: Self.testPresentationCopy,
            monotonicNow: monotonicNow
        )
    }

    private static let testPresentationCopy = ConversationPresentationCopy(
        voiceActivatedUnavailable: "本地语音检测暂不可用，请切换到手动语音输入。",
        microphonePermissionDenied: "未获得麦克风权限，请在系统设置中允许访问。",
        speechRecognitionUnavailable: "语音识别暂时不可用，请稍后重试。",
        noSpeech: "没有识别到有效语音，请靠近手机后重试。",
        replyPreparationUnavailable: "暂时无法准备 AI 回答服务，请稍后重试。",
        emptyReply: "模型返回了空回答",
        inconsistentReplyStream: "模型流的增量与完整回答不一致",
        incompleteReplyStream: "模型流未正常完成",
        unexpectedReplyFailure: "回答流程暂时中断。",
        interruptedReplyPrefix: "回答中断，请重试：",
        failedReplyPrefix: "AI 回复失败：",
        contextCommitFailed: "回答已显示，但对话上下文保存失败，请重试。"
    )

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

    private func waitUntilAsync(
        iterations: Int = 500,
        _ predicate: () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }
}

@MainActor
private final class RecordingTelemetry: ConversationTelemetrySink {
    private(set) var events: [ConversationTelemetryEvent] = []
    func record(_ event: ConversationTelemetryEvent) { events.append(event) }

    func terminals(for phase: ConversationTelemetryPhase) -> [ConversationTelemetryEvent] {
        events.filter { $0.phase == phase && $0.outcome != .started }
    }
}

private struct AIConversationConfiguration: Equatable, Sendable {
    let speechAPIKey: String
    let asrResourceID: String
    let asrLanguage: String
    let hotwords: [String]
    let inputMode: SpeechInputMode
    let llmAPIKey: String
    let llmModel: String
    let enableSearch: Bool
    let bochaAPIKey: String

    var handsFree: Bool { inputMode == .voiceActivated }

    init(
        speechAPIKey: String,
        asrResourceID: String,
        asrLanguage: String,
        hotwords: [String],
        inputMode: SpeechInputMode,
        llmAPIKey: String,
        llmModel: String,
        enableSearch: Bool,
        bochaAPIKey: String
    ) {
        self.speechAPIKey = speechAPIKey
        self.asrResourceID = asrResourceID
        self.asrLanguage = asrLanguage
        self.hotwords = hotwords
        self.inputMode = inputMode
        self.llmAPIKey = llmAPIKey
        self.llmModel = llmModel
        self.enableSearch = enableSearch
        self.bochaAPIKey = bochaAPIKey
    }

    init(
        speechAPIKey: String,
        asrResourceID: String,
        asrLanguage: String,
        hotwords: [String],
        handsFree: Bool,
        llmAPIKey: String,
        llmModel: String,
        enableSearch: Bool,
        bochaAPIKey: String
    ) {
        self.init(
            speechAPIKey: speechAPIKey,
            asrResourceID: asrResourceID,
            asrLanguage: asrLanguage,
            hotwords: hotwords,
            inputMode: handsFree ? .voiceActivated : .pushToTalk,
            llmAPIKey: llmAPIKey,
            llmModel: llmModel,
            enableSearch: enableSearch,
            bochaAPIKey: bochaAPIKey
        )
    }
}

private struct SpeechRecognitionConfiguration: Equatable, Sendable {
    let apiKey: String
    let resourceID: String
    let language: String
    let hotwords: [String]
}

private struct ConversationAgentConfiguration: Equatable, Sendable {
    let apiKey: String
    let model: String
    let enableSearch: Bool
    let bochaAPIKey: String
    let systemPrompt: String
}

private struct ConversationCredentialLease: Equatable, Sendable, CustomStringConvertible {
    let speechAPIKey: String
    let llmAPIKey: String
    let searchAPIKey: String
    let expiresAt: Date

    var description: String {
        "ConversationCredentialLease(redacted, expiresAt: \(expiresAt.ISO8601Format()))"
    }
}

private protocol ConversationCredentialProvider: Sendable {
    func lease() async throws -> ConversationCredentialLease
}

private extension AIConversationConfiguration {
    static let valid = valid(handsFree: false)

    static func valid(inputMode: SpeechInputMode) -> Self {
        Self(
            speechAPIKey: "speech-key",
            asrResourceID: "volc.seedasr.sauc.duration",
            asrLanguage: "zh-CN",
            hotwords: ["单绿眼镜"],
            inputMode: inputMode,
            llmAPIKey: "llm-key",
            llmModel: "deepseek-v4-flash",
            enableSearch: true,
            bochaAPIKey: "bocha-key"
        )
    }

    static func valid(handsFree: Bool) -> Self {
        Self(
            speechAPIKey: "speech-key",
            asrResourceID: "volc.seedasr.sauc.duration",
            asrLanguage: "zh-CN",
            hotwords: ["单绿眼镜"],
            handsFree: handsFree,
            llmAPIKey: "llm-key",
            llmModel: "deepseek-v4-flash",
            enableSearch: true,
            bochaAPIKey: "bocha-key"
        )
    }

    static let missingASR = Self(
        speechAPIKey: "",
        asrResourceID: "volc.seedasr.sauc.duration",
        asrLanguage: "zh-CN",
        hotwords: [],
        handsFree: false,
        llmAPIKey: "llm-key",
        llmModel: "deepseek-v4-flash",
        enableSearch: false,
        bochaAPIKey: ""
    )
}

@MainActor
private final class FakeSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation

    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init() {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: SpeechRecognitionEvent) {
        continuation.yield(event)
    }

    func start() async throws { startCount += 1 }
    func finish() async { finishCount += 1 }
    func cancel() async { cancelCount += 1 }
}

@MainActor
private final class FakeVoiceActivatedSpeechSession: VoiceActivatedSpeechRecognitionSession {
    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>
    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation

    private(set) var armCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init() {
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: VoiceActivatedRecognitionEvent) {
        continuation.yield(event)
    }

    func arm() async throws { armCount += 1 }
    func finish() async { finishCount += 1 }
    func cancel() async { cancelCount += 1 }
}

@MainActor
private final class SuspendedCancelSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private(set) var isCancelSuspended = false

    init() {
        events = AsyncStream { _ in }
    }

    func start() async throws {}
    func finish() async {}

    func cancel() async {
        isCancelSuspended = true
        await withCheckedContinuation { continuation in
            cancelContinuation = continuation
        }
        isCancelSuspended = false
    }

    func resolveCancel() {
        let continuation = cancelContinuation
        cancelContinuation = nil
        continuation?.resume()
    }
}

private actor SuspendedCredentialProvider: ConversationCredentialProvider {
    private let value = ConversationCredentialLease(
        speechAPIKey: "speech-fixture",
        llmAPIKey: "llm-fixture",
        searchAPIKey: "search-fixture",
        expiresAt: .distantFuture
    )
    private var continuations: [Int: CheckedContinuation<ConversationCredentialLease, Never>] = [:]
    private var nextRequest = 0

    var requestCount: Int { nextRequest }

    func lease() async throws -> ConversationCredentialLease {
        let request = nextRequest
        nextRequest += 1
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func resolve(_ request: Int) {
        continuations.removeValue(forKey: request)?.resume(returning: value)
    }
}

private actor CountingCredentialProvider: ConversationCredentialProvider {
    private(set) var requestCount = 0

    func lease() async throws -> ConversationCredentialLease {
        requestCount += 1
        return ConversationCredentialLease(
            speechAPIKey: "unused",
            llmAPIKey: "unused",
            searchAPIKey: "unused",
            expiresAt: .distantFuture
        )
    }
}

private struct FailingCredentialProvider: ConversationCredentialProvider {
    func lease() async throws -> ConversationCredentialLease {
        throw CredentialFixtureError.unavailable
    }
}

private enum CredentialFixtureError: Error {
    case unavailable
}

@MainActor
private final class SuspendedPermissionRequest {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var isSuspended = false

    func request() async -> Bool {
        isSuspended = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ granted: Bool) {
        isSuspended = false
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor
private final class SuspendedStartSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var isStartSuspended = false
    private(set) var isResourceActive = false
    private var startContinuation: CheckedContinuation<Void, Error>?

    init() {
        self.events = AsyncStream { _ in }
    }

    func start() async throws {
        startCount += 1
        isStartSuspended = true
        do {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        } catch {
            isStartSuspended = false
            isResourceActive = true
            throw error
        }
        isStartSuspended = false
        isResourceActive = true
    }

    func finish() async {}

    func cancel() async {
        cancelCount += 1
        isResourceActive = false
    }

    func resolveStart() {
        startContinuation?.resume(returning: ())
        startContinuation = nil
    }

    func resolveStart(throwing error: Error) {
        startContinuation?.resume(throwing: error)
        startContinuation = nil
    }
}

private enum SuspendedStartError: Error {
    case failed
}

@MainActor
private final class FakeConversationAgent: ConversationAgent {
    private let reply: String
    private let error: Error?
    private(set) var receivedTexts: [String] = []
    private(set) var clearCount = 0

    init(reply: String = "", error: Error? = nil) {
        self.reply = reply
        self.error = error
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        receivedTexts.append(userText)
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for character in reply {
                continuation.yield(.contentDelta(String(character)))
            }
            continuation.yield(.completed(reply))
            continuation.finish()
        }
    }

    func clearContext() async { clearCount += 1 }
}

@MainActor
private final class ControlledConversationAgent: ConversationAgent {
    private let toolName: String?
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private(set) var clearCount = 0
    private(set) var wasCancelled = false

    var isWaiting: Bool {
        continuation != nil
    }

    init(toolName: String? = nil) {
        self.toolName = toolName
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            if toolName != nil {
                continuation.yield(.toolActivity(.externalInformationLookup))
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { @MainActor in
                    self?.wasCancelled = true
                    self?.continuation = nil
                }
            }
        }
    }

    func complete(with text: String) {
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.completed(text))
        continuation?.finish()
    }

    func emit(_ event: ConversationAgentEvent) {
        continuation?.yield(event)
    }

    func fail(_ error: Error) {
        let continuation = continuation
        self.continuation = nil
        continuation?.finish(throwing: error)
    }

    func finishWithoutCompletion() {
        let continuation = continuation
        self.continuation = nil
        continuation?.finish()
    }

    func clearContext() async { clearCount += 1 }
}

@MainActor
private final class TransactionalControlledAgent: ConversationAgent {
    let token = ConversationAgentTransactionToken()
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private(set) var committed: [ConversationAgentTransactionToken] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []

    var isWaiting: Bool { continuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        committed.append(token)
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        aborted.append(token)
    }

    func clearContext() async {}
}

@MainActor
private final class SuspendedCommitConversationAgent: ConversationAgent {
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private var commitContinuation: CheckedContinuation<Void, Error>?
    private var activeUserText = ""
    private var stagedAnswer = ""
    private var activeToken: ConversationAgentTransactionToken?

    private(set) var committedContext: [String] = []
    private(set) var contextSnapshotsAtStreamStart: [[String]] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []
    private(set) var clearCount = 0
    private(set) var isCommitSuspended = false

    var isWaiting: Bool { continuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        contextSnapshotsAtStreamStart.append(committedContext)
        activeUserText = userText
        stagedAnswer = ""
        let token = ConversationAgentTransactionToken()
        activeToken = token
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        stagedAnswer = answer
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        guard activeToken == token else { throw CommitFixtureError.failed }
        isCommitSuspended = true
        try await withCheckedThrowingContinuation { continuation in
            commitContinuation = continuation
        }
        isCommitSuspended = false
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        aborted.append(token)
    }

    func clearContext() async {
        clearCount += 1
        committedContext.removeAll()
    }

    func resolveCommitSuccessfully() {
        committedContext.append(contentsOf: [activeUserText, stagedAnswer])
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(returning: ())
    }

    func resolveCommitFailure() {
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(throwing: CommitFixtureError.failed)
    }
}

@MainActor
private final class PostCommitGateConversationAgent: ConversationAgent {
    let token = ConversationAgentTransactionToken()
    private var streamContinuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private var commitContinuation: CheckedContinuation<Void, Error>?
    private var activeUserText = ""
    private var stagedAnswer = ""

    private(set) var committedContext: [String] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []
    private(set) var isCommitAppliedButNotReturned = false

    var isWaiting: Bool { streamContinuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        activeUserText = userText
        stagedAnswer = ""
        return AsyncThrowingStream { continuation in
            streamContinuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        stagedAnswer = answer
        let continuation = streamContinuation
        streamContinuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        guard token == self.token else { throw CommitFixtureError.failed }
        committedContext.append(contentsOf: [activeUserText, stagedAnswer])
        isCommitAppliedButNotReturned = true
        try await withCheckedThrowingContinuation { continuation in
            commitContinuation = continuation
        }
        isCommitAppliedButNotReturned = false
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        guard token == self.token else { return }
        if aborted.last != token { aborted.append(token) }
        if isCommitAppliedButNotReturned {
            committedContext.removeAll()
            isCommitAppliedButNotReturned = false
            let continuation = commitContinuation
            commitContinuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }

    func clearContext() async {
        committedContext.removeAll()
    }

    func allowAcceptance() {
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(returning: ())
    }
}

private enum CommitFixtureError: Error {
    case failed
}

/// Test-only injected clock; all reads and writes are confined to the MainActor controller test.
private final class MutableTime: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private final class ManualSleeper: Sendable {
    private let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let (ticks, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.ticks = ticks
        self.continuation = continuation
    }

    func sleep() async throws {
        var iterator = ticks.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func advance() {
        continuation.yield(())
    }
}

@MainActor
private final class CancellationTrackingSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isSleeping = false
    private(set) var cancellationCount = 0

    func sleep() async throws {
        isSleeping = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                cancellationCount += 1
                isSleeping = false
                continuation?.resume()
                continuation = nil
            }
        }
        try Task.checkCancellation()
    }
}

/// Test-only recorder whose mutable value is fully protected by `lock`.
private final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Duration?

    var value: Duration? { lock.withLock { storage } }

    func record(_ duration: Duration) {
        lock.withLock { storage = duration }
    }
}

private enum TestFailure: LocalizedError {
    case agent

    var errorDescription: String? { "SENTINEL_PRIVATE_PROVIDER_PAYLOAD" }
}
