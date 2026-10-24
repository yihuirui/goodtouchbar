import Foundation
import Darwin

struct HelperStorageError: Error { let code: String }

/// Fixed root-owned paths only. The RPC surface never accepts a filesystem path.
enum RootFiles {
    static let applicationDirectory = "/Library/Application Support/GoodTouchBar"
    static let directory = applicationDirectory + "/FanControl"
    static let marker = directory + "/pending-fans.json"
    static func inspect(_ path: String, directory: Bool) throws -> stat {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { throw HelperStorageError(code: "path_missing") }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG), metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0 else { throw HelperStorageError(code: "unsafe_path") }
        return metadata
    }
    static func validateDirectory() throws {
        for path in ["/Library", "/Library/Application Support", applicationDirectory, directory] {
            _ = try inspect(path, directory: true); try rejectACL(path)
        }
        try rejectACL(directory)
        let metadata = try inspect(directory, directory: true)
        guard metadata.st_mode & 0o077 == 0 else { throw HelperStorageError(code: "unsafe_private_directory") }
    }
    static func rejectACL(_ path: String) throws {
        guard let acl = acl_get_file(path,ACL_TYPE_EXTENDED) else {
            let code = errno
            var metadata = stat()
            // Darwin reports ENOENT when an existing object has no extended ACL.
            // Confirm that the object itself still exists and is not a symlink.
            let kind: mode_t
            if code == ENOENT, lstat(path,&metadata) == 0 {
                kind = metadata.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) { return }
            }
            throw HelperStorageError(code:"acl_read_failed")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl,Int32(ACL_FIRST_ENTRY.rawValue),&entry)
        // Darwin's BSD API returns 0 when an entry exists, -1/EINVAL at the end.
        guard result == -1, errno == EINVAL else { throw HelperStorageError(code:"extended_acl_rejected") }
    }
    static func read(_ path: String, maximum: Int = 16_384) throws -> Data {
        try validateDirectory()
        try rejectACL(path)
        let expected = try inspect(path, directory: false)
        guard expected.st_size >= 0, expected.st_size <= maximum, expected.st_nlink == 1 else { throw HelperStorageError(code: "invalid_file_size") }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HelperStorageError(code: "file_open_failed") }
        defer { close(descriptor) }
        var actual = stat()
        guard fstat(descriptor, &actual) == 0, actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
              actual.st_uid == 0, actual.st_mode & 0o022 == 0 else { throw HelperStorageError(code: "file_changed") }
        var data = Data(), buffer = [UInt8](repeating: 0,count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw HelperStorageError(code: "file_read_failed") }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw HelperStorageError(code: "invalid_file_size") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    static func persistMarker(_ fanIDs: [Int]) throws {
        try validateDirectory()
        guard fanIDs.count <= 10, fanIDs.allSatisfy({ (0...9).contains($0) }), Set(fanIDs).count == fanIDs.count else { throw HelperStorageError(code: "invalid_fan_ids") }
        if fanIDs.isEmpty {
            var metadata = stat()
            if lstat(marker,&metadata) == 0 {
                _ = try inspect(marker,directory:false)
                guard unlink(marker) == 0 else { throw HelperStorageError(code: "marker_remove_failed") }
            } else if errno != ENOENT { throw HelperStorageError(code: "marker_inspect_failed") }
            try syncDirectory(); return
        }
        let object: [String:Any] = ["version":1,"fanIDs":fanIDs.sorted(),"updatedAt":ISO8601DateFormatter().string(from:Date())]
        let data = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let temporary = directory + "/.pending-" + UUID().uuidString
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HelperStorageError(code:"marker_create_failed") }
        var installed = false
        defer { close(descriptor); if !installed { unlink(temporary) } }
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor,pointer,remaining)
                if written < 0 { if errno == EINTR { continue }; throw HelperStorageError(code:"marker_write_failed") }
                guard written > 0 else { throw HelperStorageError(code:"marker_write_failed") }
                pointer = pointer.advanced(by:written); remaining -= written
            }
        }
        guard fsync(descriptor) == 0 else { throw HelperStorageError(code:"marker_sync_failed") }
        var previous = stat()
        if lstat(marker,&previous) == 0 { _ = try inspect(marker,directory:false) }
        else if errno != ENOENT { throw HelperStorageError(code:"marker_inspect_failed") }
        guard rename(temporary,marker) == 0 else { throw HelperStorageError(code:"marker_install_failed") }
        installed = true; try syncDirectory()
    }
    static func pendingFanIDs() throws -> [Int] {
        try validateDirectory()
        var metadata = stat()
        guard lstat(marker,&metadata) == 0 else {
            if errno == ENOENT { return [] }; throw HelperStorageError(code:"marker_inspect_failed")
        }
        struct Marker: Decodable { let version: Int; let fanIDs: [Int] }
        let object = try JSONDecoder().decode(Marker.self,from:read(marker))
        let values = object.fanIDs
        guard object.version == 1, values.count <= 10,
              values.allSatisfy({ (0...9).contains($0) }), Set(values).count == values.count else { throw HelperStorageError(code:"marker_invalid") }
        return values.sorted()
    }
    private static func syncDirectory() throws {
        let descriptor = open(directory,O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HelperStorageError(code:"directory_open_failed") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw HelperStorageError(code:"directory_sync_failed") }
    }
}
