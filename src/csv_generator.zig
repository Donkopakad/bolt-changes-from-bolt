const std = @import("std");
const json = std.json;

const FuturesBaseUrl = "https://fapi.binance.com";
const ExchangeInfoPath = "/fapi/v1/exchangeInfo";
const KlinesPath = "/fapi/v1/klines";
const TickerPricePath = "/fapi/v1/ticker/price";

const CandleIntervalMs: i64 = 15 * 60 * 1000;
const CandleAlignmentDelayMs: i64 = 2000;
const PricePollIntervalMs: i64 = 2000;
const DayMs: i64 = 24 * 60 * 60 * 1000;
const OpenPriceThrottleBatch: usize = 40;
const OpenPriceThrottleDelayNs: u64 = 750 * std.time.ns_per_ms;
const CsvPath = "percent_changes_15m.csv";

const AtomicBool = std.atomic.Value(bool);

const SymbolOpenMap = std.StringHashMap(OpenInfo);

const OpenInfo = struct {
    open_price: f64 = 0,
    open_timestamp_ms: i64 = 0,
    last_close_price: f64 = 0,
};

const KlineComputation = struct {
    open_price: f64,
    last_close_price: f64,
};

pub fn run(stop_flag: *AtomicBool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var generator = try CsvGenerator.init(gpa.allocator(), stop_flag);
    defer generator.deinit();

    generator.runLoop() catch |err| {
        std.log.err("CSV generator stopped due to error: {}", .{err});
    };
}

const CsvGenerator = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    symbols: std.ArrayList([]const u8),
    open_prices: SymbolOpenMap,
    csv_file: ?std.fs.File = null,
    current_day_index: i64 = -1,
    stop_flag: *AtomicBool,

    pub fn init(allocator: std.mem.Allocator, stop_flag: *AtomicBool) !CsvGenerator {
        return CsvGenerator{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .symbols = std.ArrayList([]const u8).init(allocator),
            .open_prices = SymbolOpenMap.init(allocator),
            .stop_flag = stop_flag,
        };
    }

    pub fn deinit(self: *CsvGenerator) void {
        if (self.csv_file) |file| {
            file.close();
            self.csv_file = null;
        }
        for (self.symbols.items) |symbol| {
            self.allocator.free(symbol);
        }
        self.symbols.deinit();
        self.open_prices.deinit();
        self.http_client.deinit();
    }

    fn runLoop(self: *CsvGenerator) !void {
        try self.loadSymbols();

        const initial_time_ms = nowMs();
        try self.ensureCsvFile(initial_time_ms);

        var current_candle_start = alignToCandle(initial_time_ms);
        var next_candle_start = current_candle_start + CandleIntervalMs;

        try self.updateOpenPrices(current_candle_start);

        while (self.shouldContinue()) {
            const poll_start_ms = nowMs();
            try self.ensureCsvFile(poll_start_ms);

            while (poll_start_ms >= next_candle_start + CandleAlignmentDelayMs) {
                current_candle_start = next_candle_start;
                next_candle_start += CandleIntervalMs;
                std.log.info("Detected new candle at {d}, refreshing open prices...", .{current_candle_start});
                self.updateOpenPrices(current_candle_start) catch |err| {
                    std.log.err("Failed to refresh open prices: {}", .{err});
                };
            }

            self.writeLatestPrices(poll_start_ms) catch |err| {
                std.log.err("Failed to write ticker prices: {}", .{err});
            };

            const elapsed_ms = nowMs() - poll_start_ms;
            if (elapsed_ms < PricePollIntervalMs) {
                const sleep_ns = @as(u64, @intCast((PricePollIntervalMs - elapsed_ms) * std.time.ns_per_ms));
                std.time.sleep(sleep_ns);
            }
        }

        std.log.info("CSV generator stopping...", .{});
    }

    fn shouldContinue(self: *const CsvGenerator) bool {
        return self.stop_flag.load(.Acquire);
    }

    fn loadSymbols(self: *CsvGenerator) !void {
        std.log.info("Loading USDT-M futures symbols for CSV generator...", .{});
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ FuturesBaseUrl, ExchangeInfoPath });
        const uri = try std.Uri.parse(url);
        var header_buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(header_buf);

        var req = try self.http_client.open(.GET, uri, .{ .server_header_buffer = header_buf });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return error.ExchangeInfoRequestFailed;
        }

        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 10);
        defer self.allocator.free(body);

        var parsed = try json.parseFromSlice(json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidExchangeInfo;

        const symbols_val = root.object.get("symbols") orelse return error.InvalidExchangeInfo;
        if (symbols_val != .array) return error.InvalidExchangeInfo;

        for (symbols_val.array.items) |symbol_val| {
            if (symbol_val != .object) continue;
            const obj = symbol_val.object;

            const contract_type_val = obj.get("contractType") orelse continue;
            if (contract_type_val != .string or !std.mem.eql(u8, contract_type_val.string, "PERPETUAL")) continue;

            const quote_asset_val = obj.get("quoteAsset") orelse continue;
            if (quote_asset_val != .string or !std.mem.eql(u8, quote_asset_val.string, "USDT")) continue;

            const status_val = obj.get("status") orelse continue;
            if (status_val != .string or !std.mem.eql(u8, status_val.string, "TRADING")) continue;

            const symbol_name_val = obj.get("symbol") orelse continue;
            if (symbol_name_val != .string) continue;

            const owned_symbol = try self.allocator.dupe(u8, symbol_name_val.string);
            try self.symbols.append(owned_symbol);
            try self.open_prices.put(owned_symbol, OpenInfo{});
        }

        std.log.info("Loaded {d} futures symbols for CSV generation", .{self.symbols.items.len});
    }

    fn updateOpenPrices(self: *CsvGenerator, candle_start_ms: i64) !void {
        var processed: usize = 0;
        for (self.symbols.items) |symbol| {
            if (!self.shouldContinue()) return;
            const computation = self.fetchOpenForSymbol(symbol, candle_start_ms) catch |err| {
                std.log.err("Failed to fetch open price for {s}: {}", .{ symbol, err });
                continue;
            };
            if (self.open_prices.getPtr(symbol)) |info_ptr| {
                info_ptr.* = OpenInfo{
                    .open_price = computation.open_price,
                    .open_timestamp_ms = candle_start_ms,
                    .last_close_price = computation.last_close_price,
                };
            }
            processed += 1;
            if (processed % OpenPriceThrottleBatch == 0) {
                std.time.sleep(OpenPriceThrottleDelayNs);
            }
        }
    }

    fn fetchOpenForSymbol(self: *CsvGenerator, symbol: []const u8, candle_start_ms: i64) !KlineComputation {
        var url_buf: [256]u8 = undefined;
        const full_url = try std.fmt.bufPrint(&url_buf, "{s}{s}?symbol={s}&interval=15m&limit=2", .{
            FuturesBaseUrl,
            KlinesPath,
            symbol,
        });
        const uri = try std.Uri.parse(full_url);

        var header_buf = try self.allocator.alloc(u8, 1024);
        defer self.allocator.free(header_buf);

        var req = try self.http_client.open(.GET, uri, .{ .server_header_buffer = header_buf });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return error.KlinesRequestFailed;
        }

        const body = try req.reader().readAllAlloc(self.allocator, 32 * 1024);
        defer self.allocator.free(body);

        var parsed = try json.parseFromSlice(json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array or root.array.items.len == 0) {
            return error.InvalidKlines;
        }

        const last_idx = root.array.items.len - 1;
        const last_entry = root.array.items[last_idx];
        if (last_entry != .array) return error.InvalidKlines;

        const prev_idx: usize = if (root.array.items.len >= 2) last_idx - 1 else last_idx;
        const prev_entry = root.array.items[prev_idx];
        if (prev_entry != .array) return error.InvalidKlines;

        const fallback_close = try parseFloat(prev_entry.array.items[4]);

        const last_open_time = try parseInt(last_entry.array.items[0]);
        if (last_open_time == candle_start_ms) {
            const open_price = try parseFloat(last_entry.array.items[1]);
            const close_price = try parseFloat(last_entry.array.items[4]);
            return KlineComputation{ .open_price = open_price, .last_close_price = close_price };
        }

        return KlineComputation{ .open_price = fallback_close, .last_close_price = fallback_close };
    }

    fn writeLatestPrices(self: *CsvGenerator, timestamp_ms: i64) !void {
        if (self.csv_file == null) return;

        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ FuturesBaseUrl, TickerPricePath });
        const uri = try std.Uri.parse(url);
        var header_buf = try self.allocator.alloc(u8, 2048);
        defer self.allocator.free(header_buf);

        var req = try self.http_client.open(.GET, uri, .{ .server_header_buffer = header_buf });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return error.TickerRequestFailed;
        }

        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 4);
        defer self.allocator.free(body);

        var parsed = try json.parseFromSlice(json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return error.InvalidTickerResponse;

        var row_buf: [256]u8 = undefined;
        var file = self.csv_file.?;

        for (root.array.items) |item| {
            if (item != .object) continue;
            const symbol_val = item.object.get("symbol") orelse continue;
            const price_val = item.object.get("price") orelse continue;
            if (symbol_val != .string or price_val != .string) continue;

            const open_info = self.open_prices.get(symbol_val.string) orelse continue;
            if (open_info.open_price == 0) continue;

            const last_price = std.fmt.parseFloat(f64, price_val.string) catch continue;
            if (open_info.open_price == 0) continue;

            const pct_change = ((last_price - open_info.open_price) / open_info.open_price) * 100.0;
            const row_len = std.fmt.bufPrint(&row_buf, "{d},{s},{d:.6},{d:.6},{d:.6}\n", .{
                timestamp_ms,
                symbol_val.string,
                open_info.open_price,
                last_price,
                pct_change,
            }) catch continue;

            file.writeAll(row_buf[0..row_len]) catch |err| {
                std.log.err("Failed writing CSV row: {}", .{err});
                return;
            };
        }
    }

    fn ensureCsvFile(self: *CsvGenerator, timestamp_ms: i64) !void {
        const day_index = @divTrunc(timestamp_ms, DayMs);
        if (self.csv_file == null) {
            try self.openCsv(false);
            self.current_day_index = day_index;
            return;
        }

        if (self.current_day_index == -1) {
            self.current_day_index = day_index;
            return;
        }

        if (day_index != self.current_day_index) {
            self.current_day_index = day_index;
            try self.openCsv(true);
        }
    }

    fn openCsv(self: *CsvGenerator, truncate: bool) !void {
        if (self.csv_file) |file| {
            file.close();
            self.csv_file = null;
        }

        var file = try std.fs.cwd().createFile(CsvPath, .{ .read = false, .truncate = truncate });
        if (!truncate) {
            file.seekFromEnd(0) catch {};
        }
        self.csv_file = file;
    }
};

fn parseFloat(value: json.Value) !f64 {
    return switch (value) {
        .string => std.fmt.parseFloat(f64, value.string),
        .integer => @as(f64, @floatFromInt(value.integer)),
        .float => value.float,
        else => error.InvalidFloat,
    };
}

fn parseInt(value: json.Value) !i64 {
    return switch (value) {
        .integer => value.integer,
        .string => std.fmt.parseInt(i64, value.string, 10),
        else => error.InvalidInteger,
    };
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn alignToCandle(timestamp_ms: i64) i64 {
    return (@divFloor(timestamp_ms, CandleIntervalMs)) * CandleIntervalMs;
}
