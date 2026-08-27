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
    wsid: u1,
    wtms: u1,
    reserved: u1,
    msbf: u1,
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

    if (standard_hdr.htype.wsid == 1) {
        variable_offset += 4; // 4 bytes for ECU ID + 4 bytes for Session ID
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
};

fn filter(io: std.Io, in: std.Io.File, writer: anytype, fltr: DltFilter) !void {
    var buf: [256 * 1024]u8 = undefined;
    var buffered: usize = 0;
    while (true) {
        const n = in.readStreaming(io, &.{buf[buffered..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
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

            // Sanity check.
            if (msg_len > remaining.len) {
                break;
            }

            const message = buf[pos .. pos + msg_len];

            if (matches(hdr, fltr)) {
                try writer.writeAll(message);
            }

            pos += msg_len;
        }

        // Move incomplete tail to beginning of buffer.
        buffered = len - pos;
        std.mem.copyForwards(u8, buf[0..buffered], buf[pos..len]);
    }
    try writer.flush();
}

fn matches(hdr: DltHeaders, fltr: DltFilter) bool {
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
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var in: ?[:0]const u8 = null;
    var out: ?[:0]const u8 = null;
    var ecuid: ?[4]u8 = null;
    var apid: ?[4]u8 = null;
    var ctid: ?[4]u8 = null;
    var level: ?LogSeverity = null;

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

    const out_file = try std.Io.Dir.cwd().createFile(
        io,
        out orelse return error.MissingOutputFile,
        .{
            .truncate = true,
        },
    );
    defer out_file.close(io);

    var wbuf: [256 * 1024]u8 = undefined;
    var writer_impl = out_file.writer(io, &wbuf);
    const writer = &writer_impl.interface;

    const fltr = DltFilter{ .ecuid = ecuid, .apid = apid, .ctid = ctid, .severity = level };
    try filter(io, in_file, writer, fltr);
}
