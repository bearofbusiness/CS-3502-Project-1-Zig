const std = @import("std");

// futex operations: FUTEX_WAIT and FUTEX_WAKE.
const futexOpWait = 0;
const futexOpWake = 1;

// For x86_64 Linux, the syscall number for futex is 202.
const SYS_futex: usize = 202;

// Conversion between time denominations
const micro_to_nano_sec: u64 = 1000;
const milli_to_nano_sec: u64 = 1000 * micro_to_nano_sec;
const sec_to_nano_sec: u64 = 1000 * milli_to_nano_sec;

// A timespec struct for timeouts.
pub const timespec = struct {
    tv_sec: i64,
    tv_nsec: i64,
};

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

/// Convert a nanosecond count into a POSIX `timespec`.
fn nanosecondsToTimespec(ns: i128) timespec {
    // Convert total nanoseconds to whole seconds, leftover nanoseconds.
    const NSEC_PER_SEC: i64 = @intCast(sec_to_nano_sec);

    // If you are worried about negative values, do a bit more careful handling
    // if ns < 0 here.  This example keeps it simple.
    var secs: i64 = @divTrunc(@as(i64, @intCast(ns)), sec_to_nano_sec);
    var nanos: i64 = @mod(@as(i64, @intCast(ns)), sec_to_nano_sec);

    // In case remainder was negative, adjust so that timespec is always
    //  0 <= tv_nsec < 1e9.
    if (nanos < 0) {
        secs -= 1;
        nanos += NSEC_PER_SEC;
    }

    return .{ .tv_sec = secs, .tv_nsec = nanos };
}

/// A futex‑based mutex.
///
/// It uses a single i32 variable with the following meanings:
/// - 0: unlocked
/// - 1: locked (fast path, no waiters)
/// - 2: locked with contention (waiters present)
pub const FutexMutex = struct {
    pub const Error = error{ Timeout, Unknown, Interrupt };

    value: i32 = 0,

    /// Attempts to acquire the lock.
    pub fn lock(self: *FutexMutex) void {
        // Fast path: try to change 0 (unlocked) to 1 (locked).
        if (atomicExchange(&self.value, 1) == 0) {
            return;
        }
        // Slow path: mark as contended.
        _ = atomicExchange(&self.value, 2);
        // Wait until the lock becomes free.
        while (volatileLoad(&self.value) != 0) {
            _ = futex(&self.value, futexOpWait, 2, null, null, 0);
        }
    }

    /// Attempts to to acquire the lock non blocking.
    pub fn tryLock(self: *FutexMutex) bool {
        // Attempt to change from 0 -> 1
        const old_val = atomicCompareExchange(&self.value, 0, 1);
        return (old_val == 0);
    }

    /// Attempts to acquire the lock, but fails with `error.Timeout` if
    /// `timeout_nanos` elapses first.
    pub fn timeoutLock(self: *FutexMutex, timeout_nanos: i128) !void {
        // 1) Fast path: try to lock by setting 0 -> 1.
        if (atomicExchange(&self.value, 1) == 0) {
            return;
        }

        // 2) Mark as contended. (State becomes 2 if someone else has the lock.)
        _ = atomicExchange(&self.value, 2);

        // We'll measure the deadline so we can figure out how much time remains
        // on each iteration.
        const start_ns = std.time.nanoTimestamp();
        const deadline = start_ns + timeout_nanos;

        // 3) Loop until we either acquire the lock or time out.
        while (true) {
            // If the lock looks free, try once more to set 0 -> 2.
            // (We always store 2 because we assume contended once we get here.)
            if (volatileLoad(&self.value) == 0) {
                if (atomicExchange(&self.value, 2) == 0) {
                    return; // success
                }
            }
            // Figure out how much time remains.
            const now = std.time.nanoTimestamp();
            if (now >= deadline) {
                return error.Timeout;
            }
            const remain = deadline - now;

            // Convert the remaining time to a `timespec`.
            var ts = nanosecondsToTimespec(remain);

            // 4) Futex wait. Passes 2 as val as it is the expected value
            const rc = futex(&self.value, futexOpWait, 2, &ts, null, 0);
            if (rc == -1) {
                const e = std.posix.errno(rc);
                switch (e) {
                    .SUCCESS => unreachable, // `-1` cannot be success
                    .AGAIN => {}, //do nothing
                    .INTR => return error.Interrupt, // evil if true
                    .TIMEDOUT => return error.Timeout,
                    else => return error.Unknown,
                }
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
    }
};

///A struct that holds logic and containerizes the data for the showcase
const DeadlockTimeoutStruct = struct {
    mutexA: *FutexMutex,
    mutexB: *FutexMutex,

    evil_boolean_A: i1 = 0,
    evil_boolean_B: i1 = -1,

    ///Creates struct and adds the mutexes to the fields
    fn init(mutexA: *FutexMutex, mutexB: *FutexMutex) DeadlockTimeoutStruct {
        return DeadlockTimeoutStruct{ .mutexA = mutexA, .mutexB = mutexB };
    }
    /// first thread that does the lock acquisition in order
    fn deadThread1(self: *DeadlockTimeoutStruct, timeout: i128, error_channel: *?FutexMutex.Error, thread_num: usize) void {
        {
            self.mutexA.timeoutLock(timeout) catch |e| {
                error_channel.* = e;
                return;
            };
            defer self.mutexA.unlock();

            std.debug.print("Thread {d} locked mutex A\n", .{thread_num});

            std.time.sleep(micro_to_nano_sec * 3);

            self.mutexB.timeoutLock(timeout) catch |e| {
                error_channel.* = e;
                return;
            };
            defer self.mutexB.unlock();

            std.debug.print("Thread {d} locked mutex B\n", .{thread_num});
            if (self.evil_boolean_A != self.evil_boolean_B) {
                self.evil_boolean_B = self.evil_boolean_A;
            } else {
                self.evil_boolean_B = ~self.evil_boolean_B;
            }
        }
        std.debug.print("Thread {d} unlocked both Mutexes without a timeout\n", .{thread_num});
    }

    /// First thread that does the lock acquisition in reverse order
    fn deadThread2(self: *DeadlockTimeoutStruct, timeout: i128, error_channel: *?FutexMutex.Error, thread_num: usize) void {
        {
            self.mutexB.timeoutLock(timeout) catch |e| {
                error_channel.* = e;
                return;
            }; // Lock resources in the opposite order as thread1 so that it deadlocks
            defer self.mutexB.unlock();

            std.debug.print("Thread {d} locked mutex B\n", .{thread_num});

            std.time.sleep(micro_to_nano_sec * 3);

            self.mutexA.timeoutLock(timeout) catch |e| {
                error_channel.* = e;
                return;
            };
            defer self.mutexA.unlock();

            std.debug.print("Thread {d} locked mutex A\n", .{thread_num});

            if (self.evil_boolean_A != self.evil_boolean_B) {
                self.evil_boolean_A = self.evil_boolean_B;
            } else {
                self.evil_boolean_A = ~self.evil_boolean_A;
            }
        }
        std.debug.print("Thread {d} unlocked both Mutexes without a timeout\n", .{thread_num});
    }

    /// Starts the threads so that dead lock can happen
    pub fn deadlock(self: *DeadlockTimeoutStruct, timeout: i128) !void {
        const ThreadAndErrorPtrHolder = struct {
            error_channel: ?FutexMutex.Error = null,
            thread: std.Thread = undefined,
        };
        const len: comptime_int = 2;
        var thread_tape: [len]ThreadAndErrorPtrHolder = undefined;

        for (0..thread_tape.len) |index| {
            thread_tape[index] = ThreadAndErrorPtrHolder{};
            if (index % 2 == 0) {
                thread_tape[index].thread = try std.Thread.spawn(.{}, deadThread1, .{ self, timeout, &thread_tape[index].error_channel, index });
            } else {
                thread_tape[index].thread = try std.Thread.spawn(.{}, deadThread2, .{ self, timeout, &thread_tape[index].error_channel, index });
            }
        }

        // var error_channel1: ?FutexMutex.Error = null;
        // var error_channel2: ?FutexMutex.Error = null;
        // const t1 = try std.Thread.spawn(.{}, deadThread1, .{ self, timeout, &error_channel1 });
        // const t2 = try std.Thread.spawn(.{}, deadThread2, .{ self, timeout, &error_channel2 });

        // t1.join();
        // t2.join();
        for (0..thread_tape.len) |index| {
            thread_tape[index].thread.join();
        }
        var error_tape: [len]?FutexMutex.Error = undefined;
        for (0..thread_tape.len) |index| {
            if (thread_tape[index].error_channel) |error_channel_not_null| {
                std.debug.print("thread no.: {d} errored\n", .{index});
                error_tape[index] = error_channel_not_null;
            } else {
                error_tape[index] = null;
            }
        }
        for (error_tape) |err| {
            if (err) |err_not_null| {
                return err_not_null;
            }
        }
        // if (error_channel1) |error_channel_not_null| {
        //     return error_channel_not_null;
        // }

        // if (error_channel2) |error_channel_not_null| {
        //     return error_channel_not_null;
        // }
    }
};

pub fn main() !void {
    var mutex = FutexMutex{};

    mutex.lock();
    std.debug.print("Acquired futex mutex\n", .{});
    // Critical code goes here.
    mutex.unlock();
    std.debug.print("Released futex mutex\n", .{});

    var mutex1 = FutexMutex{};

    var deadlockTimeoutStruct = DeadlockTimeoutStruct.init(&mutex, &mutex1);

    for (0..5) |_| {
        deadlockTimeoutStruct.deadlock(1 * sec_to_nano_sec) catch |e| {
            switch (e) {
                error.Timeout => {
                    std.debug.print("DeadlockTimeout\n", .{});
                },
                else => {
                    return e;
                },
            }
        };
        std.debug.print("evil_boolean_A: {d}, evil_boolean_B: {d}\n", .{ deadlockTimeoutStruct.evil_boolean_A, deadlockTimeoutStruct.evil_boolean_B });
    }
}
