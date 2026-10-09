import DocuconfCore
import Foundation
import Testing

@Suite struct TOMLTests {
    @Test func readsTablesArraysAndScalars() throws {
        let doc = try TOML.parse(#"""
            # settings
            name = "orders"   # trailing comment
            replicas = 3
            ratio = 0.5
            enabled = true
            tags = ["a", 'b', """c"""]
            big = 1_000_000
            hex = 0xff
            exp = 1e3
            when = 1979-05-27T07:32:00Z
            site."google.com" = true
            point = { x = 1, y = [2, 3] }

            [limits]
            burst = 10

            [[routes]]
            prefix = "/api"

            [[routes]]
            prefix = "/web"
            multi = """
            one
            two"""
            """#)
        #expect(doc["name"] == "orders")
        #expect(doc["replicas"] == 3)
        #expect(doc["ratio"] == 0.5)
        #expect(doc["enabled"] == true)
        #expect(doc["tags"] == ["a", "b", "c"])
        #expect(doc["big"] == 1_000_000)
        #expect(doc["hex"] == 255)
        #expect(doc["exp"] == 1000.0)
        #expect(doc["when"] == "1979-05-27T07:32:00Z")
        #expect(doc["site"]?["google.com"] == true)
        #expect(doc["point"] == ["x": 1, "y": [2, 3]])
        #expect(doc["limits"] == ["burst": 10])
        #expect(doc["routes"] == [["prefix": "/api"], ["prefix": "/web", "multi": "one\ntwo"]])
    }

    @Test(arguments: [
        "name = orders\n", "name = \"orders\"\nname = \"twice\"\n", "[a]\n[a]\n", "x = [1, 2\n", "x = 007\n",
        "x = \"unterminated\n", "x = 1 2\n", "= 1\n", "x = 1__0\n", "x = \"\\q\"\n",
    ])
    func rejects(text: String) {
        #expect(throws: MalformedFileError.self) { try TOML.parse(text) }
    }

    @Test func decodesIntoATypeInDeclarationMode() throws {
        struct Settings: Decodable, Equatable { var name: String; var replicas: Int }
        let s = try FoundationDecoding().decode(Settings.self, from: Data("name = \"orders\"\nreplicas = 3\n".utf8), format: .toml)
        #expect(s == Settings(name: "orders", replicas: 3))
    }
}

@Suite struct StrictWireTests {
    @Test func bools() {
        for t in ["true", "TRUE", "True", "tRuE"] { #expect(VarSpec.parseBool(t) == true) }
        for f in ["false", "FALSE", "False"] { #expect(VarSpec.parseBool(f) == false) }
        for bad in ["1", "0", "t", "f", "yes", "no", "on", "off", " true", "true\n", "", "truE "] { #expect(VarSpec.parseBool(bad) == nil) }
    }

    @Test func floats() {
        for (text, want) in [("+1.5", 1.5), ("1E3", 1000), ("25e-2", 0.25), ("007.5", 7.5), ("-0", 0)] {
            #expect(VarSpec.parseDouble(text) == want, "\(text)")
        }
        for bad in ["0x1p4", "inf", "Infinity", "-inf", "nan", ".5", "5.", "1_000.5", " 1.5", "1.5\n", "1e", "1e400", "0,5", "+-1"] {
            #expect(VarSpec.parseDouble(bad) == nil, "\(bad)")
        }
    }
}
