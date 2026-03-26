import Foundation

/// Platform-aware type aliases so views don't need #if checks everywhere
#if targetEnvironment(simulator)
typealias ActiveAuthorizationManager = MockAuthorizationManager
typealias ActiveScreenTimeSettingsManager = MockScreenTimeSettingsManager
#else
typealias ActiveAuthorizationManager = AuthorizationManager
typealias ActiveScreenTimeSettingsManager = ScreenTimeSettingsManager
#endif
