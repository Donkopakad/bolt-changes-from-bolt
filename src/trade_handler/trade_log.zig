const std = @import("std");

pub const TradeEventType = enum { open, close };

pub const TradeLogger = struct {
    file: std.fs.File,

    // ---------------------------------------------------------------
    // INITIALIZE LOGGER
    // ---------------------------------------------------------------
    pub fn init(allocator: std.mem.Allocator) !*TradeLogger {
        var logger = try allocator.create(TradeLogger);
        errdefer allocator.destroy(logger);

        // Ensure logs directory exists
        try std.fs.cwd().makePath("logs");

        // Open or create trades.csv
        logger.file = try std.fs.cwd().openFile("logs/trades.csv", .{
            .mode = .write_only,
            .create = true,
            .append = true,
        });

        // Write header if the file is empty
        const metadata = try logger.file.metadata();
        if (metadata.size == 0) {
            try logger.writeHeader();
        }

        return logger;
    }

    pub fn deinit(self: *TradeLogger) void {
        self.file.close();
    }

    // ---------------------------------------------------------------
    // WRITE CSV HEADER
    // ---------------------------------------------------------------
    fn writeHeader(self: *TradeLogger) !void {
        try self.file.writeAll(
            "event_time_utc,event_type,symbol,side,leverage,amount,position_size_usdt,fee_rate,"
            ++ "entry_price,exit_price,candle_start_time_utc,candle_end_time_utc,"
            ++ "candle_open,candle_high,candle_low,candle_close_at_entry,candle_close_at_exit,"
            ++ "pnl_usdt,pct_change_from_open_at_entry,pct_change_from_open_at_exit\n"
        );
        try self.file.flush();
    }

    // ---------------------------------------------------------------
    // TIMESTAMP FORMATTER — Zig 0.14 (ISO-8601)
    // ---------------------------------------------------------------
    fn formatTimestamp(buffer: []u8, timestamp_ns: i128) ![]const u8 {
        const epoch_s = @as(i64, @intCast(timestamp_ns / 1_000_000_000));
        const epoch_ns = @as(u32, @intCast(timestamp_ns % 1_000_000_000));

        return try std.time.formatIso8601(buffer, .{
            .secs = epoch_s,
            .nsecs = epoch_ns,
            .utc = true,
        });
    }

    // ---------------------------------------------------------------
    // GENERIC ROW WRITER
    // ---------------------------------------------------------------
    fn writeTradeRow(
        self: *TradeLogger,
        event_time: i128,
        event_type: TradeEventType,
        symbol: []const u8,
        side: []const u8,
        leverage: f32,
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
        candle_close_at_entry: f64,
        candle_close_at_exit: f64,
        pnl_usdt: f64,
        pct_entry: f64,
        pct_exit: f64,
    ) !void {
        var ts_buf: [64]u8 = undefined;
        var candle_start_buf: [64]u8 = undefined;
        var candle_end_buf: [64]u8 = undefined;

        const ts_str = try formatTimestamp(&ts_buf, event_time);
        const candle_start_str = try formatTimestamp(&candle_start_buf, candle_start_ns);
        const candle_end_str = try formatTimestamp(&candle_end_buf, candle_end_ns);

        try self.file.writer().print(
            "{s},{s},{s},{s},{d:.2},{d:.8},{d:.8},{d:.6},{d:.8},{d:.8},{s},{s},{d:.8},{d:.8},{d:.8},{d:.8},{d:.8},{d:.8},{d:.8},{d:.8}\n",
            .{
                ts_str,
                if (event_type == .open) "OPEN" else "CLOSE",
                symbol,
                side,
                leverage,
                amount,
                position_size_usdt,
                fee_rate,
                entry_price,
                exit_price,
                candle_start_str,
                candle_end_str,
                candle_open,
                candle_high,
                candle_low,
                candle_close_at_entry,
                candle_close_at_exit,
                pnl_usdt,
                pct_entry,
                pct_exit,
            },
        );

        try self.file.flush();
    }

    // ---------------------------------------------------------------
    // PUBLIC: LOG OPEN TRADE
    // ---------------------------------------------------------------
    pub fn logOpenTrade(
        self: *TradeLogger,
        event_time: i128,
        symbol: []const u8,
        side: []const u8,
        leverage: f32,
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
    ) void {
        self.writeTradeRow(
            event_time,
            .open,
            symbol,
            side,
            leverage,
            amount,
            position_size_usdt,
            fee_rate,
            entry_price,
            0.0, // exit_price
            candle_start_ns,
            candle_end_ns,
            candle_open,
            candle_high,
            candle_low,
            candle_close_at_entry,
            0.0, // candle_close_at_exit
            0.0, // pnl
            pct_entry,
            0.0, // pct_exit
        ) catch |err| {
            std.log.err("Failed to log OPEN trade for {s}: {}", .{ symbol, err });
        };
    }

    // ---------------------------------------------------------------
    // PUBLIC: LOG CLOSE TRADE
    // ---------------------------------------------------------------
    pub fn logCloseTrade(
        self: *TradeLogger,
        event_time: i128,
        symbol: []const u8,
        side: []const u8,
        leverage: f32,
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
    ) void {
        self.writeTradeRow(
            event_time,
            .close,
            symbol,
            side,
            leverage,
            amount,
            position_size_usdt,
            fee_rate,
            entry_price,
            exit_price,
            candle_start_ns,
            candle_end_ns,
            candle_open,
            candle_high,
            candle_low,
            entry_price, // entry close
            candle_close_at_exit,
            pnl_usdt,
            pct_entry,
            pct_exit,
        ) catch |err| {
            std.log.err("Failed to log CLOSE trade for {s}: {}", .{ symbol, err });
        };
    }
};
