const std = @import("std");

const page_size = std.mem.page_size / 1024; // in KiB

const Process = struct {
    pid: u32,
    private: u32,
    shared: u32,
    swap: u32,
    // owned by the process
    name: []const u8,

    fn showUsage(self: Process, writer: anytype, show_swap: bool, per_pid: bool) !void {
        var buffer: [9]u8 = undefined;
        try writer.print("{s:>9} + ", .{toHuman(&buffer, self.private)});
        try writer.print("{s:>9} = ", .{toHuman(&buffer, self.shared)});
        try writer.print("{s:>9}", .{toHuman(&buffer, self.private + self.shared)});
        if (show_swap) try writer.print("   {s:>9}", .{toHuman(&buffer, self.swap)});
        try writer.print("\t{s}", .{self.name});
        if (per_pid) {
            try writer.print(" [{}]\n", .{self.pid});
        } else {
            try writer.print("\n", .{});
        }
    }

    fn cmpByTotalUsage(context: void, proc1: Process, proc2: Process) bool {
        _ = context;
        return (proc1.private + proc1.shared) < (proc2.private + proc2.shared);
    }
};

const Config = struct {
    show_swap: bool = false,
    // discriminate by pid
    per_pid: bool = false,
    // if null, then should show all the processes that the user has access of (WIP)
    pid_list: ?[]const u8 = null,
    // print the processes in decrescent order, by total RAM usage
    reverse: bool = false,
    // 0 means that there is no limit
    limit: u32 = 0,
    split_args: bool = false,
    // shows only the total amount of memory used
    only_total: bool = false,
    // means that watch is off
    watch: u32 = 0,
};

pub fn main() anyerror!u8 {
    const config = getConfig() catch blk: {
        usageExit(1); // if got here, then there is an invalid option
        break :blk Config{}; // workaround to call usageExit
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) std.debug.print("Memory leaked.\n", .{});
    }
    var stack_alloc = std.heap.stackFallback(2048, gpa.allocator());
    var allocator = stack_alloc.get();

    var bufOut = std.io.bufferedWriter(std.io.getStdOut().writer());
    if (!config.only_total) try showHeader(bufOut.writer(), config.show_swap, config.per_pid);

    while (true) {
        var total_ram: u32 = 0;
        var total_swap: u32 = 0;
        const processes = try getProcessesMemUsage(
            allocator,
            config.pid_list,
            &total_ram,
            if (config.show_swap) &total_swap else null,
            config.per_pid,
        );
        defer allocator.free(processes);

        if (config.only_total) {
            var buffer: [9]u8 = undefined;
            try bufOut.writer().print("{s}\n", .{toHuman(&buffer, total_ram)});
        } else {
            if (config.reverse) std.mem.reverse(Process, processes);

            var i: usize = if (config.limit != 0 and config.limit < processes.len) processes.len - config.limit else 0;
            for (processes[i..]) |proc| {
                defer allocator.free(proc.name); // deinitializing as we dont need anymore

                try proc.showUsage(bufOut.writer(), config.show_swap, config.per_pid);
            }

            try showFooter(
                bufOut.writer(),
                total_ram,
                if (config.show_swap) total_swap else null,
            );
        }

        try bufOut.flush();

        if (config.watch == 0) {
            break;
        } else {
            std.time.sleep(config.watch * 1000000000);
        }
    }
    return 0;
}

fn usageExit(exit_value: u8) void {
    const usage_str =
        \\Usage: coremem [OPTION]...
        \\Show program core memory usage
        \\-h, --help                       Show this help and exits
        \\-p, --pid <pid>[,pid2,...pidN]   Only shows the memory usage of the PIDs specified
        \\-s, --split-args                 Show and separate by, all command line arguments (WIP)
        \\-t, --total                      Show only the total RAM memory in a human readable way
        \\-d, --discriminate-by-pid        Show by process rather than by program (WIP)
        \\-S, --swap                       Show swap information
        \\-w, --watch <N>                  Measure and show process memory every N seconds
        \\-l, --limit <N>                  Show only the last N processes
        \\-r, --reverse                    Reverses the order that processes are shown
    ;
    std.io.getStdOut().writer().print("{s}\n", .{usage_str}) catch {}; // does nothing in case of error
    std.os.exit(exit_value);
}

/// Parse the args and returns the config
fn getConfig() !Config {
    var config: Config = .{};
    var iter_args = std.process.ArgIterator.init();
    if (iter_args.skip()) {
        while (iter_args.nextPosix()) |arg| {
            if (arg.len < 2 or arg[0] != '-') usageExit(1);
            // TODO support opt=arg_opt
            var opt_cluster = arg[1..];
            while (opt_cluster.len > 0) : (opt_cluster = opt_cluster[1..]) {
                switch (opt_cluster[0]) {
                    '-' => {
                        if (std.mem.eql(u8, "-help", opt_cluster)) {
                            usageExit(0);
                        } else if (std.mem.eql(u8, "-split-args", opt_cluster)) {
                            config.split_args = true;
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
                    's' => config.split_args = true,
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

/// Shows the header
fn showHeader(writer: anytype, show_swap: bool, per_pid: bool) !void {
    try writer.print(" Private  +   Shared  =  RAM used", .{});
    if (show_swap) try writer.print("   Swap used", .{});
    try writer.print("\tProgram", .{});
    if (per_pid) try writer.print(" [pid]", .{});
    try writer.print("\n\n", .{});
}

/// Gets the processes memory usage, if pids_list is null then
/// gets all the processes that the used has access of
/// The processes are sorted in ascending order by total amount of RAM
/// that they use
fn getProcessesMemUsage(
    allocator: std.mem.Allocator,
    pids_list: ?[]const u8,
    total_ram: *u32,
    total_swap: ?*u32,
    per_pid: bool, // TODO support properly
) ![]Process {
    _ = per_pid;
    var arrayProcs = std.ArrayList(Process).init(allocator);
    defer arrayProcs.deinit();
    if (pids_list) |pids| {
        var iter_pids = std.mem.split(u8, pids, ",");
        while (iter_pids.next()) |pidStr| {
            const pid = try std.fmt.parseInt(u32, pidStr, 10);
            const proc = procMemoryData(allocator, pid) catch {
                // std.debug.print("err: {}\n", .{err});
                // return err;
                // TODO show help message and consider what to do, if should exit or not
                std.debug.print("Invalid pid '{}'\n", .{pid});
                std.os.exit(1);
            };
            try arrayProcs.append(proc);
            total_ram.* += proc.private + proc.shared;
            if (total_swap) |swap| swap.* += proc.swap;
        }
    } else {
        // TODO get all processes that the user as access to
    }
    std.sort.sort(Process, arrayProcs.items, {}, Process.cmpByTotalUsage);

    return arrayProcs.toOwnedSlice();
}

/// Shows the footer (separators and in the middle the total ram
/// and swap, if not null, used)
fn showFooter(writer: anytype, total_ram: u32, total_swap: ?u32) !void {
    try writer.print("{s:->33}", .{""});
    if (total_swap != null) {
        try writer.print("{s:->12}\n", .{""});
    } else {
        try writer.print("\n", .{});
    }

    // show the total ram used
    var buffer: [9]u8 = undefined;
    try writer.print("{s:>33}", .{toHuman(&buffer, total_ram)});
    if (total_swap) |swap| {
        try writer.print("{s:>12}\n", .{toHuman(&buffer, swap)});
    } else {
        try writer.print("\n", .{});
    }

    try writer.print("{s:=>33}", .{""});
    if (total_swap != null) {
        try writer.print("{s:=>12}\n\n", .{""});
    } else {
        try writer.print("\n\n", .{});
    }
}

/// Returns a slice with a human-readable format based on `num`
fn toHuman(buffer: []u8, num: usize) []const u8 {
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

/// Creates and return a `Process`, its memory usage data is populated
/// based on /proc smaps if exists, if not, uses /proc statm
fn procMemoryData(allocator: std.mem.Allocator, pid: u32) !Process {
    var buf: [32]u8 = undefined;

    var proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/cmdline", .{pid});
    var it = try readLines(allocator, proc_data_path);
    defer allocator.free(it.buffer);
    const cmd_name = try allocator.dupe(u8, getColumn(it.next().?, 0).?);

    // TODO figure out how to properly calculate Shared memory
    var private: u32 = 0;
    var private_huge: u32 = 0;
    var shared: u32 = 0;
    var shared_huge: u32 = 0;
    var swap: u32 = 0;
    var pss: u32 = 0;
    var pss_adjust: f32 = 0.0;
    var swap_pss: u32 = 0;

    proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/smaps_rollup", .{pid});
    if (!fileExists(proc_data_path)) {
        proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/smaps", .{pid});
    }
    var iter_smaps = readLines(allocator, proc_data_path) catch null; // if cant read smaps, then uses statm
    // cant use directly on the if because an iterator must be mutable
    if (iter_smaps != null) {
        defer allocator.free(iter_smaps.?.buffer);

        _ = iter_smaps.?.next(); // ignore first line
        while (iter_smaps.?.next()) |line| {
            if (line.len == 0) continue;
            const usageValueStr = getColumn(line, 1);
            const usageValue = std.fmt.parseInt(u32, usageValueStr.?, 10) catch {
                // in smaps there is some lines that references some shared objects, ignore it
                continue;
            };
            if (startsWith(line, "Private_Hugetlb:")) {
                private_huge += usageValue;
            } else if (startsWith(line, "Shared_Hugetlb:")) {
                shared_huge += usageValue;
            } else if (startsWith(line, "Shared")) {
                shared += usageValue;
            } else if (startsWith(line, "Private")) {
                private += usageValue;
            } else if (startsWith(line, "Pss:")) {
                pss_adjust += 0.5;
                pss += usageValue;
            } else if (startsWith(line, "Swap:")) {
                swap += usageValue;
            } else if (startsWith(line, "SwapPss:")) {
                swap_pss += usageValue;
            }
        }
        if (pss != 0) shared += pss + @floatToInt(u32, pss_adjust) - private;
        private += private_huge;
        if (swap_pss != 0) swap = swap_pss;
    } else {
        proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/statm", .{pid});
        var iter_statm = try readLines(allocator, proc_data_path);
        defer allocator.free(iter_statm.buffer);
        const statm = iter_statm.next().?;

        var rss: u32 = try std.fmt.parseInt(u32, getColumn(statm, 1).?, 10);
        rss *= page_size;
        shared = try std.fmt.parseInt(u32, getColumn(statm, 2).?, 10);
        shared += page_size;
        private = rss - shared;
    }
    return Process{
        .private = private,
        .shared = shared + shared_huge,
        .swap = swap,
        .pid = pid,
        .name = cmd_name,
    };
}

// Gets the n-th column, columns are separated by spaces
fn getColumn(str: []const u8, column: usize) ?[]const u8 {
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

fn startsWith(str1: []const u8, str2: []const u8) bool {
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
fn readLines(allocator: std.mem.Allocator, file_path: []const u8) !std.mem.SplitIterator(u8) {
    var file_fd = try std.os.open(file_path, std.os.O.RDONLY, 0);
    var file = std.fs.File{ .handle = file_fd, .capable_io_mode = .blocking };
    defer file.close();

    var reader = file.reader();

    const content = try reader.readAllAlloc(allocator, 4096);

    return std.mem.split(u8, content, "\n");
}

fn fileExists(path: []const u8) bool {
    // TODO consider change it to only return false when the
    // error if FileNotExists and return the other errors
    const file = std.os.open(path, std.os.O.RDONLY, 0) catch return false;
    defer std.os.close(file);

    return true;
}
