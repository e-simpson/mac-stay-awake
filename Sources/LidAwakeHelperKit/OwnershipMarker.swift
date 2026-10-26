import Darwin
import Foundation
import LidAwakeShared

public protocol OwnershipMarker {
    var isSet: Bool { get }
    func set() throws
    func validate() throws
    func clear() throws
}

/// Opens every path component without following symlinks; the caller owns the returned descriptor.
func openSupportDirectory(_ directory: URL, create: Bool) throws -> Int32? {
    let components = Array(directory.pathComponents.dropFirst())
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw supportError() }
    do {
        for (index, component) in components.enumerated() {
            guard component != ".", component != "..", !component.contains("/") else { throw CocoaError(.fileReadNoPermission) }
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { close(fd); return nil }
                guard index == components.count - 1 else { throw CocoaError(.fileNoSuchFile) }
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw supportError() }
                guard fsync(fd) == 0 else { throw supportError() }
                next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw supportError() }
            close(fd)
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

func prepareSupportDirectory(_ directory: URL) throws {
    guard let fd = try openSupportDirectory(directory, create: true) else { throw CocoaError(.fileNoSuchFile) }
    close(fd)
}

/// Marker validation precedes every write that clears the global sleep flag.
public struct FileOwnershipMarker: OwnershipMarker {
    public static let defaultDirectory = URL(
        fileURLWithPath: "/Library/Application Support/\(HelperConstants.appBundleIdentifier)", isDirectory: true
    )
    private static let name = "sleep-disabled-by-lidawake"
    private let directory: URL

    public init(directory: URL = FileOwnershipMarker.defaultDirectory) { self.directory = directory }

    public var isSet: Bool {
        do {
            guard let fd = try openSupportDirectory(directory, create: false) else { return false }
            defer { close(fd) }
            var info = stat()
            if fstatat(fd, Self.name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            return errno != ENOENT
        } catch {
            // Unsafe state remains pending; validate() will reject it before power writes.
            return true
        }
    }

    public func set() throws {
        guard let directoryFD = try openSupportDirectory(directory, create: true) else { throw CocoaError(.fileNoSuchFile) }
        defer { close(directoryFD) }
        var fd = openat(directoryFD, Self.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST {
            try validate(in: directoryFD)
            fd = openat(directoryFD, Self.name, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw supportError() }
        defer { close(fd) }
        // A retry must complete durability even when the earlier creation's fsync failed.
        guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw supportError() }
    }

    public func validate() throws {
        guard let fd = try openSupportDirectory(directory, create: false) else { throw CocoaError(.fileNoSuchFile) }
        defer { close(fd) }
        try validate(in: fd)
    }

    public func clear() throws {
        guard let fd = try openSupportDirectory(directory, create: false) else { return }
        defer { close(fd) }
        var info = stat()
        if fstatat(fd, Self.name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return }
        try validate(in: fd)
        guard unlinkat(fd, Self.name, 0) == 0, fsync(fd) == 0 else { throw supportError() }
    }

    private func validate(in fd: Int32) throws {
        var info = stat()
        guard fstatat(fd, Self.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw CocoaError(.fileReadNoPermission) }
    }
}

private func supportError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
