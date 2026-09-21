const std = @import("std");
const pretty = @import("pretty.zig");

pub const STORAGE_HEADER_SIZE: u16 = 16;
pub const STANDARD_HEADER_SIZE: u16 = 4;
pub const EXTENDED_HEADER_SIZE: u16 = 10;

pub const PATTERN: []const u8 = "DLT\x01";

pub const StorageHeader = struct {
    ts_s: u32,
    ts_us: u32,
    ecuid: []const u8,

    pub fn init(buf: []const u8) !StorageHeader {
        if (!std.mem.eql(u8, buf[0..4], PATTERN)) return error.PatternMissing;
        if (buf.len < STORAGE_HEADER_SIZE) return error.Truncated;
        const ts_s = std.mem.readInt(u32, buf[4..8], .little);
        const ts_us = std.mem.readInt(u32, buf[8..12], .little);
        const ecuid = buf[12..16];
        return StorageHeader{ .ts_s = ts_s, .ts_us = ts_us, .ecuid = ecuid };
    }
};

pub const HeaderType = packed struct(u8) {
    wevt: u1,
    msbf: u1,
    weid: u1,
    wsid: u1,
    wtms: u1,
    vers: u3,
};

pub const MessageType = enum(u3) {
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

pub const MessageInfo = packed struct(u8) {
    verbose: u1,
    mstp: MessageType,
    mtin: LogSeverity,
};

pub const TypeInfo = packed struct(u32) {
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

pub const DltStandardHeader = struct {
    buf: []const u8,
    hdr_type: HeaderType,
    length: u16,

    pub fn init(buf: []const u8) !DltStandardHeader {
        if (buf.len < STANDARD_HEADER_SIZE) return error.Truncated;
        const hdr_type: HeaderType = @bitCast(buf[0]);
        const len = std.mem.readInt(u16, buf[2..4], .big);
        return DltStandardHeader{
            .buf = buf[0..len],
            .hdr_type = hdr_type,
            .length = len,
        };
    }
    pub fn ecuId(self: *const DltStandardHeader) ?[]const u8 {
        if (self.hdr_type.weid == 1) return self.buf[STANDARD_HEADER_SIZE..][0..4];
        return null;
    }

    pub fn sessionId(self: *const DltStandardHeader) ?[]const u8 {
        if (self.hdr_type.weid == 1 and self.hdr_type.wsid == 1)
            return self.buf[STANDARD_HEADER_SIZE + 4 ..][0..4]
        else if (self.hdr_type.weid == 0 and self.hdr_type.wsid == 1)
            return self.buf[STANDARD_HEADER_SIZE..][0..4]
        else
            return null;
    }
    pub fn timestamp(self: *const DltStandardHeader) ?u32 {
        if (self.hdr_type.weid == 1 and self.hdr_type.wsid == 1 and self.hdr_type.wtms == 1)
            return std.mem.readInt(u32, self.buf[STANDARD_HEADER_SIZE + 8 ..][0..4], self.endian())
        else if (self.hdr_type.weid == 0 and self.hdr_type.wsid == 1 and self.hdr_type.wtms == 1)
            return std.mem.readInt(u32, self.buf[STANDARD_HEADER_SIZE + 4 ..][0..4], self.endian())
        else if (self.hdr_type.weid == 0 and self.hdr_type.wsid == 0 and self.hdr_type.wtms == 1)
            return std.mem.readInt(u32, self.buf[STANDARD_HEADER_SIZE..][0..4], self.endian())
        else
            return null;
    }
    pub fn extHdr(self: *const DltStandardHeader) !?DltExtHeader {
        if (self.hdr_type.wevt == 1) {
            return try DltExtHeader.init(self.buf[self.hdrLength()..], if (self.hdr_type.msbf == 1) .big else .little);
        } else return null;
    }
    pub fn hdrLength(self: *const DltStandardHeader) usize {
        if (@as(u8, @intCast(self.hdr_type.weid)) + @as(u8, @intCast(self.hdr_type.wsid)) + @as(u8, @intCast(self.hdr_type.wtms)) == 3)
            return 16
        else if (@as(u8, @intCast(self.hdr_type.weid)) + @as(u8, @intCast(self.hdr_type.wsid)) + @as(u8, @intCast(self.hdr_type.wtms)) == 2)
            return 12
        else if (@as(u8, @intCast(self.hdr_type.weid)) + @as(u8, @intCast(self.hdr_type.wsid)) + @as(u8, @intCast(self.hdr_type.wtms)) == 1)
            return 8
        else
            return 4;
    }
    pub fn payload(self: *const DltStandardHeader) []const u8 {
        const payload_offset = if (self.hdr_type.wevt == 1) EXTENDED_HEADER_SIZE + self.hdrLength() else self.hdrLength();
        return self.buf[payload_offset..];
    }
    fn endian(self: *const DltStandardHeader) std.builtin.Endian {
        if (self.hdr_type.msbf == 1) return .big else return .little;
    }
};

pub const DltExtHeader = struct {
    buf: []const u8,
    endian: std.builtin.Endian,

    pub fn init(buf: []const u8, endian: std.builtin.Endian) !DltExtHeader {
        if (buf.len < EXTENDED_HEADER_SIZE) return error.Truncated;
        return DltExtHeader{ .buf = buf, .endian = endian };
    }
    pub fn messageInfo(self: *const DltExtHeader) MessageInfo {
        return @bitCast(self.buf[0]);
    }
    pub fn noar(self: *const DltExtHeader) u8 {
        return @bitCast(self.buf[1]);
    }
    pub fn appId(self: *const DltExtHeader) []const u8 {
        return self.buf[2..6];
    }
    pub fn ctxId(self: *const DltExtHeader) []const u8 {
        return self.buf[6..10];
    }
    pub fn payload(self: *const DltExtHeader) []const u8 {
        return self.buf[EXTENDED_HEADER_SIZE..];
    }
    pub fn argIterator(self: *const DltExtHeader) ArgIterator {
        return ArgIterator{
            .buffer = self.payload(),
            .offset = 0,
            .endian = self.endian,
            .noar = self.noar(),
            .i_arg = 0,
        };
    }
};

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

fn getIntArg(
    buf: []const u8,
    size: usize,
    signed: bool,
    endian: std.builtin.Endian,
) !Arg {
    switch (size) {
        1 => if (signed)
            return .{ .i8 = std.mem.readInt(i8, buf[0..1], endian) }
        else
            return .{ .u8 = std.mem.readInt(u8, buf[0..1], endian) },

        2 => if (signed)
            return .{ .i16 = std.mem.readInt(i16, buf[0..2], endian) }
        else
            return .{ .u16 = std.mem.readInt(u16, buf[0..2], endian) },

        4 => if (signed)
            return .{ .i32 = std.mem.readInt(i32, buf[0..4], endian) }
        else
            return .{ .u32 = std.mem.readInt(u32, buf[0..4], endian) },

        8 => if (signed)
            return .{ .i64 = std.mem.readInt(i64, buf[0..8], endian) }
        else
            return .{ .u64 = std.mem.readInt(u64, buf[0..8], endian) },

        16 => if (signed)
            return .{ .i128 = std.mem.readInt(i128, buf[0..16], endian) }
        else
            return .{ .u128 = std.mem.readInt(u128, buf[0..16], endian) },

        else => return error.UnsupportedType,
    }
}

fn getFloatArg(buf: []const u8, size: usize, endian: std.builtin.Endian) !Arg {
    switch (size) {
        4 => {
            const bits = std.mem.readInt(u32, buf[0..4], endian);
            const value: f32 = @bitCast(bits);
            return .{ .f32 = value };
        },
        8 => {
            const bits = std.mem.readInt(u64, buf[0..8], endian);
            const value: f64 = @bitCast(bits);
            return .{ .f64 = value };
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

const ArgIterator = struct {
    buffer: []const u8,
    offset: usize,
    endian: std.builtin.Endian,
    noar: u8,
    i_arg: u8,

    pub fn next(self: *ArgIterator) !?Arg {
        var buf = self.buffer[self.offset..];
        if (self.i_arg >= self.noar)
            if (buf.len == 0) return null else return error.Truncated;

        if (buf.len == 0) return error.EndOfArgs;
        if (buf.len < 4) return error.TruncatedArg;

        const raw_type_info = std.mem.readInt(
            u32,
            buf[0..4],
            self.endian,
        );
        const type_info: TypeInfo = @bitCast(raw_type_info);
        self.offset += 4;
        buf = self.buffer[self.offset..];
        if (type_info.strg == 1) {
            if (buf.len < 2)
                return error.TruncatedArgument;

            const length = std.mem.readInt(
                u16,
                buf[0..2],
                self.endian,
            );
            self.offset += 2;

            if (buf.len < length)
                return error.TruncatedArgument;

            self.offset += length;
            self.i_arg += 1;
            return .{ .string = buf[2..][0..length] };
        } else if (type_info.rawd == 1) {
            if (buf.len < 2)
                return error.TruncatedArgument;

            const length = std.mem.readInt(
                u16,
                buf[0..2],
                self.endian,
            );
            self.offset += 2;

            if (buf.len < length)
                return error.TruncatedArgument;

            self.offset += length;
            self.i_arg += 1;
            return .{ .raw = self.buffer[0..length] };
        } else if (type_info.sint == 1 or type_info.uint == 1) {
            const size = try typeLength(type_info.tyle);
            if (type_info.aray == 1) {
                return error.NotYetImplemented;
                // const n_elem = try getArrayElements(buf, self.endian, &self.offset);
                // for (0..n_elem) |_| {
                //     self.offset += size;
                //     return try getIntArg(buf, size, type_info.sint == 1, self.endian);
                // }
            } else {
                self.offset += size;
                self.i_arg += 1;
                return try getIntArg(buf, size, type_info.sint == 1, self.endian);
            }
        } else if (type_info.floa == 1) {
            const size = try typeLength(type_info.tyle);
            if (type_info.aray == 1) {
                return error.NotYetImplemented;
                // const n_elem = try getArrayElements(buf, self.endian, &self.offset);
                // for (0..n_elem) |_| {
                //     self.offset += size;
                //     return try getFloatArg(buf, size, self.endian);
                // }
            } else {
                self.offset += size;
                self.i_arg += 1;
                return try getFloatArg(buf, size, self.endian);
            }
        } else if (type_info.bool_ == 1) {
            if (type_info.aray == 1) {
                return error.NotYetImplemented;
                // const n_elem = try getArrayElements(buf, self.endian, &self.offset);
                // for (0..n_elem) |_| {
                //     const value = buf[self.offset] != 0;
                //     self.offset += 1;
                //     return .{ .bool = value };
                // }
            } else {
                const value = buf[0] != 0;
                self.offset += 1;
                self.i_arg += 1;
                return .{ .bool = value };
            }
        } else {
            return error.NotYetImplemented;
        }
        return error.NotFound;
    }
};

pub const Arg = union(enum) {
    i8: i8,
    i16: i16,
    i32: i32,
    i64: i64,
    i128: i128,
    u8: u8,
    u16: u16,
    u32: u32,
    u64: u64,
    u128: u128,
    f32: f32,
    f64: f64,
    bool: bool,
    string: []const u8,
    raw: []const u8,

    pub fn format(
        self: Arg,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .bool => |arg| try writer.print("{}", .{arg}),
            .string => |arg| try writer.print("{s}", .{arg}),
            .raw => |arg| try writer.print("{X}", .{arg}),
            inline else => |arg| try writer.print("{d}", .{arg}),
        }
    }
};

pub const DltMessage = struct {
    ecu_id: ?[]const u8,
    app_id: ?[]const u8,
    ctx_id: ?[]const u8,
    level: ?LogSeverity,
    timestamp: ?u32,
    ext_hdr: ?DltExtHeader,
    endian: std.builtin.Endian,
    payload: []const u8,

    pub fn init(buf: []const u8) !DltMessage {
        const std_hdr = try DltStandardHeader.init(buf);
        const ext_hdr = try std_hdr.extHdr();
        const app_id = if (ext_hdr) |ehdr| ehdr.appId() else null;
        const ctx_id = if (ext_hdr) |ehdr| ehdr.ctxId() else null;
        const level = if (ext_hdr) |ehdr| ehdr.messageInfo().mtin else null;
        return DltMessage{
            .ecu_id = std_hdr.ecuId(),
            .app_id = app_id,
            .ctx_id = ctx_id,
            .level = level,
            .timestamp = std_hdr.timestamp(),
            .ext_hdr = ext_hdr,
            .endian = if (std_hdr.hdr_type.msbf == 1) .big else .little,
            .payload = std_hdr.payload(),
        };
    }
    pub fn matches(self: *const DltMessage, filter: DltFilter) bool {
        if (filter.ecuid) |feid| {
            if (self.ecu_id) |eid| {
                if (!std.mem.eql(u8, feid, eid)) return false;
            } else return false;
        }
        if (filter.apid) |faid| {
            if (self.app_id) |aid| {
                if (!std.mem.eql(u8, faid, aid)) return false;
            } else return false;
        }
        if (filter.ctid) |fcid| {
            if (self.ctx_id) |cid| {
                if (!std.mem.eql(u8, fcid, cid)) return false;
            } else return false;
        }
        if (filter.err or filter.fatal or filter.warn or filter.info or filter.debug) {
            if (self.level) |level| switch (level) {
                .fatal => if (!filter.fatal) return false,
                .err => if (!filter.err) return false,
                .warn => if (!filter.warn) return false,
                .info => if (!filter.info) return false,
                .debug => if (!filter.debug) return false,
                else => return false,
            } else return false;
        } else return false;

        if (filter.from) |from| {
            if (self.timestamp) |timestamp| {
                if (timestamp < from) return false;
            } else return false;
        }

        if (filter.until) |until| {
            if (self.timestamp) |timestamp| {
                if (timestamp > until) return false;
            } else return false;
        }

        return true;
    }
};

pub const DltFilter = struct {
    ecuid: ?[]const u8 = null,
    apid: ?[]const u8 = null,
    ctid: ?[]const u8 = null,
    substring: ?[]const u8 = null,
    fatal: bool = true,
    err: bool = true,
    warn: bool = true,
    info: bool = true,
    debug: bool = true,
    from: ?u32 = null,
    until: ?u32 = null,
};
