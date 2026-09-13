const std = @import("std");
const dlt = @import("dlt.zig");

pub fn index(buf: []const u8, allocator: std.mem.Allocator) ![]usize {
    var idx: usize = 0;
    var index_list: std.ArrayList(usize) = .empty;
    while (idx < buf.len and buf[idx..].len >= dlt.STANDARD_HEADER_SIZE + dlt.STORAGE_HEADER_SIZE) {
        _ = try dlt.StorageHeader.init(buf[idx..]);
        const std_hdr = try dlt.DltStandardHeader.init(buf[idx + dlt.STORAGE_HEADER_SIZE ..]);
        if (std_hdr.length > buf[idx + dlt.STORAGE_HEADER_SIZE ..].len) return error.Truncted;

        try index_list.append(allocator, idx);
        idx += std_hdr.length + dlt.STORAGE_HEADER_SIZE;
    }
    if (idx < buf.len) return error.Truncated;
    return index_list.toOwnedSlice(allocator);
}
