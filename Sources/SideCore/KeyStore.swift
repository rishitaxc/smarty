import Foundation
import Security

public enum KeyStore {
    static let service = "dev.side.notch.openai"
    static let account = "api-key"
    public static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ key: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("sk-"), cleaned.count > 20 else { throw SideAPIError("That does not look like an OpenAI API key.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: Data(cleaned.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attrs.forEach { insert[$0.key] = $0.value }
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw SideAPIError("Keychain could not save the key (\(result)).") }
        } else if status != errSecSuccess { throw SideAPIError("Keychain could not update the key (\(status)).") }
    }
    public static func importDotEnv(at url: URL) throws {
        try save(readDotEnv(at:url))
    }
    public static func readDotEnv(at url:URL) throws ->String {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("OPENAI_API_KEY=")
        }), let equal = line.firstIndex(of: "=") else { throw SideAPIError("OPENAI_API_KEY was not found in that file.") }
        let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard value.hasPrefix("sk-"),value.count>20 else{throw SideAPIError("Invalid OPENAI_API_KEY in the selected file.")}
        return value
    }
}
