import RestoreyCore

/// Writes a plan's submitted secrets so that they can be undone: the keychain's current value for
/// every submitted key is read first, and `restore` puts those values back (deleting keys that did not
/// exist before). Errors name the keychain account, never a value.
struct PlanSecrets {
    let store: any SecretStore
    /// The value each submitted key had before the write; nil when the key did not exist.
    private(set) var previous: [SecretKey: String?] = [:]
    private let entries: [SecretEntry]
    /// Keys to remove, such as the check-in URL of a plan saved without one. Not counted as a change by
    /// `changesAnyValue`.
    private let deletions: [SecretKey]

    /// Reads the current value of every submitted or deleted key. Nothing is written if any read fails,
    /// since the write could not then be undone.
    init(store: any SecretStore, entries: [SecretEntry], deletions: [SecretKey] = []) throws {
        self.store = store
        self.entries = entries
        self.deletions = deletions
        for key in entries.map(\.key) + deletions where previous.index(forKey: key) == nil {
            do {
                previous[key] = .some(try store.read(key))
            } catch {
                throw AgentError.storage("Restorey couldn't read \(key.account) from the Keychain: \(error)")
            }
        }
    }

    /// True when any submitted value differs from what the keychain holds (including a new key).
    var changesAnyValue: Bool {
        entries.contains { entry in changes(entry) }
    }

    /// True when a value is submitted for `key` and differs from what the keychain holds.
    func changesValue(of key: SecretKey) -> Bool {
        entries.contains { $0.key == key && changes($0) }
    }

    private func changes(_ entry: SecretEntry) -> Bool {
        let old: String? = previous[entry.key] ?? nil
        return old != entry.value
    }

    /// Writes every entry, then removes every deletion. If one fails, everything already changed is
    /// restored before throwing.
    func write() throws {
        for entry in entries {
            do {
                try store.write(entry.value, for: entry.key)
            } catch {
                let failure = "Restorey couldn't save \(entry.key.account) in the Keychain: \(error)"
                throw AgentError.storage(failure + Self.describe(restore()))
            }
        }
        for key in deletions where (previous[key] ?? nil) != nil {
            do {
                try store.delete(key)
            } catch {
                let failure = "Restorey couldn't remove \(key.account) from the Keychain: \(error)"
                throw AgentError.storage(failure + Self.describe(restore()))
            }
        }
    }

    /// Puts every submitted key back as it was. Returns the accounts that could not be restored.
    @discardableResult
    func restore() -> [String] {
        var failures: [String] = []
        for (key, value) in previous {
            do {
                if let value { try store.write(value, for: key) } else { try store.delete(key) }
            } catch {
                failures.append(key.account)
            }
        }
        return failures.sorted()
    }

    /// The suffix for an error message when a restore left something behind.
    static func describe(_ restoreFailures: [String]) -> String {
        restoreFailures.isEmpty
            ? ""
            : ". Restorey also couldn't put back the previous \(restoreFailures.joined(separator: ", "))"
    }
}
