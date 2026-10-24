import Foundation
import Darwin

@main struct FanSecurityChecks {
    static func main() throws {
        var count = 0
        func check(_ condition:Bool,_ name:String) { precondition(condition,name); count += 1; print("PASS: \(name)") }
        func fails(_ action:() throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let validRequirement = "identifier \"io.github.yihuirui.goodtouchbar\" and cdhash H\"0123456789abcdef0123456789abcdef01234567\""
        func data(requirement:String = validRequirement,uid:Int = 501,version:Int = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject:["version":version,"clientRequirement":requirement,"clientUID":uid])
        }
        let valid = try ClientPolicy.decode(data())
        check(valid.clientUID == 501,"valid exact-code local policy")
        check(fails { _ = try ClientPolicy.decode(data(uid:0)) },"reject root client")
        check(fails { _ = try ClientPolicy.decode(data(version:2)) },"reject unknown policy version")
        check(fails { _ = try ClientPolicy.decode(data(requirement:"")) },"reject empty requirement")
        check(fails { _ = try ClientPolicy.decode(data(requirement:validRequirement + " or true")) },"reject widened code requirement")
        check(fails { _ = try ClientPolicy.decode(data(requirement:validRequirement.replacingOccurrences(of:"io.github.yihuirui.goodtouchbar",with:"com.other.app"))) },"reject other bundle ID")
        check(fails { _ = try ClientPolicy.decode(data(requirement:validRequirement.replacingOccurrences(of:"0123456789abcdef0123456789abcdef01234567",with:"deadbeef"))) },"reject short code hash")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fan-security-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:dir) }
        let file = dir.appendingPathComponent("policy"), link = dir.appendingPathComponent("link")
        try Data("test".utf8).write(to:file)
        try RootFiles.rejectACL(file.path); check(true,"empty Darwin ACL accepted")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        check(fails { _ = try RootFiles.inspect(link.path,directory:false) },"reject symlink file")
        if geteuid() != 0 { check(fails { _ = try RootFiles.inspect(file.path,directory:false) },"reject non-root-owned policy") }
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath:"/bin/chmod")
        chmod.arguments = ["+a","everyone allow read",file.path]; try chmod.run(); chmod.waitUntilExit()
        check(chmod.terminationStatus == 0,"temporary ACL fixture created")
        check(fails { try RootFiles.rejectACL(file.path) },"reject extended ACL under BSD semantics")
        print("\(count) fan security checks passed; no system files or hardware changed")
    }
}
