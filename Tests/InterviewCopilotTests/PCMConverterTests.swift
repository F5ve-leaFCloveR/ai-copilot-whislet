import AVFoundation
import CoreMedia
import Testing
@testable import InterviewCopilot

private enum PCMInput: String, CaseIterable, Sendable {
    case float32Mono48k, float64Stereo44k, int16Stereo48k, int32Mono32k
    var rate: Double {
        switch self { case .float32Mono48k, .int16Stereo48k: 48_000; case .float64Stereo44k: 44_100; case .int32Mono32k: 32_000 }
    }
    var commonFormat: AVAudioCommonFormat {
        switch self { case .float32Mono48k: .pcmFormatFloat32; case .float64Stereo44k: .pcmFormatFloat64; case .int16Stereo48k: .pcmFormatInt16; case .int32Mono32k: .pcmFormatInt32 }
    }
    var channels: AVAudioChannelCount { self == .float64Stereo44k || self == .int16Stereo48k ? 2 : 1 }
    var interleaved: Bool { self == .int16Stereo48k }
}

private func audioBuffer(_ kind: PCMInput, frames: Int? = nil, value: (Int, Int) -> Double) throws -> CMSampleBuffer {
    let count = frames ?? Int(kind.rate / 10)
    let format = try #require(AVAudioFormat(commonFormat: kind.commonFormat, sampleRate: kind.rate, channels: kind.channels, interleaved: kind.interleaved))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
    pcm.frameLength = AVAudioFrameCount(count)
    let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for channel in 0..<Int(kind.channels) {
        let destination = try #require(buffers[kind.interleaved ? 0 : channel].mData)
        for frame in 0..<count {
            let index = kind.interleaved ? frame * Int(kind.channels) + channel : frame
            let sample = value(frame, channel)
            switch kind.commonFormat {
            case .pcmFormatFloat32: destination.assumingMemoryBound(to: Float.self)[index] = Float(sample)
            case .pcmFormatFloat64: destination.assumingMemoryBound(to: Double.self)[index] = sample
            case .pcmFormatInt16: destination.assumingMemoryBound(to: Int16.self)[index] = Int16(sample * Double(Int16.max))
            case .pcmFormatInt32: destination.assumingMemoryBound(to: Int32.self)[index] = Int32(sample * Double(Int32.max))
            default: Issue.record("Неподдержанный формат fixture")
            }
        }
    }
    var description: CMAudioFormatDescription?
    let descriptionStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    #expect(descriptionStatus == noErr)
    let audioDescription = try #require(description)
    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(kind.rate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    let creationStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: audioDescription, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
    #expect(creationStatus == noErr)
    let result = try #require(sampleBuffer)
    let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
    #expect(copyStatus == noErr)
    #expect(CMSampleBufferSetDataReady(result) == noErr)
    return result
}

@Suite struct PCMConverterTests {
    @Test(arguments: PCMInput.allCases)
    fileprivate func outputFitsASRFloatContract(_ kind: PCMInput) throws {
        let buffer = try audioBuffer(kind) { frame, _ in (frame / Int(kind.rate / 2_000)) % 2 == 0 ? 0.99 : -0.99 }
        let samples = try PCMConverter().convert(buffer)
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.isFinite })
        let maximum = samples.map { abs($0) }.max() ?? 0
        #expect(maximum <= 1, "\(kind.rawValue): abs max = \(maximum)")
    }

    @Test func twoAudioSourcesKeepIndependentResamplingState() throws {
        let voice = try audioBuffer(.float32Mono48k) { frame, _ in 0.8 * sin(Double(frame) * 2 * .pi * 370 / 48_000) }
        let square = try audioBuffer(.float32Mono48k) { frame, _ in (frame / 24) % 2 == 0 ? 0.99 : -0.99 }
        let expected = try PCMConverter().convert(voice)
        let system = PCMConverter(); let microphone = PCMConverter()
        _ = try system.convert(square)
        let actual = try microphone.convert(voice)
        #expect(actual.count == expected.count)
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 })
        let silence = try audioBuffer(.float32Mono48k) { _, _ in 0 }
        let systemTail = try system.convert(silence)
        #expect(systemTail.contains { abs($0) > 0.001 })
        microphone.reset()
        let microphoneSilence = try microphone.convert(silence)
        #expect(microphoneSilence.allSatisfy { abs($0) < 0.000001 })
    }

    @Test func formatChangeAndResetDiscardOldAudioTail() throws {
        let converter = PCMConverter()
        let square = try audioBuffer(.float32Mono48k) { frame, _ in (frame / 24) % 2 == 0 ? 0.99 : -0.99 }
        _ = try converter.convert(square)
        let changedSilence = try audioBuffer(.int32Mono32k) { _, _ in 0 }
        let changed = try converter.convert(changedSilence)
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy { abs($0) < 0.000001 })
        _ = try converter.convert(square)
        converter.reset()
        let reset = try converter.convert(try audioBuffer(.float32Mono48k) { _, _ in 0 })
        #expect(!reset.isEmpty)
        #expect(reset.allSatisfy { abs($0) < 0.000001 })
    }

    @Test func nonFiniteInputNeverReachesASR() throws {
        let buffer = try audioBuffer(.float32Mono48k) { frame, _ in frame == 100 ? .nan : frame == 200 ? .infinity : 0.1 }
        do {
            let samples = try PCMConverter().convert(buffer)
            #expect(samples.allSatisfy { $0.isFinite })
            #expect(samples.allSatisfy { abs($0) <= 1 })
        } catch {
            #expect(error is CaptureError)
        }
    }
}
