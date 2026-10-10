import DocuconfCore
import Foundation

/// A change seen while watching a file input.
public enum FileChange<Value: Sendable>: Sendable {
    /// New content that passed every check. The property now returns it too.
    case updated(Value)
    /// New content that failed a check. The property keeps returning the last good value.
    case rejected([Violation])
}

/// The reload state of one file input (SPEC §4.6.2), for a health check or a metric. It never holds file content.
///
/// It is `Codable`; encode it with a `JSONEncoder` whose `dateEncodingStrategy` is `.iso8601` for readable times.
public struct ReloadStatus: Sendable, Hashable, Codable {
    /// 1 after boot, plus one for each accepted reload; 0 for an optional input that was absent at boot (or before
    /// ``Docuconf/load(_:from:options:)`` has loaded the input).
    public var generation: Int
    /// When the last reload was accepted, or `nil` if there has been none since boot.
    public var lastReload: Date?
    /// The last change that failed its checks and was not used, or `nil`. A later accepted reload clears it.
    public var lastRejected: RejectedReload?

    public init(generation: Int, lastReload: Date? = nil, lastRejected: RejectedReload? = nil) {
        self.generation = generation
        self.lastReload = lastReload
        self.lastRejected = lastRejected
    }
}

/// A changed file input that failed its checks, so the previous value stayed current. It names the violation
/// codes, never the content.
public struct RejectedReload: Sendable, Hashable, Codable {
    public var time: Date
    /// The input's contract name.
    public var input: String
    /// The violation codes, without duplicates, in the order they were found.
    public var codes: [ViolationCode]

    public init(time: Date, input: String, codes: [ViolationCode]) {
        self.time = time
        self.input = input
        self.codes = codes
    }
}

/// A registration made with ``FileInputHandle/onChange(every:_:)`` or by iterating
/// ``FileInputHandle/changes(every:)``. Call ``cancel()`` to unregister; it is safe to call more than once.
///
/// Dropping the subscription does **not** cancel it, so a hook meant to run for the life of the process needs no
/// variable.
public final class ReloadSubscription: @unchecked Sendable, Hashable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Unregisters the hook. When no hook or stream is left on the input, its background check stops.
    public func cancel() {
        let action = lock.withLock {
            defer { onCancel = nil }
            return onCancel
        }
        action?()
    }

    public static func == (a: ReloadSubscription, b: ReloadSubscription) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension FileInputHandle {
    /// Registers `hook`, called with the new value each time a changed input passes every check it passed at boot
    /// (SPEC §4.6.2). It is never called for a change that fails them; that change is logged (input name and
    /// violation codes) through ``LoadOptions/warn`` and shows in ``reloadStatus``.
    ///
    /// Hooks are called from a background task that checks the input every `interval` while at least one hook (or a
    /// ``changes(every:)`` stream) is registered; with several, the shortest interval wins. The property already
    /// returns the new value when the hooks run. Hooks on one input run one at a time, in the order they were
    /// registered. A hook that throws is logged by input name and error type only, and the other hooks still run.
    ///
    /// Use it to rebuild what the app made from the value, such as an HTTP client that copied a CA bundle:
    ///
    /// ```swift
    /// config.$trustedCAs.onChange { bundle in
    ///     client.replace(trusting: bundle.certificates)
    /// }
    /// ```
    ///
    /// - Returns: A subscription; ``ReloadSubscription/cancel()`` unregisters the hook. Before
    ///   ``Docuconf/load(_:from:options:)`` has loaded the input, the hook is not registered and the subscription
    ///   does nothing.
    @discardableResult
    public func onChange(
        every interval: Duration = .seconds(10), _ hook: @escaping @Sendable (Value.Base) async throws -> Void
    ) -> ReloadSubscription {
        guard let reloader else { return ReloadSubscription {} }
        let name = spec.name
        let warn = reloader.context.options.warn
        let id = reloader.subscribe(interval: interval, apply: applier) { event in
            guard case .updated(let any) = event, let value = (any as? Value)?.base else { return }
            do {
                try await hook(value)
            } catch {
                warn("on-change hook for file input \(name) threw \(String(reflecting: type(of: error)))")
            }
        }
        return ReloadSubscription { [reloader] in reloader.unsubscribe(id) }
    }

    /// The input's reload status: its generation, when the last reload was accepted, and the last rejected change.
    public var reloadStatus: ReloadStatus {
        reloader?.status ?? ReloadStatus(generation: 0)
    }

    /// Checks the input every `interval` and yields each change, for inputs declared with `.reload(.watch)`
    /// (SPEC §4.6.2).
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
    /// The stream shares one background check with ``onChange(every:_:)`` hooks, so a change is applied once and
    /// seen by every hook and stream. It ends when the iterating task is cancelled. It yields nothing before
    /// ``Docuconf/load(_:from:options:)`` has loaded the input.
    public func changes(every interval: Duration = .seconds(10)) -> AsyncStream<FileChange<Value>> {
        let (stream, continuation) = AsyncStream<FileChange<Value>>.makeStream()
        guard let reloader else {
            continuation.finish()
            return stream
        }
        let id = reloader.subscribe(interval: interval, apply: applier) { event in
            switch event {
            case .updated(let any):
                if let value = any as? Value { continuation.yield(.updated(value)) }
            case .rejected(let violations):
                continuation.yield(.rejected(violations))
            }
        }
        continuation.onTermination = { [reloader] _ in reloader.unsubscribe(id) }
        return stream
    }

    var reloader: FileReloader? { state.value?.context as? FileReloader }

    /// Stores a checked file as this input's value.
    private var applier: @Sendable (LoadedFile, any StructuredDecoding) throws -> any Sendable {
        let handle = self
        return { file, decoders in try handle.store(file, decoders: decoders) }
    }
}

/// What a reload produced, before it is typed for a hook or a stream.
enum ReloadEvent: Sendable {
    case updated(any Sendable)
    case rejected([Violation])
}

/// The reload state of one loaded file input: where it was read, the fingerprint of the content in use, its status,
/// and the hooks and streams that follow it. One background task checks the input while anything is subscribed.
final class FileReloader: @unchecked Sendable {
    let spec: FileSpec
    let path: String
    /// The boot settings, including the keystore password read at boot: a reload never reads the environment again.
    let context: FileReloadContext

    private struct Subscriber {
        var interval: Duration
        var deliver: @Sendable (ReloadEvent) async -> Void
    }

    private let lock = NSLock()
    private var last: [UInt64]?
    private var current = ReloadStatus(generation: 0)
    private var subscribers: [Int: Subscriber] = [:]
    private var nextID = 0
    private var task: Task<Void, Never>?
    private var apply: (@Sendable (LoadedFile, any StructuredDecoding) throws -> any Sendable)?

    init(spec: FileSpec, path: String, context: FileReloadContext) {
        self.spec = spec
        self.path = path
        self.context = context
    }

    /// Records the content checked at boot: generation 1.
    func booted() {
        let fp = Self.fingerprint(spec, path)
        lock.withLock {
            last = fp
            current.generation = 1
        }
    }

    var status: ReloadStatus { lock.withLock { current } }

    func subscribe(
        interval: Duration, apply: @escaping @Sendable (LoadedFile, any StructuredDecoding) throws -> any Sendable,
        deliver: @escaping @Sendable (ReloadEvent) async -> Void
    ) -> Int {
        lock.withLock {
            let id = nextID
            nextID += 1
            subscribers[id] = Subscriber(interval: interval, deliver: deliver)
            if self.apply == nil { self.apply = apply }
            if task == nil {
                task = Task { [weak self] in await self?.run() }
            }
            return id
        }
    }

    func unsubscribe(_ id: Int) {
        lock.withLock {
            subscribers[id] = nil
            if subscribers.isEmpty {
                task?.cancel()
                task = nil
            }
        }
    }

    /// Checks the input every interval until nothing is subscribed.
    private func run() async {
        while !Task.isCancelled {
            guard let interval = lock.withLock({ subscribers.values.map(\.interval).min() }) else { return }
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            guard let event = await check() else { continue }
            let targets = lock.withLock { subscribers.sorted { $0.key < $1.key }.map(\.value.deliver) }
            for deliver in targets { await deliver(event) }
        }
    }

    /// Re-reads the input if its content changed, and applies it if it passes every boot check.
    func check() async -> ReloadEvent? {
        let fp = Self.fingerprint(spec, path)
        let apply: (@Sendable (LoadedFile, any StructuredDecoding) throws -> any Sendable)? = lock.withLock {
            guard let apply = self.apply, fp != last else { return nil }
            last = fp
            return apply
        }
        guard let apply else { return nil }
        if fp == nil {
            guard spec.required else { return nil }
            return reject([Violation(.fileMissing, spec.name, "\(path) disappeared")])
        }
        switch await FileLoader.check(spec, at: path, context: context) {
        case .failure(let violations):
            return reject(violations)
        case .success(let file):
            let value: any Sendable
            do {
                value = try apply(file, context.options.decoders)
            } catch let e as ValueConversionError {
                return reject([FileLoader.violation(e, spec)])
            } catch {
                return reject([Violation(.fileMalformed, spec.name, "could not be loaded")])
            }
            let now = Date()
            lock.withLock {
                current.generation += 1
                current.lastReload = now
                current.lastRejected = nil
            }
            return .updated(value)
        }
    }

    private func reject(_ violations: [Violation]) -> ReloadEvent {
        var codes: [ViolationCode] = []
        for v in violations where !codes.contains(v.code) { codes.append(v.code) }
        let rejected = RejectedReload(time: Date(), input: spec.name, codes: codes)
        lock.withLock { current.lastRejected = rejected }
        context.options.warn("file input \(spec.name) changed but failed its checks (\(codes.map(\.rawValue).joined(separator: ", "))); keeping the previous value")
        return .rejected(violations)
    }

    /// A fingerprint of everything the input reads, or `nil` if it is missing: each path, its size and a 64-bit
    /// FNV-1a hash of its content. It only has to notice a change between two polls, so it needs no crypto.
    static func fingerprint(_ spec: FileSpec, _ path: String) -> [UInt64]? {
        let paths = spec.type == .tls ? ["tls.crt", "tls.key", "ca.crt"].map { path + "/" + $0 } : [path]
        var out: [UInt64] = []
        for p in paths {
            guard let data = FileManager.default.contents(atPath: p) else { continue }
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in Array(p.utf8) + [0] + Array(data) {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            out += [hash, UInt64(data.count)]
        }
        return out.isEmpty ? nil : out
    }
}
