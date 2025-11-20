const std = @import("std");

pub const TradeLogger = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,

    pub const TradeRow = struct {
        event_time_ns: i64,
        symbol: []const u8,
        side: []const u8,
        leverage: f64,
        amount: f64,
        position_size_usdt: f64,
        fee_rate: f64,
        entry_price: f64,
        exit_price: f64,
        candle_start_ns: i64,
        candle_end_ns: i64,
        candle_open: f64,
        candle_high: f64,
        candle_low: f64,
        candle_close_at_entry: f64,
        candle_close_at_exit: f64,
        pnl_usdt: f64,
        pct_entry: f64,
        pct_exit: f64,
    };

    pub fn init(allocator: std.mem.Allocator) !TradeLogger {
        const cwd = std.fs.cwd();
        try cwd.makePath("logs");

        var file: std.fs.File = cwd.openFile("logs/trades.csv", .{
            .mode = .read_write,
            .intended_io_mode = .blocking,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                var created = try cwd.createFile("logs/trades.csv", .{ .truncate = false });
                created.close();
                break :blk try cwd.openFile("logs/trades.csv", .{
                    .mode = .read_write,
                    .intended_io_mode = .blocking,
                });
            },
            else => return err,
        };

        try file.seekFromEnd(0);

        var logger = TradeLogger{
            .allocator = allocator,
            .file = file,
        };

        try logger.writeHeader();
        return logger;
    }

    pub fn deinit(self: *TradeLogger) void {
        self.file.close();
    }

    pub fn writeHeader(self: *TradeLogger) !void {
        const size = try self.file.getEndPos();
        if (size == 0) {
            const header = "event_time_utc,event_type,symbol,side,leverage,amount,position_size_usdt,fee_rate,entry_price,exit_price,candle_start_utc,candle_end_utc,candle_open,candle_high,candle_low,candle_close_at_entry,candle_close_at_exit,pnl_usdt,pct_entry,pct_exit\n";
            try self.file.writeAll(header);
            try self.file.flush();
        }
    }

    pub fn logOpenTrade(
        self: *TradeLogger,
        event_time_ns: i128,
        symbol: []const u8,
        side: []const u8,
        leverage: f64,
        amount: f64,
        position_size_usdt: f64,
        fee_rate: f64,
        entry_price: f64,
        candle_start_ns: i128,
        candle_end_ns: i128,
        candle_open: f64,
        candle_high: f64,
        candle_low: f64,
        candle_close_at_entry: f64,
        pct_entry: f64,
    ) !void {
        const row = TradeRow{
            .event_time_ns = @as(i64, @intCast(event_time_ns)),
            .symbol = symbol,
            .side = side,
            .leverage = leverage,
            .amount = amount,
            .position_size_usdt = position_size_usdt,
            .fee_rate = fee_rate,
            .entry_price = entry_price,
            .exit_price = 0.0,
            .candle_start_ns = @as(i64, @intCast(candle_start_ns)),
            .candle_end_ns = @as(i64, @intCast(candle_end_ns)),
            .candle_open = candle_open,
            .candle_high = candle_high,
            .candle_low = candle_low,
            .candle_close_at_entry = candle_close_at_entry,
            .candle_close_at_exit = candle_close_at_entry,
            .pnl_usdt = 0.0,
            .pct_entry = pct_entry,
            .pct_exit = 0.0,
        };
        try self.writeTradeRow("open", row);
    }

    pub fn logCloseTrade(
        self: *TradeLogger,
        event_time_ns: i128,
        symbol: []const u8,
        side: []const u8,
        leverage: f64,
        amount: f64,
        position_size_usdt: f64,
        fee_rate: f64,
        entry_price: f64,
        exit_price: f64,
        candle_start_ns: i128,
        candle_end_ns: i128,
        candle_open: f64,
        candle_high: f64,
        candle_low: f64,
        candle_close_at_exit: f64,
        pnl_usdt: f64,
        pct_entry: f64,
        pct_exit: f64,
    ) !void {
        const row = TradeRow{
            .event_time_ns = @as(i64, @intCast(event_time_ns)),
            .symbol = symbol,
            .side = side,
            .leverage = leverage,
            .amount = amount,
            .position_size_usdt = position_size_usdt,
            .fee_rate = fee_rate,
            .entry_price = entry_price,
            .exit_price = exit_price,
            .candle_start_ns = @as(i64, @intCast(candle_start_ns)),
            .candle_end_ns = @as(i64, @intCast(candle_end_ns)),
            .candle_open = candle_open,
            .candle_high = candle_high,
            .candle_low = candle_low,
            .candle_close_at_entry = candle_open,
            .candle_close_at_exit = candle_close_at_exit,
            .pnl_usdt = pnl_usdt,
            .pct_entry = pct_entry,
            .pct_exit = pct_exit,
        };
        try self.writeTradeRow("close", row);
    }

fn writeTradeRow(self: *TradeLogger, event_type: []const u8, row: TradeRow) !void {
        var buffer: [64]u8 = undefined;
        const event_time = try formatTimestamp(row.event_time_ns, &buffer);

        var candle_buf_start: [64]u8 = undefined;
        const candle_start = try formatTimestamp(row.candle_start_ns, &candle_buf_start);

        var candle_buf_end: [64]u8 = undefined;
        const candle_end = try formatTimestamp(row.candle_end_ns, &candle_buf_end);

        const writer = self.file.writer();
        try writer.print(
            "{s},{s},{s},{s},{d:.4},{d:.4},{d:.4},{d:.6},{d:.4},{d:.4},{s},{s},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}\n",
            .{
                event_time,
                event_type,
                row.symbol,
                row.side,
                row.leverage,
                row.amount,
                row.position_size_usdt,
                row.fee_rate,
                row.entry_price,
                row.exit_price,
                candle_start,
                candle_end,
                row.candle_open,
                row.candle_high,
                row.candle_low,
                row.candle_close_at_entry,
                row.candle_close_at_exit,
                row.pnl_usdt,
                row.pct_entry,
                row.pct_exit,
            },
        );
        try self.file.flush();
    }
};

fn formatTimestamp(ns: i64, buffer: *[64]u8) ![]const u8 {
    const seconds: i64 = @divTrunc(ns, 1_000_000_000);
    const dt = try std.time.utcToDateTime(seconds);
    return try std.fmt.bufPrint(buffer, "{d:04}-{d:02}-{d:02}T{d:02}:{d:02}:{d:02}Z", .{
        dt.year,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
        dt.second,
    });
}
