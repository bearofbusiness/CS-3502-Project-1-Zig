const std = @import("std");

const futex_impl = @import("futex_impl.zig");

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
        if (futex_impl.atomicExchange(&self.value, 1) == 0) {
            return;
        }

        // Slow path: mark as contended.
        _ = futex_impl.atomicExchange(&self.value, 2);

        while (true) {
            // Wait until the lock becomes free.
            while (futex_impl.volatileLoad(&self.value) != 0) {
                _ = futex_impl.futex(&self.value, futex_impl.futexOpWait, 2, null, null, 0);
            }

            if (futex_impl.atomicExchange(&self.value, 2) == 0) {
                return;
            }
        }
    }

    /// Attempts to to acquire the lock non blocking.
    pub fn tryLock(self: *FutexMutex) bool {
        // Attempt to change from 0 -> 1
        return futex_impl.atomicCompareExchange(&self.value, 0, 1) == 0;
    }

    /// Attempts to acquire the lock, but fails with `error.Timeout` if `timeout_nanos` elapses first.
    /// Uses futex to allow for low cpu utilization
    pub fn timeoutLock(self: *FutexMutex, timeout_nanos: i128) !void {
        // Fast path: try to change 0 (unlocked) to 1 (locked).
        if (futex_impl.atomicExchange(&self.value, 1) == 0) {
            return;
        }

        // Slow path: mark as contended.
        _ = futex_impl.atomicExchange(&self.value, 2);

        // Find the deadline
        const start_ns = std.time.nanoTimestamp();
        const deadline = start_ns + timeout_nanos;

        // Loop until we either acquire the lock or time out.
        while (true) {
            //std.debug.print("looped on thread: {d}\n", .{std.Thread.getCurrentId()});
            // If the lock looks free, try once more to set 0 -> 2.
            if (futex_impl.volatileLoad(&self.value) == 0) {
                if (futex_impl.atomicExchange(&self.value, 2) == 0) {
                    return; // success
                }
            }
            // Figure out how much time remains.
            const now = std.time.nanoTimestamp();
            if (now >= deadline) {
                return error.Timeout;
            }

            // Convert the remaining time to a `timespec`.
            var ts = futex_impl.nanosecondsToTimespec(deadline - now);

            // Futex wait. Passes 2 as val as it is the expected value
            const rc = futex_impl.futex(&self.value, futex_impl.futexOpWait, 2, &ts, null, 0);
            if (rc == -1) {
                const e = std.posix.errno(rc);
                switch (e) {
                    .SUCCESS => unreachable, // `-1` cannot be success
                    .AGAIN => continue, //do nothing
                    .INTR => return error.Interrupt, // Evil if true
                    .TIMEDOUT => return error.Timeout,
                    else => return error.Unknown,
                }
            }
        }
    }

    /// Releases the lock.
    pub fn unlock(self: *FutexMutex) void {
        // Atomically subtract 1.
        if (futex_impl.atomicFetchSub(&self.value, 1) != 1) {
            // If the previous value was not 1, then there were waiters.
            futex_impl.volatileStore(&self.value, 0);
            _ = futex_impl.futex(&self.value, futex_impl.futexOpWake, 1, null, null, 0);
        }
    }
};

// ----------------
// Testing Struct
// ----------------

pub const DeadlockTimeoutStruct = struct {
    mutexA: *FutexMutex,
    mutexB: *FutexMutex,

    evil_boolean_A: i1 = 0,
    evil_boolean_B: i1 = -1,

    ///Creates struct and adds the mutexes to the fields
    pub fn init(mutexA: *FutexMutex, mutexB: *FutexMutex) DeadlockTimeoutStruct {
        return DeadlockTimeoutStruct{ .mutexA = mutexA, .mutexB = mutexB };
    }
    /// first thread that does the lock acquisition in order
    fn deadThread1(self: *DeadlockTimeoutStruct, timeout: i128, error_channel: *?(FutexMutex.Error || std.mem.Allocator.Error), thread_num: usize) void {
        {
            self.mutexA.timeoutLock(timeout) catch |e| {
                std.debug.print("mutexA on thread no.{d} timedout\n", .{thread_num});
                error_channel.* = e;
                return;
            };
            defer self.mutexA.unlock();

            std.debug.print("Thread {d} locked mutex A\n", .{thread_num});

            std.time.sleep(std.time.ns_per_ms * 3);

            self.mutexB.timeoutLock(timeout) catch |e| {
                std.debug.print("mutexB on thread no.{d} timedout\n", .{thread_num});
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
    fn deadThread2(self: *DeadlockTimeoutStruct, timeout: i128, error_channel: *?(FutexMutex.Error || std.mem.Allocator.Error), thread_num: usize) void {
        {
            self.mutexB.timeoutLock(timeout) catch |e| {
                std.debug.print("mutexB on thread no.{d} timedout\n", .{thread_num});
                error_channel.* = e;
                return;
            }; // Lock resources in the opposite order as thread1 so that it deadlocks
            defer self.mutexB.unlock();

            std.debug.print("Thread {d} locked mutex B\n", .{thread_num});

            std.time.sleep(std.time.ns_per_ms * 3);

            self.mutexA.timeoutLock(timeout) catch |e| {
                std.debug.print("mutexA on thread no.{d} timedout\n", .{thread_num});
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

        for (0..thread_tape.len) |index| {
            thread_tape[index].thread.join();
        }
        var error_tape: [len]?(FutexMutex.Error || std.mem.Allocator.Error) = undefined;
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
    }
};
