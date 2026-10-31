import Foundation

/// The app was called Azeroth Survivors (`io.github.matguitarist.azeroth-survivors`) up to 0.7.3.
/// Its first start as Hearthside takes over the old preferences, Application Support folder (the
/// game data, its settings, the server on this Mac) and logs, once.
enum Migration {
    static let oldName = "Azeroth Survivors"
    static let oldDomain = "io.github.matguitarist.azeroth-survivors"
    private static let doneKey = "migratedFromAzerothSurvivors"

    /// Runs before anything reads a preference or a folder.
    @discardableResult
    static func run() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return false }
        defaults.set(true, forKey: doneKey)
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let oldSupport = library.appendingPathComponent("Application Support/\(oldName)", isDirectory: true)
        let oldLogs = library.appendingPathComponent("Logs/\(oldName)", isDirectory: true)
        move(oldSupport, to: Paths.support)
        move(oldLogs, to: Paths.logs)

        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                // A path into the old folder follows it to the new one.
                if let path = value as? String, path.hasPrefix(oldSupport.path) {
                    defaults.set(Paths.support.path + path.dropFirst(oldSupport.path.count), forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        }
        return true
    }

    private static func move(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: from, to: to)
    }
}
