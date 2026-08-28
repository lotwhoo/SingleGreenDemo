import Foundation

struct VoiceActivatedASRMonotonicClock: Sendable {
    private let readNow: @Sendable () async -> Duration
    private let sleepUntilDeadline: @Sendable (Duration) async -> Void

    init(
        now: @escaping @Sendable () async -> Duration,
        sleepUntil: @escaping @Sendable (Duration) async -> Void
    ) {
        self.readNow = now
        self.sleepUntilDeadline = sleepUntil
    }

    func now() async -> Duration {
        await readNow()
    }

    func sleep(until deadline: Duration) async {
        await sleepUntilDeadline(deadline)
    }

    static let continuous: Self = {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(
            now: {
                origin.duration(to: clock.now)
            },
            sleepUntil: { deadline in
                try? await clock.sleep(until: origin.advanced(by: deadline))
            }
        )
    }()
}
