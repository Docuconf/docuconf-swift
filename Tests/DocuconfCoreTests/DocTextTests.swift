import CueTestSupport
import DocuconfCore
import Foundation
import Testing

/// Descriptions and details (SPEC §4.2, §14.7): the first paragraph of an input's documentation is its
/// description, and the rest its details, converted from DocC to CommonMark.
@Suite struct DocTextTests {
    @Test(arguments: [
        ("", "", nil),
        ("HTTP listen port", "HTTP listen port", nil),
        ("Certificate to serve HTTPS with.\nWithout it, the service serves HTTP.",
         "Certificate to serve HTTPS with. Without it, the service serves HTTP.", nil),
        ("Number of workers\n\nEach holds a database connection,\nso keep it below the pool size.\n\nRaise it when the queue grows.\n",
         "Number of workers", "Each holds a database connection,\nso keep it below the pool size.\n\nRaise it when the queue grows."),
        ("    /// Queue depth.\n    ///\n    /// Alert above 10.\n", "Queue depth.", "Alert above 10."),
        ("Grußtext für die Startseite\n\nZeigt «ça va» und 東京.", "Grußtext für die Startseite", "Zeigt «ça va» und 東京."),
        ("- first\n- second", "- first - second", nil),
    ] as [(String, String, String?)])
    func splits(text: String, description: String, details: String?) {
        let doc = DocText.split(text)
        #expect(doc.description == description)
        #expect(doc.details == details)
    }

    @Test func convertsDocC() {
        let doc = DocText.split("""
            Upstream timeout, in ``Duration`` units

            See ``Gateway/timeout`` and <doc:Configuring>, but not `` `code` `` or `in ``code`` spans`.

            # Choosing a value

            1. Measure the p99 latency.
            2. Add the retries:
               - one
               - two

            ```swift
            let t = ``NotConverted``
            ```

                indented ``code``

            - Note: Applies to retries.
            - Important: Not below 1s.
            - SeeAlso: ``LoadBalancer``
            - Parameter limit: Dropped: it documents a function,
              with its continuation.
            - Returns: Dropped too.
            - Throws: And this.

            > Warning: Read once, at boot.
            """)
        #expect(doc.description == "Upstream timeout, in `Duration` units")
        #expect(doc.details == """
            See `Gateway/timeout` and Configuring, but not `` `code` `` or `in ``code`` spans`.

            # Choosing a value

            1. Measure the p99 latency.
            2. Add the retries:
               - one
               - two

            ```swift
            let t = ``NotConverted``
            ```

                indented ``code``

            **Note:** Applies to retries.
            **Important:** Not below 1s.
            **See Also:** `LoadBalancer`

            > **Warning:** Read once, at boot.
            """)
    }

    @Test func exportsDetailsAfterTheDescription() throws {
        struct Svc: DocuconfConfig {
            @Env("workers", """
                Worker count

                Keep it below the pool size.
                """)
            var workers = 4
            @Env("queue", "Queue length per worker", .details("Per worker, *not* in total.")) var queue: Int?
            @Env("port", "HTTP listen port") var port = 8080
        }
        let text = try Contract.cue(for: Svc.self, name: "svc")
        #expect(text.contains("description: \"Worker count\"\n\t\t\tdetails: \"Keep it below the pool size.\"\n"), "\(text)")
        #expect(text.contains("description: \"Queue length per worker\"\n\t\t\tdetails: \"Per worker, *not* in total.\"\n"), "\(text)")
        #expect(!text.contains("description: \"HTTP listen port\"\n\t\t\tdetails:"), "\(text)")
        if case .failed(let output) = try CueVet.vet(text, package: "svc") { Issue.record("cue vet failed:\n\(output)") }
    }

    func problems<C: DocuconfConfig>(_ type: C.Type) -> [String] {
        do {
            _ = try Declaration(type)
            return []
        } catch let e as DeclarationError {
            return e.problems
        } catch {
            return ["unexpected \(error)"]
        }
    }

    @Test func detailsMistakes() {
        struct Blank: DocuconfConfig {
            @Env("blank", "Blank details", .details(" \n\t")) var blank = 1
        }
        #expect(problems(Blank.self) == ["BLANK: details must not be blank"])

        struct Long: DocuconfConfig {
            @Env("long", "Too much to say\n\n" + String(repeating: "日本", count: 2000) + "日") var long = 1
            @Env("enough", "Just enough to say\n\n" + String(repeating: "日本", count: 2000)) var enough = 1
        }
        #expect(problems(Long.self) == ["LONG: details are 4001 characters; details may have at most 4000"])

        struct Undescribed: DocuconfConfig {
            @Env("undescribed", "", .details("Details without a description.")) var undescribed = 1
        }
        #expect(problems(Undescribed.self) == ["UNDESCRIBED: description must be at least 5 characters"])

        struct BlankFile: DocuconfConfig {
            @FileInput("notes", "Release notes", path: "/etc/svc/notes/notes.txt", .details("\t")) var notes: TextFile?
        }
        #expect(problems(BlankFile.self) == ["notes: details must not be blank"])
    }

    @Test func contractFirstLoadsAndIgnoresDetails() throws {
        func contract(_ details: JSONValue) -> JSONValue {
            [
                "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "svc"],
                "vars": ["PORT": ["type": "int", "description": "HTTP listen port", "details": details, "default": 8080]],
            ]
        }
        let doc = try ContractDocument(contract: contract("Behind the mesh, keep the **default**.\n\n- one\n- two"))
        #expect(try doc.load(environment: [:])["PORT"] == .int(8080))
        for (details, want) in [
            (JSONValue.string(" \n"), "PORT: details must not be blank"),
            (.string(String(repeating: "日本", count: 2000) + "日"), "PORT: details are 4001 characters"),
            (.int(42), "PORT: details must be a string"),
        ] {
            #expect {
                try ContractDocument(contract: contract(details))
            } throws: { error in
                (error as? DeclarationError)?.problems.contains { $0.hasPrefix(want) } == true
            }
        }
    }
}
