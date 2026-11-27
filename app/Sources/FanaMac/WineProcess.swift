// Finds CrossOver's running bottles. A bottle only sees the base's force
// feedback plug-in and axis filter if it starts after FanaMac has marked the base.

import Darwin

enum WineProcess {
    /// The wineservers running now: one per bottle in use.
    static func servers() -> Set<pid_t> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        var name = [CChar](repeating: 0, count: 64)
        return Set(pids.prefix(Int(found)).filter { pid in
            proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name) == "wineserver"
        })
    }
}
