const std = @import("std");
const FutexMutex = @import("futex_mutex.zig").FutexMutex;
const FutexMutexDeadlockDetection = @import("futex_mutex_deadlock_detection.zig").FutexMutex;
const DeadlockTimeoutStruct = @import("futex_mutex.zig").DeadlockTimeoutStruct;

///A struct that holds logic and containerizes the data for the showcase
const DeadlockDetectionStruct = struct {
    mutexA: *FutexMutexDeadlockDetection,
    mutexB: *FutexMutexDeadlockDetection,

    evil_boolean_A: i1 = 0,
    evil_boolean_B: i1 = -1,

    ///Creates struct and adds the mutexes to the fields
    pub fn init(mutexA: *FutexMutexDeadlockDetection, mutexB: *FutexMutexDeadlockDetection) DeadlockDetectionStruct {
        return DeadlockDetectionStruct{ .mutexA = mutexA, .mutexB = mutexB };
    }
    /// first thread that does the lock acquisition in order
    fn deadThread1(self: *DeadlockDetectionStruct, timeout: i128, error_channel: *?(FutexMutexDeadlockDetection.Error || std.mem.Allocator.Error), thread_num: usize) void {
        {
            self.mutexA.timeoutLock(timeout) catch |e| {
                error_channel.* = e;
                return;
            };
            defer self.mutexA.unlock();

            std.debug.print("Thread {d} locked mutex A\n", .{thread_num});

            std.time.sleep(std.time.ns_per_ms * 3);

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
    fn deadThread2(self: *DeadlockDetectionStruct, timeout: i128, error_channel: *?(FutexMutexDeadlockDetection.Error || std.mem.Allocator.Error), thread_num: usize) void {
        {
            self.mutexB.timeoutLock(timeout) catch |e| {
                error_channel.* = e;
                return;
            }; // Lock resources in the opposite order as thread1 so that it deadlocks
            defer self.mutexB.unlock();

            std.debug.print("Thread {d} locked mutex B\n", .{thread_num});

            std.time.sleep(std.time.ns_per_ms * 3);

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
    pub fn deadlock(self: *DeadlockDetectionStruct, timeout: i128) !void {
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
        var error_tape: [len]?(FutexMutexDeadlockDetection.Error || std.mem.Allocator.Error) = undefined;
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

    /// This thread function always locks the "lower" mutex pointer first, then the "higher" one,
    /// preventing the cross-lock scenario that can lead to deadlock.
    fn safeThread(self: *DeadlockDetectionStruct, timeout: i128, error_channel: *?(FutexMutexDeadlockDetection.Error || std.mem.Allocator.Error), thread_num: usize) void {
        // Determine which mutex pointer is "lower" vs "higher" in address
        var first_mutex = self.mutexA;
        var second_mutex = self.mutexB;

        if (@intFromPtr(first_mutex) > @intFromPtr(second_mutex)) {
            const tmp = first_mutex;
            first_mutex = second_mutex;
            second_mutex = tmp;
        }

        // Lock the first mutex
        first_mutex.timeoutLock(timeout) catch |e| {
            error_channel.* = e;
            return;
        };
        defer first_mutex.unlock();

        std.debug.print("Thread {d} locked the first mutex\n", .{thread_num});

        // Simulate some work
        std.time.sleep(std.time.ns_per_ms * 3);

        // lock the second mutex
        second_mutex.timeoutLock(timeout) catch |e| {
            error_channel.* = e;
            return;
        };
        defer second_mutex.unlock();

        std.debug.print("Thread {d} locked the second mutex\n", .{thread_num});

        // Do any "evil_boolean" logic or shared data changes
        if (self.evil_boolean_A != self.evil_boolean_B) {
            self.evil_boolean_B = self.evil_boolean_A;
        } else {
            self.evil_boolean_B = ~self.evil_boolean_B;
        }

        std.debug.print("Thread {d} unlocked both Mutexes without a timeout\n", .{thread_num});
    }

    /// Phase 4 demonstration: We show that, with ordered locking, no deadlock occurs.
    pub fn avoidDeadlock(self: *DeadlockDetectionStruct, timeout: i128) !void {
        const ThreadAndErrorPtrHolder = struct {
            error_channel: ?(FutexMutexDeadlockDetection.Error || std.mem.Allocator.Error) = null,
            thread: std.Thread = undefined,
        };
        const len: comptime_int = 2;
        var thread_tape: [len]ThreadAndErrorPtrHolder = undefined;

        // Spawn 2 threads that both do "safe" locking
        for (0..thread_tape.len) |index| {
            thread_tape[index] = ThreadAndErrorPtrHolder{};
            thread_tape[index].thread = try std.Thread.spawn(.{}, safeThread, .{ self, timeout, &thread_tape[index].error_channel, index });
        }

        // Join the threads
        for (0..thread_tape.len) |index| {
            thread_tape[index].thread.join();
        }

        // Collect & return any errors
        var error_tape: [len]?(FutexMutexDeadlockDetection.Error || std.mem.Allocator.Error) = undefined;
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

pub fn main() !void {
    std.debug.print("\n\nBasic mutex usage\n", .{});

    var mutex = FutexMutex{};

    try mutex.lock();
    std.debug.print("Acquired futex mutex\n", .{});
    // Critical code goes here.
    mutex.unlock();
    std.debug.print("Released futex mutex\n", .{});

    std.debug.print("\n\nDeadlock Timeout\n", .{});

    var mutex1 = FutexMutex{};

    var deadlockTimeoutStruct = DeadlockTimeoutStruct.init(&mutex, &mutex1);

    for (0..5) |_| {
        deadlockTimeoutStruct.deadlock(1 * std.time.ns_per_s) catch |e| {
            switch (e) {
                error.Timeout => {
                    std.debug.print("ThreadTimeout: possable deadlock\n", .{});
                },
                else => {
                    return e;
                },
            }
        };
        std.debug.print("evil_boolean_A: {d}, evil_boolean_B: {d}\n\n", .{ deadlockTimeoutStruct.evil_boolean_A, deadlockTimeoutStruct.evil_boolean_B });
    }

    std.debug.print("\n\nDeadlock Detection\n", .{});

    var mutex2 = FutexMutexDeadlockDetection{};
    var mutex3 = FutexMutexDeadlockDetection{};

    var deadlockDetectionStruct = DeadlockDetectionStruct.init(&mutex2, &mutex3);

    for (0..5) |_| {
        deadlockDetectionStruct.deadlock(1 * std.time.ns_per_s) catch |e| {
            switch (e) {
                error.Timeout => {
                    std.debug.print("ThreadTimeout: possable deadlock\n", .{});
                },
                error.DeadlockDetected => {
                    std.debug.print("DeadlockDetected\n", .{});
                },
                else => {
                    return e;
                },
            }
        };
        std.debug.print("evil_boolean_A: {d}, evil_boolean_B: {d}\n\n", .{ deadlockDetectionStruct.evil_boolean_A, deadlockDetectionStruct.evil_boolean_B });
    }

    try deadlockDetectionStruct.avoidDeadlock(5 * std.time.ns_per_s);
    std.debug.print("Phase 4 completed without deadlock\n", .{});
}

test "deadlock with std lib" {
    var mutex = std.Thread.Mutex{};

    mutex.lock();
    mutex.lock();
}
