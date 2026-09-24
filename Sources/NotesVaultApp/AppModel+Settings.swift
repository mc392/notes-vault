import Foundation
import NotesVaultCore

/// The device's own settings: retention, note fields, templates and the lock policy.
///
/// All four live in `UserDefaults`, as JSON, and none of them is written to the vault —
/// they describe how this device behaves, not anything about a client.
extension AppModel {
    static let retentionKey = "retention.policy"
    static let noteFieldsKey = "note.fields"
    static let noteTemplatesKey = "note.templates"
    static let lockPolicyKey = "lock.policy"

    /// Reads every stored setting over its default. A setting that is missing or will not
    /// decode keeps the default rather than failing the launch.
    func loadSettings() {
        if let stored = Self.loadSetting(RetentionPolicy.self, key: Self.retentionKey) {
            retentionPolicy = stored
        }
        // Normalised so a built-in added in a later version appears for someone who has
        // already saved their settings once.
        if let stored = Self.loadSetting(NoteFieldSettings.self, key: Self.noteFieldsKey) {
            noteFields = stored.normalised()
        }
        if let stored = Self.loadSetting(NoteTemplateSettings.self, key: Self.noteTemplatesKey) {
            noteTemplates = stored.normalised()
        }
        if let stored = Self.loadSetting(LockPolicy.self, key: Self.lockPolicyKey) {
            lockPolicy = stored
        }
    }

    static func loadSetting<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func saveSetting<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
