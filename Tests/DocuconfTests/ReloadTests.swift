import Docuconf
import Foundation
import Testing

/// Records what hooks saw, from any task.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// Waits up to 10 seconds for `condition`, checking every 10ms.
func eventually(_ what: Comment, _ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
}

func routes(_ match: String) -> String { #"{"items":[{"match":"\#(match)","upstream":"http://api:8080"}]}"# }

struct HookFailure: Error {}

/// SPEC §4.6.2: on-change hooks and reload status for `reload: watch` inputs.
@Suite(.timeLimit(.minutes(1))) struct ReloadTests {
    @Test func hooksRunAfterAcceptedReloadsOnly() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routes("/v1"))
        let c = try await box.load(FilesConfig.self)
        #expect(c.$routes.reloadStatus == ReloadStatus(generation: 1))

        let seen = Recorder()
        let a = c.$routes.onChange(every: .milliseconds(20)) { seen.add("a:" + $0.items[0].match) }
        let b = c.$routes.onChange(every: .milliseconds(20)) { seen.add("b:" + $0.items[0].match) }

        try box.write("/etc/svc/routes/routes.json", routes("/v2"))
        await eventually("both hooks see /v2") { seen.all == ["a:/v2", "b:/v2"] }
        #expect(c.routes.items[0].match == "/v2", "the property already returns the new value")
        let accepted = c.$routes.reloadStatus
        #expect(accepted.generation == 2)
        #expect(accepted.lastReload != nil)
        #expect(accepted.lastRejected == nil)

        // Fails Routes.validate(): rejected, never passed to a hook, and logged without its content.
        try box.write("/etc/svc/routes/routes.json", #"{"items":[],"marker":"do-not-log"}"#)
        await eventually("the rejection is recorded") { c.$routes.reloadStatus.lastRejected != nil }
        let rejected = c.$routes.reloadStatus
        #expect(rejected.generation == 2)
        #expect(rejected.lastReload == accepted.lastReload)
        #expect(rejected.lastRejected?.input == "routes")
        #expect(rejected.lastRejected?.codes == [.schemaMismatch])
        #expect(c.routes.items[0].match == "/v2", "the previous value stays current")
        #expect(seen.all == ["a:/v2", "b:/v2"])
        #expect(box.warnings.contains { $0.contains("routes") && $0.contains("schema_mismatch") })
        #expect(!box.warnings.joined().contains("do-not-log"))

        // A status encodes as JSON with codes, never content.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(rejected), encoding: .utf8))
        #expect(json.contains(#""generation":2"#) && json.contains(#""codes":["schema_mismatch"]"#) && json.contains(#""input":"routes""#))
        #expect(!json.contains("do-not-log"))

        // The next accepted reload clears the rejection.
        try box.write("/etc/svc/routes/routes.json", routes("/v3"))
        await eventually("both hooks see /v3") { seen.all.count == 4 }
        #expect(seen.all == ["a:/v2", "b:/v2", "a:/v3", "b:/v3"], "hooks run in registration order")
        #expect(c.$routes.reloadStatus.generation == 3)
        #expect(c.$routes.reloadStatus.lastRejected == nil)

        // An unsubscribed hook is not called again.
        b.cancel()
        b.cancel()
        try box.write("/etc/svc/routes/routes.json", routes("/v4"))
        await eventually("hook a sees /v4") { seen.all.last == "a:/v4" }
        #expect(seen.all == ["a:/v2", "b:/v2", "a:/v3", "b:/v3", "a:/v4"])

        // With no hook left, the background check stops: a change is no longer applied.
        a.cancel()
        try await Task.sleep(for: .milliseconds(50))
        try box.write("/etc/svc/routes/routes.json", routes("/v5"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.routes.items[0].match == "/v4")
        #expect(c.$routes.reloadStatus.generation == 4)
    }

    @Test func aThrowingHookIsLoggedAndTheOthersRun() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routes("/v1"))
        let c = try await box.load(FilesConfig.self)
        let seen = Recorder()
        let failing = c.$routes.onChange(every: .milliseconds(20)) { _ in throw HookFailure() }
        let after = c.$routes.onChange(every: .milliseconds(20)) { seen.add($0.items[0].match) }
        defer {
            failing.cancel()
            after.cancel()
        }

        try box.write("/etc/svc/routes/routes.json", routes("/secret-path"))
        await eventually("the second hook runs") { seen.all == ["/secret-path"] }
        let logged = box.warnings.filter { $0.contains("on-change hook") }
        #expect(logged.count == 1)
        #expect(logged.first?.contains("routes") == true)
        #expect(logged.first?.contains("HookFailure") == true)
        #expect(logged.first?.contains("secret-path") == false)
        #expect(c.$routes.reloadStatus.generation == 2, "a failing hook does not undo the reload")
    }

    @Test func streamsAndHooksShareOneCheck() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routes("/v1"))
        let c = try await box.load(FilesConfig.self)
        let seen = Recorder()
        let hook = c.$routes.onChange(every: .milliseconds(20)) { seen.add($0.items[0].match) }
        defer { hook.cancel() }
        var changes = c.$routes.changes(every: .milliseconds(20)).makeAsyncIterator()

        try box.write("/etc/svc/routes/routes.json", routes("/v2"))
        guard case .updated(let r)? = await changes.next() else {
            Issue.record("expected an update")
            return
        }
        #expect(r.items[0].match == "/v2")
        await eventually("the hook sees /v2") { seen.all == ["/v2"] }
        #expect(c.$routes.reloadStatus.generation == 2, "one change is one reload, however many follow it")
    }

    @Test func optionalInputAbsentAtBoot() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routes("/v1"))
        let c = try await box.load(FilesConfig.self)
        #expect(c.$settings.reloadStatus == ReloadStatus(generation: 0))
        #expect(c.$routes.reloadStatus.generation == 1)
    }

    @Test func beforeLoadNothingIsRegistered() {
        let c = FilesConfig()
        #expect(c.$routes.reloadStatus == ReloadStatus(generation: 0))
        c.$routes.onChange { _ in Issue.record("never called") }.cancel()
    }

    /// Contract-first mode reads files once, so it rejects `reload: watch` at load, naming the input.
    @Test func contractFirstRejectsWatch() {
        let contract: JSONValue = [
            "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "svc"],
            "files": [
                "routes": ["type": "config", "format": "json", "description": "Routing table", "path": "/etc/svc/routes/r.json", "reload": "watch"],
                "license": ["type": "text", "description": "Licence key", "path": "/etc/svc/license/key.txt", "reload": "restart"],
            ],
            "overlays": ["platform": ["format": "json", "path": "/etc/svc/overlay/o.json", "keySeparator": ":", "reload": "watch"]],
        ]
        #expect {
            try ContractDocument(contract: contract)
        } throws: { error in
            let p = (error as? DeclarationError)?.problems ?? []
            return p.count == 2 && p[0].hasPrefix("routes: reload: watch is not supported")
                && p[1].hasPrefix("overlay platform: reload: watch is not supported")
        }
    }
}

#if TLS
struct WatchedKeystoreConfig: DocuconfConfig {
    @Env("ks.password", "Partner keystore password", .secret) var ksPassword: String?
    @FileInput("partner", "Partner keystore", path: "/etc/svc/partner/ks.p12", .passwordVar("KS_PASSWORD"), .reload(.watch))
    var partner: Keystore
}

@Suite(.timeLimit(.minutes(1))) struct KeystoreReloadTests {
    /// SPEC §4.6.2: a reload opens the keystore with the password read at boot. A keystore that needs another password
    /// is keystore_unreadable, and the previous one stays current.
    @Test func reloadKeepsTheBootPassword() async throws {
        let box = try Sandbox(["KS_PASSWORD": "changeit"])
        let original = try Sandbox.fixture("keystore.p12")
        try box.write("/etc/svc/partner/ks.p12", original)
        let c = try await box.load(WatchedKeystoreConfig.self)
        let seen = Recorder()
        let hook = c.$partner.onChange(every: .milliseconds(20)) { seen.add("\($0.data.count)") }
        defer { hook.cancel() }

        // The platform rotated the password: the new keystore does not open with the one read at boot.
        try box.write("/etc/svc/partner/ks.p12", Sandbox.fixture("keystore-rotated.p12"))
        await eventually("the rejection is recorded") { c.$partner.reloadStatus.lastRejected != nil }
        #expect(c.$partner.reloadStatus.lastRejected?.codes == [.keystoreUnreadable])
        #expect(c.$partner.reloadStatus.generation == 1)
        #expect(c.partner.data == original, "the previous keystore stays current")
        #expect(seen.all.isEmpty)
        #expect(!box.warnings.joined().contains("changeit"))

        // A new keystore under the boot password is accepted.
        let legacy = try Sandbox.fixture("keystore-legacy.p12")
        try box.write("/etc/svc/partner/ks.p12", legacy)
        await eventually("the hook runs") { seen.all == ["\(legacy.count)"] }
        #expect(c.partner.data == legacy)
        #expect(c.$partner.reloadStatus.generation == 2)
        #expect(c.$partner.reloadStatus.lastRejected == nil)
    }
}
#endif
