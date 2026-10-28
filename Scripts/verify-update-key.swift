import Foundation
import CryptoKit

// Never print private key material. Fail before producing a feed with the wrong key.
let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let infoURL = URL(fileURLWithPath: CommandLine.arguments[2])
let permissions = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? NSNumber
if (permissions?.intValue ?? 0o777) & 0o077 != 0 {
    throw NSError(domain: "NousRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Signing key must not be accessible by other users (chmod 600)."])
}
let encoded = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let data = Data(base64Encoded: encoded) else { fatalError("Invalid signing key encoding") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
guard info?["SUPublicEDKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else {
    throw NSError(domain: "NousRelease", code: 2, userInfo: [NSLocalizedDescriptionKey: "Signing key does not match the public key embedded in Nous."])
}
print("Update signing key matches the embedded public key.")
