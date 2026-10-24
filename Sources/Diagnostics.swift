import Foundation
import CoreFoundation
import MetricKit

/// Converts only the documented, bounded diagnostic fields into metric events.
enum DiagnosticsParser {
    struct Event: Equatable {
        let kind: String
        let ms: Double
        let extra: [String: PocketMetrics.Value]
    }

    static func events(from data: Data) -> [Event] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var result: [Event] = []
        for (key, kind) in [("crashDiagnostics", "diag_crash"),
                            ("hangDiagnostics", "diag_hang"),
                            ("cpuExceptionDiagnostics", "diag_other"),
                            ("diskWriteExceptionDiagnostics", "diag_other")] {
            guard let diagnostics = root[key] as? [[String: Any]] else { continue }
            for diagnostic in diagnostics {
                guard let meta = diagnostic["diagnosticMetaData"] as? [String: Any],
                      let build = meta["appBuildVersion"] as? String,
                      let os = meta["osVersion"] as? String,
                      !build.isEmpty, !os.isEmpty else { continue }
                var extra: [String: PocketMetrics.Value] = ["appBuild": .text(short(build)), "os": .text(short(os))]
                var ms = 0.0
                if kind == "diag_crash" {
                    for field in ["exceptionType", "exceptionCode", "signal"] {
                        if let number = finiteNumber(meta[field]) { extra[field] = .number(number) }
                    }
                    if let reason = meta["terminationReason"] as? String { extra["reason"] = .text(short(reason)) }
                    addFrames(diagnostic, to: &extra)
                } else if kind == "diag_hang" {
                    guard let duration = durationMS(meta["hangDuration"]), duration >= 0 else { continue }
                    ms = duration
                    addFrames(diagnostic, to: &extra)
                } else {
                    extra["type"] = .text(key == "cpuExceptionDiagnostics" ? "cpu" : "disk")
                }
                result.append(Event(kind: kind, ms: ms, extra: extra))
            }
        }
        return result
    }

    private static func short(_ text: String) -> String { String(text.prefix(200)) }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// MetricKit's JSON diagnostic metadata serializes NSMeasurement as text,
    /// for example "20 secs". An explicit value/unit dictionary is also accepted.
    private static func durationMS(_ value: Any?) -> Double? {
        if let object = value as? [String: Any], let number = finiteNumber(object["value"]),
           let unit = object["unit"] as? String {
            return convert(number, unit: unit)
        }
        guard let string = value as? String else { return nil }
        let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)\s*(ms|msec|milliseconds?|s|secs?|seconds?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let numberRange = Range(match.range(at: 1), in: string),
              let unitRange = Range(match.range(at: 2), in: string),
              let number = Double(string[numberRange]) else { return nil }
        return convert(number, unit: String(string[unitRange]))
    }

    private static func convert(_ value: Double, unit: String) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        let lower = unit.lowercased()
        let multiplier = ["ms", "msec", "millisecond", "milliseconds"].contains(lower) ? 1.0 :
            (["s", "sec", "secs", "second", "seconds"].contains(lower) ? 1000.0 : nil)
        guard let multiplier, (value * multiplier).isFinite else { return nil }
        return value * multiplier
    }

    private static func addFrames(_ diagnostic: [String: Any], to extra: inout [String: PocketMetrics.Value]) {
        guard let tree = diagnostic["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]],
              let stack = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first,
              let roots = stack["callStackRootFrames"] as? [[String: Any]] else { return }
        var frame = roots.first
        for index in 0..<5 {
            guard let current = frame,
                  let binary = current["binaryName"] as? String,
                  let offset = finiteNumber(current["offsetIntoBinaryTextSegment"]) else { break }
            extra["f\(index)"] = .text(short("\(binary)+\(String(format: "%.0f", offset))"))
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
    }
}

final class PocketDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = PocketDiagnostics()

    static func install() {
        guard !PocketMetrics.isTesting else { return }
        MXMetricManager.shared.add(shared)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for event in DiagnosticsParser.events(from: payload.jsonRepresentation()) {
                PocketMetrics.record(event.kind, ms: event.ms, extra: event.extra)
            }
        }
    }
}
