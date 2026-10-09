// Code the README shows as fragments, compiled here so the README cannot drift from what builds.
// ReadmeTests checks each region against the README block that names it.
import Configuration
import Docuconf
import Foundation

struct ReadmeItemBounds: DocuconfConfig {
    // snippet:item-bounds
    @Env("shard.ids", "Shard ids this instance owns", .itemRange(0...1023)) var shardIDs: [UInt16] = [0]
    // exports itemMin: 0, itemMax: 1023
    @Env("listen.ports", "Extra ports to listen on") var ports: [UInt16]?
    // exports itemMin: 0, itemMax: 65535
    // snippet:end
}

struct ReadmeDetails: DocuconfConfig {
    // snippet:details
    @Env("request.timeout", """
        Upstream request timeout

        The gateway gives up on an upstream after this long and answers 504. Keep it below the load
        balancer's idle timeout; see ``LoadBalancer/idleTimeout``.

        - Note: Read in seconds, as `REQUEST_TIMEOUT=30`.
        """, .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)

    @Env("worker.count", "Number of request workers", .details("Each holds one database connection.")) var workers = 4
    // snippet:end
}

struct ReadmeLengths: DocuconfConfig {
    // snippet:key-set
    @Env("webhook.keys", "Keys that verify webhook signatures", .keyLength(32...256)) var webhookKeys: KeySet?
    // snippet:end
    // snippet:lengths
    @Env("callback.url", "Where to report each run", .schemes("https"), .maxLength(40)) var callback: URL?
    @Env("branches", "Branch codes, two to four characters each", .itemLength(2...4)) var branches: [String] = ["BE"]
    // snippet:end
}

// snippet:overlays
struct OverlaidConfig: DocuconfConfig {
    static let overlays = [
        ConfigOverlay("platform", "Settings the platform manages", path: "/etc/gateway/overlay/gateway.json"),
    ]

    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8443
}

// snippet:end
func readmeOverlays() async throws -> OverlaidConfig {
    // snippet:overlays
    let base = try await FileProvider<JSONSnapshot>(filePath: "/app/config/gateway.json")
    let config = await Docuconf.loadOrExit(OverlaidConfig.self, files: [base])
    // providers, first match wins: environment, overlays, then `files`
    // snippet:end
    return config
}

func readmeContractFirst() async throws {
    // snippet:contract-first
    let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
    let values = try await contract.load(support: DocuconfFileSupport())   // or load(environment: [...], support: ...)
    if case .int(let port)? = values["PORT"] { print(port) }
    // snippet:end
}
