import Foundation

/// Schedules stdio JSON-RPC work for `serve --mcp`.
///
/// Requests are parallel by default. A request can declare `params.dependsOn`
/// with another JSON-RPC id to run after that upstream request completes. The
/// transport still writes one complete response line at a time.
final class MCPServeSession {
    typealias Writer = @Sendable (String) -> Void

    private let server: MCPServer
    private let writer: Writer
    private let lock = NSLock()

    private var tasks: [String: Task<Void, Never>] = [:]
    private var dependents: [String: Set<String>] = [:]
    private var canceled: Set<String> = []
    private var completedBeforeRegistration: Set<String> = []

    init(server: MCPServer, writer: @escaping Writer) {
        self.server = server
        self.writer = writer
    }

    func receive(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }

        guard let request = JSONRPCCodec.decodeRequest(trimmed) else {
            write(.failure(id: .null, code: JSONRPCErrorCode.parseError, message: "Could not parse JSON-RPC request."))
            return
        }

        if request.isNotification {
            handleNotification(request)
            return
        }

        let id = request.id ?? .null
        let key = Self.key(for: id)
        let dependencyKey = request.params?["dependsOn"].map(Self.key(for:))
        let dependencyTask = register(key: key, dependencyKey: dependencyKey)

        let task = Task { [server, writer] in
            defer {
                self.complete(key)
            }
            if let dependencyTask {
                await dependencyTask.value
            }
            guard !Task.isCancelled else {
                return
            }
            guard !self.isCanceled(key) else {
                return
            }
            if let line = await server.handle(request: request), !Task.isCancelled {
                writer(line)
            }
        }

        setTask(task, for: key)
    }

    func finish() async {
        let active = snapshotTasks()
        for task in active {
            await task.value
        }
    }

    private func handleNotification(_ request: JSONRPCRequest) {
        guard request.method == "notifications/cancelled",
              let id = request.params?["requestId"] else {
            return
        }
        cancel(Self.key(for: id))
    }

    private func register(key: String, dependencyKey: String?) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard let dependencyKey else {
            return nil
        }
        dependents[dependencyKey, default: []].insert(key)
        return tasks[dependencyKey]
    }

    private func setTask(_ task: Task<Void, Never>, for key: String) {
        lock.lock()
        if completedBeforeRegistration.remove(key) == nil {
            tasks[key] = task
        }
        lock.unlock()
    }

    private func complete(_ key: String) {
        lock.lock()
        if tasks.removeValue(forKey: key) == nil {
            completedBeforeRegistration.insert(key)
        }
        dependents.removeValue(forKey: key)
        canceled.remove(key)
        lock.unlock()
    }

    private func cancel(_ key: String) {
        let toCancel = collectCancellationKeys(startingAt: key)
        for key in toCancel {
            task(for: key)?.cancel()
        }
    }

    private func collectCancellationKeys(startingAt key: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var result: [String] = []
        var stack = [key]
        while let current = stack.popLast() {
            guard !canceled.contains(current) else {
                continue
            }
            canceled.insert(current)
            result.append(current)
            stack.append(contentsOf: dependents[current] ?? [])
        }
        return result
    }

    private func task(for key: String) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[key]
    }

    private func isCanceled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled.contains(key)
    }

    private func snapshotTasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values)
    }

    private func write(_ response: JSONRPCResponse) {
        do {
            writer(try JSONRPCCodec.encode(response))
        } catch {
            writeError("mcp: could not encode response: \(error)")
        }
    }

    private static func key(for id: JSONValue) -> String {
        (try? id.compactLine()) ?? String(describing: id)
    }
}
