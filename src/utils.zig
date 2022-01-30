const std = @import("std");

// TODO consider showing the username (-n/--show-username) on process

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
    // only show processes of the user id, null means no restriction
    user_id: ?std.os.uid_t = null, // TODO consider having more than one uid allowed
};

/// Gets the uid of the owner of given pid
pub fn getPidOwner(pid: u32) !std.os.uid_t {
    var buf: [48]u8 = undefined;
    const proc_cmd_path = try std.fmt.bufPrint(&buf, "/proc/{}/stat", .{pid});
    const proc_fd = try std.os.open(proc_cmd_path, std.os.O.RDONLY, 0);
    defer std.os.close(proc_fd);

    const proc_stat = try std.os.fstat(proc_fd);
    return proc_stat.uid;
}

/// Gets the command line name (with args or not), caller must free the return
pub fn getCmdName(allocator: std.mem.Allocator, pid: u32, show_args: bool) ![]const u8 {
    var buf: [48]u8 = undefined;
    const proc_cmd_path = try std.fmt.bufPrint(&buf, "/proc/{}/cmdline", .{pid});
    const file_fd = try std.os.open(proc_cmd_path, std.os.O.RDONLY, 0);
    var file = std.fs.File{ .handle = file_fd, .capable_io_mode = .blocking };
    defer file.close();

    if (try file.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 512)) |cmd| {
        // ignores the last character
        std.mem.replaceScalar(u8, cmd[0 .. cmd.len - 2], 0, ' ');
        if (show_args) {
            return cmd;
        } else {
            defer allocator.free(cmd);
            if (getColumn(cmd, 0)) |cmd_name| return allocator.dupe(u8, std.fs.path.basename(cmd_name));
        }
    }
    return error.skipProc;
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
    var file = std.fs.File{ .handle = file_fd };
    defer file.close();

    const file_content = try file.reader().readUntilDelimiterOrEofAlloc(allocator, 0, 4096);
    if (file_content) |content| {
        return std.mem.split(u8, content, "\n");
    } else return error.invalidFile;
}

/// Checks if path is a existing file (user has to have access too) and its size is at least of 1
pub fn fileExistsNotEmpty(path: []const u8) bool {
    const file_fd = std.os.open(path, std.os.O.RDONLY, 0) catch return false;
    defer std.os.close(file_fd);

    const proc_stat = std.os.fstat(file_fd) catch return false;
    return proc_stat.size > 0;
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
pub fn usageExit(exit_value: u8) noreturn {
    const usage_str =
        \\Usage: coremem [OPTION]...
        \\Show program core memory usage
        \\-h, --help                       Show this help and exits
        \\-S, --swap                       Show swap information
        \\-s, --show-args                  Show all command line arguments
        \\-r, --reverse                    Reverses the order that processes are shown
        \\-t, --total                      Show only the total RAM memory in a human readable way
        \\-d, --discriminate-by-pid        Show by process rather than by program
        \\-w, --watch <N>                  Measure and show process memory every N seconds
        \\-l, --limit <N>                  Show only the last N processes
        \\-u, --user-id [uid]              Only consider the processes owned by uid (if none specified, defaults to current user)
        \\-p, --pid <pid>[,pid2,...pidN]   Only shows the memory usage of the PIDs specified
    ;

    const out = if (exit_value == 0) std.io.getStdOut() else std.io.getStdErr();
    out.writer().print("{s}\n", .{usage_str}) catch {}; // does nothing in case of error
    std.os.exit(exit_value);
}

const Flag = struct {
    long: []const u8,
    short: u8,
    kind: enum { no_arg, optional_arg, needs_arg } = .no_arg,
    identifier: enum { swap, by_pid, args, total, reverse, limit, user, pid, watch, help },
};

const flags = [_]Flag{
    .{ .identifier = .by_pid, .long = "discriminate-by-pid", .short = 'd' },
    .{ .identifier = .help, .long = "help", .short = 'h' },
    .{ .identifier = .args, .long = "show-args", .short = 's' },
    .{ .identifier = .swap, .long = "swap", .short = 'S' },
    .{ .identifier = .reverse, .long = "reverse", .short = 'r' },
    .{ .identifier = .total, .long = "total", .short = 't' },
    .{ .identifier = .user, .long = "user-id", .short = 'u', .kind = .optional_arg },
    .{ .identifier = .limit, .long = "limit", .short = 'l', .kind = .needs_arg },
    .{ .identifier = .pid, .long = "pid", .short = 'p', .kind = .needs_arg },
    .{ .identifier = .watch, .long = "watch", .short = 'w', .kind = .needs_arg },
};

/// Parse the args and returns the config
pub fn getConfig() !Config {
    var config: Config = .{};
    var iter_args = std.process.ArgIteratorPosix.init();
    _ = iter_args.skip(); // skip cmd name
    while (iter_args.next()) |arg| {
        // ignoring the sentinel
        try parseArg(arg[0..], &config, &iter_args);
    }
    return config;
}

// internal, for purposes of testing
fn parseArg(arg: []const u8, config: *Config, iterator: anytype) !void {
    if (arg.len < 2 or arg[0] != '-') usageExit(1); // no positional args, nor only '-' allowed
    var opt_cluster = arg[1..];
    while (opt_cluster.len > 0) : (opt_cluster = opt_cluster[1..]) {
        // get the index of the equals, if not then get the last index of the cluster
        const stop_index = if (std.mem.indexOfScalar(u8, opt_cluster, '=')) |equals_index| equals_index else opt_cluster.len;
        const flag = for (flags) |flag| {
            if ((opt_cluster[0] == '-' and std.mem.eql(u8, opt_cluster[1..stop_index], flag.long) or
                opt_cluster[0] == flag.short))
            {
                break flag;
            }
        } else usageExit(1);

        if (flag.kind == .no_arg) {
            switch (flag.identifier) {
                .help => usageExit(0),
                .total => config.only_total = true,
                .args => config.show_args = true,
                .swap => config.show_swap = true,
                .by_pid => config.per_pid = true,
                .reverse => config.reverse = true,
                else => unreachable,
            }
            if (opt_cluster[0] == '-') break else continue;
        }
        const opt_arg = blk: {
            if (stop_index != opt_cluster.len) {
                // if stop_index is the last character returns null, else returns the slice after the equals
                break :blk if (stop_index < opt_cluster.len - 1) opt_cluster[stop_index + 1 ..] else null;
            } else if (opt_cluster.len > 1 and opt_cluster[0] != '-') {
                break :blk opt_cluster[1..];
            } else { // get the next arg or null
                break :blk if (iterator.next()) |next_arg| next_arg[0..] else null;
                // break :blk iterator.next();
            }
        };
        if (opt_arg) |arg_value| {
            switch (flag.identifier) {
                .user => {
                    if (arg_value[0] != '-') {
                        config.user_id = try std.fmt.parseInt(std.os.uid_t, arg_value, 10);
                    } else {
                        config.user_id = std.os.linux.getuid();
                        opt_cluster = arg_value[0..]; // continues iterating based on this arg_value
                        continue;
                    }
                },
                .limit => config.limit = try std.fmt.parseInt(u32, arg_value, 10),
                .watch => config.watch = try std.fmt.parseInt(u32, arg_value, 10),
                .pid => config.pid_list = arg_value,
                else => unreachable,
            }
        } else if (flag.kind == .optional_arg) {
            switch (flag.identifier) {
                .user => config.user_id = std.os.linux.getuid(),
                else => unreachable,
            }
        } else usageExit(1);

        break;
    }
}

test "getConfig" {
    {
        const str = "-u 1000 -ds";
        var config = Config{};
        var iter = std.mem.tokenize(u8, str, " ");
        while (iter.next()) |arg| {
            try parseArg(arg, &config, &iter);
        }
        try std.testing.expectEqual(config.user_id.?, 1000);
        try std.testing.expectEqual(config.show_args, true);
        try std.testing.expectEqual(config.per_pid, true);
        try std.testing.expectEqual(config.show_swap, false);
        try std.testing.expectEqual(config.pid_list, null);
        try std.testing.expectEqual(config.reverse, false);
        try std.testing.expectEqual(config.limit, 0);
        try std.testing.expectEqual(config.watch, 0);
        try std.testing.expectEqual(config.only_total, false);
    }
    {
        const str = "--reverse --user-id --watch 5 --swap --limit=10";
        var config = Config{};
        var iter = std.mem.tokenize(u8, str, " ");
        while (iter.next()) |arg| {
            try parseArg(arg, &config, &iter);
        }
        try std.testing.expectEqual(config.user_id.?, std.os.linux.getuid()); // TODO make it more multiplatform
        try std.testing.expectEqual(config.show_args, false);
        try std.testing.expectEqual(config.per_pid, false);
        try std.testing.expectEqual(config.show_swap, true);
        try std.testing.expectEqual(config.pid_list, null);
        try std.testing.expectEqual(config.reverse, true);
        try std.testing.expectEqual(config.limit, 10);
        try std.testing.expectEqual(config.watch, 5);
        try std.testing.expectEqual(config.only_total, false);
    }
    {
        const str = "-d --pid 2354,9870 -t";
        var config = Config{};
        var iter = std.mem.tokenize(u8, str, " ");
        while (iter.next()) |arg| {
            try parseArg(arg, &config, &iter);
        }
        try std.testing.expectEqual(config.user_id, null);
        try std.testing.expectEqual(config.show_args, false);
        try std.testing.expectEqual(config.per_pid, true);
        try std.testing.expectEqual(config.show_swap, false);
        try std.testing.expect(config.pid_list != null);
        try std.testing.expect(std.mem.eql(u8, config.pid_list.?, "2354,9870"));
        try std.testing.expectEqual(config.reverse, false);
        try std.testing.expectEqual(config.limit, 0);
        try std.testing.expectEqual(config.watch, 0);
        try std.testing.expectEqual(config.only_total, true);
    }
}
