public struct VADPCMFrame: Equatable, Sendable {
    public static let sampleRateHertz = 16_000
    public static let channelCount = 1
    public static let durationMilliseconds = 20
    public static let sampleCount = 320
    public static let byteCount = 640

    public let sequence: UInt64
    public let littleEndianBytes: [UInt8]

    public init(sequence: UInt64, littleEndianBytes: [UInt8]) throws {
        guard littleEndianBytes.count == Self.byteCount else {
            throw VADPCMFrameError.invalidByteCount(
                expected: Self.byteCount,
                actual: littleEndianBytes.count
            )
        }
        self.sequence = sequence
        self.littleEndianBytes = littleEndianBytes
    }

    public init(sequence: UInt64, samples: [Int16]) throws {
        guard samples.count == Self.sampleCount else {
            throw VADPCMFrameError.invalidSampleCount(
                expected: Self.sampleCount,
                actual: samples.count
            )
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }

        self.sequence = sequence
        self.littleEndianBytes = bytes
    }

    public var samples: [Int16] {
        stride(from: 0, to: littleEndianBytes.count, by: 2).map { index in
            let low = UInt16(littleEndianBytes[index])
            let high = UInt16(littleEndianBytes[index + 1]) << 8
            return Int16(bitPattern: low | high)
        }
    }
}

public enum VADPCMFrameError: Error, Equatable, Sendable {
    case invalidByteCount(expected: Int, actual: Int)
    case invalidSampleCount(expected: Int, actual: Int)
}
