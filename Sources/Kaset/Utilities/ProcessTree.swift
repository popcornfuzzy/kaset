import Darwin
import Foundation

// MARK: - ProcessTree

/// Read-only helpers for inspecting the running process tree.
///
/// WebKit plays audio from helper processes that the app spawns, so capturing Kaset's own audio
/// means tapping those helpers as well as the app itself.
enum ProcessTree {
    /// A running process.
    struct Entry: Equatable, Sendable {
        /// Process identifier.
        let pid: pid_t

        /// Identifier of the parent process.
        let parentPID: pid_t

        /// Short executable name reported by the kernel.
        let name: String
    }

    /// Every process the current user can see.
    static func entries() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0

        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The process list can grow between the sizing call and the read, so leave headroom.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)

        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = min(size / MemoryLayout<kinfo_proc>.stride, buffer.count)

        return buffer.prefix(count).map { process in
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { rawName -> String in
                guard let base = rawName.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }

            return Entry(
                pid: process.kp_proc.p_pid,
                parentPID: process.kp_eproc.e_ppid,
                name: name
            )
        }
    }

    /// Every descendant of `rootPID`, breadth first.
    ///
    /// - Parameter rootPID: Process whose children should be collected.
    /// - Parameter matching: Optional filter applied to each descendant's executable name.
    static func descendantProcessIDs(
        of rootPID: pid_t,
        matching: ((String) -> Bool)? = nil
    ) -> [pid_t] {
        let all = self.entries()
        var childrenByParent: [pid_t: [Entry]] = [:]
        for entry in all {
            childrenByParent[entry.parentPID, default: []].append(entry)
        }

        var result: [pid_t] = []
        var queue: [pid_t] = [rootPID]
        var visited: Set<pid_t> = [rootPID]

        while let parent = queue.first {
            queue.removeFirst()

            for child in childrenByParent[parent] ?? [] {
                guard !visited.contains(child.pid) else { continue }
                visited.insert(child.pid)
                queue.append(child.pid)

                if let matching, !matching(child.name) {
                    continue
                }
                result.append(child.pid)
            }
        }

        return result
    }
}
