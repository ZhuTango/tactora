import Foundation
import Security
import CryptoKit

/// The privileged service exposes exactly one operation; no file paths, commands or key events.
@objc protocol KeyboardHelperProtocol {
    func setProtection(_ externalIDs: [String], reply: @escaping (Bool, String) -> Void)
}

enum KeyboardHelperIdentity {
    static let label = "local.tango.macbglive.keyboard-helper"
    static let appIdentifier = "local.tango.macbglive"
    static let plist = label + ".plist"
    static func peerRequirement(identifier: String) throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else {
            throw KeyboardControlError(message: "辅助服务需要固定证书签名，临时签名不能启用。")
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(digest)\""
    }
}
