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

func readmeContractFirst() throws {
    // snippet:contract-first
    let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
    let values = try contract.load()   // or load(environment: [...]); throws ConfigurationError
    if case .int(let port)? = values["PORT"] { print(port) }
    // snippet:end
}
