import Foundation
import UIKit

struct DeviceInfo: Codable, Identifiable {
    var id: String
    var name: String
    var model: String
    var osVersion: String
    var lastSeen: Date
    var isOnline: Bool

    static var current: DeviceInfo {
        DeviceInfo(
            id: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
            name: UIDevice.current.name,
            model: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion,
            lastSeen: Date(),
            isOnline: true
        )
    }
}
