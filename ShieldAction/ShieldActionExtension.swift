import ManagedSettings
@preconcurrency import ManagedSettingsUI

class ShieldActionExtension: ShieldActionDelegate {

    nonisolated override init() {
        super.init()
    }

    nonisolated override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:   completionHandler(.close)
        case .secondaryButtonPressed: completionHandler(.defer)
        @unknown default:             completionHandler(.close)
        }
    }

    nonisolated override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:   completionHandler(.close)
        case .secondaryButtonPressed: completionHandler(.defer)
        @unknown default:             completionHandler(.close)
        }
    }

    nonisolated override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:   completionHandler(.close)
        case .secondaryButtonPressed: completionHandler(.defer)
        @unknown default:             completionHandler(.close)
        }
    }
}
