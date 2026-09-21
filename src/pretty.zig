const std = @import("std");
const dlt = @import("dlt.zig");

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

fn printArgs(writer: *std.Io.Writer, noar: u8, buf: []const u8, endian: std.builtin.Endian) !void {
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
        const type_info: dlt.TypeInfo = @bitCast(raw_type_info);
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

pub fn printLog(buf: []const u8, outbuf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(outbuf);
    const std_hdr = try dlt.DltStandardHeader.init(buf);
    if (std_hdr.ecuId()) |eid| try writer.print(
        "ECU={s} ",
        .{eid},
    );
    if (try std_hdr.extHdr()) |ehdr| {
        const endian: std.builtin.Endian = if (std_hdr.hdr_type.msbf == 1) .big else .little;
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
        if (ehdr.messageInfo().verbose == 1 and ehdr.noar() > 0)
            try printArgs(&writer, ehdr.noar(), ehdr.payload(), endian)
        else
            try writer.print("{x}", .{ehdr.payload()});
    } else try writer.print("| {x}", .{buf[std_hdr.hdrLength()..][0 .. std_hdr.length - std_hdr.hdrLength()]});

    try writer.print("\n", .{});
    return outbuf[0..writer.end];
}

pub fn printMessage(msg: dlt.DltMessage, outbuf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(outbuf);
    if (msg.timestamp) |ts| {
        const h = ts / 36_000_000;
        const m = ts / 600_000 % 60;
        const s = ts / 10_000 % 60;
        const fraction = ts % 10_000;
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>2} ", .{ h, m, s, fraction });
    }
    if (msg.ecu_id) |ecuid| try writer.print("ECU={s} ", .{ecuid});
    if (msg.app_id) |appid| try writer.print("APP={s} ", .{appid});
    if (msg.ctx_id) |ctxid| try writer.print("CTX={s} ", .{ctxid});
    try writer.print("|", .{});
    if (msg.ext_hdr) |exthdr| {
        if (exthdr.messageInfo().verbose == 1 and exthdr.noar() > 0) {
            try writer.print("[", .{});
            var arg_it = exthdr.argIterator();
            while (try arg_it.next()) |arg| {
                try writer.print("{f}, ", .{arg});
            }
            try writer.print("]", .{});
        }
    } else {
        try writer.print("{X}", .{msg.payload});
    }
    try writer.print("\n", .{});
    return outbuf[0..writer.end];
}
