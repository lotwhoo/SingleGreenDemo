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

    func testConcurrentShutdownJoinsOneInputCleanupAndRejectsLateASREventsAndCommands() async {
        let session = SuspendedCancelSpeechSession()
        let agent = FakeConversationAgent(reply: "unused")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: agent
        ))

        await controller.toggleConversation()
        XCTAssertEqual(controller.state, .listening)

        let revisionBeforeShutdown = controller.revision
        var shutdownSnapshots: [ExperienceSnapshot] = []
        let snapshotCancellable = controller.$snapshot.dropFirst().sink {
            shutdownSnapshots.append($0)
        }
        var firstCompleted = false
        var secondCompleted = false
        let first = Task {
            await controller.shutdown()
            firstCompleted = true
        }
        await waitUntil { session.isCancelSuspended }
        let terminalSnapshot = controller.snapshot
        let second = Task {
            await controller.shutdown()
            secondCompleted = true
        }

        session.emit(.transcript("late transcript"))
        session.emit(.level(1))
        session.emit(.failed(.init(code: .connectionLost)))
        session.emit(.finished)
        await controller.toggleConversation()
        await controller.resetConversation()
        await controller.suspendForBackground()
        controller.resumeFromForeground()
        await controller.waitForPendingHostLifecycleTransition()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(session.startCount, 1)
        XCTAssertFalse(firstCompleted)
        XCTAssertFalse(secondCompleted)
        XCTAssertEqual(controller.revision, revisionBeforeShutdown + 1)
        XCTAssertEqual(controller.conversation.inputState, .idle)
        XCTAssertNil(controller.conversation.activeReplyID)
        XCTAssertEqual(controller.liveText, "")
        XCTAssertEqual(controller.audioLevel, 0)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(shutdownSnapshots, [terminalSnapshot])
        XCTAssertEqual(controller.snapshot, terminalSnapshot)

        session.resolveCancel()
        await first.value
        await second.value

        XCTAssertTrue(firstCompleted)
        XCTAssertTrue(secondCompleted)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.snapshot, terminalSnapshot)
        withExtendedLifetime(snapshotCancellable) {}
    }

    func testConcurrentShutdownJoinsBackgroundCancellationAlreadyInFlightExactlyOnce() async {
        let completedSession = FakeSpeechSession()
        let cancellingSession = SuspendedCancelSpeechSession()
        var sessions: [any SpeechRecognitionSession] = [completedSession, cancellingSession]
        let agent = FakeConversationAgent(reply: "completed context")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: completedSession,
            agent: agent,
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        completedSession.emit(.transcript("retained turn"))
        completedSession.emit(.finished)
        await waitUntil { controller.state == .completed }
        await controller.toggleConversation()
        XCTAssertEqual(cancellingSession.startCount, 1)

        controller.updateHostLifecycle(.background)
        await waitUntil { cancellingSession.isCancelSuspended }
        controller.resumeFromForeground()
        for _ in 0..<20 { await Task.yield() }

        var firstCompleted = false
        var secondCompleted = false
        let first = Task {
            await controller.shutdown()
            firstCompleted = true
        }
        let second = Task {
            await controller.shutdown()
            secondCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(cancellingSession.cancelCount, 1)
        XCTAssertFalse(cancellingSession.observedCancellation)
        XCTAssertEqual(agent.clearCount, 0)
        XCTAssertFalse(firstCompleted)
        XCTAssertFalse(secondCompleted)

        cancellingSession.resolveCancel()
        await first.value
        await second.value

        XCTAssertTrue(firstCompleted)
        XCTAssertTrue(secondCompleted)
        XCTAssertEqual(cancellingSession.cancelCount, 1)
        XCTAssertFalse(cancellingSession.observedCancellation)
        XCTAssertEqual(agent.clearCount, 1)
    }

    func testShutdownJoinsDirectBackgroundSuspensionWithoutCancellingReservedCleanup() async {
        let completedSession = FakeSpeechSession()
        let session = SuspendedCancelSpeechSession()
        var sessions: [any SpeechRecognitionSession] = [completedSession, session]
        let agent = FakeConversationAgent(reply: "completed context")
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: completedSession,
            agent: agent,
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        completedSession.emit(.transcript("retained turn"))
        completedSession.emit(.finished)
        await waitUntil { controller.state == .completed }
        await controller.toggleConversation()
        var suspendCompleted = false
        let suspend = Task {
            await controller.suspendForBackground()
            suspendCompleted = true
        }
        await waitUntil { session.isCancelSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(suspendCompleted)
        XCTAssertFalse(shutdownCompleted)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertFalse(session.observedCancellation)
        XCTAssertEqual(agent.clearCount, 0)

        session.resolveCancel()
        await suspend.value
        await shutdown.value

        XCTAssertTrue(suspendCompleted)
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertFalse(session.observedCancellation)
        XCTAssertEqual(agent.clearCount, 1)
    }

    func testSuspendedBackgroundCleanupDoesNotRetainController() async {
        let session = SuspendedCancelSpeechSession()
        var controller: VoiceConversationController? = VoiceConversationController(
            dependencies: makeDependencies(
                session: session,
                agent: FakeConversationAgent(reply: "unused")
            )
        )

        await controller?.toggleConversation()
        controller?.updateHostLifecycle(.background)
        await waitUntil { session.isCancelSuspended }
        weak let weakController = controller

        controller = nil

        await waitUntil { weakController == nil }
        XCTAssertFalse(session.observedCancellation)

        session.resolveCancel()
    }

    func testShutdownJoinsSuspendedPushToTalkStartAndLeavesResourceInactive() async {
        let session = SuspendedStartSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "unused")
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntil { session.isStartSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(shutdownCompleted)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertFalse(session.isResourceActive)

        session.resolveStart()
        await start.value
        await shutdown.value

        XCTAssertTrue(shutdownCompleted)
        XCTAssertGreaterThanOrEqual(session.cancelCount, 2)
        XCTAssertFalse(session.isStartSuspended)
        XCTAssertFalse(session.isResourceActive)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownJoinsSuspendedPermissionBeforeReturning() async {
        let permission = SuspendedPermissionRequest()
        let session = FakeSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "unused"),
            requestMicrophonePermission: { await permission.request() }
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntil { permission.isSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(shutdownCompleted)
        XCTAssertEqual(session.cancelCount, 1)

        permission.resolve(true)
        await start.value
        await shutdown.value

        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(session.startCount, 0)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownJoinsSuspendedAutomaticVoiceRearmAndLeavesResourceInactive() async {
        let firstSession = FakeVoiceActivatedSpeechSession()
        let rearmedSession = SuspendedArmVoiceActivatedSpeechSession()
        var sessions: [any VoiceActivatedSpeechRecognitionSession] = [
            firstSession,
            rearmedSession
        ]
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: FakeSpeechSession(),
            agent: FakeConversationAgent(reply: "completed answer"),
            configuration: { .valid(inputMode: .voiceActivated) },
            makeVoiceActivatedSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        firstSession.emit(.phase(.speechStarted))
        firstSession.emit(.transcript("automatic rearm"))
        firstSession.emit(.finished)
        await waitUntil { rearmedSession.isArmSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(shutdownCompleted)
        XCTAssertEqual(rearmedSession.cancelCount, 1)
        XCTAssertFalse(rearmedSession.isResourceActive)

        rearmedSession.resolveArm()
        await shutdown.value

        XCTAssertTrue(shutdownCompleted)
        XCTAssertGreaterThanOrEqual(rearmedSession.cancelCount, 2)
        XCTAssertFalse(rearmedSession.isArmSuspended)
        XCTAssertFalse(rearmedSession.isResourceActive)
        XCTAssertEqual(controller.state, .completed)
    }

    func testShutdownJoinsResetAlreadySuspendedInSessionCancellation() async {
        let session = SuspendedCancelSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "unused")
        ))

        await controller.toggleConversation()
        var resetCompleted = false
        let reset = Task {
            await controller.resetConversation()
            resetCompleted = true
        }
        await waitUntil { session.isCancelSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(resetCompleted)
        XCTAssertFalse(shutdownCompleted)
        XCTAssertFalse(session.observedCancellation)

        session.resolveCancel()
        await reset.value
        await shutdown.value

        XCTAssertTrue(resetCompleted)
        XCTAssertTrue(shutdownCompleted)
        XCTAssertFalse(session.observedCancellation)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownJoinsResetOwnedSuspendedAgentAbort() async {
        let session = FakeSpeechSession()
        let agent = SuspendedAbortConversationAgent()
        let sleeper = ManualSleeper()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: agent,
            sleep: { _ in try await sleeper.sleep() },
            reduceMotion: { false }
        ))

        await controller.toggleConversation()
        session.emit(.transcript("pending transaction"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "display catch-up")
        await waitUntil { controller.state == .streaming && !controller.assistantReply.isEmpty }

        var resetCompleted = false
        let reset = Task {
            await controller.resetConversation()
            resetCompleted = true
        }
        await waitUntil { agent.isAbortSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(resetCompleted)
        XCTAssertFalse(shutdownCompleted)

        agent.resolveAbort()
        await reset.value
        await shutdown.value

        XCTAssertTrue(resetCompleted)
        XCTAssertTrue(shutdownCompleted)
        XCTAssertFalse(agent.isAbortSuspended)
        XCTAssertGreaterThanOrEqual(agent.clearCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownJoinsResetOwnedSuspendedAgentClearContext() async {
        let session = FakeSpeechSession()
        let agent = FirstClearSuspendedConversationAgent(reply: "committed reply")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("committed question"))
        session.emit(.finished)
        await waitUntil { controller.state == .completed }

        var resetCompleted = false
        let reset = Task {
            await controller.resetConversation()
            resetCompleted = true
        }
        await waitUntil { agent.isFirstClearSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(resetCompleted)
        XCTAssertFalse(shutdownCompleted)
        XCTAssertGreaterThanOrEqual(agent.clearCount, 1)

        agent.resolveFirstClear()
        await reset.value
        await shutdown.value

        XCTAssertTrue(resetCompleted)
        XCTAssertTrue(shutdownCompleted)
        XCTAssertFalse(agent.isFirstClearSuspended)
        XCTAssertEqual(controller.state, .completed)
    }

    func testShutdownJoinsToggleStopAlreadySuspendedInFinish() async {
        let session = SuspendedFinishSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "unused")
        ))

        await controller.toggleConversation()
        var stopCompleted = false
        let stop = Task {
            await controller.toggleConversation()
            stopCompleted = true
        }
        await waitUntil { session.isFinishSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(stopCompleted)
        XCTAssertFalse(shutdownCompleted)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertFalse(session.isResourceActive)

        session.resolveFinish()
        await stop.value
        await shutdown.value

        XCTAssertTrue(stopCompleted)
        XCTAssertTrue(shutdownCompleted)
        XCTAssertGreaterThanOrEqual(session.cancelCount, 2)
        XCTAssertFalse(session.isResourceActive)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownDrainsFailureOwnedCoordinatorCleanupWithoutSelfAwait() async {
        let session = SuspendedCancelSpeechSession()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: FakeConversationAgent(reply: "unused")
        ))

        await controller.toggleConversation()
        session.emit(.failed(.init(code: .connectionLost)))
        await waitUntil { session.isCancelSuspended }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(shutdownCompleted)
        XCTAssertFalse(session.observedCancellation)

        session.resolveCancel()
        await shutdown.value

        XCTAssertTrue(shutdownCompleted)
        XCTAssertFalse(session.observedCancellation)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownJoinsRetiredInputEventTaskBlockedInReplyPreparation() async {
        let session = FakeSpeechSession()
        let credentials = SuspendedCredentialProvider()
        let agent = ControlledConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: session,
            agent: agent,
            credentialProvider: credentials
        ))

        let start = Task { await controller.toggleConversation() }
        await waitUntilAsync { await credentials.requestCount == 1 }
        await credentials.resolve(0)
        await start.value
        session.emit(.transcript("blocked reply preparation"))
        session.emit(.finished)
        await waitUntilAsync { await credentials.requestCount == 2 }

        var shutdownCompleted = false
        let shutdown = Task {
            await controller.shutdown()
            shutdownCompleted = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(shutdownCompleted)

        await credentials.resolve(1)
        await shutdown.value

        XCTAssertTrue(shutdownCompleted)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertFalse(agent.isWaiting)
        XCTAssertEqual(controller.state, .idle)
    }

    func testShutdownAbortsPendingReplyAndRejectsLateTypewriterWorkWithoutRearm() async {
        let voiceSession = FakeVoiceActivatedSpeechSession()
        let unexpectedRearmSession = FakeVoiceActivatedSpeechSession()
        var sessions = [voiceSession, unexpectedRearmSession]
        let agent = TransactionalControlledAgent()
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
        voiceSession.emit(.transcript("shutdown reply"))
        voiceSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "late typewriter content")
        await waitUntil { controller.state == .streaming && !controller.assistantReply.isEmpty }

        let revisionBeforeShutdown = controller.revision
        var shutdownSnapshots: [ExperienceSnapshot] = []
        let snapshotCancellable = controller.$snapshot.dropFirst().sink {
            shutdownSnapshots.append($0)
        }
        await controller.shutdown()
        let terminalSnapshot = controller.snapshot
        sleeper.advance()
        await controller.toggleConversation()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(agent.committed, [])
        XCTAssertEqual(agent.aborted, [agent.token])
        XCTAssertEqual(agent.clearCount, 1)
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertNil(controller.conversation.activeReplyID)
        XCTAssertEqual(controller.conversation.inputState, .idle)
        XCTAssertEqual(controller.revision, revisionBeforeShutdown + 1)
        XCTAssertEqual(shutdownSnapshots, [terminalSnapshot])
        XCTAssertEqual(controller.snapshot, terminalSnapshot)
        withExtendedLifetime(snapshotCancellable) {}
    }

    func testShutdownAbortsRequestingTurnAndPublishesOneCoherentTerminalSnapshot() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("pending request"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting && controller.state == .thinking }

        let revisionBeforeShutdown = controller.revision
        var shutdownSnapshots: [ExperienceSnapshot] = []
        let snapshotCancellable = controller.$snapshot.dropFirst().sink {
            shutdownSnapshots.append($0)
        }
        await controller.shutdown()
        let terminalSnapshot = controller.snapshot

        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertNil(controller.conversation.activeReplyID)
        XCTAssertEqual(controller.conversation.inputState, .idle)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.liveText, "")
        XCTAssertEqual(controller.audioLevel, 0)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.revision, revisionBeforeShutdown + 1)
        XCTAssertEqual(shutdownSnapshots, [terminalSnapshot])
        withExtendedLifetime(snapshotCancellable) {}
    }

    func testShutdownAbortsStreamingTurnAndRejectsLateStreamEvents() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("streaming request"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("visible partial"))
        await waitUntil { controller.state == .streaming }

        let revisionBeforeShutdown = controller.revision
        var shutdownSnapshots: [ExperienceSnapshot] = []
        let snapshotCancellable = controller.$snapshot.dropFirst().sink {
            shutdownSnapshots.append($0)
        }
        await controller.shutdown()
        let terminalSnapshot = controller.snapshot

        agent.emit(.contentDelta("late content"))
        agent.complete(with: "late completion")
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertNil(controller.conversation.activeReplyID)
        XCTAssertEqual(controller.conversation.inputState, .idle)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.revision, revisionBeforeShutdown + 1)
        XCTAssertEqual(shutdownSnapshots, [terminalSnapshot])
        XCTAssertEqual(controller.snapshot, terminalSnapshot)
        withExtendedLifetime(snapshotCancellable) {}
    }

    func testShutdownPreservesCommittedHistoryWhileRemovingNewPendingTurn() async {
        let firstSession = FakeSpeechSession()
        let secondSession = FakeSpeechSession()
        var sessions: [any SpeechRecognitionSession] = [firstSession, secondSession]
        let agent = ControlledConversationAgent()
        let controller = VoiceConversationController(dependencies: makeDependencies(
            session: firstSession,
            agent: agent,
            makeSpeechSession: { _ in sessions.removeFirst() }
        ))

        await controller.toggleConversation()
        firstSession.emit(.transcript("committed question"))
        firstSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.complete(with: "committed answer")
        await waitUntil { controller.state == .completed }
        let committedMessages = controller.messages

        await controller.toggleConversation()
        secondSession.emit(.transcript("pending question"))
        secondSession.emit(.finished)
        await waitUntil { agent.isWaiting && controller.state == .thinking }

        let revisionBeforeShutdown = controller.revision
        var shutdownSnapshots: [ExperienceSnapshot] = []
        let snapshotCancellable = controller.$snapshot.dropFirst().sink {
            shutdownSnapshots.append($0)
        }
        await controller.shutdown()
        let terminalSnapshot = controller.snapshot

        XCTAssertEqual(controller.messages, committedMessages)
        XCTAssertNil(controller.conversation.activeReplyID)
        XCTAssertEqual(controller.conversation.inputState, .idle)
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.transcript, "committed question")
        XCTAssertEqual(controller.assistantReply, "committed answer")
        XCTAssertEqual(controller.revision, revisionBeforeShutdown + 1)
        XCTAssertEqual(shutdownSnapshots, [terminalSnapshot])
        withExtendedLifetime(snapshotCancellable) {}
    }

    func testShutdownDuringContextCommitRollsBackAndNeverRestartsVoiceInput() async {
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
        voiceSession.emit(.transcript("shutdown during commit"))
        voiceSession.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.finalize(with: "must roll back")
        await waitUntil { agent.isCommitSuspended }

        let shutdown = Task { await controller.shutdown() }
        await waitUntil { !agent.aborted.isEmpty }
        let terminalSnapshot = controller.snapshot
        agent.resolveCommitSuccessfully()
        await shutdown.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(agent.aborted.isEmpty)
        XCTAssertEqual(agent.clearCount, 1)
        XCTAssertEqual(unexpectedRearmSession.armCount, 0)
        XCTAssertEqual(controller.snapshot, terminalSnapshot)
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

}
