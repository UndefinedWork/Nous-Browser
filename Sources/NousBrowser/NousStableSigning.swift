import CryptoKit
import Foundation
import Security

/// Identifies builds eligible for team-backed Keychain storage. Installations
/// that already use local encryption retain their existing profile and vault.
nonisolated enum NousStableSigning {
    /// `NousStableStorageTeam` in Info.plist names the only accepted team.
    static func verifiedTeam(bundle: Bundle = .main) -> String? {
        guard let team = bundle.object(forInfoDictionaryKey: "NousStableStorageTeam") as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return team
    }

    /// 64 hex characters, stable for one team + bundle identifier.
    static func fingerprint(team: String, bundleIdentifier: String) -> String {
        SHA256.hash(data: Data("nous-stable-storage:\(team):\(bundleIdentifier)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
