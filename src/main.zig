const std = @import("std");
const builtin = @import("builtin");

const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("vaxis");

pub const panic = vaxis.panic_handler;

const dlt = @import("dlt.zig");
const index = @import("index.zig");
const pretty = @import("pretty.zig");

const MAX_VISIBLE_ROWS = 64;
const ROW_BUF_SIZE = 4 * 1024;

const DltViewer = struct {
    file: []const u8,
    index: []const usize,

    rowbufs: [MAX_VISIBLE_ROWS][ROW_BUF_SIZE]u8 = undefined,

    start_row: usize = 0,

    pub fn draw(self: *DltViewer, win: vaxis.Window) !void {
        const height: usize = @intCast(win.height);
        const visible = @min(height, MAX_VISIBLE_ROWS);

        const end = @min(
            self.start_row + visible,
            self.index.len,
        );

        for (self.start_row..end) |row_idx| {
            const y: usize = row_idx - self.start_row;

            const start =
                self.index[row_idx] + dlt.STORAGE_HEADER_SIZE;

            const msg =
                try dlt.DltMessage.init(self.file[start..]);

            try drawRow(
                win,
                @intCast(y),
                msg,
                &self.rowbufs[y],
            );
        }
    }
    fn drawRow(
        win: vaxis.Window,
        y: u16,
        msg: dlt.DltMessage,
        outbuf: []u8,
    ) !void {
        const row = try pretty.printMessage(msg, outbuf[0..]);

        _ = win.printSegment(
            .{
                .text = row,
            },
            .{
                .row_offset = y,
                .col_offset = 0,
            },
        );
    }
    fn scrollDown(self: *DltViewer) void {
        const max_start = if (self.index.len > MAX_VISIBLE_ROWS)
            self.index.len - MAX_VISIBLE_ROWS
        else
            0;

        if (self.start_row < max_start) self.start_row += 1;
    }
    fn scrollUp(self: *DltViewer) void {
        if (self.start_row > 0) self.start_row -= 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next() orelse {
        return error.MissingProgramName;
    };
    const path = it.next() orelse {
        return error.MissingPath;
    };

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

    var viewer = DltViewer{
        .file = mmap.memory,
        .index = dlt_index,
    };

    var buffer: [1024]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &buffer);
    defer tty.deinit();
    const tty_writer = tty.writer();
    var vx = try vaxis.init(io, alloc, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
    }) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty_writer);
    try tty_writer.flush();

    try vx.queryTerminal(
        tty_writer,
        .fromMilliseconds(250),
    );
    try tty_writer.flush();

    // Wait for the initial terminal size.
    while (true) {
        const event = try loop.nextEvent();

        switch (event) {
            .winsize => |ws| {
                try vx.resize(alloc, tty_writer, ws);
                break;
            },
            else => continue,
        }
    }

    while (true) {
        const win = vx.window();
        win.clear();
        try viewer.draw(win);

        try vx.render(tty_writer);
        try tty_writer.flush();

        const event = try loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    viewer.scrollDown();
                }

                if (key.matches(vaxis.Key.up, .{})) {
                    viewer.scrollUp();
                }
            },
            .winsize => {},
        }
    }
}
