import Crypto
import DocuconfCore
import Foundation

/// A change seen while watching a file input.
public enum FileChange<Value: Sendable>: Sendable {
    /// New content that passed every check. The property now returns it too.
    case updated(Value)
    /// New content that failed a check. The property keeps returning the last good value.
    case rejected([Violation])
}

extension FileInputHandle {
    /// Polls the input and yields each change, for inputs declared with `.reload(.watch)` (SPEC §4.6.2).
    ///
    /// Kubernetes updates a mounted Secret or ConfigMap by swapping a symlink, so docuconf re-reads every
    /// file of the input together (for TLS: `tls.crt`, `tls.key` and `ca.crt`) and compares a digest of
    /// their content. New content goes through the same checks as at boot; content that fails is reported
    /// and not applied. Iterate the stream in your service's task group:
    ///
    /// ```swift
    /// for await change in config.$routes.changes(every: .seconds(10)) {
    ///     if case .updated(let routes) = change { router.replace(routes.value) }
    /// }
    /// ```
    ///
    /// The stream ends when the iterating task is cancelled. It yields nothing before
    /// ``Docuconf/load(_:from:options:)`` has loaded the input.
    public func changes(every interval: Duration = .seconds(10)) -> AsyncStream<FileChange<Value>> {
        let handle = self
        let (stream, continuation) = AsyncStream<FileChange<Value>>.makeStream()
        guard let state = handle.state.value, let context = state.context as? FileReloadContext else {
            continuation.finish()
            return stream
        }
        // Taken now, so a change made right after this call is seen.
        let initial = Self.fingerprint(handle.spec, state.path)
        do {
            let task = Task {
                var last = initial
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    let current = Self.fingerprint(handle.spec, state.path)
                    guard current != last else { continue }
                    last = current
                    if current == nil {
                        if handle.spec.required {
                            continuation.yield(.rejected([Violation(.fileMissing, handle.spec.name, "\(state.path) disappeared")]))
                        }
                        continue
                    }
                    switch await FileLoader.check(handle.spec, at: state.path, context: context) {
                    case .failure(let violations):
                        continuation.yield(.rejected(violations))
                    case .success(let file):
                        do {
                            continuation.yield(.updated(try handle.store(file, decoders: context.options.decoders)))
                        } catch let e as ValueConversionError {
                            continuation.yield(.rejected([FileLoader.violation(e, handle.spec)]))
                        } catch {
                            continuation.yield(.rejected([Violation(.fileMalformed, handle.spec.name, "could not be loaded")]))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return stream
    }

    /// A digest of everything the input reads, or `nil` if it is missing.
    static func fingerprint(_ spec: FileSpec, _ path: String) -> [UInt8]? {
        let paths = spec.type == .tls ? ["tls.crt", "tls.key", "ca.crt"].map { path + "/" + $0 } : [path]
        var hasher = SHA256()
        var any = false
        for p in paths {
            guard let data = FileManager.default.contents(atPath: p) else { continue }
            any = true
            hasher.update(data: Array(p.utf8) + [0])
            hasher.update(data: data)
        }
        return any ? Array(hasher.finalize()) : nil
    }
}
