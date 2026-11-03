import Darwin
import CoreMedia

/// Общие часы хоста (mach_absolute_time). В них приходят и PTS ScreenCaptureKit,
/// и AVAudioTime.hostTime микрофона, поэтому дорожки сравниваются напрямую.
public struct HostClock: Equatable, Sendable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = denom
    }

    public static let system: HostClock = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return HostClock(numer: info.numer, denom: info.denom)
    }()

    public func now() -> UInt64 { mach_absolute_time() }

    public func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000
    }

    public func ticks(seconds: Double) -> UInt64 {
        UInt64((seconds * 1_000_000_000 * Double(denom) / Double(numer)).rounded())
    }

    /// b − a в миллисекундах, со знаком.
    public func milliseconds(from a: UInt64, to b: UInt64) -> Double {
        (seconds(b) - seconds(a)) * 1000
    }

    /// PTS ScreenCaptureKit (CMTime в часах хоста) в тики mach_absolute_time.
    public static func ticks(fromHostTime time: CMTime) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(time)
    }
}

/// Момент в часах хоста: тики и секунды (секунды для чтения человеком).
public struct HostInstant: Codable, Equatable, Sendable {
    public var ticks: UInt64
    public var seconds: Double

    public init(ticks: UInt64, clock: HostClock = .system) {
        self.ticks = ticks
        self.seconds = clock.seconds(ticks)
    }
}
