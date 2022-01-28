const std = @import("std");
const syscall0 = std.os.linux.syscall0;
const pid_t = std.os.pid_t;

pub const Config = struct {
    show_swap: bool = false,
    // discriminate by pid
    per_pid: bool = false,
    // if null, then should show all the processes that the user has access of (WIP)
    pid_list: ?[]const u8 = null,
    // print the processes in decrescent order, by total RAM usage
    reverse: bool = false,
    // 0 means that there is no limit
    limit: u32 = 0,
    show_args: bool = false,
    // shows only the total amount of memory used
    only_total: bool = false,
    // means that watch is off
    watch: u32 = 0,
};

pub fn getppid() pid_t {
    return @bitCast(pid_t, @truncate(u32, syscall0(.getppid)));
}

/// Gets the command line name (with args or not), caller must free the return
pub fn getCmdName(allocator: std.mem.Allocator, pid: u32, show_args: bool) ![]const u8 {
    var buf: [48]u8 = undefined;
    return if (show_args) blk: {
        const proc_cmd_path = try std.fmt.bufPrint(&buf, "/proc/{}/cmdline", .{pid});
        const file_fd = try std.os.open(proc_cmd_path, std.os.O.RDONLY, 0);
        var file = std.fs.File{ .handle = file_fd, .capable_io_mode = .blocking };
        defer file.close();

        if (try file.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 256)) |cmd_with_args| {
            // ignores the last character
            std.mem.replaceScalar(u8, cmd_with_args[0 .. cmd_with_args.len - 2], 0, ' ');
            break :blk cmd_with_args;
        } else return error.skipProc;
    } else blk: {
        const proc_status_path = try std.fmt.bufPrint(&buf, "/proc/{}/status", .{pid});
        const file_fd = try std.os.open(proc_status_path, std.os.O.RDONLY, 0);
        var file = std.fs.File{ .handle = file_fd, .capable_io_mode = .blocking };
        defer file.close();
        if (try file.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 256)) |cmd_name_line| {
            defer allocator.free(cmd_name_line);
            var iter_name = std.mem.tokenize(u8, cmd_name_line, "\t");
            _ = iter_name.next(); // ignores "Name:...spaces..."
            break :blk allocator.dupe(u8, iter_name.rest());
        } else return error.skipProc;
    };
}

/// Gets the n-th column, columns are separated by spaces
pub fn getColumn(str: []const u8, column: usize) ?[]const u8 {
    var it = std.mem.tokenize(u8, str, " ");
    var i: usize = 0;
    while (i < column) : (i += 1) {
        _ = it.next(); // ignoring the value
    }
    return it.next();
}

test "getColumn" {
    const str = "this is    a   test";
    try std.testing.expect(std.mem.eql(u8, getColumn(str, 0).?, "this"));
    try std.testing.expect(std.mem.eql(u8, getColumn(str, 1).?, "is"));
    try std.testing.expect(std.mem.eql(u8, getColumn(str, 2).?, "a"));
    try std.testing.expect(std.mem.eql(u8, getColumn(str, 3).?, "test"));
    try std.testing.expect(getColumn(str, 4) == null);
}

/// Checks if str1 starts with str2, case sensitive
pub fn startsWith(str1: []const u8, str2: []const u8) bool {
    return if (str2.len > str1.len) false else std.mem.eql(u8, str1[0..str2.len], str2);
}

test "startsWith" {
    try std.testing.expect(startsWith("Starting today", "Start"));
    try std.testing.expect(startsWith("doesStarting today", "doesStart"));
    try std.testing.expect(!startsWith("Starting today...", "start"));
    try std.testing.expect(!startsWith("today starting...", " today"));
}

/// Reads a file and returns an iterator of the contents, caller is responsible
/// of deallocating the contents read
pub fn readLines(allocator: std.mem.Allocator, file_path: []const u8) !std.mem.SplitIterator(u8) {
    const file_fd = try std.os.open(file_path, std.os.O.RDONLY, 0);
    var file = std.fs.File{ .handle = file_fd, .capable_io_mode = .blocking };
    defer file.close();

    var reader = file.reader();
    const content = try reader.readAllAlloc(allocator, 4096);
    return std.mem.split(u8, content, "\n");
}

/// Checks if path is a existing file (user has to have access too)
pub fn fileExists(path: []const u8) bool {
    const file = std.os.open(path, std.os.O.RDONLY, 0) catch return false;
    defer std.os.close(file);

    return true;
}

/// Returns a slice with a human-readable format based on `num`
pub fn toHuman(buffer: []u8, num: usize) []const u8 {
    const powers = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };
    var f: f64 = @intToFloat(f64, num);
    var i: u2 = 0;
    while (f >= 1000.0) : (i += 1) {
        f /= 1024.0;
    }
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ f, powers[i] }) catch unreachable;
}

test "toHuman" {
    var buffer: [9]u8 = undefined;
    try std.testing.expect(std.mem.eql(u8, toHuman(&buffer, 128), "128.0 KiB"));
    try std.testing.expect(std.mem.eql(u8, toHuman(&buffer, 1024), "1.0 MiB"));
    try std.testing.expect(std.mem.eql(u8, toHuman(&buffer, 2184), "2.1 MiB"));
    try std.testing.expect(std.mem.eql(u8, toHuman(&buffer, 200184), "195.5 MiB"));
}

/// prints the usage and then exits
pub fn usageExit(exit_value: u8) void {
    const usage_str =
        \\Usage: coremem [OPTION]...
        \\Show program core memory usage
        \\-h, --help                       Show this help and exits
        \\-p, --pid <pid>[,pid2,...pidN]   Only shows the memory usage of the PIDs specified
        \\-s, --show-args                  Show all command line arguments
        \\-t, --total                      Show only the total RAM memory in a human readable way
        \\-d, --discriminate-by-pid        Show by process rather than by program
        \\-S, --swap                       Show swap information
        \\-w, --watch <N>                  Measure and show process memory every N seconds
        \\-l, --limit <N>                  Show only the last N processes
        \\-r, --reverse                    Reverses the order that processes are shown
    ;

    const out = if (exit_value == 0) std.io.getStdOut() else std.io.getStdErr();
    out.writer().print("{s}\n", .{usage_str}) catch {}; // does nothing in case of error
    std.os.exit(exit_value);
}

/// Parse the args and returns the config
pub fn getConfig() !Config {
    var config: Config = .{};
    var iter_args = std.process.ArgIterator.init();
    if (iter_args.skip()) {
        while (iter_args.nextPosix()) |arg| {
            if (arg.len < 2 or arg[0] != '-') usageExit(1);
            var opt_cluster = arg[1..];
            while (opt_cluster.len > 0) : (opt_cluster = opt_cluster[1..]) {
                switch (opt_cluster[0]) {
                    '-' => {
                        if (std.mem.eql(u8, "-help", opt_cluster)) {
                            usageExit(0);
                        } else if (std.mem.eql(u8, "-show-args", opt_cluster)) {
                            config.show_args = true;
                        } else if (std.mem.eql(u8, "-total", opt_cluster)) {
                            config.only_total = true;
                        } else if (std.mem.eql(u8, "-discriminate-by-pid", opt_cluster)) {
                            config.per_pid = true;
                        } else if (std.mem.eql(u8, "-swap", opt_cluster)) {
                            config.show_swap = true;
                        } else if (std.mem.eql(u8, "-limit", opt_cluster) or
                            std.mem.eql(u8, "-pid", opt_cluster) or
                            std.mem.eql(u8, "-watch", opt_cluster))
                        {
                            break; // options with arguments, next block
                        } else usageExit(1);

                        continue; // goes to next arg
                    },
                    'h' => usageExit(0),
                    's' => config.show_args = true,
                    't' => config.only_total = true,
                    'd' => config.per_pid = true,
                    'S' => config.show_swap = true,
                    'r' => config.reverse = true,
                    'l', 'p', 'w' => break, // options with arguments, next block
                    else => usageExit(1),
                }
            } else continue;

            const opt_arg = if (opt_cluster[0] != '-' and opt_cluster.len > 1) opt_cluster[1..] else iter_args.nextPosix();
            if (opt_arg == null) usageExit(1);

            switch (opt_cluster[0]) {
                '-' => {
                    if (std.mem.eql(u8, "-limit", opt_cluster)) {
                        config.limit = try std.fmt.parseInt(u8, opt_arg.?, 10);
                    } else if (std.mem.eql(u8, "-pid", opt_cluster)) {
                        config.pid_list = opt_arg.?;
                    } else if (std.mem.eql(u8, "-watch", opt_cluster)) {
                        config.limit = try std.fmt.parseInt(u8, opt_arg.?, 10);
                    } else unreachable;
                },
                'p' => config.pid_list = opt_arg.?,
                'w' => config.watch = try std.fmt.parseInt(u32, opt_arg.?, 10),
                'l' => config.limit = try std.fmt.parseInt(u32, opt_arg.?, 10),
                else => unreachable,
            }
        }
    }
    return config;
}
