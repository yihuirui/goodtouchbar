import Foundation
import Security
import Darwin
import FanHardware

struct ClientPolicy: Decodable {
    let version: Int
    let clientRequirement: String
    let clientUID: UInt32
    static func load() throws -> ClientPolicy {
        try decode(RootFiles.read(FanHelperIdentity.policyPath))
    }
    static func decode(_ data: Data) throws -> ClientPolicy {
        let policy = try JSONDecoder().decode(ClientPolicy.self,from:data)
        guard policy.version == 1, policy.clientUID > 0,
              policy.clientRequirement.range(of: #"^identifier "io\.github\.yihuirui\.goodtouchbar" and cdhash H"[a-fA-F0-9]{40}"$"#,options:.regularExpression) != nil else { throw HelperStorageError(code:"invalid_client_policy") }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(policy.clientRequirement as CFString,[],&requirement) == errSecSuccess, requirement != nil else { throw HelperStorageError(code:"invalid_client_requirement") }
        return policy
    }
    func validates(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == clientUID,
              connection.responds(to:NSSelectorFromString("auditToken")) else { return false }
        // NSXPCConnection exposes the kernel audit token via KVC on supported macOS.
        // Fail closed if this compatibility path is unavailable; never fall back to PID-only identity.
        let raw = connection.value(forKey:"auditToken")
        var token = audit_token_t()
        if let value = raw as? NSValue {
            withUnsafeMutableBytes(of:&token) { value.getValue($0.baseAddress!,size:$0.count) }
        } else if let bytes = raw as? Data, bytes.count == MemoryLayout<audit_token_t>.size {
            _ = withUnsafeMutableBytes(of:&token) { bytes.copyBytes(to:$0) }
        } else { return false }
        let tokenData = withUnsafeBytes(of:token) { Data($0) } as CFData
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit:tokenData] as CFDictionary,[],&code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(clientRequirement as CFString,[],&requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement) == errSecSuccess
    }
}
