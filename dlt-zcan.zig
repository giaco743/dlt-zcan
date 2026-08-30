const std = @import("std");

const DLT_PATTERN = "DLT\x01";

const STORAGE_HEADER_SIZE: usize = 16;

const StorageHeader = extern struct {
    pattern: [4]u8,
    timestamp_secs: u32,
    timestamp_micros: u32,
    ecu_id: [4]u8,
};

comptime {
    if (@sizeOf(StorageHeader) != STORAGE_HEADER_SIZE)
        @compileError("StorageHeader must be exactly 10 bytes");
}

const HeaderType = packed struct(u8) {
    wevt: u1,
    msbf: u1,
    weid: u1,
    wsid: u1,
    wtms: u1,
    vers: u3,
};

const STANDARD_HEADER_SIZE: usize = 4;

comptime {
    if (@sizeOf(StandardHeader) != STANDARD_HEADER_SIZE)
        @compileError("StandardHeader must be exactly 4 bytes");
}

const StandardHeader = extern struct {
    htype: HeaderType,
    mcount: u8,
    length: u16, // this is big-endian
};

fn decodeStandardHeader(buf: *const [4]u8) StandardHeader {
    const htype: HeaderType = @bitCast(buf[0]);
    const mcount = buf[1];
    const length = std.mem.readInt(u16, buf[2..4], .big);
    return StandardHeader{
        .htype = htype,
        .mcount = mcount,
        .length = length,
    };
}

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

const EXTENDED_HEADER_SIZE: usize = 10;

comptime {
    if (@sizeOf(ExtendedHeader) != EXTENDED_HEADER_SIZE)
        @compileError("ExtendedHeader must be exactly 10 bytes");
}

const ExtendedHeader = extern struct {
    msin: MessageInfo,
    noar: u8,
    apid: [4]u8,
    ctid: [4]u8,
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

const DltHeaders = struct {
    storage_hdr: StorageHeader,
    standard_hdr: StandardHeader,
    extended_hdr: ?ExtendedHeader,
};

fn decode(buf: []const u8) !DltHeaders {
    if (buf.len < STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE) return error.BufferTooShort;

    const storage_hdr = std.mem.bytesToValue(
        StorageHeader,
        buf[0..STORAGE_HEADER_SIZE],
    );
    if (!std.mem.eql(u8, storage_hdr.pattern[0..], DLT_PATTERN[0..])) {
        return error.UnexpectedPattern;
    }
    const standard_hdr = decodeStandardHeader(
        &buf[STORAGE_HEADER_SIZE..][0..STANDARD_HEADER_SIZE].*,
    );

    var variable_offset: usize = STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE;

    if (standard_hdr.htype.weid == 1) {
        variable_offset += 4; // 4 bytes for ECU ID
    }
    if (standard_hdr.htype.wsid == 1) {
        variable_offset += 4; // 4 bytes for Session ID
    }
    if (standard_hdr.htype.wtms == 1) {
        variable_offset += 4; // 4 bytes for Timestamp
    }
    var extended_hdr: ?ExtendedHeader = null;
    if (standard_hdr.htype.wevt == 1) {
        if (buf.len < variable_offset + EXTENDED_HEADER_SIZE)
            return error.BufferTooShort;

        extended_hdr = std.mem.bytesToValue(
            ExtendedHeader,
            buf[variable_offset..][0..EXTENDED_HEADER_SIZE],
        );
    }
    return .{
        .storage_hdr = storage_hdr,
        .standard_hdr = standard_hdr,
        .extended_hdr = extended_hdr,
    };
}

const DltFilter = struct {
    ecuid: ?[4]u8,
    apid: ?[4]u8,
    ctid: ?[4]u8,
    severity: ?LogSeverity,
    substring: ?[]const u8,
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

            const hdr = decode(remaining) catch |err| switch (err) {
                error.BufferTooShort => {
                    // Keep incomplete message for next read.
                    break;
                },
                else => return err,
            };

            const msg_len = STORAGE_HEADER_SIZE + hdr.standard_hdr.length;
            var payload_offset = STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE;
            if (hdr.standard_hdr.htype.wsid == 1)
                payload_offset += 4;
            if (hdr.standard_hdr.htype.wtms == 1)
                payload_offset += 4;
            if (hdr.standard_hdr.htype.wevt == 1)
                payload_offset += EXTENDED_HEADER_SIZE;

            // Sanity check.
            if (msg_len > remaining.len) {
                break;
            }

            const message = buf[pos .. pos + msg_len];
            const payload = buf[pos + payload_offset .. pos + msg_len];

            if (matches(hdr, payload, fltr)) {
                if (pretty) {
                    try prettyPrint(writer, hdr, payload);
                } else {
                    try writer.writeAll(message);
                }
            }

            pos += msg_len;
        }

        // Move incomplete tail to beginning of buffer.
        buffered = len - pos;
        std.mem.copyForwards(u8, buf[0..buffered], buf[pos..len]);
    }
    try writer.flush();
}

fn matches(hdr: DltHeaders, payload: []const u8, fltr: DltFilter) bool {
    if (fltr.ecuid) |ecuid| {
        if (!std.mem.eql(u8, hdr.storage_hdr.ecu_id[0..], ecuid[0..])) {
            return false;
        }
    }
    if (hdr.extended_hdr) |extended_hdr| {
        if (fltr.apid) |apid| {
            if (!std.mem.eql(u8, extended_hdr.apid[0..], apid[0..])) {
                return false;
            }
        }
        if (fltr.ctid) |ctid| {
            if (!std.mem.eql(u8, extended_hdr.ctid[0..], ctid[0..])) {
                return false;
            }
        }
        if (fltr.severity) |severity| {
            if (severity != extended_hdr.msin.mtin) {
                return false;
            }
        }
    } else {
        if (fltr.apid != null or fltr.ctid != null or fltr.severity != null) {
            return false;
        }
    }
    if (fltr.substring) |substring| {
        if (!std.mem.containsAtLeast(u8, payload, 1, substring)) {
            return false;
        }
    }
    return true;
}

//------------------------------ No copy filtering ------------------------------------
fn checkPattern(storage_hdr: []const u8) bool {
    return std.mem.eql(u8, storage_hdr[0..4], DLT_PATTERN[0..]);
}
fn getLength(standard_hdr: []const u8) u16 {
    return std.mem.readInt(u16, standard_hdr[2..4], .big);
}
fn getHeaderType(standard_hdr: []const u8) HeaderType {
    return @bitCast(standard_hdr[0]);
}
fn getEcuIdFromStorageHdr(storage_hdr: []const u8) []const u8 {
    return storage_hdr[12..];
}
fn getAppIdFromExtHdr(ext_hdr: []const u8) []const u8 {
    return ext_hdr[2..6];
}
fn getCtxIdFromExtHdr(ext_hdr: []const u8) []const u8 {
    return ext_hdr[6..10];
}
fn getMessageInfoFromExtHdr(ext_hdr: []const u8) MessageInfo {
    return @bitCast(ext_hdr[0]);
}
fn filter2(reader: anytype, writer: anytype, fltr: DltFilter) !void {
    var buf: [256 * 1024]u8 = undefined;
    var buffered: usize = 0;
    const need_extra_hdr = fltr.apid != null or fltr.ctid != null or fltr.severity != null;

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
            if (remaining.len < STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE) {
                break;
            }
            const storage_hdr = remaining[0..STORAGE_HEADER_SIZE];
            const standard_hdr = remaining[STORAGE_HEADER_SIZE..][0..STANDARD_HEADER_SIZE];

            const msg_len = getLength(standard_hdr) + STORAGE_HEADER_SIZE;
            if (pos + msg_len > len) break;

            pos += msg_len;

            const hdr_type = getHeaderType(standard_hdr);
            var payload_offset = STORAGE_HEADER_SIZE + STANDARD_HEADER_SIZE;
            if (hdr_type.weid == 1) payload_offset += 4;
            if (hdr_type.wsid == 1) payload_offset += 4;
            if (hdr_type.wtms == 1) payload_offset += 4;
            const ext_hdr_offset = payload_offset;
            if (hdr_type.wevt == 1) payload_offset += EXTENDED_HEADER_SIZE;

            if (fltr.ecuid) |ecuid| {
                if (!std.mem.eql(u8, ecuid[0..], getEcuIdFromStorageHdr(storage_hdr))) continue;
            }

            if (need_extra_hdr) {
                // We need the extended header to retrieve this information
                if (hdr_type.wevt == 0) continue;
                const ext_hdr = remaining[ext_hdr_offset..][0..EXTENDED_HEADER_SIZE];

                if (fltr.apid) |appid| {
                    if (!std.mem.eql(u8, appid[0..], getAppIdFromExtHdr(ext_hdr))) continue;
                }

                if (fltr.ctid) |ctxid| {
                    if (!std.mem.eql(u8, ctxid[0..], getCtxIdFromExtHdr(ext_hdr))) continue;
                }

                if (fltr.severity) |log_level| {
                    if (@intFromEnum(log_level) <= @intFromEnum(getMessageInfoFromExtHdr(ext_hdr).mtin)) continue;
                }
            }
            if (fltr.substring) |substring| {
                if (!std.mem.containsAtLeast(u8, remaining[payload_offset..msg_len], 1, substring)) continue;
            }
            try writer.writeAll(remaining[0..msg_len]);
        }

        // Move incomplete tail to beginning of buffer.
        buffered = len - pos;
        std.mem.copyForwards(u8, buf[0..buffered], buf[pos..len]);
    }
    try writer.flush();
}
//------------------------------ No copy filtering ------------------------------------

//------------------------------ Start Printing -----------------------------------------

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
                try printFloat(writer, buf[arg_pos..], try typeLength(type_info.tyle), endian);
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

fn prettyPrint(writer: anytype, hdr: DltHeaders, payload: []const u8) !void {
    if (hdr.extended_hdr) |ext_hdr| {
        const level = switch (ext_hdr.msin.mtin) {
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
            .{ hdr.storage_hdr.ecu_id, ext_hdr.apid, ext_hdr.ctid, level },
        );
        if (ext_hdr.msin.verbose == 1) {
            const endian: std.builtin.Endian =
                if (hdr.standard_hdr.htype.msbf == 1)
                    .big
                else
                    .little;
            try printArgs(writer, ext_hdr.noar, payload, endian);
        }
        try writer.print(
            "\n",
            .{},
        );
    } else {
        try writer.print(
            "ECU={s} | {x}\n",
            .{ hdr.storage_hdr.ecu_id, payload },
        );
    }
}

//------------------------------ End Printing -----------------------------------------

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
    try filter2(reader, writer, fltr);
}
