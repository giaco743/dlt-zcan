const std = @import("std");
const builtin = @import("builtin");

const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("vaxis");

const log = std.log.scoped(.main);
pub const panic = vaxis.panic_handler;

const dlt = @import("dlt.zig");
const index = @import("index.zig");
const pretty = @import("pretty.zig");

const MAX_VISIBLE_ROWS = 64;
const ROW_BUF_SIZE = 4 * 1024;

const normal: vaxis.Cell.Color = .default;
const errr: vaxis.Cell.Color = .{ .index = 1 };
const warn: vaxis.Cell.Color = .{ .index = 3 };
const fatal: vaxis.Cell.Color = .{ .index = 5 };

const DltViewer = struct {
    file: []const u8,
    index: []const usize,
    rowbufs: [MAX_VISIBLE_ROWS][ROW_BUF_SIZE]u8 = undefined,
    first_msg_idx: u16 = 0,
    filter: dlt.DltFilter = .{},

    pub fn draw(self: *DltViewer, win: vaxis.Window) !void {
        const height: usize = @intCast(win.height);
        const visible = @min(height, MAX_VISIBLE_ROWS);

        const end = @min(
            visible,
            self.index.len,
        );
        var visible_row_idx: u16 = 0;
        var msg_idx = self.first_msg_idx;
        while (visible_row_idx < end and msg_idx < self.index.len) : (msg_idx += 1) {
            const msg_start = self.index[msg_idx] + dlt.STORAGE_HEADER_SIZE;
            const msg =
                try dlt.DltMessage.init(self.file[msg_start..]);
            if (!msg.matches(self.filter)) {
                continue;
            }
            try drawRow(
                win,
                @intCast(visible_row_idx),
                msg,
                &self.rowbufs[visible_row_idx],
            );
            visible_row_idx += 1;
        }
    }
    fn drawRow(
        win: vaxis.Window,
        y: u16,
        msg: dlt.DltMessage,
        outbuf: []u8,
    ) !void {
        const row = try pretty.printMessage(msg, outbuf[0..]);

        const bg = if (msg.level) |lvl| switch (lvl) {
            .fatal => fatal,
            .err => errr,
            .warn => warn,
            else => normal,
        } else normal;
        _ = win.printSegment(
            .{
                .text = row,
                .style = .{ .bg = bg },
            },
            .{
                .row_offset = y,
                .col_offset = 0,
            },
        );
    }
    fn scrollDown(self: *DltViewer) void {
        const max_start = if (self.index[self.first_msg_idx..].len > MAX_VISIBLE_ROWS)
            self.index[self.first_msg_idx..].len - MAX_VISIBLE_ROWS
        else
            0;

        if (self.first_msg_idx < max_start) self.first_msg_idx += 1;
    }
    fn scrollUp(self: *DltViewer) void {
        if (self.first_msg_idx > 0) self.first_msg_idx -= 1;
    }
};

const Focus = enum {
    ecu,
    app,
    ctx,
    table,
};

fn drawTitleBox(
    comptime title: []const u8,
    win: vaxis.Window,
    x: u16,
    y: u16,
    width: u16,
) void {
    if (width < title.len + 6)
        return;

    // Top border
    _ = win.printSegment(
        .{ .text = "┌" },
        .{ .row_offset = y, .col_offset = x },
    );

    _ = win.printSegment(
        .{ .text = "─ " },
        .{ .row_offset = y, .col_offset = x + 1 },
    );

    _ = win.printSegment(
        .{ .text = title },
        .{ .row_offset = y, .col_offset = x + 3 },
    );

    // Padding after title.
    const used = title.len + 4;
    const padding = width - used - 1;

    var col = x + 3 + @as(u16, @intCast(title.len));

    _ = win.printSegment(
        .{ .text = " " },
        .{ .row_offset = y, .col_offset = col },
    );
    col += 1;

    var i: u16 = 0;
    while (i < padding) : (i += 1) {
        _ = win.printSegment(
            .{ .text = "─" },
            .{ .row_offset = y, .col_offset = col },
        );
        col += 1;
    }

    _ = win.printSegment(
        .{ .text = "┐" },
        .{ .row_offset = y, .col_offset = x + width - 1 },
    );

    // Bottom border
    _ = win.printSegment(
        .{ .text = "└" },
        .{ .row_offset = y + 2, .col_offset = x },
    );

    var bottom_col = x + 1;
    while (bottom_col < x + width - 1) : (bottom_col += 1) {
        _ = win.printSegment(
            .{ .text = "─" },
            .{ .row_offset = y + 2, .col_offset = bottom_col },
        );
    }

    _ = win.printSegment(
        .{ .text = "┘" },
        .{ .row_offset = y + 2, .col_offset = x + width - 1 },
    );

    // Vertical sides
    _ = win.printSegment(
        .{ .text = "│" },
        .{ .row_offset = y + 1, .col_offset = x },
    );

    _ = win.printSegment(
        .{ .text = "│" },
        .{ .row_offset = y + 1, .col_offset = x + width - 1 },
    );
}

fn drawInputBox(
    comptime title: []const u8,
    win: vaxis.Window,
    input: *vaxis.widgets.TextInput,
    x: u16,
    y: u16,
    width: u16,
    style: vaxis.Cell.Style,
) void {
    drawTitleBox(title, win, x, y, width);

    const input_win = win.child(.{
        .x_off = x + 2,
        .y_off = y + 1,
        .width = width - 3,
        .height = 1,
    });

    input.drawWithStyle(input_win, style);
}

pub fn dltIdFromTextInput(self: *const vaxis.widgets.TextInput.Buffer, out: []u8) !?[]const u8 {
    const first = self.firstHalf();
    const second = self.secondHalf();
    if (first.len + second.len == 0) return null else if (first.len + second.len > 4) return error.OutOfBounds;

    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len .. first.len + second.len], second);
    return out[0..];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next() orelse {
        return error.MissingProgramName;
    };
    var path: ?[]const u8 = null;
    if ((it.next())) |arg|
        path = arg
    else
        return error.MultiplePaths;

    var file = try std.Io.Dir.cwd().openFile(io, path orelse return error.MissingPath, .{});
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

    try std.posix.madvise(
        mmap.memory.ptr,
        mmap.memory.len,
        std.posix.MADV.DONTNEED,
    );

    var viewer = DltViewer{ .file = mmap.memory, .index = dlt_index, .filter = .{} };

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

    var ecuout = [_]u8{0} ** 4;
    var ecu_input_style: vaxis.Cell.Style = .{};
    var ecu_input = vaxis.widgets.TextInput.init(alloc);
    defer ecu_input.deinit();
    var appout = [_]u8{0} ** 4;
    var app_input_style: vaxis.Cell.Style = .{};
    var app_input = vaxis.widgets.TextInput.init(alloc);
    defer app_input.deinit();
    var ctxout = [_]u8{0} ** 4;
    var ctx_input_style: vaxis.Cell.Style = .{};
    var ctx_input = vaxis.widgets.TextInput.init(alloc);
    defer ctx_input.deinit();

    try vx.setMouseMode(tty_writer, true);

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

    var focus: Focus = .table;

    while (true) {
        const win = vx.window();
        win.clear();

        const style: vaxis.Style = .{
            .fg = .{ .index = 0 },
        };
        const hdr_width = 40;
        drawInputBox("ECU ID", win, &ecu_input, 0, 0, hdr_width, ecu_input_style);
        drawInputBox("APP ID", win, &app_input, hdr_width, 0, hdr_width, app_input_style);
        drawInputBox("CTX ID", win, &ctx_input, 2 * hdr_width, 0, hdr_width, ctx_input_style);

        const tbl = win.child(.{
            .x_off = 0,
            .y_off = 3,
            .width = win.width,
            .height = win.height,
            .border = .{
                .where = .all,
                .style = style,
            },
        });
        try viewer.draw(tbl);

        // Put the cursor where the focused input wants it.
        switch (focus) {
            .ecu => win.showCursor(
                0 + 2 + ecu_input.prev_cursor_col,
                1,
            ),
            .app => win.showCursor(
                hdr_width + 2 + app_input.prev_cursor_col,
                1,
            ),
            .ctx => win.showCursor(
                2 * hdr_width + 2 + ctx_input.prev_cursor_col,
                1,
            ),
            .table => win.hideCursor(),
        }

        try vx.render(tty_writer);
        try tty_writer.flush();

        const event = try loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('e', .{ .ctrl = true })) {
                    focus = .ecu;
                }
                if (key.matches('a', .{ .ctrl = true })) {
                    focus = .app;
                }
                if (key.matches('k', .{ .ctrl = true })) {
                    focus = .ctx;
                }
                if (key.matches('t', .{ .ctrl = true })) {
                    focus = .table;
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    switch (focus) {
                        .ecu => {
                            ecuout = [_]u8{0} ** 4;
                            if (dltIdFromTextInput(&ecu_input.buf, &ecuout)) |id| {
                                ecu_input_style = .{ .fg = .default };
                                viewer.filter.ecuid = id;
                            } else |_| {
                                ecu_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .app => {
                            appout = [_]u8{0} ** 4;
                            if (dltIdFromTextInput(&app_input.buf, &appout)) |id| {
                                app_input_style = .{ .fg = .default };
                                viewer.filter.apid = id;
                            } else |_| {
                                app_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .ctx => {
                            ctxout = [_]u8{0} ** 4;
                            if (dltIdFromTextInput(&ctx_input.buf, &ctxout)) |id| {
                                ctx_input_style = .{ .fg = .default };
                                viewer.filter.ctid = id;
                            } else |_| {
                                ctx_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .table => {},
                    }
                } else {
                    // Send key to currently focused input
                    switch (focus) {
                        .ecu => {
                            try ecu_input.update(.{ .key_press = key });
                        },
                        .app => {
                            try app_input.update(.{ .key_press = key });
                        },
                        .ctx => {
                            try ctx_input.update(.{ .key_press = key });
                        },
                        .table => {
                            if (key.matches(vaxis.Key.down, .{}))
                                viewer.scrollDown();

                            if (key.matches(vaxis.Key.up, .{}))
                                viewer.scrollUp();
                        },
                    }
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty_writer, ws);
            },
        }
    }
}
