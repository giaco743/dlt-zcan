const std = @import("std");

const DLT_PATTERN = "DLT\x01";

const STORAGE_HEADER_SIZE: u16 = 16;

const HeaderType = packed struct(u8) {
    wevt: u1,
    msbf: u1,
    weid: u1,
    wsid: u1,
    wtms: u1,
    vers: u3,
};

const STANDARD_HEADER_SIZE: u16 = 4;

const MessageType = enum(u3) {
    log = 0x0,
    app_trace = 0x1,
    nw_trace = 0x2,
    control = 0x3,
    _, // Fallback for unspecified vendor variants
};

pub const LogSeverity = enum(u4) {
    fatal = 0x1,
    err = 0x2,
    warn = 0x3,
    info = 0x4,
    debug = 0x5,
    verbose = 0x6,
    _, // Handles non-log trace modes cleanly
};

const MessageInfo = packed struct(u8) {
    verbose: u1,
    mstp: MessageType,
    mtin: LogSeverity,
};

const EXTENDED_HEADER_SIZE: u16 = 10;

const TypeInfo = packed struct(u32) {
    tyle: u4,
    bool_: u1,
    sint: u1,
    uint: u1,
    floa: u1,
    aray: u1,
    strg: u1,
    rawd: u1,
    vari: u1,
    fixp: u1,
    trai: u1,
    stru: u1,
    scod: u3,
    reserved: u14,
};

const DltFilter = struct {
    ecuid: ?[4]u8,
    apid: ?[4]u8,
    ctid: ?[4]u8,
    severity: ?LogSeverity,
    substring: ?[]const u8,
};

const DltMessageView = struct {
    storage_hdr: []const u8,
    standard_hdr: []const u8,
    hdr_type: HeaderType,
    payload: []const u8,
    ecu_id: ?[]const u8,
    session_id: ?[]const u8,
    timestamp: ?[]const u8,
    ext_hdr: ?[]const u8,
    len: u16,

    fn init(buf: []const u8) !DltMessageView {
        if (buf.len < STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE) return error.Truncated;
        if (!std.mem.eql(u8, buf[0..4], DLT_PATTERN[0..])) return error.WrongPattern;

        const storage_hdr = buf[0..STORAGE_HEADER_SIZE];
        const standard_hdr = buf[STORAGE_HEADER_SIZE..][0..STANDARD_HEADER_SIZE];

        const len = std.mem.readInt(u16, standard_hdr[2..4], .big) + STORAGE_HEADER_SIZE;
        if (buf.len < len) return error.Truncated;

        var ecu_id: ?[]const u8 = null;
        var session_id: ?[]const u8 = null;
        var timestamp: ?[]const u8 = null;
        var ext_hdr: ?[]const u8 = null;

        const hdr_type: HeaderType = @bitCast(standard_hdr[0]);
        var payload_offset = STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE;
        if (hdr_type.weid == 1) {
            ecu_id = buf[payload_offset..][0..4];
            payload_offset += 4;
        }
        if (hdr_type.wsid == 1) {
            session_id = buf[payload_offset..][0..4];
            payload_offset += 4;
        }
        if (hdr_type.wtms == 1) {
            timestamp = buf[payload_offset..][0..4];
            payload_offset += 4;
        }
        if (hdr_type.wevt == 1) {
            ext_hdr = buf[payload_offset..][0..EXTENDED_HEADER_SIZE];
            payload_offset += EXTENDED_HEADER_SIZE;
        }
        const payload = buf[payload_offset..len];
        return DltMessageView{
            .storage_hdr = storage_hdr,
            .standard_hdr = standard_hdr,
            .hdr_type = hdr_type,
            .payload = payload,
            .ecu_id = ecu_id,
            .session_id = session_id,
            .timestamp = timestamp,
            .ext_hdr = ext_hdr,
            .len = len,
        };
    }
    fn ecuId(self: *const DltMessageView) []const u8 {
        if (self.ecu_id) |ecu_id| return ecu_id;
        // Fall back to storage header ECU ID
        return self.storage_hdr[12..];
    }
    fn appId(self: *const DltMessageView) ?[]const u8 {
        if (self.ext_hdr) |ext_hdr|
            return ext_hdr[2..6];
        return null;
    }
    fn ctxId(self: *const DltMessageView) ?[]const u8 {
        if (self.ext_hdr) |ext_hdr|
            return ext_hdr[6..10];
        return null;
    }
    fn messageInfo(self: *const DltMessageView) ?MessageInfo {
        if (self.ext_hdr) |ext_hdr|
            return @bitCast(ext_hdr[0]);
        return null;
    }
    fn noar(self: *const DltMessageView) ?u8 {
        if (self.ext_hdr) |ext_hdr|
            return @bitCast(ext_hdr[1]);
        return null;
    }
};

fn filter(reader: anytype, writer: anytype, fltr: DltFilter, pretty: bool) !void {
    var buf: [256 * 1024]u8 = undefined;
    var buffered: usize = 0;

    while (true) {
        const n = try reader.readSliceShort(buf[buffered..]);
        if (n == 0) {
            if (buffered != 0)
                return error.TruncatedMessage;
            break;
        }

        const len = buffered + n;
        var pos: usize = 0;

        while (pos < len) {
            const remaining = buf[pos..len];
            const msg_view = DltMessageView.init(remaining) catch |err| switch (err) {
                error.Truncated => break,
                else => return err,
            };
            pos += msg_view.len;

            if (fltr.ecuid) |ecuid| {
                if (!std.mem.eql(u8, ecuid[0..], msg_view.ecuId())) continue;
            }

            if (fltr.apid) |appid| {
                if (!std.mem.eql(u8, appid[0..], msg_view.appId() orelse continue)) continue;
            }

            if (fltr.ctid) |ctxid| {
                if (!std.mem.eql(u8, ctxid[0..], msg_view.ctxId() orelse continue)) continue;
            }

            if (fltr.severity) |log_level| {
                const message_info = msg_view.messageInfo() orelse continue;
                if (@intFromEnum(log_level) <= @intFromEnum(message_info.mtin)) continue;
            }
            if (fltr.substring) |substring| {
                if (!std.mem.containsAtLeast(u8, msg_view.payload, 1, substring)) continue;
            }
            if (pretty) {
                try prettyPrint(writer, msg_view);
            } else {
                try writer.writeAll(remaining[0..msg_view.len]);
            }
        }

        // Move incomplete tail to beginning of buffer.
        buffered = len - pos;
        std.mem.copyForwards(u8, buf[0..buffered], buf[pos..len]);
    }
    try writer.flush();
}

//------------------------------ Start Pretty Printing -----------------------------------------

fn typeLength(tyle: u4) !usize {
    return switch (tyle) {
        1 => 1, // 8 bit
        2 => 2, // 16 bit
        3 => 4, // 32 bit
        4 => 8, // 64 bit
        5 => 16, // 128 bit
        else => error.UnsupportedTypeLength,
    };
}

fn printInt(
    writer: anytype,
    buf: []const u8,
    size: usize,
    signed: bool,
    endian: std.builtin.Endian,
) !void {
    switch (size) {
        1 => if (signed)
            try writer.print("{d}", .{std.mem.readInt(i8, buf[0..1], endian)})
        else
            try writer.print("{d}", .{std.mem.readInt(u8, buf[0..1], endian)}),

        2 => if (signed)
            try writer.print("{d}", .{std.mem.readInt(i16, buf[0..2], endian)})
        else
            try writer.print("{d}", .{std.mem.readInt(u16, buf[0..2], endian)}),

        4 => if (signed)
            try writer.print("{d}", .{std.mem.readInt(i32, buf[0..4], endian)})
        else
            try writer.print("{d}", .{std.mem.readInt(u32, buf[0..4], endian)}),

        8 => if (signed)
            try writer.print("{d}", .{std.mem.readInt(i64, buf[0..8], endian)})
        else
            try writer.print("{d}", .{std.mem.readInt(u64, buf[0..8], endian)}),

        16 => if (signed)
            try writer.print("{d}", .{std.mem.readInt(i128, buf[0..16], endian)})
        else
            try writer.print("{d}", .{std.mem.readInt(u128, buf[0..16], endian)}),

        else => return error.UnsupportedType,
    }
}

fn printFloat(writer: anytype, buf: []const u8, size: usize, endian: std.builtin.Endian) !void {
    switch (size) {
        4 => {
            const bits = std.mem.readInt(u32, buf[0..4], endian);
            const value: f32 = @bitCast(bits);
            try writer.print("{d}", .{value});
        },
        8 => {
            const bits = std.mem.readInt(u64, buf[0..8], endian);
            const value: f64 = @bitCast(bits);
            try writer.print("{d}", .{value});
        },
        else => return error.UnsupportedType,
    }
}

fn getArrayElements(buf: []const u8, endian: std.builtin.Endian, arg_pos: *usize) !usize {
    const dimensions = std.mem.readInt(
        u16,
        buf[0..2],
        endian,
    );
    arg_pos.* += 2;
    var n_elements: usize = 1;
    for (0..dimensions) |_| {
        const n_dim = std.mem.readInt(
            u16,
            buf[arg_pos.*..][0..2],
            endian,
        );
        arg_pos.* += 2;
        n_elements *= n_dim;
    }
    return n_elements;
}

fn printArgs(writer: anytype, noar: u8, buf: []const u8, endian: std.builtin.Endian) !void {
    try writer.print(
        "[",
        .{},
    );
    var arg_pos: usize = 0;
    for (0..noar) |i| {
        const raw_type_info = std.mem.readInt(
            u32,
            buf[arg_pos..][0..4],
            endian,
        );
        const type_info: TypeInfo = @bitCast(raw_type_info);
        arg_pos += 4;
        if (type_info.strg == 1) {
            if (buf[arg_pos..].len < 2)
                return error.TruncatedArgument;

            const length = std.mem.readInt(
                u16,
                buf[arg_pos..][0..2],
                endian,
            );
            arg_pos += 2;

            if (buf[arg_pos..].len < length)
                return error.TruncatedArgument;

            try writer.print(
                "\"{s}\"",
                .{buf[arg_pos..][0..length]},
            );
            arg_pos += length;
        } else if (type_info.rawd == 1) {
            if (buf[arg_pos..].len < 2)
                return error.TruncatedArgument;

            const length = std.mem.readInt(
                u16,
                buf[arg_pos..][0..2],
                endian,
            );
            arg_pos += 2;

            if (buf[arg_pos..].len < length)
                return error.TruncatedArgument;

            try writer.print(
                "{x}",
                .{buf[arg_pos..][0..length]},
            );
            arg_pos += length;
        } else if (type_info.sint == 1 or type_info.uint == 1) {
            const size = try typeLength(type_info.tyle);
            if (type_info.aray == 1) {
                const n_elem = try getArrayElements(buf[arg_pos..], endian, &arg_pos);
                for (0..n_elem) |_| {
                    try printInt(writer, buf[arg_pos..], size, type_info.sint == 1, endian);
                    arg_pos += size;
                }
            } else {
                try printInt(writer, buf[arg_pos..], size, type_info.sint == 1, endian);
                arg_pos += size;
            }
        } else if (type_info.floa == 1) {
            const size = try typeLength(type_info.tyle);
            if (type_info.aray == 1) {
                const n_elem = try getArrayElements(buf[arg_pos..], endian, &arg_pos);
                for (0..n_elem) |_| {
                    try printFloat(writer, buf[arg_pos..], size, endian);
                    arg_pos += size;
                }
            } else {
                try printFloat(writer, buf[arg_pos..], size, endian);
                arg_pos += size;
            }
        } else if (type_info.bool_ == 1) {
            if (type_info.aray == 1) {
                const n_elem = try getArrayElements(buf[arg_pos..], endian, &arg_pos);
                for (0..n_elem) |_| {
                    const value = buf[arg_pos] != 0;
                    try writer.print("{}", .{value});
                    arg_pos += 1;
                }
            } else {
                const value = buf[arg_pos] != 0;
                try writer.print("{}", .{value});
                arg_pos += 1;
            }
        } else {
            return error.NotYetImplemented;
        }
        if (i + 1 < noar) {
            try writer.writeAll(", ");
        }
    }
    try writer.print(
        "]",
        .{},
    );
}

fn prettyPrint(writer: anytype, msg: DltMessageView) !void {
    if (msg.ext_hdr != null) {
        const msg_info = msg.messageInfo().?;
        const level = switch (msg_info.mtin) {
            .fatal => "FATL",
            .err => " ERR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBG",
            .verbose => "VERB",
            _ => "????",
        };
        try writer.print(
            "ECU={s} APID={s} CTID={s} Level={s} | ",
            .{ msg.ecuId(), msg.appId().?, msg.ctxId().?, level },
        );
        if (msg_info.verbose == 1) {
            const endian: std.builtin.Endian =
                if (msg.hdr_type.msbf == 1)
                    .big
                else
                    .little;
            try printArgs(writer, msg.noar().?, msg.payload, endian);
        }
        try writer.print("\n", .{});
    } else {
        try writer.print("ECU={s} | {x}\n", .{ msg.ecuId(), msg.payload });
    }
}

//------------------------------ End Pretty Printing -----------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var in: ?[:0]const u8 = null;
    var out: ?[:0]const u8 = null;
    var ecuid: ?[4]u8 = null;
    var apid: ?[4]u8 = null;
    var ctid: ?[4]u8 = null;
    var level: ?LogSeverity = null;
    var substring: ?[]const u8 = null;
    var pretty: bool = false;

    var it = init.minimal.args.iterate();
    const name = it.next() orelse {
        return error.MissingProgramName;
    };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ecuid")) {
            if (it.next()) |id| {
                if (id.len > 4)
                    return error.InvalidEcuId;
                var eid: [4]u8 = [_]u8{0} ** 4;
                @memcpy(eid[0..id.len], id);
                ecuid = eid;
            } else {
                return error.EcuIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--apid")) {
            if (it.next()) |id| {
                if (id.len != 4)
                    return error.InvalidAppId;
                var aid: [4]u8 = [_]u8{0} ** 4;
                @memcpy(aid[0..id.len], id);
                apid = aid;
            } else {
                return error.AppIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--ctid")) {
            if (it.next()) |id| {
                if (id.len != 4)
                    return error.InvalidContextId;
                var cid: [4]u8 = [_]u8{0} ** 4;
                @memcpy(cid[0..id.len], id);
                ctid = cid;
            } else {
                return error.ContextIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--level")) {
            if (it.next()) |l_str| {
                level = @enumFromInt(try std.fmt.parseInt(u4, l_str, 10));
            } else {
                return error.LogLevelNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--substring")) {
            if (it.next()) |substr| {
                substring = substr;
            } else {
                return error.SubstringNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            pretty = true;
        } else {
            if (in == null) in = arg else if (out == null) out = arg else {
                std.debug.print(
                    "Usage: {s} <in> <out> [--ecuid ECUID] [--apid APID] [--ctid CTID] [--level LEVEL]\n",
                    .{name},
                );
                return error.WrongUsage;
            }
        }
    }

    const in_file = try std.Io.Dir.cwd().openFile(
        io,
        in orelse return error.MissingInputFile,
        .{},
    );
    defer in_file.close(io);

    const out_file = if (out) |outfile|
        try std.Io.Dir.cwd().createFile(
            io,
            outfile,
            .{
                .truncate = true,
            },
        )
    else
        std.Io.File.stdout();
    defer if (out != null) out_file.close(io);

    var rbuf: [256 * 1024]u8 = undefined;
    var reader_impl = in_file.reader(io, &rbuf);
    const reader = &reader_impl.interface;

    var wbuf: [256 * 1024]u8 = undefined;
    var writer_impl = out_file.writer(io, &wbuf);
    const writer = &writer_impl.interface;

    const fltr = DltFilter{ .ecuid = ecuid, .apid = apid, .ctid = ctid, .severity = level, .substring = substring };
    try filter(reader, writer, fltr, pretty);
}
