import Foundation
import Darwin

@main struct FanLogChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition,name); count += 1; print("PASS: \(name)")
        }
        func fails(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        func changing(_ original: stat, _ update: (inout stat) -> Void) -> stat {
            var value = original; update(&value); return value
        }
        var directory = stat()
        directory.st_uid = 0; directory.st_mode = mode_t(S_IFDIR) | 0o700
        check(FanLogMetadata.directory(directory,privateDirectory:true),"private root 0700 directory accepted")
        check(FanLogMetadata.directory(changing(directory) { $0.st_mode = mode_t(S_IFDIR) | 0o755 },privateDirectory:false),"root 0755 ancestor accepted")
        check(!FanLogMetadata.directory(changing(directory) { $0.st_uid = 501 },privateDirectory:false),"non-root ancestor rejected")
        check(!FanLogMetadata.directory(changing(directory) { $0.st_mode |= 0o020 },privateDirectory:false),"group-writable ancestor rejected")
        check(!FanLogMetadata.directory(changing(directory) { $0.st_mode |= 0o002 },privateDirectory:false),"world-writable ancestor rejected")
        check(!FanLogMetadata.directory(changing(directory) { $0.st_mode = mode_t(S_IFLNK) | 0o700 },privateDirectory:false),"symlink ancestor rejected")
        check(!FanLogMetadata.directory(changing(directory) { $0.st_mode |= 0o050 },privateDirectory:true),"non-private log directory rejected")
        check(!FanLogMetadata.directory(changing(directory) { $0.st_mode |= 0o2000 },privateDirectory:true),"setgid log directory rejected")
        var file = stat()
        file.st_uid = 0; file.st_mode = mode_t(S_IFREG) | 0o600; file.st_nlink = 1
        file.st_dev = 1; file.st_ino = 2; file.st_size = 100
        check(FanLogMetadata.file(file),"root 0600 single-link log accepted")
        check(!FanLogMetadata.file(changing(file) { $0.st_uid = 501 }),"non-root log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_mode |= 0o044 }),"readable-by-others log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_mode |= 0o020 }),"group-writable log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_mode &= ~mode_t(0o200) }),"read-only log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_nlink = 2 }),"hard-linked current or rotated log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_nlink = 0 }),"unlinked open log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_mode = mode_t(S_IFLNK) | 0o600 }),"symlink current or rotated log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_mode |= 0o4000 }),"setuid log rejected")
        check(!FanLogMetadata.file(changing(file) { $0.st_size = -1 }),"invalid log size rejected")
        check(FanLogMetadata.sameIdentity(file,file),"unchanged opened file identity accepted")
        check(!FanLogMetadata.sameIdentity(changing(file) { $0.st_ino = 3 },file),"substituted inode rejected")
        check(!FanLogMetadata.sameIdentity(changing(file) { $0.st_dev = 3 },file),"substituted device rejected")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("fan-log-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temporary) }
        let path = temporary.appendingPathComponent("events.jsonl").path
        let descriptor = open(path,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw HelperStorageError(code:"fixture_create_failed") }
        defer { close(descriptor) }
        try RootFiles.rejectACL(path); check(true,"path without extended ACL accepted")
        try FanEventLog.rejectDescriptorACL(descriptor); check(true,"opened file without extended ACL accepted")
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath:"/bin/chmod")
        chmod.arguments = ["+a","everyone allow read",path]; try chmod.run(); chmod.waitUntilExit()
        check(chmod.terminationStatus == 0,"temporary log ACL fixture created")
        check(fails { try RootFiles.rejectACL(path) },"path with extended ACL rejected")
        check(fails { try FanEventLog.rejectDescriptorACL(descriptor) },"opened file with extended ACL rejected")

        let full = (0...3).map { temporary.appendingPathComponent("full.\($0)").path }
        for i in 0...3 { try Data("generation\(i)".utf8).write(to:URL(fileURLWithPath:full[i])) }
        try FanLogRotation.rotate(paths:full,present:[true,true,true,true])
        check(!FileManager.default.fileExists(atPath:full[0]),"full rotation releases current log path")
        check(try String(contentsOfFile:full[1]) == "generation0", "full rotation preserves current as first backup")
        check(try String(contentsOfFile:full[2]) == "generation1", "full rotation advances first backup")
        check(try String(contentsOfFile:full[3]) == "generation2", "full rotation replaces oldest backup")
        let sparse = (0...3).map { temporary.appendingPathComponent("sparse.\($0)").path }
        for i in [0,2] { try Data("generation\(i)".utf8).write(to:URL(fileURLWithPath:sparse[i])) }
        try FanLogRotation.rotate(paths:sparse,present:[true,false,true,false])
        check(!FileManager.default.fileExists(atPath:sparse[0]),"sparse rotation releases current log path")
        check(try String(contentsOfFile:sparse[1]) == "generation0", "sparse rotation keeps current as first backup")
        check(!FileManager.default.fileExists(atPath:sparse[2]),"sparse rotation preserves generation gap")
        check(try String(contentsOfFile:sparse[3]) == "generation2", "sparse rotation advances available older backup")
        print("\(count) fan log checks passed; no system files or hardware changed")
    }
}
