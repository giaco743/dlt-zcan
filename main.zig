const std = @import("std");
const builtin = @import("builtin");
// const filter = @import("filter.zig");
const dlt = @import("dlt.zig");
const index = @import("index.zig");
const pretty = @import("pretty.zig");

const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    connect: ?[]const u8 = null,

    ecuid: ?[4]u8 = null,
    apid: ?[4]u8 = null,
    ctid: ?[4]u8 = null,
    level: ?dlt.LogSeverity = null,
    substring: ?[]const u8 = null,

    start: ?usize = null,
    end: ?usize = null,

    storage: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    const name = it.next() orelse {
        return error.MissingProgramName;
    };
    var options = Options{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--connect")) {
            if (it.next()) |host| {
                options.connect = host;
            } else {
                return error.EcuIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--infile")) {
            if (it.next()) |infile| {
                options.input = infile;
            } else {
                return error.InputFileNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--outfile")) {
            if (it.next()) |outfile| {
                options.output = outfile;
            } else {
                return error.InputFileNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--ecuid")) {
            if (it.next()) |id| {
                if (id.len > 4)
                    return error.InvalidEcuId;
                var eid: [4]u8 = @splat(0);
                @memcpy(eid[0..id.len], id);
                options.ecuid = eid;
            } else {
                return error.EcuIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--apid")) {
            if (it.next()) |id| {
                var aid: [4]u8 = @splat(0);
                @memcpy(aid[0..id.len], id);
                options.apid = aid;
            } else {
                return error.AppIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--ctid")) {
            if (it.next()) |id| {
                var cid: [4]u8 = @splat(0);
                @memcpy(cid[0..id.len], id);
                options.ctid = cid;
            } else {
                return error.ContextIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--level")) {
            if (it.next()) |l_str| {
                options.level = @fromBackingInt(@intCast(try std.fmt.parseInt(u4, l_str, 10)));
            } else {
                return error.LogLevelNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--substring")) {
            if (it.next()) |substr| {
                options.substring = substr;
            } else {
                return error.SubstringNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--start")) {
            if (it.next()) |start| {
                options.start = try std.fmt.parseInt(usize, start, 10);
            } else {
                return error.LogLevelNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--end")) {
            if (it.next()) |end| {
                options.end = try std.fmt.parseInt(usize, end, 10);
            } else {
                return error.LogLevelNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--storage")) {
            options.storage = true;
        } else {
            if (options.output == null) {
                options.output = arg;
            } else {
                std.debug.print(
                    "Usage: {s} [--connect host] [--ecuid ECUID] [--apid APID] [--ctid CTID] [--substring STRING] [--level LEVEL]\n",
                    .{name},
                );
                return error.WrongUsage;
            }
        }
    }

    var wbuf: [256 * 1024]u8 = undefined;
    var out = if (options.output) |output| try std.Io.Dir.cwd().createFile(io, output, .{
        .exclusive = false,
        .truncate = true,
    }) else std.Io.File.stdout();
    var writer_impl = out.writer(io, &wbuf);
    const writer = &writer_impl.interface;

    // const fltr = filter.DltFilter{
    //     .ecuid = options.ecuid,
    //     .apid = options.apid,
    //     .ctid = options.ctid,
    //     .severity = options.level,
    //     .substring = options.substring,
    // };
    // if (options.connect) |host| {
    // var it_host = std.mem.splitScalar(u8, host, ':');
    // const hostname = it_host.next() orelse return error.MissingHostname;
    // const port_str = it_host.next() orelse return error.MissingPort;
    // const port = try std.fmt.parseInt(u16, port_str, 10);
    // const hn = try std.Io.net.HostName.init(hostname);
    // const stream = try hn.connect(io, port, .{ .mode = .stream });
    // defer stream.close(io);

    // var rbuf: [256 * 1024]u8 = undefined;
    // var reader_impl = stream.reader(io, &rbuf);
    // const reader = &reader_impl.interface;
    // try filter.filterStream(reader, writer, fltr, options.storage);
    if (options.input) |path| {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var mmap = try file.createMemoryMap(
            io,
            .{
                .len = try file.length(io),
                .protection = .{ .read = true },
            },
        );
        defer mmap.destroy(io);

        const allocator = init.arena.allocator();
        const dlt_index = try index.index(mmap.memory, allocator);
        defer allocator.free(dlt_index);
        std.debug.print("Indexed {d} dlt messages:\n", .{dlt_index.len});
        var idx = options.start orelse return;
        const end_idx = options.end orelse return;
        var outbuf: [64 * 1024]u8 = undefined;
        while (idx < end_idx) : (idx += 1) {
            const start = dlt_index[idx] + dlt.STORAGE_HEADER_SIZE;
            const end = if (idx + 1 < dlt_index.len) dlt_index[idx + 1] else mmap.memory[start..].len;
            const msg = try dlt.DltMessage.init(mmap.memory[start..end]);
            const log_msg = try pretty.printMessage(msg, &outbuf);
            try writer.writeAll(log_msg);
            try writer.flush();
        }
    }
}
