#if SUDRF_QA_46
import Foundation
import os

/// Synchronous QA-only observations. Does not install or wait for runtime state.
enum Issue46Trace {
    private static let logger = Logger(subsystem: "ru.sudrf.qa.issue46", category: "cold-start")
    static func emit(_ event: String) {
        logger.notice("pid=\(ProcessInfo.processInfo.processIdentifier) uptime=\(ProcessInfo.processInfo.systemUptime) event=\(event, privacy: .public)")
    }
}
#endif
