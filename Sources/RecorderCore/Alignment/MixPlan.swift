import Foundation

/// Раскладка дорожек на общей шкале сведения. Начало шкалы (кадр 0) — первый сэмпл
/// дорожки, стартовавшей раньше; другая дорожка сдвигается тишиной на |startOffsetMs|.
/// Все кадры плана — в частоте выхода.
public struct MixPlan: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public var firstSampleTicks: UInt64
        public var sampleRate: Double
        public var frames: Int64

        public init(firstSampleTicks: UInt64, sampleRate: Double, frames: Int64) {
            self.firstSampleTicks = firstSampleTicks
            self.sampleRate = sampleRate
            self.frames = frames
        }
    }

    public let outputRate: Double
    public let originTicks: UInt64
    public let systemLeadFrames: Int64
    public let micLeadFrames: Int64
    public let systemOutputFrames: Int64
    public let micOutputFrames: Int64
    public let totalFrames: Int64
    /// mic − system, мс; nil, если дорожка одна.
    public let startOffsetMs: Double?

    public init(system: Track?, mic: Track?, outputRate: Double, clock: HostClock) {
        self.outputRate = outputRate
        let origin = [system?.firstSampleTicks, mic?.firstSampleTicks].compactMap { $0 }.min() ?? 0
        originTicks = origin

        func lead(_ t: Track?) -> Int64 {
            guard let t else { return 0 }
            return Int64((clock.seconds(t.firstSampleTicks - origin) * outputRate).rounded())
        }
        func length(_ t: Track?) -> Int64 {
            guard let t else { return 0 }
            return Int64((Double(t.frames) * outputRate / t.sampleRate).rounded())
        }
        systemLeadFrames = lead(system)
        micLeadFrames = lead(mic)
        systemOutputFrames = length(system)
        micOutputFrames = length(mic)
        totalFrames = max(system == nil ? 0 : systemLeadFrames + systemOutputFrames,
                          mic == nil ? 0 : micLeadFrames + micOutputFrames)
        if let system, let mic {
            startOffsetMs = clock.milliseconds(from: system.firstSampleTicks, to: mic.firstSampleTicks)
        } else {
            startOffsetMs = nil
        }
    }
}

/// Смешивание блока: системный звук сохраняет стерео (моно идёт в оба канала),
/// микрофон сводится в моно и добавляется в оба канала. Сумма ограничивается ±1.
public enum MixKernel {
    public struct Output {
        public var left: [Float]
        public var right: [Float]
        public var clippedSamples: Int
    }

    /// system и mic — каналы по [кадр]; nil или пустой массив — тишина.
    public static func mix(system: [[Float]]?, mic: [[Float]]?, frames: Int) -> Output {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        if let system, !system.isEmpty {
            let l = system[0], r = system.count > 1 ? system[1] : system[0]
            for i in 0..<frames { left[i] = l[i]; right[i] = r[i] }
        }
        if let mic, !mic.isEmpty {
            let scale = 1 / Float(mic.count)
            for i in 0..<frames {
                var m: Float = 0
                for ch in mic { m += ch[i] }
                m *= scale
                left[i] += m
                right[i] += m
            }
        }
        var clipped = 0
        for i in 0..<frames {
            if abs(left[i]) > 1 { left[i] = max(-1, min(1, left[i])); clipped += 1 }
            if abs(right[i]) > 1 { right[i] = max(-1, min(1, right[i])); clipped += 1 }
        }
        return Output(left: left, right: right, clippedSamples: clipped)
    }
}
