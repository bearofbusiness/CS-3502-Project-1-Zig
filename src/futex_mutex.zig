const std = @import("std");

// futex operations: FUTEX_WAIT and FUTEX_WAKE.
const futexOpWait = 0;
const futexOpWake = 1;

// For x86_64 Linux, the syscall number for futex is 202.
const SYS_futex: usize = 202;

// A timespec struct for timeouts.
pub const timespec = struct {
    tv_sec: i64,
    tv_nsec: i64,
};

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
    var global_graph_lock = FutexMutex{ .use_deadlock_checking = false };

    value: i32 = 0,
    use_deadlock_checking: bool = true,

    fn lockGlobalGraphMutex() void {
        FutexMutex.global_graph_lock.lock() catch {
            @panic("FutexMutex global graph lock errored. should be impossable");
        };
    }

    fn unlockGlobalGraphMutex() void {
        FutexMutex.global_graph_lock.unlock();
    }

    /// Attempts to acquire the lock.
    pub fn lock(self: *FutexMutex) !void {
        // Fast path: try to change 0 (unlocked) to 1 (locked).
        if (atomicExchange(&self.value, 1) == 0) {
            if (self.use_deadlock_checking) {
                FutexMutex.lockGlobalGraphMutex();
                defer FutexMutex.unlockGlobalGraphMutex();

                self.switchOwner(std.Thread.getCurrentId());

                // no reason to detect deadlock if unlocking is possable
            }
            return;
        }

        // Slow path: mark as contended.
        _ = atomicExchange(&self.value, 2);

        if (self.use_deadlock_checking) {
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

        // Wait until the lock becomes free.
        while (volatileLoad(&self.value) != 0) {
            _ = futex(&self.value, futexOpWait, 2, null, null, 0);
        }

        if (self.use_deadlock_checking) {
            FutexMutex.lockGlobalGraphMutex();
            defer FutexMutex.unlockGlobalGraphMutex();

            const thread_id = std.Thread.getCurrentId();

            self.removeWaitingThread(thread_id);
            self.switchOwner(thread_id);
        }
    }

    /// Attempts to to acquire the lock non blocking.
    pub fn tryLock(self: *FutexMutex) bool {
        // Attempt to change from 0 -> 1
        const old_val = atomicCompareExchange(&self.value, 0, 1);
        if (old_val == 0) {
            if (self.use_deadlock_checking) {
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
        if (atomicExchange(&self.value, 1) == 0) {
            if (self.use_deadlock_checking) {
                FutexMutex.lockGlobalGraphMutex();
                defer FutexMutex.unlockGlobalGraphMutex();

                const thread_id = std.Thread.getCurrentId();

                self.switchOwner(thread_id);

                // no reason to detect deadlock if unlocking is possable
            }
            return;
        }

        // Slow path: mark as contended.
        _ = atomicExchange(&self.value, 2);

        if (self.use_deadlock_checking) {
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
            std.debug.print("looped on thread: {d}\n", .{std.Thread.getCurrentId()});
            // If the lock looks free, try once more to set 0 -> 2.
            if (volatileLoad(&self.value) == 0) {
                if (atomicExchange(&self.value, 2) == 0) {
                    if (self.use_deadlock_checking) {
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
                if (self.use_deadlock_checking) {
                    FutexMutex.lockGlobalGraphMutex();
                    defer FutexMutex.unlockGlobalGraphMutex();

                    const thread_id = std.Thread.getCurrentId();

                    self.removeWaitingThread(thread_id);
                }
                return error.Timeout;
            }

            // Convert the remaining time to a `timespec`.
            var ts = nanosecondsToTimespec(deadline - now);

            // Futex wait. Passes 2 as val as it is the expected value
            const rc = futex(&self.value, futexOpWait, 2, &ts, null, 0);
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

                if (self.use_deadlock_checking) {
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
        if (atomicFetchSub(&self.value, 1) != 1) {
            // If the previous value was not 1, then there were waiters.
            volatileStore(&self.value, 0);
            _ = futex(&self.value, futexOpWake, 1, null, null, 0);
        }

        if (self.use_deadlock_checking) {
            FutexMutex.lockGlobalGraphMutex();
            defer FutexMutex.unlockGlobalGraphMutex();

            //remove ownership
            self.releaseOwnership();
        }
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

// --------------------
// Asm for futex calls
// --------------------

/// Performs a syscall with six arguments using inline assembly (x86_64 Linux).
fn syscall6(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) i64 {
    return asm volatile (
        \\syscall
        : [ret] "={rax}" (-> i64),
        : [number] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
          [a4] "{r10}" (arg4),
          [a5] "{r8}" (arg5),
          [a6] "{r9}" (arg6),
        : "rcx", "r11", "memory"
    );
}

/// Wrapper for the futex syscall.
fn futex(uaddr: *i32, futex_op: i32, val: i32, timeout: ?*const timespec, uaddr2: ?*i32, val3: i32) i64 {
    const timeout_addr: u64 = if (timeout) |t| @intFromPtr(t) else 0;
    const uaddr2_addr: u64 = if (uaddr2) |p| @intFromPtr(p) else 0;
    return @intCast(syscall6( //
        SYS_futex, //
        @intFromPtr(uaddr), //
        @intCast(futex_op), //
        @intCast(val), //
        timeout_addr, //
        uaddr2_addr, //
        @intCast(val3)) //
    );
}

/// Atomic exchange implemented with inline assembly (x86_64).
/// It atomically exchanges the value at `ptr` with `new_val` and returns the old value.
pub fn atomicExchange(ptr: *i32, new_val: i32) i32 {
    var old_val: i32 = new_val;
    asm volatile ("lock xchgl %eax, (%[addr])"
        : [val] "+{eax}" (old_val),
        : [addr] "r" (ptr),
        : "memory"
    );

    return old_val;
}

/// Atomic fetch-subtract implemented with inline assembly using the x86_64 XADD instruction.
/// It atomically subtracts `val` from `*ptr` and returns the original value.
pub fn atomicFetchSub(ptr: *i32, val: i32) i32 {
    var neg: i32 = -val;
    const local_ptr: *i32 = ptr;
    asm volatile ("lock xaddl %eax, (%[mem])"
        : [old] "+{eax}" (neg), //
        : [mem] "+r" (local_ptr), //
        : "memory"
    );
    return neg;
}

pub fn volatileLoad(ptr: *i32) i32 {
    return asm volatile (
        \\ movl (%[addr]), %eax
        : [result] "={eax}" (-> i32),
        : [addr] "r" (ptr),
        : "memory"
    );
}

/// Performs a volatile store of `val` into the address in `ptr` using inline assembly.
pub fn volatileStore(ptr: *i32, val: i32) void {
    asm volatile ("movl %[value], (%[addr])"
        :
        : [addr] "r" (ptr),
          [value] "r" (val),
        : "memory"
    );
}

/// Atomically compare `*ptr` to `expected`; if equal, write `desired` into `*ptr`.
/// Returns the original value of `*ptr`.
fn atomicCompareExchange(ptr: *i32, expected: i32, desired: i32) i32 {
    // On entry, EAX must hold `expected`.
    var old_val: i32 = expected;
    asm volatile ("lock cmpxchgl %[desired], (%[ptr])"
        : [old_val] "+{eax}" (old_val),
        : [desired] "r" (desired),
          [ptr] "r" (ptr),
        : "memory"
    );
    return old_val;
}

// ----------------
// Other Functions
// ----------------

/// Convert a nanosecond count into a POSIX `timespec`.
fn nanosecondsToTimespec(ns: i128) timespec {
    // Convert total nanoseconds to whole seconds, leftover nanoseconds.
    const NSEC_PER_SEC: i64 = std.time.ns_per_s;

    // If you are worried about negative values, do a bit more careful handling
    // if ns < 0 here.  This example keeps it simple.
    var secs: i64 = @divTrunc(@as(i64, @intCast(ns)), std.time.ns_per_s);
    var nanos: i64 = @mod(@as(i64, @intCast(ns)), std.time.ns_per_s);

    // In case remainder was negative, adjust so that timespec is always
    //  0 <= tv_nsec < 1e9.
    if (nanos < 0) {
        secs -= 1;
        nanos += NSEC_PER_SEC;
    }

    return .{ .tv_sec = secs, .tv_nsec = nanos };
}
