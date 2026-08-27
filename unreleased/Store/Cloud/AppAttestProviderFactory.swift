import FirebaseAppCheck
import FirebaseCore
import DeviceCheck
import Foundation

/// Supplies App Check with an App Attest provider, falling back to DeviceCheck.
///
/// App Attest needs iOS 14+ and real hardware; DeviceCheck covers the rest so a
/// simulator or an unsupported device still produces a token instead of failing
/// every request once enforcement is switched on.
final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if DCAppAttestService.shared.isSupported,
           let provider = AppAttestProvider(app: app) {
            return provider
        }
        return DeviceCheckProvider(app: app)
    }
}
