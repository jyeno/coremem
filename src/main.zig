const std = @import("std");
const utils = @import("utils.zig");

const page_size = std.mem.page_size / 1024; // in KiB

const Process = struct {
    pid: u32,
    private: u32,
    shared: u32,
    swap: u32,
    counter: u8 = 1,
    // owned by the process
    name: []const u8,

    fn showUsage(self: Process, writer: anytype, show_swap: bool, per_pid: bool) !void {
        var buffer: [9]u8 = undefined;
        try writer.print("{s:>9} + ", .{utils.toHuman(&buffer, self.private)});
        try writer.print("{s:>9} = ", .{utils.toHuman(&buffer, self.shared)});
        try writer.print("{s:>9}", .{utils.toHuman(&buffer, self.private + self.shared)});
        if (show_swap) try writer.print("   {s:>9}", .{utils.toHuman(&buffer, self.swap)});
        try writer.print("\t{s}", .{self.name});
        if (per_pid) {
            try writer.print(" [{}]\n", .{self.pid});
        } else if (self.counter > 1) {
            try writer.print(" ({})\n", .{self.counter});
        } else {
            try writer.print("\n", .{});
        }
    }

    fn mergeWith(self: *Process, other: Process) void {
        self.private += other.private;
        self.shared += other.shared;
        self.swap += other.swap;
        self.counter += 1;
    }

    fn cmpByTotalUsage(context: void, proc1: Process, proc2: Process) bool {
        _ = context;
        return (proc1.private + proc1.shared) < (proc2.private + proc2.shared);
    }
};

pub fn main() anyerror!u8 {
    const config = utils.getConfig() catch utils.usageExit(1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) std.debug.print("Memory leaked.\n", .{});
    }
    var stack_alloc = std.heap.stackFallback(2048, gpa.allocator());
    var allocator = stack_alloc.get();

    var bufOut = std.io.bufferedWriter(std.io.getStdOut().writer());
    if (config.only_total == null) try showHeader(bufOut.writer(), config.show_swap, config.per_pid);

    while (true) {
        var total_ram: u32 = 0;
        var total_swap: u32 = 0;
        const processes = try getProcessesMemUsage(
            allocator,
            config.pid_list,
            &total_ram,
            if (config.show_swap) &total_swap else null,
            config.per_pid,
            config.show_args,
            config.user_id,
        );
        defer {
            for (processes) |proc| allocator.free(proc.name);
            allocator.free(processes);
        }

        if (config.only_total) |display_format| switch (display_format) {
            .machine_readable => try bufOut.writer().print("{}\n", .{total_ram}),
            .human_readable => {
                var buffer: [9]u8 = undefined;
                try bufOut.writer().print("{s}\n", .{utils.toHuman(&buffer, total_ram)});
            },
        } else {
            if (config.reverse) std.mem.reverse(Process, processes);

            var i: usize = if (config.limit != 0 and config.limit < processes.len) processes.len - config.limit else 0;
            for (processes[i..]) |proc| {
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

/// Shows the header
fn showHeader(writer: anytype, show_swap: bool, per_pid: bool) !void {
    try writer.print(" Private  +   Shared  =  RAM used", .{});
    if (show_swap) try writer.print("   Swap used", .{});
    try writer.print("\tProgram", .{});
    if (per_pid) try writer.print(" [pid]", .{});
    try writer.print("\n\n", .{});
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
    try writer.print("{s:>33}", .{utils.toHuman(&buffer, total_ram)});
    if (total_swap) |swap| {
        try writer.print("{s:>12}\n", .{utils.toHuman(&buffer, swap)});
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

/// Gets the processes memory usage, if pids_list is null then
/// gets all the processes that the used has access of
/// The processes are sorted in ascending order by total amount of RAM
/// that they use
fn getProcessesMemUsage(
    allocator: std.mem.Allocator,
    pids_list: ?[]const u8,
    total_ram: *u32,
    total_swap: ?*u32,
    per_pid: bool,
    show_args: bool,
    user_id: ?std.os.uid_t,
) ![]Process {
    var array_procs = std.ArrayList(Process).init(allocator);
    defer array_procs.deinit();

    if (pids_list) |pids| {
        var iter_pids = std.mem.split(u8, pids, ",");
        while (iter_pids.next()) |pidStr| {
            const pid = try std.fmt.parseInt(u32, pidStr, 10);
            if (user_id != null and user_id.? != try utils.getPidOwner(pid)) continue;

            try addOrMergeProcMemUsage(allocator, &array_procs, pid, total_ram, total_swap, per_pid, show_args);
        }
    } else {
        var proc_dir = try std.fs.cwd().openDir("/proc", .{ .access_sub_paths = false, .iterate = true });
        defer proc_dir.close();

        var proc_it = proc_dir.iterate();
        while (try proc_it.next()) |proc_entry| {
            if (proc_entry.kind != .Directory) {
                continue;
            } // only treat process entries related to PIDs
            const pid = std.fmt.parseInt(u32, proc_entry.name, 10) catch continue;
            if (user_id != null and user_id.? != try utils.getPidOwner(pid)) continue;

            try addOrMergeProcMemUsage(allocator, &array_procs, pid, total_ram, total_swap, per_pid, show_args);
        }
    }
    std.sort.sort(Process, array_procs.items, {}, Process.cmpByTotalUsage);

    return array_procs.toOwnedSlice();
}

// helper function
fn addOrMergeProcMemUsage(
    allocator: std.mem.Allocator,
    array_procs: *std.ArrayList(Process),
    pid: u32,
    total_ram: *u32,
    total_swap: ?*u32,
    per_pid: bool,
    show_args: bool,
) !void {
    const proc = procMemoryData(allocator, pid, show_args) catch |err| switch (err) {
        error.skipProc => return,
        else => return err,
    };
    if (per_pid) {
        try array_procs.append(proc);
    } else {
        // iterate through existings items, if found any, then merge then together
        var i: usize = 0;
        while (i < array_procs.items.len) : (i += 1) {
            if (std.mem.eql(u8, proc.name, array_procs.items[i].name)) {
                allocator.free(proc.name); // liberates memory, as they are the same
                array_procs.items[i].mergeWith(proc);
                break;
            }
        } else {
            try array_procs.append(proc); // if none found, add it to array of processes
        }
    }
    total_ram.* += proc.private + proc.shared;
    if (total_swap) |swap| swap.* += proc.swap;
}

/// Creates and return a `Process`, its memory usage data is populated
/// based on /proc smaps if exists, if not, uses /proc statm, also gets the cmd name
fn procMemoryData(allocator: std.mem.Allocator, pid: u32, show_args: bool) !Process {
    var buf: [48]u8 = undefined;
    var private: u32 = 0;
    var private_huge: u32 = 0;
    var shared: u32 = 0;
    var shared_huge: u32 = 0;
    var swap: u32 = 0;
    var pss: u32 = 0;
    var pss_adjust: f32 = 0.0;
    var swap_pss: u32 = 0;

    var proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/smaps_rollup", .{pid});
    if (!utils.fileExistsNotEmpty(proc_data_path)) {
        proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/smaps", .{pid});
    }
    // if cant read smaps, then uses statm
    if (utils.fileExistsNotEmpty(proc_data_path)) {
        // if cant read the contents, skip it
        var iter_smaps = utils.readLines(allocator, proc_data_path) catch return error.skipProc;
        defer allocator.free(iter_smaps.buffer);

        _ = iter_smaps.next(); // ignore first line
        while (iter_smaps.next()) |line| {
            if (line.len == 0) continue;
            const usageValueStr = utils.getColumn(line, 1) orelse continue;

            const usageValue = std.fmt.parseInt(u32, usageValueStr, 10) catch {
                // in smaps there is some lines that references some shared objects, ignore it
                continue;
            };
            if (utils.startsWith(line, "Private_Hugetlb:")) {
                private_huge += usageValue;
            } else if (utils.startsWith(line, "Shared_Hugetlb:")) {
                shared_huge += usageValue;
            } else if (utils.startsWith(line, "Shared")) {
                shared += usageValue;
            } else if (utils.startsWith(line, "Private")) {
                private += usageValue;
            } else if (utils.startsWith(line, "Pss:")) {
                pss_adjust += 0.5;
                pss += usageValue;
            } else if (utils.startsWith(line, "Swap:")) {
                swap += usageValue;
            } else if (utils.startsWith(line, "SwapPss:")) {
                swap_pss += usageValue;
            }
        }
        if (pss != 0) shared += pss + @floatToInt(u32, pss_adjust) - private;
        private += private_huge;
        if (swap_pss != 0) swap = swap_pss;
    } else {
        proc_data_path = try std.fmt.bufPrint(&buf, "/proc/{}/statm", .{pid});
        var iter_statm = try utils.readLines(allocator, proc_data_path);
        defer allocator.free(iter_statm.buffer);
        const statm = iter_statm.next().?;

        var rss: u32 = try std.fmt.parseInt(u32, utils.getColumn(statm, 1).?, 10);
        rss *= page_size;
        shared = try std.fmt.parseInt(u32, utils.getColumn(statm, 2).?, 10);
        shared *= page_size;
        private = std.math.max(rss, shared) - std.math.min(rss, shared);
    }
    return Process{
        .private = private,
        .shared = shared + shared_huge,
        .swap = swap,
        .pid = pid,
        .name = try utils.getCmdName(allocator, pid, show_args),
    };
}

test "utils" {
    _ = @import("utils.zig");
}
