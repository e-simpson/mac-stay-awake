import Darwin
import Foundation
import LidAwakeShared

public protocol ClosedLidPowerManaging {
    var hasPendingRestore: Bool { get }
    func update(closed: Bool, source: PowerSource) throws
    func restore() throws
}

public enum ClosedLidPowerError: Error, Equatable, LocalizedError {
    case unknownSource, unreadable, commandFailed(Int32), notApplied
    case invalidJournal, unsafeJournal, journalIO(Int32)

    public var errorDescription: String? {
        switch self {
        case .unknownSource: return "The current power source is unavailable."
        case .unreadable: return "The power mode setting is unavailable or unrecognized."
        case .commandFailed(let status): return "pmset exited with status \(status)."
        case .notApplied: return "The power mode change could not be verified."
        case .invalidJournal: return "The saved power mode recovery record is invalid."
        case .unsafeJournal: return "The power mode recovery path has unsafe ownership or permissions."
        case .journalIO(let code): return "The power mode recovery record could not be accessed (\(code))."
        }
    }
}

/// Fixed Low Power operations for the current source, with recovery owned by the root helper.
/// The directory is helper configuration, never a path supplied by an XPC caller.
public final class ClosedLidPower: ClosedLidPowerManaging {
    private enum Scope: String, Codable, CaseIterable {
        case battery = "-b", ac = "-c"
    }

    private enum Key: String, Codable {
        case modern = "powermode", legacy = "lowpowermode"

        func accepts(_ value: Int) -> Bool {
            (0...(self == .modern ? 2 : 1)).contains(value)
        }
    }

    private struct Touch: Codable {
        let scope: Scope
        let key: Key
        let original: Int
        var applied: Bool
    }

    private struct Journal: Codable {
        let version: Int
        var touches: [Touch]
    }

    private static let journalName = "closed-lid-power.json"
    private let runner: CommandRunning
    private let directory: URL

    public init(runner: CommandRunning = ProcessRunner(), directory: URL = FileOwnershipMarker.defaultDirectory) {
        self.runner = runner
        self.directory = directory
    }

    /// Invalid or inaccessible records are pending, so startup cannot silently discard recovery.
    public var hasPendingRestore: Bool {
        do { return try readJournal() != nil } catch { return true }
    }

    public func update(closed: Bool, source: PowerSource) throws {
        guard closed else { return try restore() }
        var journal = try readJournal() ?? Journal(version: 1, touches: [])
        let scope: Scope
        switch source {
        case .battery: scope = .battery
        case .ac: scope = .ac
        case .unknown: throw ClosedLidPowerError.unknownSource
        }
        let index: Int
        if let existing = journal.touches.firstIndex(where: { $0.scope == scope }) {
            index = existing
            // Never reapply over a later external change after a verified application.
            if journal.touches[index].applied { return }
            let touch = journal.touches[index]
            let current = try read(scope: scope, key: touch.key)
            if current == 1 {
                journal.touches[index].applied = true
                try saveJournal(journal)
                return
            }
            guard current == touch.original else { return }
        } else {
            let settings = try readSettings(scope: scope)
            guard let key = settings[.modern] != nil ? Key.modern : settings[.legacy] != nil ? .legacy : nil,
                  let original = settings[key] else { throw ClosedLidPowerError.unreadable }
            // An existing Low Power choice belongs to the user and needs no recovery record.
            guard original != 1 else { return }
            index = journal.touches.count
            journal.touches.append(Touch(scope: scope, key: key, original: original, applied: false))
            try saveJournal(journal)
        }
        try write(scope: scope, key: journal.touches[index].key, value: 1)
        journal.touches[index].applied = true
        try saveJournal(journal)
    }

    public func restore() throws {
        guard let journal = try readJournal() else { return }
        var remaining: [Touch] = []
        var firstError: Error?
        for touch in journal.touches {
            do {
                // A different current value is a newer external choice, not ours to overwrite.
                if try read(scope: touch.scope, key: touch.key) == 1 {
                    try write(scope: touch.scope, key: touch.key, value: touch.original)
                }
            } catch {
                remaining.append(touch)
                if firstError == nil { firstError = error }
            }
        }
        try saveJournal(Journal(version: 1, touches: remaining))
        if let firstError { throw firstError }
    }

    private func run(_ arguments: [String]) throws -> String {
        let result = try runner.run("/usr/bin/pmset", arguments, timeout: 10)
        guard result.status == 0 else { throw ClosedLidPowerError.commandFailed(result.status) }
        return result.output
    }

    private func read(scope: Scope, key: Key) throws -> Int {
        guard let value = try readSettings(scope: scope)[key] else { throw ClosedLidPowerError.unreadable }
        return value
    }

    private func write(scope: Scope, key: Key, value: Int) throws {
        _ = try run([scope.rawValue, key.rawValue, String(value)])
        guard try read(scope: scope, key: key) == value else { throw ClosedLidPowerError.notApplied }
    }

    private func readSettings(scope: Scope) throws -> [Key: Int] {
        let output = try run(["-g", "custom"])
        var current: Scope?
        var settings: [Key: Int] = [:]
        var legacyHighPower = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                switch line {
                case "Battery Power:": current = .battery
                case "AC Power:": current = .ac
                default: current = nil
                }
                continue
            }
            guard current == scope else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "highpowermode" {
                guard fields.count == 2, let high = Int(fields[1]), (0...1).contains(high) else {
                    throw ClosedLidPowerError.unreadable
                }
                legacyHighPower = high == 1
                continue
            }
            guard let first = fields.first, let key = Key(rawValue: String(first)) else { continue }
            guard fields.count == 2, let value = Int(fields[1]), key.accepts(value), settings[key] == nil else {
                throw ClosedLidPowerError.unreadable
            }
            settings[key] = value
        }
        guard !settings.isEmpty, settings[.modern] != nil || !legacyHighPower else {
            // A legacy High Power setting needs more than a boolean restoration; do not clobber it.
            throw ClosedLidPowerError.unreadable
        }
        return settings
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        try openSupportDirectory(directory, create: create)
    }

    private func validate(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            throw ClosedLidPowerError.unsafeJournal
        }
    }

    private func validateExisting(in directoryFD: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(directoryFD, Self.journalName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw ClosedLidPowerError.journalIO(errno)
        }
        try validate(info)
        return true
    }

    private func readJournal() throws -> Journal? {
        guard let directoryFD = try openDirectory(create: false) else { return nil }
        defer { Darwin.close(directoryFD) }
        guard try validateExisting(in: directoryFD) else { return nil }
        let fd = openat(directoryFD, Self.journalName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClosedLidPowerError.journalIO(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ClosedLidPowerError.journalIO(errno) }
        try validate(info)
        guard (1...4096).contains(info.st_size) else { throw ClosedLidPowerError.invalidJournal }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 4097), data.count <= 4096,
              let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.version == 1, (1...2).contains(journal.touches.count),
              Set(journal.touches.map(\.scope)).count == journal.touches.count,
              journal.touches.allSatisfy({ $0.key.accepts($0.original) && $0.original != 1 }) else {
            throw ClosedLidPowerError.invalidJournal
        }
        return journal
    }

    private func saveJournal(_ journal: Journal) throws {
        guard let directoryFD = try openDirectory(create: true) else { throw ClosedLidPowerError.unsafeJournal }
        defer { Darwin.close(directoryFD) }
        let exists = try validateExisting(in: directoryFD)
        if journal.touches.isEmpty {
            if exists, unlinkat(directoryFD, Self.journalName, 0) != 0 { throw ClosedLidPowerError.journalIO(errno) }
        } else {
            let temporary = ".closed-lid-power-\(UUID().uuidString)"
            let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ClosedLidPowerError.journalIO(errno) }
            defer {
                Darwin.close(fd)
                unlinkat(directoryFD, temporary, 0)
            }
            guard fchmod(fd, 0o600) == 0 else { throw ClosedLidPowerError.journalIO(errno) }
            let data = try JSONEncoder().encode(journal)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ClosedLidPowerError.journalIO(errno) }
                    offset += count
                }
            }
            guard fsync(fd) == 0,
                  renameat(directoryFD, temporary, directoryFD, Self.journalName) == 0 else {
                throw ClosedLidPowerError.journalIO(errno)
            }
        }
        guard fsync(directoryFD) == 0 else { throw ClosedLidPowerError.journalIO(errno) }
    }
}
