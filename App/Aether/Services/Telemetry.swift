import Foundation
import MetricKit
import os
import AetherCore

/// Aether's lines in the system log (Console, Instruments), intervals for Instruments, and the reports iOS gathers on the
/// phone (MetricKit: crashes, hangs, launch time), summarised in the diagnostic log so that an exported log tells what went wrong.
/// Nothing is sent anywhere: like the diagnostic log, it stays on the phone until the viewer shares it.
enum Telemetry {
    static let subsystem = "app.aether"
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// For `DiagnosticLog.setMirror`: the lines are already redacted (no full URLs, no keys), so they are public in the log.
    static let mirror: @Sendable (LogLevel, String, String) -> Void = { level, category, message in
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    /// A span of time shown in Instruments (Points of Interest).
    final class Interval {
        private let name: StaticString
        private var state: OSSignpostIntervalState?

        init(name: StaticString) {
            self.name = name
            self.state = Telemetry.signposter.beginInterval(name, id: Telemetry.signposter.makeSignpostID())
        }

        func end() {
            guard let state = state else { return }
            Telemetry.signposter.endInterval(name, state)
            self.state = nil
        }
    }

    static func begin(_ name: StaticString) -> Interval { return Interval(name: name) }

    private static var collector: MetricsCollector?

    @MainActor
    static func startMetrics(log: DiagnosticLog) {
        guard collector == nil else { return }
        let made = MetricsCollector(log: log)
        MXMetricManager.shared.add(made)
        collector = made
    }
}

/// Receives the reports iOS delivers (about once a day, and the diagnostics of a crash at the next launch).
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {
    private let log: DiagnosticLog

    init(log: DiagnosticLog) {
        self.log = log
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var parts: [String] = []
            if let launch = payload.applicationLaunchMetrics {
                let buckets = launch.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.compactMap { $0 as? MXHistogramBucket<UnitDuration> }
                if let typical = buckets.max(by: { $0.bucketCount < $1.bucketCount }) {
                    parts.append(String(format: "avvio tipico %.1f s", typical.bucketEnd.converted(to: .seconds).value))
                }
            }
            if let hangs = payload.applicationResponsivenessMetrics {
                let buckets = hangs.histogrammedApplicationHangTime.bucketEnumerator.allObjects.compactMap { $0 as? MXHistogramBucket<UnitDuration> }
                let count = buckets.reduce(0) { $0 + $1.bucketCount }
                if count > 0 { parts.append("\(count) blocchi dell'interfaccia") }
            }
            if let exits = payload.applicationExitMetrics {
                let foreground = exits.foregroundExitData
                let crashes = foreground.cumulativeBadAccessExitCount + foreground.cumulativeAbnormalExitCount
                    + foreground.cumulativeIllegalInstructionExitCount + foreground.cumulativeAppWatchdogExitCount
                    + foreground.cumulativeMemoryResourceLimitExitCount
                if crashes > 0 { parts.append("\(crashes) chiusure anomale con l'app aperta") }
            }
            let text = parts.isEmpty ? "nessun problema segnalato" : parts.joined(separator: ", ")
            log.logDetached(.info, "metriche", "Rapporto di iOS sulle ultime 24 ore: \(text)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let signal = crash.signal.map { "segnale \($0)" } ?? ""
                let reason = crash.terminationReason ?? crash.exceptionType.map { "eccezione \($0)" } ?? "motivo non indicato"
                log.logDetached(.error, "metriche", "Chiusura anomala segnalata da iOS (versione \(crash.metaData.applicationBuildVersion)): \(reason) \(signal)")
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                log.logDetached(.warning, "metriche", String(format: "Blocco dell'interfaccia di %.1f s segnalato da iOS", seconds))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                log.logDetached(.warning, "metriche", "Uso eccessivo del processore segnalato da iOS (\(cpu.totalCPUTime.converted(to: .seconds).value) s)")
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                log.logDetached(.warning, "metriche", "Scritture su disco eccessive segnalate da iOS (\(disk.totalWritesCaused.converted(to: .megabytes).value) MB)")
            }
        }
    }
}
