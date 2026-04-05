import Foundation

/// Safari Content Blocker entry point for B-SAFE.
///
/// Reads blockerRules.json from the shared App Group container
/// (group.com.abbrachfeld.bsafe) and returns it to Safari.
/// The main app writes this file via ContentBlockerService whenever
/// settings change, then calls SFContentBlockerManager.reloadContentBlocker
/// to trigger this handler.
class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let url = existingRulesURL() ?? emptyRulesURL()

        guard let attachment = NSItemProvider(contentsOf: url) else {
            context.completeRequest(returningItems: [])
            return
        }

        let item = NSExtensionItem()
        item.attachments = [attachment]
        context.completeRequest(returningItems: [item])
    }

    // MARK: - Private

    /// Returns the rules file URL only if the file actually exists on disk.
    private func existingRulesURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.abbrachfeld.bsafe") else {
            return nil
        }
        let url = container.appendingPathComponent("blockerRules.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes a minimal empty JSON array and returns its URL.
    /// Used when no rules file exists yet — tells Safari to allow everything.
    private func emptyRulesURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsafe_empty_rules.json")
        try? "[]".data(using: .utf8)?.write(to: url)
        return url
    }
}
