import Combine
import PindoCore

/// The retired provider must never resume a saved connection on launch. Legacy
/// credentials, journals, replicas and frozen outboxes stay untouched for recovery.
/// Cloudflare activation belongs to the SQLite/connection-transaction milestone.
@MainActor final class CloudSyncController: ObservableObject {
    let isConfigured = false
    init(model: AppModel) {}
    func start() {}
    func documentDidChange() {}
    func editingDidBegin() {}
    func editingDidEnd() {}
}
