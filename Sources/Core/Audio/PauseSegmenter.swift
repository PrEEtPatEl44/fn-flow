import Foundation

/// Decides when to cut live 16 kHz mono audio, preferring natural pauses, so it can be
/// transcribed while the user keeps talking. Pure and deterministic (unit tested).
struct PauseSegmenter {
    static let sampleRate = 16_000
    /// 20 ms analysis frames.
    static let frameLength = 320

    /// Don't cut before this much audio: very short segments hurt recognition.
    var minSegment: TimeInterval = 4
    /// A quiet stretch this long counts as a pause. Pauses at commas and full stops are
    /// similar (~0.2 s); cuts needn't fall between sentences, since `StreamingDictation`
    /// only commits words that have speech after them.
    var minPause: TimeInterval = 0.2
    /// Force a cut (at the quietest moment) if nobody pauses for this long.
    var maxSegment: TimeInterval = 12

    /// Where to end the current segment (an absolute sample index inside `samples[start...]`),
    /// or nil to keep listening. Cuts land in the middle of the pause.
    func cutPoint(in samples: [Int16], from start: Int) -> Int? {
        let rms = Self.frameRMS(samples, from: start)
        let minFrames = frames(minSegment), pauseFrames = frames(minPause), maxFrames = frames(maxSegment)
        guard rms.count > minFrames else { return nil }
        let threshold = Self.silenceThreshold(rms)

        var run = 0
        for (i, level) in rms.enumerated() {
            run = level < threshold ? run + 1 : 0
            if i >= minFrames, run >= pauseFrames {
                return start + (i - run / 2) * Self.frameLength
            }
        }
        if rms.count >= maxFrames {
            // No pause: cut at the quietest frame after the minimum length (always past
            // `start`, so the caller's segment advances).
            let window = rms.indices.dropFirst(max(minFrames, 1))
            let quietest = window.min { rms[$0] < rms[$1] } ?? rms.count - 1
            return start + max(quietest, 1) * Self.frameLength
        }
        return nil
    }

    /// Whether a stretch of audio contains any speech (not just room noise).
    static func containsSpeech(_ samples: ArraySlice<Int16>) -> Bool {
        let rms = frameRMS(Array(samples), from: 0)
        let threshold = silenceThreshold(rms)
        return rms.contains { $0 > threshold * 2 }
    }

    /// Adapts to the room: a few times the quiet floor, but always well below the typical
    /// (median) level, so someone who barely pauses doesn't get their speech treated as
    /// silence. Never below about -48 dBFS.
    static func silenceThreshold(_ rms: [Float]) -> Float {
        let sorted = rms.sorted()
        guard !sorted.isEmpty else { return 0.004 }
        let floor = sorted[sorted.count / 20]
        let typical = sorted[sorted.count / 2]
        return max(0.004, min(floor * 3, typical * 0.3))
    }

    static func frameRMS(_ samples: [Int16], from start: Int) -> [Float] {
        stride(from: start, to: samples.count - frameLength + 1, by: frameLength).map { offset in
            var sum: Float = 0
            for i in offset..<(offset + frameLength) {
                let s = Float(samples[i]) / 32768
                sum += s * s
            }
            return (sum / Float(frameLength)).squareRoot()
        }
    }

    private func frames(_ seconds: TimeInterval) -> Int {
        Int(seconds * Double(Self.sampleRate)) / Self.frameLength
    }
}

/// 16-bit PCM WAV encoding/decoding for 16 kHz mono audio.
enum WAV {
    static func encode(_ samples: ArraySlice<Int16>, sampleRate: Int = PauseSegmenter.sampleRate) -> Data {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.withUnsafeBufferPointer { buffer in
            buffer.forEach { append($0) }
        }
        return data
    }

    /// Samples from a 16-bit mono WAV (the format the app records and `say` produces).
    static func decode(_ data: Data) -> [Int16] {
        guard let range = data.range(of: Data("data".utf8)) else { return [] }
        let start = range.upperBound + 4
        guard start <= data.count else { return [] }
        return data[start...].withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))
            }
        }
    }
}
