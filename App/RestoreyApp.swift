import AppKit
import RestoreyCore
import SwiftUI
#if DEBUG
import ServiceManagement
#endif

@main
struct RestoreyApp: App {
    init() {
        #if DEBUG
        TemporaryDebugArguments.handle(CommandLine.arguments)
        #endif
    }

    var body: some Scene {
        MenuBarExtra("Restorey", systemImage: "externaldrive.badge.timemachine") {
            Text("Restorey")
            Divider()
            Button("Quit Restorey") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

#if DEBUG
/// Temporary Debug-only launch arguments for checking the agent by hand before the app shell exists
/// (Ruling R3). Task 17 replaces them with real registration and the heartbeat, and removes this.
///
/// - `--register`: registers the embedded agent with `SMAppService`, prints the result and exits.
/// - `--hello`: sends one `hello` and one `status` to the agent over XPC, prints the replies and exits.
enum TemporaryDebugArguments {
    static func handle(_ arguments: [String]) {
        let wantsRegister = arguments.contains("--register")
        let wantsHello = arguments.contains("--hello")
        guard wantsRegister || wantsHello else { return }
        let identity: Identity
        do {
            identity = try Identity.fromBundle(.main)
        } catch {
            print("Can't read the identity from Info.plist: \(error)")
            exit(1)
        }
        if wantsRegister { register(identity) }
        if wantsHello { hello(identity) }
        exit(0)
    }

    private static func register(_ identity: Identity) {
        let service = SMAppService.agent(plistName: "\(identity.agentLabel).plist")
        do {
            try service.register()
            print("register() succeeded")
        } catch {
            print("register() failed: \(error)")
        }
        print("SMAppService status: \(describe(service.status))")
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    private static func hello(_ identity: Identity) {
        let connection = NSXPCConnection(machServiceName: identity.agentLabel, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
        connection.resume()
        defer { connection.invalidate() }

        let info = Bundle.main.infoDictionary ?? [:]
        let request = HelloRequest(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown")
        guard let requestData = try? XPCCoding.encode(request) else {
            print("Couldn't encode the hello request")
            return
        }
        call("hello", connection) { agent, reply in agent.hello(requestData, withReply: reply) }
        call("status", connection) { agent, reply in agent.status(withReply: reply) }
    }

    /// Makes one call and waits up to 10 s for its reply or an XPC error.
    private static func call(
        _ name: String, _ connection: NSXPCConnection,
        _ send: (AgentXPC, @escaping @Sendable (Data?, String?) -> Void) -> Void
    ) {
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("\(name): XPC error: \(error)")
            done.signal()
        }
        guard let agent = proxy as? AgentXPC else {
            print("\(name): no proxy")
            return
        }
        send(agent) { data, error in
            if let data {
                print("\(name): \(String(decoding: data, as: UTF8.self))")
            } else {
                print("\(name): error: \(error ?? "none")")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut { print("\(name): timed out after 10 s") }
    }
}
#endif
