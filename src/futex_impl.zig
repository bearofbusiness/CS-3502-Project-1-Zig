const std = @import("std");

// futex operations: FUTEX_WAIT and FUTEX_WAKE.
pub const futexOpWait = 0;
pub const futexOpWake = 1;

// For x86_64 Linux, the syscall number for futex is 202.
const SYS_futex: usize = 202;

// A timespec struct for timeouts.
pub const timespec = struct {
    tv_sec: i64,
    tv_nsec: i64,
};

// --------------------
// Asm for futex calls
// --------------------

/// Performs a syscall with six arguments using inline assembly (x86_64 Linux).
pub fn syscall6(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) i64 {
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
pub fn futex(uaddr: *i32, futex_op: i32, val: i32, timeout: ?*const timespec, uaddr2: ?*i32, val3: i32) i64 {
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
pub fn atomicCompareExchange(ptr: *i32, expected: i32, desired: i32) i32 {
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
pub fn nanosecondsToTimespec(ns: i128) timespec {
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
