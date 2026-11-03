import Foundation

/// Фактическая частота дорожки по anchors (host time, номер кадра).
/// Наклон прямой «кадры от host time» методом наименьших квадратов.
/// ppm > 0: устройство выдаёт больше кадров в секунду host time, чем номинал.
public struct TrackDrift: Codable, Equatable, Sendable {
    public var nominalRate: Double
    public var measuredRate: Double
    public var ppm: Double
    public var anchorCount: Int
    public var spanSeconds: Double
    /// Наибольшее отклонение anchor от прямой, мс: дрожание меток, а не дрейф.
    public var maxResidualMs: Double

    /// Короче этого промежутка наклон слишком зависит от дрожания меток.
    public static let minimumSpanSeconds = 10.0

    public static func measure(anchors: [TrackAnchor], nominalRate: Double, clock: HostClock) -> TrackDrift? {
        guard anchors.count >= 2, nominalRate > 0 else { return nil }
        let t0 = clock.seconds(anchors[0].hostTime.ticks)
        let f0 = anchors[0].frame
        // смещаем к первой точке, чтобы не терять точность на больших host time
        let xs = anchors.map { clock.seconds($0.hostTime.ticks) - t0 }
        let ys = anchors.map { Double($0.frame - f0) }
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        guard span >= minimumSpanSeconds else { return nil }

        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
        }
        guard sxx > 0 else { return nil }
        let rate = sxy / sxx
        let intercept = my - rate * mx
        let maxResidual = zip(xs, ys).map { x, y in abs(x - (y - intercept) / rate) }.max() ?? 0

        return TrackDrift(nominalRate: nominalRate,
                          measuredRate: rate,
                          ppm: (rate / nominalRate - 1) * 1e6,
                          anchorCount: anchors.count,
                          spanSeconds: span,
                          maxResidualMs: maxResidual * 1000)
    }
}

/// Дрейф дорожек относительно друг друга при воспроизведении на номинальной частоте.
/// Знак как у startOffsetMs: mic − system. Положительное: микрофон со временем отстаёт.
public struct DriftReport: Codable, Equatable, Sendable {
    public var system: TrackDrift?
    public var mic: TrackDrift?
    public var sessionSeconds: Double
    public var relativePpm: Double?
    public var driftMsAtEnd: Double?
    public var driftMsPer70Min: Double?

    public static let referenceSeconds = 70.0 * 60

    public init(system: TrackDrift?, mic: TrackDrift?, sessionSeconds: Double) {
        self.system = system
        self.mic = mic
        self.sessionSeconds = sessionSeconds
        if let system, let mic {
            let ppm = mic.ppm - system.ppm
            relativePpm = ppm
            driftMsAtEnd = ppm * 1e-6 * sessionSeconds * 1000
            driftMsPer70Min = ppm * 1e-6 * Self.referenceSeconds * 1000
        }
    }

    public static func measure(_ meta: SessionMetadata) -> DriftReport {
        let clock = HostClock(numer: meta.hostTimebase.numer, denom: meta.hostTimebase.denom)
        func drift(_ t: TrackMetadata?) -> TrackDrift? {
            t.flatMap { TrackDrift.measure(anchors: $0.anchors, nominalRate: $0.sampleRate, clock: clock) }
        }
        let seconds = max(meta.system?.durationSeconds ?? 0, meta.mic?.durationSeconds ?? 0)
        return DriftReport(system: drift(meta.system), mic: drift(meta.mic), sessionSeconds: seconds)
    }
}
