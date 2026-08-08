import Network

/// A cheap pre-flight check so an offline paste isn't consumed for nothing.
///
/// Deliberately lenient: anything other than a definite `.unsatisfied` counts
/// as online. A false "you're offline" would block a paste that would have
/// worked, whereas a false "online" costs nothing — `EmojiDownloader` already
/// records every transport failure as a per-item result, so the truth still
/// reaches the user in the summary.
enum NetworkReachability {

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "NetworkReachability"))
        return monitor
    }()

    static var isLikelyOnline: Bool {
        monitor.currentPath.status != .unsatisfied
    }
}
