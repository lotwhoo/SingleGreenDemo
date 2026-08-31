import Darwin
import Foundation
import TeleprompterEvaluationSupport

private func peakResidentMemoryBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(usage.ru_maxrss, 0))
}

do {
    let report = try TeleprompterOfflineEvaluator().evaluate(
        TeleprompterSyntheticFixtureCatalog.makeScenarios(),
        memorySampler: peakResidentMemoryBytes
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("teleprompter benchmark failed\n".utf8))
    exit(EXIT_FAILURE)
}
