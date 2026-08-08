import Foundation

/// The result of one paste batch. Every emoji lands in exactly one bucket,
/// so a batch never fails as a unit and the UI can always report honestly.
/// All arrays hold Discord emoji IDs.
public struct DownloadOutcome: Equatable {
    public let added: [String]
    public let alreadyPresent: [String]
    /// Fetched but gone from Discord (404). Not retried — permanent.
    public let missing: [String]
    /// Fetched but failed validation even at the fallback size.
    public let unusable: [String]

    public init(added: [String], alreadyPresent: [String],
                missing: [String], unusable: [String]) {
        self.added = added
        self.alreadyPresent = alreadyPresent
        self.missing = missing
        self.unusable = unusable
    }

    public var isEmpty: Bool {
        added.isEmpty && alreadyPresent.isEmpty
            && missing.isEmpty && unusable.isEmpty
    }
}
