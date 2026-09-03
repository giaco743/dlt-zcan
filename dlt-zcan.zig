const std = @import("std");

const STORAGE_HEADER_SIZE: u16 = 16;
const STANDARD_HEADER_SIZE: u16 = 4;
const EXTENDED_HEADER_SIZE: u16 = 10;

const PATTERN: []const u8 = "DLT\x01";

const StorageHeader = struct {
    ts_s: u32,
    ts_us: u32,
    ecuid: []const u8,

    fn init(buf: []const u8) !StorageHeader {
        if (!std.mem.eql(u8, buf[0..4], PATTERN)) return error.PatternMissing;
        const ts_s = std.mem.readInt(u32, buf[4..8], .little);
        const ts_us = std.mem.readInt(u32, buf[8..12], .little);
        const ecuid = buf[12..16];
        return StorageHeader{ .ts_s = ts_s, .ts_us = ts_us, .ecuid = ecuid };
    }
};

const HeaderType = packed struct(u8) {
    wevt: u1,
    msbf: u1,
    weid: u1,
    wsid: u1,
    wtms: u1,
    vers: u3,
};

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

const DltStandardHeader = struct {
    hdr_type: HeaderType,
    payload_len: u16,

    fn init(buf: []const u8) DltStandardHeader {
        const hdr_type: HeaderType = @bitCast(buf[0]);
        const len = std.mem.readInt(u16, buf[2..4], .big);
        return DltStandardHeader{
            .hdr_type = hdr_type,
            .payload_len = len - 4,
        };
    }
};

const DltExtHeader = struct {
    buf: []const u8,

    fn messageInfo(self: *const DltExtHeader) MessageInfo {
        return @bitCast(self.buf[0]);
    }
    fn noar(self: *const DltExtHeader) u8 {
        return @bitCast(self.buf[1]);
    }
    fn appId(self: *const DltExtHeader) []const u8 {
        return self.buf[2..6];
    }
    fn ctxId(self: *const DltExtHeader) []const u8 {
        return self.buf[6..10];
    }
};

fn filterMessage(reader: anytype, writer: anytype, fltr: DltFilter, need_ext_hdr: bool, storage: bool) !bool {
    const strg_eid = if (storage) blk: {
        var storage_hdr_buf: [STORAGE_HEADER_SIZE]u8 = undefined;
        try reader.readSliceAll(&storage_hdr_buf);
        const str_hdr = try StorageHeader.init(&storage_hdr_buf);
        break :blk str_hdr.ecuid;
    } else null;

    var std_hdr_buf: [STANDARD_HEADER_SIZE]u8 = undefined;
    try reader.readSliceAll(&std_hdr_buf);

    const std_hdr = DltStandardHeader.init(std_hdr_buf[0..]);

    // The length field of the DLT message allows 0xFFFF = 65,535 bytes
    var buffer: [64 * 1024]u8 = undefined;
    if (std_hdr.payload_len > buffer.len) return error.MaxMessageSizeExceeded;

    var payload = buffer[0..std_hdr.payload_len];
    try reader.readSliceAll(payload);

    const ecuid: ?[]const u8 =
        if (std_hdr.hdr_type.weid == 1) blk: {
            const ecuid = payload[0..4];
            payload = payload[4..];
            break :blk ecuid;
        } else strg_eid;

    if (std_hdr.hdr_type.wsid == 1) payload = payload[4..];

    if (std_hdr.hdr_type.wtms == 1) payload = payload[4..];

    const ext_hdr: ?DltExtHeader = if (std_hdr.hdr_type.wevt == 1) blk: {
        const ehdr_buf = payload[0..EXTENDED_HEADER_SIZE];
        payload = payload[EXTENDED_HEADER_SIZE..];
        break :blk DltExtHeader{ .buf = ehdr_buf };
    } else null;

    if (fltr.ecuid) |eid| {
        if (!std.mem.eql(u8, eid[0..], ecuid orelse return false)) return false;
    }
    if (fltr.substring) |substring| {
        if (!std.mem.containsAtLeast(u8, payload, 1, substring)) return false;
    }

    if (need_ext_hdr) {
        const ehdr = ext_hdr orelse return false;

        if (fltr.apid) |appid| {
            if (!std.mem.eql(u8, appid[0..], ehdr.appId())) return false;
        }

        if (fltr.ctid) |ctxid| {
            if (!std.mem.eql(u8, ctxid[0..], ehdr.ctxId())) return false;
        }

        if (fltr.severity) |log_level| {
            if (@intFromEnum(log_level) <= @intFromEnum(ehdr.messageInfo().mtin)) return false;
        }
    }

    try prettyPrint(ecuid, ext_hdr, payload, writer, if (std_hdr.hdr_type.msbf == 1) .big else .little);
    return true;
}

fn filterStream(reader: anytype, writer: anytype, fltr: DltFilter, storage: bool) !void {
    const need_ext_hdr = fltr.apid != null or fltr.ctid != null or fltr.severity != null;
    while (true) {
        const written = filterMessage(reader, writer, fltr, need_ext_hdr, storage) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (written) try writer.flush();
    }
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

fn prettyPrint(
    ecuid: ?[]const u8,
    ext_hdr: ?DltExtHeader,
    payload: []const u8,
    writer: anytype,
    endian: std.builtin.Endian,
) !void {
    if (ecuid) |eid| try writer.print(
        "ECU={s} ",
        .{eid},
    );
    if (ext_hdr) |ehdr| {
        const level = switch (ehdr.messageInfo().mtin) {
            .fatal => "FATL",
            .err => " ERR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBG",
            .verbose => "VERB",
            _ => "???",
        };
        try writer.print(
            "APID={s} CTID={s} Level={s} | ",
            .{ ehdr.appId(), ehdr.ctxId(), level },
        );
        if (ehdr.messageInfo().verbose == 1)
            try printArgs(writer, ehdr.noar(), payload, endian)
        else
            try writer.print("{x}", .{payload});
    } else try writer.print("| {x}", .{payload});

    try writer.print("\n", .{});
}

//------------------------------ End Pretty Printing -----------------------------------------
const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    connect: ?[]const u8 = null,

    ecuid: ?[4]u8 = null,
    apid: ?[4]u8 = null,
    ctid: ?[4]u8 = null,
    level: ?LogSeverity = null,
    substring: ?[]const u8 = null,

    storage: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var it = init.minimal.args.iterate();
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
        } else if (std.mem.eql(u8, arg, "--ecuid")) {
            if (it.next()) |id| {
                if (id.len > 4)
                    return error.InvalidEcuId;
                var eid: [4]u8 = [_]u8{0} ** 4;
                @memcpy(eid[0..id.len], id);
                options.ecuid = eid;
            } else {
                return error.EcuIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--apid")) {
            if (it.next()) |id| {
                if (id.len != 4)
                    return error.InvalidAppId;
                var aid: [4]u8 = [_]u8{0} ** 4;
                @memcpy(aid[0..id.len], id);
                options.apid = aid;
            } else {
                return error.AppIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--ctid")) {
            if (it.next()) |id| {
                if (id.len != 4)
                    return error.InvalidContextId;
                var cid: [4]u8 = [_]u8{0} ** 4;
                @memcpy(cid[0..id.len], id);
                options.ctid = cid;
            } else {
                return error.ContextIdNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--level")) {
            if (it.next()) |l_str| {
                options.level = @enumFromInt(try std.fmt.parseInt(u4, l_str, 10));
            } else {
                return error.LogLevelNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--substring")) {
            if (it.next()) |substr| {
                options.substring = substr;
            } else {
                return error.SubstringNotSpecified;
            }
        } else if (std.mem.eql(u8, arg, "--storage")) {
            options.storage = true;
        } else {
            std.debug.print(
                "Usage: {s} [--connect host] [--ecuid ECUID] [--apid APID] [--ctid CTID] [--substring STRING] [--level LEVEL]\n",
                .{name},
            );
            return error.WrongUsage;
        }
    }

    const host = options.connect orelse return error.MissingHost;

    var it_host = std.mem.splitScalar(u8, host, ':');
    const hostname = it_host.next() orelse return error.MissingHostname;
    const port_str = it_host.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const hn = try std.Io.net.HostName.init(hostname);
    const stream = try hn.connect(io, port, .{ .mode = .stream });
    defer stream.close(io);

    var rbuf: [256]u8 = undefined;
    var reader_impl = stream.reader(io, &rbuf);
    const reader = &reader_impl.interface;

    var wbuf: [1 * 1024]u8 = undefined;
    var writer_impl = std.Io.File.stdout().writer(io, &wbuf);
    const writer = &writer_impl.interface;

    const fltr = DltFilter{
        .ecuid = options.ecuid,
        .apid = options.apid,
        .ctid = options.ctid,
        .severity = options.level,
        .substring = options.substring,
    };
    try filterStream(reader, writer, fltr, options.storage);
}
