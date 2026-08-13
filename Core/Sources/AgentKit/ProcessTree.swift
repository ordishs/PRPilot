import Darwin
import Foundation

/// Finds every process descended from a pid, whatever process group they joined.
///
/// `killpg` is not enough on its own. It reaches the agent and the MCP servers that share the
/// agent's group, but Claude Code puts each Bash tool command in a new process group of its own.
/// Those commands are still children of the agent, so a walk down the parent links finds them
/// when a group signal cannot. Long-running commands that never touch the terminal survive the
/// agent's death otherwise, and go on burning a core until the machine reboots.
public enum ProcessTree {
    /// Every descendant of `pid`, children first and deeper generations after.
    ///
    /// The order matters to the caller: signalling a parent can reparent its children to `launchd`
    /// mid-sweep, so a caller that walks the returned list in order signals each process while its
    /// place in the tree is still the one this snapshot recorded.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in snapshot() {
            childrenByParent[entry.parent, default: []].append(entry.pid)
        }

        var found: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var frontier = childrenByParent[pid] ?? []
        while !frontier.isEmpty {
            var next: [pid_t] = []
            for candidate in frontier where seen.insert(candidate).inserted {
                found.append(candidate)
                next.append(contentsOf: childrenByParent[candidate] ?? [])
            }
            frontier = next
        }
        return found
    }

    /// One `sysctl` snapshot of the process table as pid/parent pairs.
    ///
    /// The table can grow between the sizing call and the fetch, so the buffer carries spare
    /// entries and the second call's byte count decides how many are real.
    private static func snapshot() -> [(pid: pid_t, parent: pid_t)] {
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&request, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = table.count * stride
        guard sysctl(&request, 4, &table, &size, nil, 0) == 0 else { return [] }

        return table.prefix(size / stride).map { (pid: $0.kp_proc.p_pid, parent: $0.kp_eproc.e_ppid) }
    }
}
