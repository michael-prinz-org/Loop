//
//  DiagnosticLog.swift
//  LoopKit
//
//  Created by Darin Krauss on 6/12/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import Foundation
import Combine

public class DiagnosticLog {

    private let subsystem: String

    private let category: String

    private let log: OSLog

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    public func debug(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .debug, args)
    }

    public func info(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .info, args)
    }

    public func `default`(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .default, args)
    }

    public func error(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .error, args)
    }

    private func log(_ message: StaticString, type: OSLogType, _ args: [CVarArg]) {
        switch args.count {
        case 0:
            os_log(message, log: log, type: type)
        case 1:
            os_log(message, log: log, type: type, args[0])
        case 2:
            os_log(message, log: log, type: type, args[0], args[1])
        case 3:
            os_log(message, log: log, type: type, args[0], args[1], args[2])
        case 4:
            os_log(message, log: log, type: type, args[0], args[1], args[2], args[3])
        case 5:
            os_log(message, log: log, type: type, args[0], args[1], args[2], args[3], args[4])
        default:
            os_log(message, log: log, type: type, args)
        }

        if InAppLogStore.shared.isCapturing {
            InAppLogStore.shared.record(type: type, category: category, message: DiagnosticLog.renderMessage(message, args))
        }

        guard let sharedLogging = SharedLogging.instance else {
            return
        }
        sharedLogging.log(message, subsystem: subsystem, category: category, type: type, args)
    }

    /// Best-effort, crash-safe rendering of an os_log format string plus its arguments for the in-app log.
    /// Each format specifier is replaced by the next argument's description, so — unlike `String(format:)` —
    /// a specifier/argument type or count mismatch can never crash (it only renders imperfectly).
    private static func renderMessage(_ message: StaticString, _ args: [CVarArg]) -> String {
        let format = message.description
        guard !args.isEmpty else { return format }

        let conversionCharacters = Set("@dDiuUxXoOfeEgGaAFcCsSp")
        let characters = Array(format)
        var result = ""
        var argIndex = 0
        var i = 0

        while i < characters.count {
            let character = characters[i]
            guard character == "%" else {
                result.append(character)
                i += 1
                continue
            }

            // Literal "%%".
            if i + 1 < characters.count, characters[i + 1] == "%" {
                result.append("%")
                i += 2
                continue
            }

            // Skip a privacy qualifier such as "{public}" / "{private}", then flags/width/length up to the
            // conversion character.
            var j = i + 1
            if j < characters.count, characters[j] == "{" {
                while j < characters.count, characters[j] != "}" { j += 1 }
                if j < characters.count { j += 1 }
            }
            while j < characters.count, !conversionCharacters.contains(characters[j]) { j += 1 }

            if argIndex < args.count {
                result.append(String(describing: args[argIndex]))
                argIndex += 1
            }
            i = j < characters.count ? j + 1 : j
        }

        return result
    }

}

// MARK: - In-app log buffer

/// Severity of an in-app log entry, ordered least-to-most severe so the log view can filter by minimum level.
enum InAppLogLevel: Int, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case notice = 2
    case error = 3
    case fault = 4

    init(_ type: OSLogType) {
        switch type {
        case .debug: self = .debug
        case .info: self = .info
        case .error: self = .error
        case .fault: self = .fault
        default: self = .notice
        }
    }

    static func < (lhs: InAppLogLevel, rhs: InAppLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Default"
        case .error: return "Error"
        case .fault: return "Fault"
        }
    }

    var systemImageName: String {
        switch self {
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .notice: return "circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .fault: return "xmark.octagon.fill"
        }
    }
}

/// A single captured log line shown in the in-app log view.
struct InAppLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: InAppLogLevel
    let category: String
    let message: String
}

/// A bounded, in-memory ring buffer of the most recent `DiagnosticLog` lines, surfaced by the in-app log
/// view. It retains at most `maximumEntryCount` entries and never persists anything to disk.
final class InAppLogStore: ObservableObject {
    static let shared = InAppLogStore()

    /// The largest number of entries retained, and the most the log view can display.
    static let maximumEntryCount = 10000

    /// UserDefaults key backing `isCapturing`.
    private static let capturingDefaultsKey = "com.loopkit.Loop.inAppLogCaptureEnabled"

    private let lock = NSLock()
    private var storage: [InAppLogEntry] = []
    private var updateScheduled = false
    private var capturing: Bool

    private init() {
        // Disabled by default: no log line is captured until the user turns it on in the log view.
        capturing = UserDefaults.standard.bool(forKey: Self.capturingDefaultsKey)
        storage.reserveCapacity(Self.maximumEntryCount)
    }

    /// Whether new log lines are captured into the buffer. Read from every logging thread, so it is
    /// lock-guarded; when `false` the capture hook does no rendering or storage work at all.
    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return capturing
    }

    /// Enables or disables log capture and persists the choice. Call from the main thread (the toggle).
    func setCapturing(_ enabled: Bool) {
        lock.lock()
        capturing = enabled
        lock.unlock()
        UserDefaults.standard.set(enabled, forKey: Self.capturingDefaultsKey)
        objectWillChange.send()
    }

    func record(date: Date = Date(), type: OSLogType, category: String, message: String) {
        let entry = InAppLogEntry(date: date, level: InAppLogLevel(type), category: category, message: message)

        lock.lock()
        storage.append(entry)
        if storage.count > Self.maximumEntryCount {
            storage.removeFirst(storage.count - Self.maximumEntryCount)
        }
        let alreadyScheduled = updateScheduled
        updateScheduled = true
        lock.unlock()

        guard !alreadyScheduled else { return }
        // Coalesce bursts of log lines into a single UI refresh on the main run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.updateScheduled = false
            self.lock.unlock()
            self.objectWillChange.send()
        }
    }

    /// A snapshot of all retained entries, oldest first.
    func allEntries() -> [InAppLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// The distinct categories present in the buffer, sorted alphabetically.
    func categories() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.map { $0.category }).sorted()
    }

    func clear() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
        objectWillChange.send()
    }
}
