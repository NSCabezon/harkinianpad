import Foundation
import Darwin
import os

/// FPS meter and perf reports (docs/visionos-run.md, "Performance reports").
///
/// Polls HP_GetStats and the host present counters once per second on the main
/// actor (no per-frame work): the overlay shows the last second, and every 5 s one
/// `[Perf]` line goes to the log and a row to Documents/perf.csv. Switching 2D/3D
/// writes a mode-change line and row.
@MainActor
@Observable
final class PerfMonitor {
    static let shared = PerfMonitor()

    /// Last 1 s window, shown by the overlay.
    struct Sample {
        var eyes = 0
        var width = 0
        var height = 0
        var gameFps = 0.0
        var presentFps = 0.0
        var dropped: UInt64 = 0
        var cpuAvgMs = 0.0
        var cpuMaxMs = 0.0
        var audioUnderruns: UInt64 = 0
        var audioQueued = 0
    }

    private(set) var sample = Sample()
    private(set) var mode = "2D"

    /// Sink the counters were read from (they restart with each new sink).
    @ObservationIgnored private var lastSink: ObjectIdentifier?

    @ObservationIgnored private let log = Logger(subsystem: "com.nscabezon.sohvision", category: "Perf")
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var csv: FileHandle?
    @ObservationIgnored private var last = Counters()
    @ObservationIgnored private var window = Counters() // start of the current 5 s report window
    @ObservationIgnored private var windowStart = ContinuousClock.now
    @ObservationIgnored private var windowCpuMaxNs: UInt64 = 0
    @ObservationIgnored private var lastTick = ContinuousClock.now

    private struct Counters {
        var frames: UInt64 = 0
        var runTimeNs: UInt64 = 0
        var presents: UInt64 = 0
        var dropped: UInt64 = 0
        var underruns: UInt64 = 0
    }

    private init() {}

    /// Starts polling (idempotent).
    func start() {
        guard task == nil else { return }
        let (now, _) = poll()
        last = now
        window = now
        windowStart = .now
        lastTick = .now
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    /// The view switched between the flat (2D) and stereo (3D) presentation.
    func setMode(_ newMode: String) {
        guard newMode != mode else { return }
        let old = mode
        guard task != nil else {
            mode = newMode
            return
        }
        // Close the current window under the old mode, then restart counting.
        report(event: "report", mode: old)
        mode = newMode
        let (now, _) = poll()
        last = now
        window = now
        log.notice("[Perf] mode change \(old, privacy: .public) -> \(newMode, privacy: .public)")
        appendCSV(event: "mode", mode: newMode, eyes: 0, width: 0, height: 0,
                  gameFps: 0, presentFps: 0, dropped: 0, cpuAvg: 0, cpuMax: 0, footprint: Self.footprintMB(),
                  underruns: 0, queued: 0)
    }

    /// Presents = frames the main thread took from the attached sink (2D: drawables
    /// presented on the display tick; 3D: LowLevelTexture replaces). Dropped = ring
    /// full at eye 0 + published frames superseded before the main thread took them.
    private func poll() -> (Counters, HPStats) {
        var stats = HPStats()
        stats.size = UInt32(MemoryLayout<HPStats>.size)
        HP_GetStats(&stats)
        var c = Counters(frames: stats.frames, runTimeNs: stats.runTimeNs, underruns: stats.audioUnderruns)
        let sink = HPVisionHost.attachedStereoSink
        if let sink {
            c.presents = sink.takenFrames
            c.dropped = sink.droppedFrames &+ sink.supersededFrames
        }
        let id = sink.map(ObjectIdentifier.init)
        if id != lastSink {
            // New sink (mode switch, resize): its counters start at zero.
            lastSink = id
            last.presents = c.presents
            last.dropped = c.dropped
            window.presents = c.presents
            window.dropped = c.dropped
        }
        return (c, stats)
    }

    private func tick() {
        let (now, stats) = poll()
        let t = ContinuousClock.now
        let dt = max(Self.seconds(t - lastTick), 0.001)
        lastTick = t
        windowCpuMaxNs = max(windowCpuMaxNs, stats.runTimeMaxNs)

        let frames = now.frames &- last.frames
        var s = Sample()
        s.eyes = Int(stats.eyeCount)
        s.width = Int(stats.width)
        s.height = Int(stats.height)
        s.gameFps = Double(frames) / dt
        // Counters restart when the presenter changes (mode switch, tier rebuild).
        s.presentFps = now.presents >= last.presents ? Double(now.presents - last.presents) / dt : 0
        s.dropped = now.dropped >= last.dropped ? now.dropped - last.dropped : 0
        s.cpuAvgMs = frames > 0 ? Double(now.runTimeNs &- last.runTimeNs) / Double(frames) / 1e6 : 0
        s.cpuMaxMs = Double(stats.runTimeMaxNs) / 1e6
        s.audioUnderruns = now.underruns &- last.underruns
        s.audioQueued = Int(stats.audioQueuedFrames)
        sample = s
        last = now

        if Self.seconds(t - windowStart) >= 5 {
            report(event: "report", mode: mode)
        }
    }

    /// Logs and appends the current 5 s window, then starts a new one.
    private func report(event: String, mode: String) {
        let (now, stats) = poll()
        let t = ContinuousClock.now
        let dt = max(Self.seconds(t - windowStart), 0.001)
        windowCpuMaxNs = max(windowCpuMaxNs, stats.runTimeMaxNs)
        let frames = now.frames &- window.frames
        let gameFps = Double(frames) / dt
        let presentFps = now.presents >= window.presents ? Double(now.presents - window.presents) / dt : 0
        let dropped = now.dropped >= window.dropped ? now.dropped - window.dropped : 0
        let cpuAvg = frames > 0 ? Double(now.runTimeNs &- window.runTimeNs) / Double(frames) / 1e6 : 0
        let cpuMax = Double(windowCpuMaxNs) / 1e6
        let footprint = Self.footprintMB()
        let eyes = Int(stats.eyeCount), w = Int(stats.width), h = Int(stats.height)
        let underruns = now.underruns &- window.underruns, queued = Int(stats.audioQueuedFrames)

        log.notice("""
            [Perf] mode=\(mode, privacy: .public) eyes=\(eyes) res=\(w)x\(h) \
            gameFps=\(gameFps, format: .fixed(precision: 1)) presentFps=\(presentFps, format: .fixed(precision: 1)) \
            dropped=\(dropped) cpuMs avg/max=\(cpuAvg, format: .fixed(precision: 2))/\(cpuMax, format: .fixed(precision: 2)) \
            footprintMB=\(footprint, format: .fixed(precision: 0)) audioUnderruns=\(underruns) audioQueued=\(queued)
            """)
        appendCSV(event: event, mode: mode, eyes: eyes, width: w, height: h, gameFps: gameFps,
                  presentFps: presentFps, dropped: dropped, cpuAvg: cpuAvg, cpuMax: cpuMax, footprint: footprint,
                  underruns: underruns, queued: queued)

        window = now
        last = now
        windowStart = t
        lastTick = t
        windowCpuMaxNs = 0
    }

    private func appendCSV(event: String, mode: String, eyes: Int, width: Int, height: Int, gameFps: Double,
                           presentFps: Double, dropped: UInt64, cpuAvg: Double, cpuMax: Double, footprint: Double,
                           underruns: UInt64, queued: Int) {
        if csv == nil {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = docs.appendingPathComponent("perf.csv")
            if !FileManager.default.fileExists(atPath: url.path) {
                let header = "time,event,mode,eyes,width,height,gameFps,presentFps,dropped,cpuAvgMs,cpuMaxMs,footprintMB,audioUnderruns,audioQueued\n"
                FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
            }
            csv = try? FileHandle(forWritingTo: url)
            _ = try? csv?.seekToEnd()
        }
        let time = Date.now.formatted(.iso8601) // UTC, e.g. 2026-10-12T17:20:05Z
        let line = String(format: "%@,%@,%@,%d,%d,%d,%.1f,%.1f,%llu,%.2f,%.2f,%.0f,%llu,%d\n", time, event, mode, eyes,
                          width, height, gameFps, presentFps, dropped, cpuAvg, cpuMax, footprint, underruns, queued)
        // FileHandle writes go straight to the file descriptor (no user-space buffer).
        try? csv?.write(contentsOf: Data(line.utf8))
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    /// phys_footprint (what jetsam accounts), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
