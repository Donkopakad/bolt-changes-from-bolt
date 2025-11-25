const std = @import("std");
const json = std.json;
const websocket = @import("websocket");
const http = std.http;

const SymbolMap = @import("../symbol-map.zig").SymbolMap;
const OHLC = @import("../types.zig").OHLC;
const Symbol = @import("../types.zig").Symbol;
const OrderBook = @import("../types.zig").OrderBook;
const TickerHandler = @import("ticker_handler.zig").TickerHandler;
const DepthHandler = @import("depth_handler.zig").DepthHandler;
const metrics = @import("../metrics.zig");

pub const WSClient = struct {
    ticker_client: websocket.Client,
    depth_client: websocket.Client,
    ticker_streams: std.ArrayList([]const u8),
    depth_streams: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    ticker_handler: ?*TickerHandler = null,
    depth_handler: ?*DepthHandler = null,
    http_client: http.Client,
    metrics_collector: ?*metrics.MetricsCollector,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, metrics_collector: ?*metrics.MetricsCollector) !WSClient {
        return WSClient{
            .ticker_client = undefined,
            .depth_client = undefined,
            .ticker_streams = std.ArrayList([]const u8).init(allocator),
            .depth_streams = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
            .http_client = http.Client{ .allocator = allocator },
            .metrics_collector = metrics_collector,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *WSClient) void {
        for (self.ticker_streams.items) |stream| {
            self.allocator.free(stream);
        }
        self.ticker_streams.deinit();

        for (self.depth_streams.items) |stream| {
            self.allocator.free(stream);
        }
        self.depth_streams.deinit();

        if (self.depth_handler) |d| d.deinit();
        if (self.ticker_handler) |t| t.deinit();

        self.ticker_client.deinit();
        self.depth_client.deinit();
    }

    pub fn startListener(self: *WSClient, symbol_map: *SymbolMap) !void {
        // ---------------------------
        //  TICKER CLIENT
        // ---------------------------
        self.ticker_client = try websocket.Client.init(self.allocator, .{
            .host = "stream.binance.com",
            .port = 9443,
            .tls = true,
        });

        // ADD TICKER CLOSE HANDLER
        self.ticker_client.onClose = struct {
            pub fn call(code: u16, reason: []const u8) void {
                std.log.err("⚠️ TICKER WebSocket closed: code={} reason={s}", .{ code, reason });
            }
        };

        // ---------------------------
        //  DEPTH CLIENT
        // ---------------------------
        self.depth_client = try websocket.Client.init(self.allocator, .{
            .host = "stream.binance.com",
            .port = 443,
            .tls = true,
        });

        // ADD DEPTH CLOSE HANDLER
        self.depth_client.onClose = struct {
            pub fn call(code: u16, reason: []const u8) void {
                std.log.err("⚠️ DEPTH WebSocket closed: code={} reason={s}", .{ code, reason });
            }
        };

        // ---------------------------
        // Perform Binance WS handshake
        // ---------------------------
        try self.ticker_client.handshake("/ws", .{
            .timeout_ms = 5000,
            .headers = "Host: stream.binance.com:9443",
        });

        try self.depth_client.handshake("/ws", .{
            .timeout_ms = 5000,
            .headers = "Host: stream.binance.com:9443",
        });

        // ---------------------------
        // Build subscription streams
        // ---------------------------
        var it = symbol_map.iterator();
        while (it.next()) |entry| {
            const symbol_lower = try std.ascii.allocLowerString(self.allocator, entry.key_ptr.*);
            defer self.allocator.free(symbol_lower);

            const ticker_stream = try std.fmt.allocPrint(self.allocator, "{s}@miniTicker", .{symbol_lower});
            try self.ticker_streams.append(ticker_stream);

            const depth_stream = try std.fmt.allocPrint(self.allocator, "{s}@depth", .{symbol_lower});
            try self.depth_streams.append(depth_stream);
        }

        // ---------------------------
        // Subscribe ticker stream
        // ---------------------------
        const ticker_sub = .{
            .method = "SUBSCRIBE",
            .params = self.ticker_streams.items,
            .id = 1,
        };
        const ticker_msg = try json.stringifyAlloc(self.allocator, ticker_sub, .{});
        defer self.allocator.free(ticker_msg);
        try self.ticker_client.write(ticker_msg);

        // ---------------------------
        // Subscribe depth stream
        // ---------------------------
        const depth_sub = .{
            .method = "SUBSCRIBE",
            .params = self.depth_streams.items,
            .id = 2,
        };
        const depth_msg = try json.stringifyAlloc(self.allocator, depth_sub, .{});
        defer self.allocator.free(depth_msg);
        try self.depth_client.write(depth_msg);

        // ---------------------------
        // Handlers
        // ---------------------------
        self.ticker_handler = try self.allocator.create(TickerHandler);
        self.ticker_handler.?.* = try TickerHandler.init(symbol_map, self.allocator, self.metrics_collector);

        self.depth_handler = try self.allocator.create(DepthHandler);
        self.depth_handler.?.* = try DepthHandler.init(symbol_map, self.allocator, &self.http_client, self.metrics_collector);

        // ---------------------------
        // Reader threads
        // ---------------------------
        _ = self.ticker_client.readLoopInNewThread(self.ticker_handler.?) catch |err| {
            std.log.err("❌ Ticker read-loop crashed: {}", .{err});
            return err;
        };

        _ = self.depth_client.readLoopInNewThread(self.depth_handler.?) catch |err| {
            std.log.err("❌ Depth read-loop crashed: {}", .{err});
            return err;
        };
    }

    pub fn stopListener(self: *WSClient) !void {
        if (self.ticker_streams.items.len > 0) {
            const msg = .{
                .method = "UNSUBSCRIBE",
                .params = self.ticker_streams.items,
                .id = 3,
            };
            const json_msg = try json.stringifyAlloc(self.allocator, msg, .{});
            defer self.allocator.free(json_msg);
            try self.ticker_client.write(json_msg);
        }

        if (self.depth_streams.items.len > 0) {
            const msg = .{
                .method = "UNSUBSCRIBE",
                .params = self.depth_streams.items,
                .id = 4,
            };
            const json_msg = try json.stringifyAlloc(self.allocator, msg, .{});
            defer self.allocator.free(json_msg);
            try self.depth_client.write(json_msg);
        }

        try self.ticker_client.close(.{});
        try self.depth_client.close(.{});
    }
};
