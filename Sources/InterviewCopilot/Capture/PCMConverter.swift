import AVFoundation
import CoreMedia

final class PCMConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func reset() { converter = nil; inputFormat = nil }

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { throw CaptureError.invalidAudio }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return [] }
        input.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard status == noErr else { throw CaptureError.invalidAudio }
        if inputFormat != format {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(count) * 16_000 / format.sampleRate)) + 64) else { throw CaptureError.invalidAudio }
        var consumed = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard result != .error, let samples = output.floatChannelData?[0] else { throw CaptureError.invalidAudio }
        let converted = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        guard converted.allSatisfy(\.isFinite) else { reset(); throw CaptureError.invalidAudio }
        return converted.map { min(1, max(-1, $0)) }
    }
}
