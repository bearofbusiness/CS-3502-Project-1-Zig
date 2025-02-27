const std = @import("std");
const FutexMutex = @import("futex_mutex_deadlock_detection.zig").FutexMutex;

pub const SeatBlock = struct {
    mutex: FutexMutex,
    available_seats: i32,
};

pub const Theater = struct {
    blocks: []SeatBlock,

    pub fn init(allocator: std.mem.Allocator, count: usize, seats_each: i32) !Theater {
        const arr = try allocator.alloc(SeatBlock, count);
        for (arr) |*b| {
            b.mutex = FutexMutex{};
            b.available_seats = seats_each;
        }
        return .{ .blocks = arr };
    }

    pub fn deinit(self: *Theater, allocator: std.mem.Allocator) void {
        allocator.free(self.blocks);
    }
};

fn bookSeats(block: *SeatBlock, seats: i32) !bool {
    // Simple lock-based seat booking
    try block.mutex.lock();
    defer block.mutex.unlock();

    if (block.available_seats >= seats) {
        block.available_seats -= seats;
        return true;
    }
    return false;
}

// Worker threads: randomly pick a block, try to book some seats, print the result
fn workerThread(theater_ptr: *Theater, thread_id: usize) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var rng = std.rand.DefaultPrng.init(@truncate(@as(u64, @intCast(std.time.nanoTimestamp())) + thread_id));

    for (0..5) |_| { // each thread does 5 bookings
        const block_idx: usize = @intCast(rng.random().int(usize) % theater_ptr.blocks.len);
        const seats_to_book: i32 = @mod(rng.random().int(i32), 5) + 1; // 1..5 seats

        const success = try bookSeats(&theater_ptr.blocks[block_idx], seats_to_book);
        if (success) {
            // Print to stdout
            try stdout.print("Thread {d} booked {d} seats in block {d}\n", .{ thread_id, seats_to_book, block_idx });
        } else {
            try stdout.print("Thread {d} NOT ENOUGH seats for {d} in block {d}\n", .{ thread_id, seats_to_book, block_idx });
        }
        try bw.flush();
    }

    // Thread done
    try stdout.print("Thread {d} done.\n", .{thread_id});
    try bw.flush();
}

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const alloc = std.heap.page_allocator;

    // Create a Theater with 2 blocks, each starting with 10 seats
    var theater = try Theater.init(alloc, 10, 10);
    defer theater.deinit(alloc);

    // Spawn 3 threads for concurrency
    const num_threads = 10;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, workerThread, .{ &theater, i }) catch |err| {
            for (0..i) |o| {
                threads[o].join();
            }
            std.debug.print("errored on thread num.{d}\n", .{i});
            return err;
        };
    }

    // Join them
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Print final seat counts
    for (theater.blocks, 0..) |blk, idx| {
        try stdout.print("Block {d} final seats: {d}\n", .{ idx, blk.available_seats });
    }

    try stdout.print("all done.\n", .{});
    try bw.flush();
}
