const std = @import("std");

pub fn main() !void {
    const stdin = std.io.getStdIn();
    var bReader = std.io.bufferedReader(stdin.reader());
    // We'll read line by line until EOF
    var line_stream = try bReader.reader().readAllAlloc(std.heap.page_allocator, 0xFFFFFFFFFFFFFFFF);
    var line_count: usize = 0;

    var start: usize = 0;
    while (true) {
        var end: usize = undefined;
        defer start = end +% 1; // overflow add for error bypass
        for (start..line_stream.len) |i| {
            if (line_stream[i] == '\n') {
                end = i;
                break;
            }
        } else {
            end = line_stream.len;
        }
        const next_line = line_stream[start..end];
        if (next_line.len == 0) {
            // Reached EOF
            break;
        }
        line_count += 1;

        std.debug.print("main3: I see line {d}: {s}\n", .{ line_count, next_line });
    }

    std.debug.print("main3: all done. read {d} lines.\n", .{line_count});
}
