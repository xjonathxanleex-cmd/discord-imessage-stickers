import Network

/// A cheap pre-flight check so an offline paste isn't consumed for nothing.
///
/// `NWPathMonitor` reports its first real path *asynchronously*, via
/// `pathUpdateHandler`, some short time after `start(queue:)` is called —
/// there is no synchronous way to get an initial reading. Until that first
/// update arrives, we have no evidence either way about the connection, and
/// an unknown state is treated as online rather than offline: a false
/// "you're offline" would block a paste that would have worked, whereas a
/// false "online" costs nothing, because `EmojiDownloader` already records
/// every transport failure as a per-item result, so the truth still reaches
/// the user in the batch summary.
///
/// The practical consequence is that the very first paste in a process is
/// never blocked by this check, even if the device is genuinely offline —
/// that's the intended trade, not a bug. The only thing that ever produces
/// an "offline" verdict is a path update that has actually been delivered
/// with status `.unsatisfied`.
enum NetworkReachability {

    private static var latestStatus: NWPath.Status?

    /// Held in a static so the monitor outlives `started`. A local would be
    /// eligible for deallocation once that closure returned, and a deallocated
    /// monitor never delivers a path update — leaving `latestStatus` nil
    /// forever and turning this whole type into a constant `true`.
    private static let monitor = NWPathMonitor()

    /// Starts the monitor exactly once, no matter how many times or how
    /// concurrently `isLikelyOnline` is read. Swift guarantees `static let`
    /// initializers run at most once, lazily, and thread-safely, so this is
    /// used purely for its once-only side effect.
    private static let started: Void = {
        monitor.pathUpdateHandler = { path in
            latestStatus = path.status
        }
        monitor.start(queue: DispatchQueue(label: "NetworkReachability"))
    }()

    static var isLikelyOnline: Bool {
        _ = started
        guard let latestStatus else {
            // No path update has been delivered yet — we can't tell, so
            // don't block the paste.
            return true
        }
        return latestStatus != .unsatisfied
    }
}
