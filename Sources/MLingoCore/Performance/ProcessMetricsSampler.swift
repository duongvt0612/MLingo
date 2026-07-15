import Darwin
import Foundation

struct ProcessResourceSample: Equatable, Sendable {
    let cpuUsagePercent: Double?
    let residentMemoryBytes: UInt64
}

protocol ProcessMetricsSampling: Sendable {
    func sample() async -> ProcessResourceSample?
    func reset() async
}

actor DarwinProcessMetricsSampler: ProcessMetricsSampling {
    private var previousCPUTimeNanoseconds: UInt64?
    private var previousInstant: ContinuousClock.Instant?

    func reset() {
        previousCPUTimeNanoseconds = nil
        previousInstant = nil
    }

    func sample() -> ProcessResourceSample? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { usagePointer in
            usagePointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, pointer)
            }
        }
        guard result == 0 else { return nil }

        let currentInstant = ContinuousClock.now
        let currentCPUTime = usage.ri_user_time &+ usage.ri_system_time
        defer {
            previousCPUTimeNanoseconds = currentCPUTime
            previousInstant = currentInstant
        }

        let cpuPercent: Double?
        if let previousCPUTimeNanoseconds,
           let previousInstant
        {
            let elapsed = previousInstant.duration(to: currentInstant).timeInterval
            let cpuElapsed = Double(currentCPUTime &- previousCPUTimeNanoseconds) / 1e9
            cpuPercent = elapsed > 0 ? max(0, cpuElapsed / elapsed * 100) : nil
        } else {
            cpuPercent = nil
        }

        return ProcessResourceSample(
            cpuUsagePercent: cpuPercent,
            residentMemoryBytes: usage.ri_resident_size
        )
    }
}
