import Docuconf
import Foundation
import Testing

@testable import Orders

private let oldKey = String(repeating: "o", count: 32)
private let newKey = String(repeating: "n", count: 32)
private let body = Data(#"{"order":"42","status":"paid"}"#.utf8)

/// Loads the configuration as the service does at boot.
private func load(_ keys: String) async throws -> OrdersConfig {
    try await Docuconf.load(OrdersConfig.self, environment: ["DATABASE_URL": "postgres://u:p@db/orders", "WEBHOOK_KEYS": keys])
}

/// A key rotation: each step is a rollout with a new WEBHOOK_KEYS, and a webhook signed with the key in use always
/// verifies.
@Test(arguments: [
    ("before", oldKey, [oldKey: true, newKey: false]),
    ("overlap", "\(oldKey),\(newKey)", [oldKey: true, newKey: true]),
    ("after", newKey, [oldKey: false, newKey: true]),
])
func rotation(step: String, keys: String, accepts: [String: Bool]) async throws {
    let loaded = try #require(try await load(keys).webhookKeys)
    for (key, want) in accepts {
        #expect(Webhook.verify(keys: loaded, body: body, signature: Webhook.sign(key: key, body: body)) == want, "\(step)")
    }
    #expect(!Webhook.verify(keys: loaded, body: body, signature: Webhook.sign(key: String(repeating: "x", count: 32), body: body)))
}

@Test func malformedOrMissing() async throws {
    #expect(!Webhook.verify(keys: KeySet([oldKey]), body: body, signature: "not hex"))
    #expect(!Webhook.verify(keys: KeySet([oldKey]), body: body, signature: ""))
    #expect(!Webhook.verify(keys: KeySet([]), body: body, signature: Webhook.sign(key: oldKey, body: body)))
    #expect(try await load("").webhookKeys == nil)
}

/// A key set is always secret: printing the configuration never shows a key.
@Test func keysAreRedacted() async throws {
    let config = try await load("\(oldKey),\(newKey)")
    let keys = try #require(config.webhookKeys)
    #expect(keys.keys == [oldKey, newKey])
    #expect(keys.contains(newKey))
    for text in [String(describing: config), "\(keys)", String(reflecting: keys)] {
        #expect(!text.contains(oldKey) && !text.contains(newKey), "\(text)")
    }
}

/// The key set's constraints catch an empty or truncated key, and a third key, at boot, without printing any key.
@Test(arguments: [
    ("\(oldKey),", ViolationCode.outOfRange),
    ("\(oldKey),\(newKey.prefix(10))", ViolationCode.outOfRange),
    ("\(oldKey),\(newKey),\(String(repeating: "x", count: 32))", ViolationCode.tooManyItems),
])
func badKeySets(value: String, code: ViolationCode) async throws {
    let error = await #expect(throws: ConfigurationError.self) { try await load(value) }
    let violations = try #require(error).violations.filter { $0.input == "WEBHOOK_KEYS" }
    #expect(violations.map(\.code) == [code])
    let text = String(describing: try #require(error))
    #expect(!text.contains(oldKey) && !text.contains(newKey.prefix(10)), "the error printed a key: \(text)")
}
