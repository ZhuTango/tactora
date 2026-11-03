import Foundation
import Security
import CryptoKit

@objc protocol FanHelperProtocol {
    func configure(_ enabled: Bool, low: Double, high: Double, reply: @escaping (Bool, String) -> Void)
    func heartbeat(reply: @escaping (Data?, String) -> Void)
}
enum FanHelperIdentity {
    static let label = "local.tango.macbglive.fan-helper"
    static let plist = label + ".plist"
    static func requirement(identifier: String) throws -> String {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let cert = ((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else {
            throw FanControlError(message: "风扇辅助服务需要固定证书签名。")
        }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
    }
}
