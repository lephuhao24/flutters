import Foundation

struct SDKStorageItem: Identifiable, Sendable, Equatable {
    var id: String { version }
    let version: String
    let directory: String
    let logicalSize: UInt64
    let allocatedSize: UInt64?
    let isGlobal: Bool
    let registeredProjectReferenceCount: Int
    let discoveredProjectReferenceCount: Int
    let measurementIssue: String?

    init(version: String, directory: String, logicalSize: UInt64, allocatedSize: UInt64?, isGlobal: Bool,
         registeredProjectReferenceCount: Int, discoveredProjectReferenceCount: Int, measurementIssue: String? = nil) {
        self.version = version
        self.directory = directory
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.isGlobal = isGlobal
        self.registeredProjectReferenceCount = registeredProjectReferenceCount
        self.discoveredProjectReferenceCount = discoveredProjectReferenceCount
        self.measurementIssue = measurementIssue
    }

    var projectReferenceCount: Int { registeredProjectReferenceCount + discoveredProjectReferenceCount }
    var isCleanupCandidate: Bool { !isGlobal && projectReferenceCount == 0 }
    var measuredSize: UInt64 { allocatedSize ?? logicalSize }
}

struct SDKStorageAnalysis: Sendable, Equatable {
    let items: [SDKStorageItem]
    let storageWithoutKnownReferences: UInt64
    let potentialCleanupSpace: UInt64
    let allocatedSizeAvailable: Bool
    let measuredAt: Date

    var totalStorage: UInt64 { items.reduce(0) { Self.addingSaturating($0, $1.measuredSize) } }
    var referencedStorage: UInt64 { items.filter { $0.projectReferenceCount > 0 }.reduce(0) { Self.addingSaturating($0, $1.measuredSize) } }
    var installedSDKCount: Int { items.count }

    private static func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

struct SDKDirectoryUsage: Sendable, Equatable {
    let logicalSize: UInt64
    let allocatedSize: UInt64?
}

enum SDKStorageError: LocalizedError, Sendable {
    case missingDirectory(String)
    case unreadableDirectory(String, String)

    var errorDescription: String? {
        switch self {
        case .missingDirectory(let path): "SDK directory is missing: \(path)"
        case .unreadableDirectory(let path, let reason): "Cannot measure SDK directory at \(path): \(reason)"
        }
    }
}

enum SDKRemovalPolicy {
    static func blockReason(sdk: FlutterSDK?, operationActive: Bool) -> String? {
        guard !operationActive else { return "An FVM operation is active. Wait for it to finish before removing an SDK." }
        guard let sdk else { return "This SDK is no longer installed. Refresh SDKs and try again." }
        if sdk.isGlobal { return "\(sdk.name) is the global Flutter SDK. Set another version as global before removing it." }
        return nil
    }

    static func referenceWarning(sdk: FlutterSDK, registeredReferences: Int, discoveredReferences: Int) -> String? {
        if registeredReferences + discoveredReferences > 0 {
            return "\(sdk.name) is referenced by \(registeredReferences) registered and \(discoveredReferences) discovered projects. Removing it may break those projects until another SDK is selected."
        }
        return nil
    }
}
