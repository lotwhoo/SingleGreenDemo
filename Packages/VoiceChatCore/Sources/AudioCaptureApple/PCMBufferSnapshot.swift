import AVFoundation

/// Sendable copy used to reconstruct an AVAudioPCMBuffer inside AVAudioConverter's Sendable input
/// callback. This keeps the framework object itself from crossing the callback isolation boundary.
struct PCMBufferSnapshot: Sendable {
    private struct StreamDescription: Sendable {
        let sampleRate: Double
        let formatID: UInt32
        let formatFlags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32
        let reserved: UInt32

        init(_ value: AudioStreamBasicDescription) {
            sampleRate = value.mSampleRate
            formatID = value.mFormatID
            formatFlags = value.mFormatFlags
            bytesPerPacket = value.mBytesPerPacket
            framesPerPacket = value.mFramesPerPacket
            bytesPerFrame = value.mBytesPerFrame
            channelsPerFrame = value.mChannelsPerFrame
            bitsPerChannel = value.mBitsPerChannel
            reserved = value.mReserved
        }

        func makeValue() -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: formatID,
                mFormatFlags: formatFlags,
                mBytesPerPacket: bytesPerPacket,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channelsPerFrame,
                mBitsPerChannel: bitsPerChannel,
                mReserved: reserved
            )
        }
    }

    private struct ChannelDescription: Sendable {
        let label: UInt32
        let flags: UInt32
        let coordinate0: Float32
        let coordinate1: Float32
        let coordinate2: Float32

        init(_ value: AudioChannelDescription) {
            label = value.mChannelLabel
            flags = value.mChannelFlags.rawValue
            coordinate0 = value.mCoordinates.0
            coordinate1 = value.mCoordinates.1
            coordinate2 = value.mCoordinates.2
        }

        func makeValue() -> AudioChannelDescription {
            AudioChannelDescription(
                mChannelLabel: label,
                mChannelFlags: AudioChannelFlags(rawValue: flags),
                mCoordinates: (coordinate0, coordinate1, coordinate2)
            )
        }
    }

    private struct ChannelLayout: Sendable {
        let tag: UInt32
        let bitmap: UInt32
        let descriptions: [ChannelDescription]

        init(_ value: AVAudioChannelLayout) {
            let layout = value.layout.pointee
            tag = layout.mChannelLayoutTag
            bitmap = layout.mChannelBitmap.rawValue
            let descriptionCount = Int(layout.mNumberChannelDescriptions)
            let descriptionOffset = MemoryLayout<AudioChannelLayout>.offset(
                of: \.mChannelDescriptions
            )!
            let descriptionPointer = UnsafeRawPointer(value.layout)
                .advanced(by: descriptionOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            descriptions = (0..<descriptionCount).map { ChannelDescription(descriptionPointer[$0]) }
        }

        func makeValue() -> AVAudioChannelLayout? {
            let descriptionOffset = MemoryLayout<AudioChannelLayout>.offset(
                of: \.mChannelDescriptions
            )!
            let byteCount = descriptionOffset
                + max(descriptions.count, 1) * MemoryLayout<AudioChannelDescription>.stride
            let rawLayout = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: MemoryLayout<AudioChannelLayout>.alignment
            )
            defer { rawLayout.deallocate() }
            rawLayout.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

            let layoutPointer = rawLayout.assumingMemoryBound(to: AudioChannelLayout.self)
            layoutPointer.pointee.mChannelLayoutTag = tag
            layoutPointer.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: bitmap)
            layoutPointer.pointee.mNumberChannelDescriptions = UInt32(descriptions.count)
            let descriptionPointer = rawLayout
                .advanced(by: descriptionOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            for (index, description) in descriptions.enumerated() {
                descriptionPointer[index] = description.makeValue()
            }
            return AVAudioChannelLayout(layout: layoutPointer)
        }
    }

    private struct BufferBytes: Sendable {
        let channelCount: UInt32
        let data: Data
    }

    private let streamDescription: StreamDescription
    private let channelLayout: ChannelLayout?
    let frameLength: AVAudioFrameCount
    private let audioBuffers: [BufferBytes]

    init?(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength <= buffer.frameCapacity else { return nil }
        streamDescription = StreamDescription(buffer.format.streamDescription.pointee)
        channelLayout = buffer.format.channelLayout.map(ChannelLayout.init)
        frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var copiedBuffers: [BufferBytes] = []
        copiedBuffers.reserveCapacity(sourceBuffers.count)
        for source in sourceBuffers {
            let byteCount = Int(source.mDataByteSize)
            guard byteCount == 0 || source.mData != nil else { return nil }
            let bytes = source.mData.map { Data(bytes: $0, count: byteCount) } ?? Data()
            copiedBuffers.append(BufferBytes(channelCount: source.mNumberChannels, data: bytes))
        }
        audioBuffers = copiedBuffers
    }

    func makeBuffer() -> AVAudioPCMBuffer? {
        var sourceDescription = streamDescription.makeValue()
        guard let format = AVAudioFormat(
                streamDescription: &sourceDescription,
                channelLayout: channelLayout?.makeValue()
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        buffer.frameLength = frameLength
        let destinations = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destinations.count == audioBuffers.count else { return nil }

        for index in destinations.indices {
            let source = audioBuffers[index]
            let destination = destinations[index]
            guard destination.mNumberChannels == source.channelCount,
                  Int(destination.mDataByteSize) >= source.data.count,
                  source.data.isEmpty || destination.mData != nil else { return nil }
            if let destinationData = destination.mData {
                source.data.copyBytes(
                    to: destinationData.assumingMemoryBound(to: UInt8.self),
                    count: source.data.count
                )
            }
            destinations[index].mDataByteSize = UInt32(source.data.count)
        }
        return buffer
    }
}
