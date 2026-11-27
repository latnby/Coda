import Foundation

/// All persistent state is scoped to an installation's product identity.
/// Unit-test executables do not carry our Info.plist, so they use the release namespace.
enum CodaIdentity {
    static let releaseBundleIdentifier = "wow.caicai.coda"
    static let developmentBundleIdentifier = releaseBundleIdentifier + ".dev"

    static func namespace(for bundleIdentifier: String?) -> String {
        bundleIdentifier == developmentBundleIdentifier ? developmentBundleIdentifier : releaseBundleIdentifier
    }

    static var namespace: String { namespace(for: Bundle.main.bundleIdentifier) }
    static var syncDirectoryName: String { namespace == developmentBundleIdentifier ? "Coda Dev" : "Coda" }
    static func keychainService(_ purpose: String) -> String { namespace + "." + purpose }
    static var releaseRepository: String {
        Bundle.main.object(forInfoDictionaryKey: "CodaReleaseRepository") as? String ?? "latnby/Coda"
    }
}
