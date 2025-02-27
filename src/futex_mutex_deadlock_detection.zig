const std = @import("std");

const futex_mutex = @import("futex_mutex.zig");

const futex_impl = @import("futex_impl.zig");

const FutexMap = std.HashMap( //
    *FutexMutex, // key type
    FutexMutex.MutexInfo, // value type
    FutexMutex.MapContext, // hashing function and equality function
    70 // a lower max load persentage for a faster speed
);

fn initFutexMap(allocator: std.mem.Allocator) FutexMap {
    return FutexMap.init(allocator);
}

/// A futex‑based mutex.
///
/// It uses a single i32 variable with the following meanings:
/// - 0: unlocked
/// - 1: locked (fast path, no waiters)
/// - 2: locked with contention (waiters present)
pub const FutexMutex = struct {
    pub const Error = error{ Timeout, Unknown, Interrupt, DeadlockDetected };

    const MutexInfo = struct {
        const MutexInfoWaitingThreadsMap = std.HashMap(std.Thread.Id, void, MutexInfoContext, 80);
        const MutexInfoContext = struct {
            pub fn hash(_: MutexInfoContext, mutex_info_ptr: std.Thread.Id) u64 {
                return mutex_info_ptr;
            }
            pub fn eql(_: MutexInfoContext, a: std.Thread.Id, b: std.Thread.Id) bool {
                return a == b;
            }
        };

        owner: ?std.Thread.Id = null,
        waiting_threads: MutexInfoWaitingThreadsMap = MutexInfoWaitingThreadsMap.init(std.heap.page_allocator),
    };

    const MapContext = struct {
        pub fn hash(_: MapContext, mutex_ptr: *FutexMutex) u64 {
            return @intFromPtr(mutex_ptr);
        }
        pub fn eql(_: MapContext, a: *FutexMutex, b: *FutexMutex) bool {
            return a == b;
        }
    };

    var global_futex_map = initFutexMap(std.heap.page_allocator);
    var global_graph_lock = futex_mutex.FutexMutex{}; // std.Thread.Mutex{}; //

    value: i32 = 0,

    pub fn init() FutexMutex {
        return FutexMutex{};
    }

    pub fn deinit(self: FutexMutex) void {
        lockGlobalGraphMutex();
        defer unlockGlobalGraphMutex();

        const k_v_optional = global_futex_map.fetchRemove(self);
        if (k_v_optional) |k_v| {
            k_v.value.waiting_threads.deinit();
        }
    }

    fn lockGlobalGraphMutex() void {
        FutexMutex.global_graph_lock.lock();
    }

    fn unlockGlobalGraphMutex() void {
        FutexMutex.global_graph_lock.unlock();
    }

    /// Attempts to acquire the lock.
    pub fn lock(self: *FutexMutex) !void {
        // Fast path: try to change 0 (unlocked) to 1 (locked).
        if (futex_impl.atomicExchange(&self.value, 1) == 0) {
            {
                FutexMutex.lockGlobalGraphMutex();
                defer FutexMutex.unlockGlobalGraphMutex();

                self.switchOwner(std.Thread.getCurrentId());
            }

            // no reason to detect deadlock if unlocking is possible
            return;
        }

        // Slow path: mark as contended.
        if (futex_impl.atomicExchange(&self.value, 2)) {
            return;
        }

        {
            FutexMutex.lockGlobalGraphMutex();
            defer FutexMutex.unlockGlobalGraphMutex();

            const thread_id = std.Thread.getCurrentId();

            self.addWaitingThread(thread_id);

            // detect deadlock
            if (try detectCycle(thread_id)) {
                // remove "thread_id -> self" so the graph is consistent
                self.removeWaitingThread(thread_id);
                return error.DeadlockDetected;
            }
        }

        while (true) {

            // Wait until the lock becomes free.
            while (futex_impl.volatileLoad(&self.value) != 0) {
                _ = futex_impl.futex(&self.value, futex_impl.futexOpWait, 2, null, null, 0);
            }

            // Attempt to atomically acquire it
            if (futex_impl.atomicExchange(&self.value, 2) == 0) {
                {
                    //update the global mutex
                    FutexMutex.lockGlobalGraphMutex();
                    defer FutexMutex.unlockGlobalGraphMutex();

                    const thread_id = std.Thread.getCurrentId();

                    self.removeWaitingThread(thread_id);
                    self.switchOwner(thread_id);
                }
                return;
            }
        }
    }

    /// Attempts to to acquire the lock non blocking.
    pub fn tryLock(self: *FutexMutex) bool {
        // Attempt to change from 0 -> 1
        if (futex_impl.atomicCompareExchange(&self.value, 0, 1) == 0) {
            {
                // If successful, record ownership
                FutexMutex.lockGlobalGraphMutex();
                defer FutexMutex.unlockGlobalGraphMutex();

                self.switchOwner(std.Thread.getCurrentId());
            }
            return true;
        }
        return false;
    }

    /// Attempts to acquire the lock, but fails with `error.Timeout` if `timeout_nanos` elapses first.
    /// Uses futex to allow for low cpu utilization
    pub fn timeoutLock(self: *FutexMutex, timeout_nanos: i128) !void {
        // Fast path: try to change 0 (unlocked) to 1 (locked).
        if (futex_impl.atomicExchange(&self.value, 1) == 0) {
            {
                FutexMutex.lockGlobalGraphMutex();
                defer FutexMutex.unlockGlobalGraphMutex();

                const thread_id = std.Thread.getCurrentId();

                self.switchOwner(thread_id);
            }

            return;
        }

        // Slow path: mark as contended.
        if (futex_impl.atomicExchange(&self.value, 2)) {
            return;
        }

        { // Inner scope for defering
            FutexMutex.lockGlobalGraphMutex();
            defer FutexMutex.unlockGlobalGraphMutex();

            const thread_id = std.Thread.getCurrentId();

            self.addWaitingThread(thread_id);

            // detect deadlock
            if (try detectCycle(thread_id)) {
                // remove "thread_id -> self" so the graph is consistent
                self.removeWaitingThread(thread_id);
                return error.DeadlockDetected;
            }
        }

        // Find the deadline
        const start_ns = std.time.nanoTimestamp();
        const deadline = start_ns + timeout_nanos;

        // Loop until we either acquire the lock or time out.
        while (true) {
            std.log.debug("{d} is looping", .{std.Thread.getCurrentId()});
            //std.debug.print("looped on thread: {d}\n", .{std.Thread.getCurrentId()});
            // If the lock looks free, try once more to set 0 -> 2.
            if (futex_impl.volatileLoad(&self.value) == 0) {
                if (futex_impl.atomicExchange(&self.value, 2) == 0) {
                    {
                        FutexMutex.lockGlobalGraphMutex();
                        defer FutexMutex.unlockGlobalGraphMutex();

                        const thread_id = std.Thread.getCurrentId();

                        self.removeWaitingThread(thread_id);
                        self.switchOwner(thread_id);
                    }
                    return; // success
                }
            }
            // Figure out how much time remains.
            const now = std.time.nanoTimestamp();
            if (now >= deadline) {
                {
                    FutexMutex.lockGlobalGraphMutex();
                    defer FutexMutex.unlockGlobalGraphMutex();

                    const thread_id = std.Thread.getCurrentId();

                    self.removeWaitingThread(thread_id);
                }
                return error.Timeout;
            }

            // Convert the remaining time to a `timespec`.
            var ts = futex_impl.nanosecondsToTimespec(deadline - now);

            // Futex wait. Passes 2 as val as it is the expected value
            const rc = futex_impl.futex(&self.value, futex_impl.futexOpWait, 2, &ts, null, 0);
            if (rc == -1) {
                const e = std.posix.errno(rc);
                var returned_error: ?Error = null;
                switch (e) {
                    .SUCCESS => unreachable, // `-1` cannot be success
                    .AGAIN => continue, //do nothing
                    .INTR => returned_error = error.Interrupt, // Evil if true
                    .TIMEDOUT => returned_error = error.Timeout,
                    else => returned_error = error.Unknown,
                }
                {
                    FutexMutex.lockGlobalGraphMutex();
                    defer FutexMutex.unlockGlobalGraphMutex();

                    const thread_id = std.Thread.getCurrentId();

                    self.removeWaitingThread(thread_id);
                }
                return returned_error.?;
            }
        }
    }

    /// Releases the lock.
    pub fn unlock(self: *FutexMutex) void {
        // Atomically subtract 1.
        if (futex_impl.atomicExchange(&self.value, 0) != 1) {
            // If the previous value was not 1, then there were waiters.
            _ = futex_impl.futex(&self.value, futex_impl.futexOpWake, 1, null, null, 0);
        }

        FutexMutex.lockGlobalGraphMutex();
        defer FutexMutex.unlockGlobalGraphMutex();

        //remove ownership
        self.releaseOwnership();
    }

    // ------------
    // Graph Utils
    // ------------

    /// Retrieve (or create) a MutexInfo for the given FutexMutex pointer.
    pub fn getOrInitMutexInfo(self: *FutexMutex) *MutexInfo {
        const entry = global_futex_map.getOrPutValue(self, MutexInfo{
            .owner = null,
        }) catch unreachable; // Out of memory TODO handle
        return entry.value_ptr;
    }

    /// Indicate that `thread_id` is now waiting for `mutex_ptr` (add edge T -> M).
    fn addWaitingThread(mutex_ptr: *FutexMutex, thread_id: std.Thread.Id) void {
        const info = mutex_ptr.getOrInitMutexInfo();

        // Make sure it's not already in the waiting list.
        if (!info.waiting_threads.contains(thread_id)) {
            _ = info.waiting_threads.put(thread_id, {}) catch unreachable;
        }
    }

    /// Remove “thread_id -> mutex_ptr” (stop waiting).
    fn removeWaitingThread(mutex_ptr: *FutexMutex, thread_id: std.Thread.Id) void {
        // Remove the thread_id from waiting_threads if present
        _ = getOrInitMutexInfo(mutex_ptr).waiting_threads.remove(thread_id);
    }

    /// Set “mutex_ptr -> thread_id” (mutex is now owned by that thread).
    fn switchOwner(mutex_ptr: *FutexMutex, thread_id: std.Thread.Id) void {
        const info = getOrInitMutexInfo(mutex_ptr);
        info.owner = thread_id;
    }

    /// Remove “mutex_ptr -> thread_id” (mutex is no longer owned).
    fn releaseOwnership(mutex_ptr: *FutexMutex) void {
        const info = getOrInitMutexInfo(mutex_ptr);
        info.owner = null;
    }

    // ----------------
    // Cycle Detection
    // ----------------

    /// Naive DFS-based cycle check.
    /// Returns True if there is Deadlock.
    fn detectCycle(thread_id: std.Thread.Id) !bool {
        // Keep track of visited threads to avoid infinite recursion.
        var visited_set = std.AutoHashMap(std.Thread.Id, bool).init(FutexMutex.global_futex_map.allocator);
        defer visited_set.deinit();
        return try detectCycleRecursive(thread_id, &visited_set);
    }

    /// DFS from `current_thread`; returns true if `thread_id` is found again on the path.
    fn detectCycleRecursive(current_thread: std.Thread.Id, visited_set: *std.AutoHashMap(std.Thread.Id, bool)) !bool {

        // If true, there is a cycle.
        if (try visited_set.fetchPut(current_thread, true)) |kv| {
            if (kv.value) {
                return true; // cycle
            }
        }

        // Find all mutexes that current_thread is waiting on.
        var it = FutexMutex.global_futex_map.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;

            // If current_thread is in info.waiting_threads, that means T->M
            if (info.waiting_threads.contains(current_thread)) {
                // Then there's M->owner if owner is set.
                if (info.owner) |owner_tid| {
                    // current_thread -> M -> owner_tid
                    // Recurse from owner_tid
                    if (try detectCycleRecursive(owner_tid, visited_set)) {
                        return true;
                    }
                }
            }
        }

        // return false if deadend and remove from visited set
        _ = visited_set.remove(current_thread);

        return false;
    }
};
