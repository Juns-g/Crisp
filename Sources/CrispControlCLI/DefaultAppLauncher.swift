import AppKit

public struct DefaultCrispAppLauncher: AppLaunching {
    public init() {}

    public func launch() throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.crisp.app") else {
            throw LauncherError.notFound
        }
        guard applicationURL.pathExtension == "app",
              Bundle(url: applicationURL)?.bundleIdentifier == "com.crisp.app" else {
            throw LauncherError.untrustedBundle
        }
        guard NSWorkspace.shared.open(applicationURL) else { throw LauncherError.launchFailed }
    }
}
