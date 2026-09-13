const std = @import("std");
const dlt = @import("dlt.zig");
const pretty = @import("pretty.zig");

pub const DltFilter = struct {
    ecuid: ?[4]u8,
    apid: ?[4]u8,
    ctid: ?[4]u8,
    severity: ?dlt.LogSeverity,
    substring: ?[]const u8,
};

fn filterMessage(
    ecu_id: ?[]const u8,
    std_hdr: dlt.DltStandardHeader,
    buffer: []const u8,
    writer: anytype,
    fltr: DltFilter,
    need_ext_hdr: bool,
) !bool {
    var payload = buffer;
    const ecuid: ?[]const u8 =
        if (std_hdr.hdr_type.weid == 1) blk: {
            const ecuid = payload[0..4];
            payload = payload[4..];
            break :blk ecuid;
        } else ecu_id;

    // SKip session ID and timestamp for now
    if (std_hdr.hdr_type.wsid == 1) payload = payload[4..];
    if (std_hdr.hdr_type.wtms == 1) payload = payload[4..];

    const ext_hdr: ?dlt.DltExtHeader = if (std_hdr.hdr_type.wevt == 1) blk: {
        const ehdr_buf = payload[0..dlt.EXTENDED_HEADER_SIZE];
        payload = payload[dlt.EXTENDED_HEADER_SIZE..];
        break :blk dlt.DltExtHeader{ .buf = ehdr_buf };
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

    try pretty.printLog(ecuid, ext_hdr, payload, writer, if (std_hdr.hdr_type.msbf == 1) .big else .little);
    return true;
}

pub fn filterStream(
    reader: anytype,
    writer: anytype,
    fltr: DltFilter,
    storage: bool,
) !void {
    const need_ext_hdr = fltr.apid != null or fltr.ctid != null or fltr.severity != null;
    // The length field of the DLT message allows 0xFFFF = 65,535 bytes
    var buffer: [64 * 1024]u8 = undefined;
    var strg_hdr_buf: [16]u8 = undefined;
    var std_hdr_buf: [4]u8 = undefined;
    while (true) {
        const strg_eid = if (storage) blk: {
            try reader.readSliceAll(&strg_hdr_buf);
            break :blk (try dlt.StorageHeader.init(&strg_hdr_buf)).ecuid;
        } else null;
        try reader.readSliceAll(&std_hdr_buf);
        const std_hdr = dlt.DltStandardHeader.init(&std_hdr_buf);
        const payload_len = std_hdr.length - dlt.STANDARD_HEADER_SIZE;
        const payload = buffer[0..payload_len];
        try reader.readSliceAll(payload);

        if (payload_len > buffer.len) return error.MaxMessageSizeExceeded;
        const written = try filterMessage(strg_eid, std_hdr, payload, writer, fltr, need_ext_hdr);
        if (written) try writer.flush();
    }
}

pub fn filterFile(file: *std.Io.File, io: std.Io, writer: anytype, fltr: DltFilter) !void {
    const need_ext_hdr = fltr.apid != null or fltr.ctid != null or fltr.severity != null;
    // The length field of the DLT message allows 0xFFFF = 65,535 bytes
    var buffer: [254 * 1024]u8 = undefined;
    var bytes_buffered: usize = 0;
    var cursor: usize = 0;
    while (true) {
        const bytes_read = try file.readPositionalAll(io, buffer[bytes_buffered..], cursor);
        if (bytes_read == 0) break;
        cursor += bytes_read;
        if (bytes_read == 0) continue;

        const buffer_length = bytes_buffered + bytes_read;
        if (buffer_length < dlt.STANDARD_HEADER_SIZE + dlt.STORAGE_HEADER_SIZE) {
            bytes_buffered = buffer_length;
            continue;
        }
        var pos: usize = 0;
        while ((buffer_length - pos) >= dlt.STANDARD_HEADER_SIZE + dlt.STORAGE_HEADER_SIZE) {
            const strg_eid = (try dlt.StorageHeader.init(buffer[pos..][0..dlt.STORAGE_HEADER_SIZE])).ecuid;
            const std_hdr = dlt.DltStandardHeader.init(buffer[pos + dlt.STORAGE_HEADER_SIZE ..][0..dlt.STANDARD_HEADER_SIZE]);

            if (std_hdr.length > buffer_length - pos) break;

            const payload = buffer[pos + dlt.STORAGE_HEADER_SIZE + dlt.STANDARD_HEADER_SIZE ..][0 .. std_hdr.length - dlt.STANDARD_HEADER_SIZE];
            _ = try filterMessage(strg_eid, std_hdr, payload, writer, fltr, need_ext_hdr);

            pos += std_hdr.length + dlt.STORAGE_HEADER_SIZE;
        }

        bytes_buffered = buffer_length - pos;
        std.mem.copyForwards(u8, &buffer, buffer[pos..][0..bytes_buffered]);
    }
    try writer.flush();
}
