const std = @import("std");

pub const TradeEventType = enum { open, close };

pub const TradeLogger = struct {
    file: std.fs.File,

    // ---------------------------------------------------------------
    // INIT LOGGER - Zig 0.14 compatible
    // ---------------------------------------------------------------
    pub fn init(allocator: std.mem.Allocator) !*TradeLogger {
        var logger = try allocator.create(TradeLogger);
        errdefer allocator.destroy(logger);

        try std.fs.cwd().makePath("logs");

        // Only valid flags in Zig 0.14:
        // .read, .write, .append, .truncate, .exclusive, .read_write
        logger.file = try std.fs.cwd().openFile("logs/trades.csv", .{
            .write = true,
            .append = true,
        });

        const meta = try logger.file.metadata();
        if (meta.size == 0) {
            try logger.writeHeader();
        }

        return logger;
    }

    pub fn deinit(self: *TradeLogger) void {
        self.file.close();
    }

    // ---------------------------------------------------------------
    // CSV HEADER
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
    // FORMAT TIMESTAMP - Zig 0.14 uses std.time.printIso8601
    // ---------------------------------------------------------------
    fn formatTimestamp(buffer: []u8, ts_ns: i128) ![]const u8 {
        const secs = @divTrunc(ts_ns, 1_000_000_000);
        const nsecs = @as(u32, @intCast(ts_ns - (secs * 1_000_000_000)));

        return try std.time.printIso8601(
            buffer,
            .{
                .secs = @as(i64, @intCast(secs)),
                .nsecs = nsecs,
                .utc = true,
            },
        );
    }

    // ---------------------------------------------------------------
    // INTERNAL GENERIC CSV WRITER
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
        var buf_ts: [64]u8 = undefined;
        var buf_cs: [64]u8 = undefined;
        var buf_ce: [64]u8 = undefined;

        const ts_str = try formatTimestamp(&buf_ts, event_time);
        const cs_str = try formatTimestamp(&buf_cs, candle_start_ns);
        const ce_str = try formatTimestamp(&buf_ce, candle_end_ns);

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
                cs_str,
                ce_str,
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
    // PUBLIC: OPEN TRADE
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
            0.0,
            candle_start_ns,
            candle_end_ns,
            candle_open,
            candle_high,
            candle_low,
            candle_close_at_entry,
            0.0,
            0.0,
            pct_entry,
            0.0,
        ) catch {};
    }

    // ---------------------------------------------------------------
    // PUBLIC: CLOSE TRADE
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
            entry_price,
            candle_close_at_exit,
            pnl_usdt,
            pct_entry,
            pct_exit,
        ) catch {};
    }
};
