@preconcurrency import AVFoundation
import Foundation

public enum PCMInt16WAV {
    public static let transcriptionSampleRate = 16_000.0

    public static func settings(
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
    }
}

@MainActor
public final class AVCaptureMicrophoneAuthorizer: MicrophoneAuthorizing {
    public init() {}

    public func currentAuthorization() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }

    public func requestAuthorization() async -> MicrophoneAuthorization {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return currentAuthorization()
    }
}

@MainActor
public final class AVAudioEngineRecorder: AudioRecordingManaging {
    nonisolated(unsafe) private let engine: AVAudioEngine
    private var session: AudioTapSession?
    private var tapInstalled = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public func start(
        at url: URL,
        onUpdate: @escaping @Sendable (RecordingSnapshot) -> Void,
        onPartialRecording: @escaping @Sendable (AudioRecording) -> Void
    ) throws {
        guard session == nil else { throw AudioRecorderError.alreadyRecording }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioRecorderError.noInputDevice
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let session: AudioTapSession
        do {
            session = try AudioTapSession(
                url: url,
                inputFormat: inputFormat,
                onUpdate: onUpdate,
                onPartialRecording: onPartialRecording
            )
        } catch {
            throw AudioRecorderError.unableToStart(error.localizedDescription)
        }
        self.session = session

        let tapCallback = Self.makeRealtimeTapCallback { [session] buffer in
            session.consume(buffer)
        }
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat,
            block: tapCallback
        )
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            self.session = nil
            engine.reset()
            throw AudioRecorderError.unableToStart(error.localizedDescription)
        }
    }

    public func stop() throws -> AudioRecording {
        guard let session else { throw AudioRecorderError.notRecording }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        self.session = nil
        return try session.finish()
    }

    nonisolated static func makeRealtimeTapCallback(
        forwarding consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            consume(buffer)
        }
    }

    isolated deinit {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }
}

private final class AudioTapSession: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let onUpdate: @Sendable (RecordingSnapshot) -> Void
    private let onPartialRecording: @Sendable (AudioRecording) -> Void
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var frames: AVAudioFramePosition = 0
    private var partialFile: AVAudioFile?
    private var partialURL: URL?
    private var partialFrames: AVAudioFramePosition = 0
    private var partialIndex = 0
    private var failure: AudioRecorderError?
    private var finished = false

    init(
        url: URL,
        inputFormat: AVAudioFormat,
        onUpdate: @escaping @Sendable (RecordingSnapshot) -> Void,
        onPartialRecording: @escaping @Sendable (AudioRecording) -> Void
    ) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: PCMInt16WAV.transcriptionSampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.invalidInputFormat
        }
        self.url = url
        self.file = try AVAudioFile(
            forWriting: url,
            settings: PCMInt16WAV.settings(
                sampleRate: PCMInt16WAV.transcriptionSampleRate,
                channelCount: inputFormat.channelCount
            ),
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        self.converter = converter
        self.onUpdate = onUpdate
        self.onPartialRecording = onPartialRecording
        startPartialFile()
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finished, failure == nil else { return }
            do {
                let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
                let capacity = max(
                    1,
                    AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
                )
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat,
                    frameCapacity: capacity
                ) else {
                    throw AudioRecorderError.writeFailed("Could not allocate an audio buffer.")
                }

                let input = ConverterInput(buffer)
                var conversionError: NSError?
                let status = converter.convert(
                    to: output,
                    error: &conversionError
                ) { _, inputStatus in
                    input.next(status: inputStatus)
                }
                if let conversionError {
                    throw AudioRecorderError.writeFailed(conversionError.localizedDescription)
                }
                guard status != .error else {
                    throw AudioRecorderError.writeFailed("Audio conversion failed.")
                }
                if output.frameLength > 0 {
                    try file.write(from: output)
                    frames += AVAudioFramePosition(output.frameLength)
                    writePartial(output)
                }
                onUpdate(
                    RecordingSnapshot(
                        elapsedSeconds: max(
                            0,
                            ProcessInfo.processInfo.systemUptime - startedAt
                        ),
                        rmsLevel: Self.rmsLevel(of: buffer)
                    )
                )
            } catch let recorderError as AudioRecorderError {
                failure = recorderError
            } catch {
                failure = .writeFailed(error.localizedDescription)
            }
        }
    }

    func finish() throws -> AudioRecording {
        try lock.withLock {
            finished = true
            completePartialFile()
            let duration = converter.outputFormat.sampleRate > 0
                ? Double(frames) / converter.outputFormat.sampleRate
                : 0
            let recording = AudioRecording(
                fileURL: url,
                frameCount: frames,
                durationSeconds: duration
            )
            if let failure {
                throw AudioRecordingStopFailure(
                    error: failure,
                    partialRecording: frames > 0 ? recording : nil
                )
            }
            return recording
        }
    }

    private func writePartial(_ buffer: AVAudioPCMBuffer) {
        guard let partialFile else { return }
        do {
            try partialFile.write(from: buffer)
            partialFrames += AVAudioFramePosition(buffer.frameLength)
            if partialFrames >= Self.partialSegmentFrames {
                completePartialFile()
                startPartialFile()
            }
        } catch {
            self.partialFile = nil
            partialURL = nil
            partialFrames = 0
        }
    }

    private func startPartialFile() {
        partialIndex += 1
        let filename = "\(url.deletingPathExtension().lastPathComponent)-partial-\(partialIndex).wav"
        let candidate = url.deletingLastPathComponent().appending(path: filename)
        do {
            partialFile = try AVAudioFile(
                forWriting: candidate,
                settings: PCMInt16WAV.settings(
                    sampleRate: converter.outputFormat.sampleRate,
                    channelCount: converter.outputFormat.channelCount
                ),
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            partialURL = candidate
            partialFrames = 0
        } catch {
            partialFile = nil
            partialURL = nil
            partialFrames = 0
        }
    }

    private func completePartialFile() {
        guard let partialURL, partialFrames > 0 else {
            partialFile = nil
            self.partialURL = nil
            partialFrames = 0
            return
        }
        let completedFrames = partialFrames
        let duration = Double(completedFrames) / converter.outputFormat.sampleRate
        partialFile = nil
        self.partialURL = nil
        partialFrames = 0
        onPartialRecording(
            AudioRecording(
                fileURL: partialURL,
                frameCount: completedFrames,
                durationSeconds: duration
            )
        )
    }

    private static let partialSegmentFrames = AVAudioFramePosition(
        PCMInt16WAV.transcriptionSampleRate * 6
    )

    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        let sampleCount = Int(buffer.frameLength)
        var sum: Float = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return 0 }
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<sampleCount {
                    let sample = channels[channel][index]
                    sum += sample * sample
                }
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return 0 }
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<sampleCount {
                    let sample = Float(channels[channel][index]) / Float(Int16.max)
                    sum += sample * sample
                }
            }
        default:
            return 0
        }

        let totalSamples = sampleCount * Int(buffer.format.channelCount)
        guard totalSamples > 0 else { return 0 }
        return min(1, sqrt(sum / Float(totalSamples)))
    }
}

private final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
