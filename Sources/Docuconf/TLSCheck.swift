#if TLS
import DocuconfCore
import Foundation
import SwiftASN1
import X509

/// Boot checks for a `kubernetes.io/tls` key pair, with swift-certificates (SPEC §11.2 item 7).
enum TLSCheck {
    static func check(_ spec: FileSpec, directory: String, now: Date) async -> Checked<LoadedFile> {
        let name = spec.name
        var violations: [Violation] = []
        var files: [String: Data] = [:]
        for file in ["tls.crt", "tls.key"] + (spec.requireCA ? ["ca.crt"] : []) {
            let path = directory + "/" + file
            guard FileManager.default.fileExists(atPath: path) else {
                violations.append(Violation(.fileMissing, name, "\(path) does not exist"))
                continue
            }
            do {
                files[file] = try FileLoader.readFile(path)
            } catch let v as Violation {
                violations.append(v.with(input: name))
            } catch {
                violations.append(Violation(.fileUnreadable, name, "\(path) could not be read"))
            }
        }
        if !spec.requireCA, FileManager.default.fileExists(atPath: directory + "/ca.crt") {
            files["ca.crt"] = try? FileLoader.readFile(directory + "/ca.crt")
        }
        guard violations.isEmpty, let certData = files["tls.crt"], let keyData = files["tls.key"] else {
            return .failure(violations)
        }

        let chain: [Certificate]
        switch PEM.certificates(in: certData) {
        case .failure(let problems):
            return .failure([Violation(problems[0].code, name, "tls.crt \(problems[0].message)")])
        case .success(let certs):
            // SPEC §11.2 item 5: a file with no PEM certificate at all is file_malformed.
            guard !certs.isEmpty else { return .failure([Violation(.fileMalformed, name, "tls.crt holds no PEM certificate")]) }
            chain = certs
        }
        let leaf = chain[0]

        // The key: parse it and check it belongs to the certificate. Never print it.
        if let keyText = String(data: keyData, encoding: .utf8), let key = try? Certificate.PrivateKey(pemEncoded: keyText) {
            if key.publicKey != leaf.publicKey {
                violations.append(Violation(.keyMismatch, name, "tls.key is not the private key for the certificate in tls.crt"))
            }
        } else if let keyText = String(data: keyData, encoding: .utf8), (try? PEMDocument.parseMultiple(pemString: keyText))?.isEmpty == false {
            violations.append(Violation(.keyMismatch, name, "tls.key is not a PEM private key this SDK can read (PKCS#8, SEC1 or PKCS#1)"))
        } else {
            violations.append(Violation(.fileMalformed, name, "tls.key holds no PEM private key"))
        }

        // Validity, and enough of it left.
        let stamp = ISO8601DateFormatter()
        var timeValid = true
        if now < leaf.notValidBefore {
            timeValid = false
            violations.append(Violation(.certificateInvalid, name, "the certificate is not valid until \(stamp.string(from: leaf.notValidBefore))"))
        } else if now > leaf.notValidAfter {
            timeValid = false
            violations.append(Violation(.certificateInvalid, name, "the certificate expired at \(stamp.string(from: leaf.notValidAfter))"))
        } else if let minRemaining = spec.minRemaining {
            let left = leaf.notValidAfter.timeIntervalSince(now)
            let needed = Double(GoDuration.nanoseconds(minRemaining)) / 1e9
            if left < needed {
                violations.append(Violation(.certificateExpiring, name,
                    "the certificate expires at \(stamp.string(from: leaf.notValidAfter)), sooner than the required \(GoDuration.format(minRemaining)) from now"))
            }
        }

        // Names.
        if let wanted = spec.dnsNames {
            let sans = dnsNames(of: leaf)
            for host in wanted where !covers(sans, host) {
                violations.append(Violation(.certificateNameMismatch, name, "the certificate does not cover \(host)" + (sans.isEmpty ? " (it has no DNS subject alternative names)" : "")))
            }
        }

        // Key algorithm.
        let algorithm = keyAlgorithm(of: leaf)
        if let allowed = spec.keyAlgorithms, !allowed.isEmpty {
            if algorithm.map({ !allowed.contains($0) }) ?? true {
                violations.append(Violation(.certificateInvalid, name,
                    "the certificate uses a \(algorithm?.rawValue ?? "unsupported") key; allowed: \(allowed.map(\.rawValue).joined(separator: ", "))"))
            }
        }

        // Chain to ca.crt.
        if spec.requireCA, timeValid, let caData = files["ca.crt"] {
            switch PEM.certificates(in: caData) {
            case .failure(let problems):
                violations.append(Violation(problems[0].code, name, "ca.crt \(problems[0].message)"))
            case .success(let roots) where roots.isEmpty:
                violations.append(Violation(.fileMalformed, name, "ca.crt holds no PEM certificate"))
            case .success(let roots):
                var verifier = Verifier(rootCertificates: CertificateStore(roots)) {
                    RFC5280Policy()  // validates expiry against the system clock
                }
                let result = await verifier.validate(leaf: leaf, intermediates: CertificateStore(chain.dropFirst()))
                if case .couldNotValidate = result {
                    violations.append(Violation(.certificateInvalid, name, "the certificate does not chain to a certificate in ca.crt"))
                }
            }
        }

        if !violations.isEmpty { return .failure(violations) }
        return .success(LoadedFile(path: directory, data: certData, keyData: keyData, caData: files["ca.crt"]))
    }

    static func dnsNames(of cert: Certificate) -> [String] {
        guard let sans = try? cert.extensions.subjectAlternativeNames else { return [] }
        return sans.compactMap { if case .dnsName(let n) = $0 { n } else { nil } }
    }

    /// Whether the certificate's names cover `host`. A wildcard (`*.example.com`) covers exactly one label.
    static func covers(_ names: [String], _ host: String) -> Bool {
        let h = host.lowercased()
        return names.contains { raw in
            let n = raw.lowercased()
            if n == h { return true }
            if n.hasPrefix("*."), let dot = h.firstIndex(of: ".") {
                let label = h[..<dot]
                return !label.isEmpty && h[h.index(after: dot)...] == n.dropFirst(2)
            }
            return false
        }
    }

    static let rsaOID: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 1]
    static let ecOID: ASN1ObjectIdentifier = [1, 2, 840, 10045, 2, 1]
    static let ed25519OID: ASN1ObjectIdentifier = [1, 3, 101, 112]

    /// The certificate's key algorithm, from the algorithm identifier in its SubjectPublicKeyInfo.
    static func keyAlgorithm(of cert: Certificate) -> KeyAlgorithm? {
        var serializer = DER.Serializer()
        guard (try? serializer.serialize(cert.publicKey)) != nil,
            let root = try? DER.parse(serializer.serializedBytes),
            case .constructed(let spki) = root.content,
            let algorithmNode = spki.first(where: { _ in true }),
            case .constructed(let algorithm) = algorithmNode.content,
            let oidNode = algorithm.first(where: { _ in true }),
            let oid = try? ASN1ObjectIdentifier(derEncoded: oidNode)
        else { return nil }
        switch oid {
        case rsaOID: return .rsa
        case ecOID: return .ecdsa
        case ed25519OID: return .ed25519
        default: return nil
        }
    }
}
#endif
