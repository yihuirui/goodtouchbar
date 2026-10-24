import Foundation
import Darwin
import FanControlCore
import SystemMonitoring

enum FanLogMetadata {
    static func directory(_ metadata: stat, privateDirectory: Bool) -> Bool {
        guard metadata.st_uid == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_mode & 0o022 == 0 else { return false }
        return !privateDirectory || metadata.st_mode & 0o7777 == 0o700
    }
    static func file(_ metadata: stat) -> Bool {
        metadata.st_uid == 0 && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_mode & 0o7777 == 0o600 && metadata.st_nlink == 1 && metadata.st_size >= 0
    }
    static func sameIdentity(_ actual: stat, _ expected: stat) -> Bool {
        actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
    }
}

enum FanLogRotation {
    static func rotate(paths: [String], present: [Bool]) throws {
        guard paths.count == 4, present.count == 4 else { throw HelperStorageError(code:"invalid_log_generations") }
        if present[3], unlink(paths[3]) != 0 { throw HelperStorageError(code:"log_rotation_failed") }
        for i in stride(from:3,through:1,by:-1) where present[i-1] {
            guard rename(paths[i-1],paths[i]) == 0 else { throw HelperStorageError(code:"log_rotation_failed") }
        }
    }
}

/// Log failures must never prevent restoring hardware to automatic.
final class FanEventLog {
    private let directory = "/Library/Logs/GoodTouchBar"
    private let file = "/Library/Logs/GoodTouchBar/fan-control-events.jsonl"
    private let queue = DispatchQueue(label:"io.github.yihuirui.goodtouchbar.fan-helper.log",qos:.utility)
    func record(_ event: FanControlEvent) {
        guard let data = try? JSONEncoder().encode(event), var object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return }
        object["time"] = ISO8601DateFormatter().string(from:Date()); object["build"] = AppBuild.current; object["pid"] = getpid()
        guard let line = try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) + Data([10]) else { return }
        queue.async { [self] in write(line) }
    }
    func flush() { queue.sync {} }
    private func inspectDirectory(_ path: String, privateDirectory: Bool = false) throws {
        var metadata = stat()
        guard lstat(path,&metadata) == 0, FanLogMetadata.directory(metadata,privateDirectory:privateDirectory) else {
            throw HelperStorageError(code:"unsafe_log_directory")
        }
        try RootFiles.rejectACL(path)
    }
    private func inspectFile(_ path: String) throws -> stat? {
        var metadata = stat()
        guard lstat(path,&metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw HelperStorageError(code:"log_inspect_failed")
        }
        guard FanLogMetadata.file(metadata) else { throw HelperStorageError(code:"unsafe_log_file") }
        try RootFiles.rejectACL(path)
        return metadata
    }
    static func rejectDescriptorACL(_ descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor,ACL_TYPE_EXTENDED) else {
            let code = errno
            var metadata = stat()
            // Darwin can report ENOENT for an existing file with no extended ACL.
            if code == ENOENT, fstat(descriptor,&metadata) == 0,
               metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) { return }
            throw HelperStorageError(code:"log_acl_read_failed")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        guard acl_get_entry(acl,Int32(ACL_FIRST_ENTRY.rawValue),&entry) == -1,
              errno == EINVAL else { throw HelperStorageError(code:"log_acl_rejected") }
    }
    private func write(_ line: Data) {
        do {
            for path in ["/", "/Library", "/Library/Logs"] { try inspectDirectory(path) }
            var metadata = stat()
            if lstat(directory,&metadata) != 0 {
                guard errno == ENOENT, mkdir(directory,0o700) == 0 else { return }
            }
            try inspectDirectory(directory,privateDirectory:true)
            // Validate every generation, including the one to be deleted, before any rotation mutation.
            let paths = [file, file + ".1", file + ".2", file + ".3"]
            let existing = try paths.map { try inspectFile($0) }
            if let current = existing[0], current.st_size > 1_048_576 - off_t(line.count) {
                try FanLogRotation.rotate(paths:paths,present:existing.map { $0 != nil })
            }
            let expected = try inspectFile(file)
            var flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            if expected == nil { flags |= O_CREAT | O_EXCL }
            let descriptor = open(file,flags,0o600)
            guard descriptor >= 0 else { return }; defer { close(descriptor) }
            guard fstat(descriptor,&metadata) == 0, FanLogMetadata.file(metadata) else { return }
            if let expected, !FanLogMetadata.sameIdentity(metadata,expected) { return }
            try Self.rejectDescriptorACL(descriptor)
            line.withUnsafeBytes { pointer in
                guard var current = pointer.baseAddress else { return }
                var remaining = pointer.count
                while remaining > 0 {
                    let count = Darwin.write(descriptor,current,remaining)
                    if count < 0 { if errno == EINTR { continue }; return }
                    guard count > 0 else { return }; current = current.advanced(by:count); remaining -= count
                }
            }
        } catch { return }
    }
}
