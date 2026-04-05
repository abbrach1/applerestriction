import Foundation
import SafariServices

/// Safari Content Blocker Extension for B-SAFE.
///
/// Reads blockerRules.json from the shared App Group container
/// (group.com.abbrachfeld.bsafe) and returns it to Safari.
/// The main app writes this file via ContentBlockerService whenever
/// settings change, then calls SFContentBlockerManager.reloadContentBlocker
/// to trigger this handler.
class ActionRequestHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let attachment = NSItemProvider(
            contentsOf: rulesFileURL(),
            contentType: .json
        )

        if let attachment {
            let item = NSExtensionItem()
            item.attachments = [attachment]
            context.completeRequest(returningItems: [item])
        } else {
            // No rules file yet — return an empty array so Safari allows everything
            let emptyRules = "[]".data(using: .utf8)!
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty.json")
            try? emptyRules.write(to: tmp)
            let fallback = NSItemProvider(contentsOf: tmp, contentType: .json)
            let item = NSExtensionItem()
            item.attachments = fallback.map { [$0] } ?? []
            context.completeRequest(returningItems: [item])
        }
    }

    private func rulesFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.abbrachfeld.bsafe")?
            .appendingPathComponent("blockerRules.json")
    }
}
