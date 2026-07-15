import OSLog

enum PerformanceSignposts {
    static let signposter = OSSignposter(
        logger: Logger(subsystem: "com.duongvt.MLingo", category: "performance")
    )
}
