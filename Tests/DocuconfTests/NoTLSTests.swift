#if !TLS
import Configuration
import Docuconf
import Foundation
import Testing

@Suite struct NoTLSTests {
    @Test func tlsInputsWithoutTheTraitAreADeclarationErrorThatSaysHowToFixIt() async throws {
        struct TLSOnly: DocuconfConfig {
            @FileInput("tls", "Serving certificate", path: "/etc/svc/tls") var tls: TLSKeyPair?
        }
        do {
            _ = try await Docuconf.load(TLSOnly.self, environment: [:])
            Issue.record("expected a declaration error")
        } catch let e as DeclarationError {
            #expect(e.problems.count == 1)
            #expect(e.problems[0].contains(#"traits: ["TLS"]"#))
        }
        // Export needs no checks, so it works without the trait.
        #expect(try Contract.cue(for: TLSOnly.self, name: "tls-only").contains("tls"))
    }
}
#endif
