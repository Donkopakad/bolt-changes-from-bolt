const std = @import("std");
const stat_calc_lib = @import("../stat_calc/lib.zig");
const StatCalc = stat_calc_lib.StatCalc;
const SymbolMap = @import("../symbol-map.zig").SymbolMap;
const types = @import("../types.zig");
const GPUBatchResult = types.GPUBatchResult;
const GPUPercentageChangeResultBatch = types.GPUPercentageChangeResultBatch;
const MAX_SYMBOLS = types.MAX_SYMBOLS;
const SignalType = types.SignalType;
const TradingSignal = types.TradingSignal;
const TradeHandler = @import("../trade_handler/lib.zig").TradeHandler;
const PortfolioManager = @import("../trade_handler/portfolio_manager.zig").PortfolioManager;

// CHANGED: Updated extern function to match the new C function signature
extern fn analyze_trading_signals_with_liquidity_simd(
    rsi_values: [*]f32,
    bid_percentages: [*]f32,
    ask_percentages: [*]f32,
    spread_percentages: [*]f32,
    bid_volumes: [*]f32,
    ask_volumes: [*]f32,
    best_bids: [*]f32,
    best_asks: [*]f32,
    position_sizes: [*]f32,
    has_positions: [*]bool,
    len: c_int,
    decisions: [*]TradingDecision,
) void;

const TradingDecision = extern struct {
    should_generate_buy: bool,
    should_generate_sell: bool,
    has_open_position: bool,
    spread_valid: bool,
    liquidity_sufficient: bool,
    signal_strength: f32,
    adjusted_spread_threshold: f32,
    available_liquidity_ratio: f32,
};

const ProcessingTask = struct {
    rsi_values: []f32,
    bid_percentages: []f32,
    ask_percentages: []f32,
    spread_percentages: []f32,
    bid_volumes: []f32,
    ask_volumes: []f32,
    best_bids: []f32,
    best_asks: []f32,
    position_sizes: []f32,
    has_positions: []bool,
    decisions: []TradingDecision,
    symbol_names: [][]const u8,
    start_idx: usize,
    end_idx: usize,
    task_id: u32,
};

// thread-safe signal queue with batched appends to reduce lock contention
const SignalQueue = struct {
    signals: std.ArrayList(TradingSignal),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) SignalQueue {
        return SignalQueue{
            .signals = std.ArrayList(TradingSignal).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *SignalQueue) void {
        self.signals.deinit();
    }

    // add a whole slice of signals under a single lock
    pub fn addSlice(self: *SignalQueue, new_signals: []const TradingSignal) !void {
        
@@ -77,173 +77,173 @@ const SignalQueue = struct {
        if (new_signals.len == 0) return;
        if (new_signals.len == 0) return;
        self.mutex.lock();
        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.mutex.unlock();
        try self.signals.appendSlice(new_signals);
        try self.signals.appendSlice(new_signals);
    }
    }


    pub fn drainAll(self: *SignalQueue, out_signals: *std.ArrayList(TradingSignal)) !void {
    pub fn drainAll(self: *SignalQueue, out_signals: *std.ArrayList(TradingSignal)) !void {
        self.mutex.lock();
        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.mutex.unlock();


        try out_signals.appendSlice(self.signals.items);
        try out_signals.appendSlice(self.signals.items);
        self.signals.clearRetainingCapacity();
        self.signals.clearRetainingCapacity();
    }
    }
};
};


pub const SignalEngine = struct {
pub const SignalEngine = struct {
    allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    symbol_map: *const SymbolMap,
    symbol_map: *const SymbolMap,
    stat_calc: ?*StatCalc = null,
    stat_calc: ?*StatCalc = null,
    trade_handler: TradeHandler,
    trade_handler: TradeHandler,


    processing_thread: ?std.Thread,
    processing_thread: ?std.Thread,
    batch_thread: ?std.Thread,
    batch_thread: ?std.Thread,
    worker_threads: []std.Thread,
    worker_threads: []std.Thread,
    num_worker_threads: u32,
    num_worker_threads: u32,
    should_stop: std.atomic.Value(bool),
    run_flag: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,
    mutex: std.Thread.Mutex,


    batch_result_queue: std.ArrayList(GPUBatchResult),
    batch_result_queue: std.ArrayList(GPUBatchResult),
    batch_queue_mutex: std.Thread.Mutex,
    batch_queue_mutex: std.Thread.Mutex,
    batch_condition: std.Thread.Condition,
    batch_condition: std.Thread.Condition,


    task_queue: std.ArrayList(ProcessingTask),
    task_queue: std.ArrayList(ProcessingTask),
    task_queue_mutex: std.Thread.Mutex,
    task_queue_mutex: std.Thread.Mutex,
    task_condition: std.Thread.Condition,
    task_condition: std.Thread.Condition,
    tasks_finished_sem: std.Thread.Semaphore,
    tasks_finished_sem: std.Thread.Semaphore,


    signal_queue: SignalQueue,
    signal_queue: SignalQueue,


    tasks_completed: std.atomic.Value(u64),
    tasks_completed: std.atomic.Value(u64),
    total_processing_time: std.atomic.Value(u64),
    total_processing_time: std.atomic.Value(u64),


    csv_file_path: []const u8,
    csv_file_path: []const u8,
    csv_file_position: u64,
    csv_file_position: u64,
    csv_header_processed: bool,
    csv_header_processed: bool,
    csv_missing_warned: bool,
    csv_missing_warned: bool,
    symbol_name_cache: std.StringHashMap([]const u8),
    symbol_name_cache: std.StringHashMap([]const u8),


    pub fn init(allocator: std.mem.Allocator, symbol_map: *const SymbolMap) !SignalEngine {
    pub fn init(allocator: std.mem.Allocator, symbol_map: *const SymbolMap) !SignalEngine {
        const device_id = try stat_calc_lib.selectBestCUDADevice();
        const device_id = try stat_calc_lib.selectBestCUDADevice();
        var stat_calc = try allocator.create(StatCalc);
        var stat_calc = try allocator.create(StatCalc);
        stat_calc.* = try StatCalc.init(allocator, device_id);
        stat_calc.* = try StatCalc.init(allocator, device_id);
        try stat_calc.getDeviceInfo();
        try stat_calc.getDeviceInfo();
        try stat_calc.warmUp();
        try stat_calc.warmUp();


        const trade_handler = TradeHandler.init(allocator, symbol_map);
        const trade_handler = TradeHandler.init(allocator, symbol_map);


        const cpu_count = (std.Thread.getCpuCount() catch 8) / 2; // hyper threading cores wont count
        const cpu_count = (std.Thread.getCpuCount() catch 8) / 2; // hyper threading cores wont count
        const num_workers = @max(2, cpu_count - 2);
        const num_workers = @max(2, cpu_count - 2);


        const worker_threads = try allocator.alloc(std.Thread, num_workers);
        const worker_threads = try allocator.alloc(std.Thread, num_workers);


        return SignalEngine{
        return SignalEngine{
            .allocator = allocator,
            .allocator = allocator,
            .symbol_map = symbol_map,
            .symbol_map = symbol_map,
            .stat_calc = stat_calc,
            .stat_calc = stat_calc,
            .trade_handler = trade_handler,
            .trade_handler = trade_handler,
            .processing_thread = null,
            .processing_thread = null,
            .batch_thread = null,
            .batch_thread = null,
            .worker_threads = worker_threads,
            .worker_threads = worker_threads,
            .num_worker_threads = @intCast(num_workers),
            .num_worker_threads = @intCast(num_workers),
            .should_stop = std.atomic.Value(bool).init(false),
            .run_flag = std.atomic.Value(bool).init(true),
            .mutex = std.Thread.Mutex{},
            .mutex = std.Thread.Mutex{},
            .batch_result_queue = std.ArrayList(GPUBatchResult).init(allocator),
            .batch_result_queue = std.ArrayList(GPUBatchResult).init(allocator),
            .batch_queue_mutex = std.Thread.Mutex{},
            .batch_queue_mutex = std.Thread.Mutex{},
            .batch_condition = std.Thread.Condition{},
            .batch_condition = std.Thread.Condition{},
            .task_queue = std.ArrayList(ProcessingTask).init(allocator),
            .task_queue = std.ArrayList(ProcessingTask).init(allocator),
            .task_queue_mutex = std.Thread.Mutex{},
            .task_queue_mutex = std.Thread.Mutex{},
            .task_condition = std.Thread.Condition{},
            .task_condition = std.Thread.Condition{},
            .tasks_finished_sem = std.Thread.Semaphore{},
            .tasks_finished_sem = std.Thread.Semaphore{},
            .signal_queue = SignalQueue.init(allocator),
            .signal_queue = SignalQueue.init(allocator),
            .tasks_completed = std.atomic.Value(u64).init(0),
            .tasks_completed = std.atomic.Value(u64).init(0),
            .total_processing_time = std.atomic.Value(u64).init(0),
            .total_processing_time = std.atomic.Value(u64).init(0),
            .csv_file_path = "percent_changes_15m.csv",
            .csv_file_path = "percent_changes_15m.csv",
            .csv_file_position = 0,
            .csv_file_position = 0,
            .csv_header_processed = false,
            .csv_header_processed = false,
            .csv_missing_warned = false,
            .csv_missing_warned = false,
            .symbol_name_cache = std.StringHashMap([]const u8).init(allocator),
            .symbol_name_cache = std.StringHashMap([]const u8).init(allocator),
        };
        };
    }
    }


    pub fn deinit(self: *SignalEngine) void {
    pub fn deinit(self: *SignalEngine) void {
        self.should_stop.store(true, .seq_cst);
        self.run_flag.store(false, .seq_cst);
        self.batch_condition.signal();
        self.batch_condition.signal();
        self.task_condition.broadcast();
        self.task_condition.broadcast();


        if (self.processing_thread) |thread| {
        if (self.processing_thread) |thread| {
            thread.join();
            thread.join();
        }
        }
        if (self.batch_thread) |thread| {
        if (self.batch_thread) |thread| {
            thread.join();
            thread.join();
        }
        }


        for (self.worker_threads) |thread| {
        for (self.worker_threads) |thread| {
            thread.join();
            thread.join();
        }
        }


        self.trade_handler.deinit();
        self.trade_handler.deinit();
        self.batch_result_queue.deinit();
        self.batch_result_queue.deinit();
        self.task_queue.deinit();
        self.task_queue.deinit();
        self.signal_queue.deinit();
        self.signal_queue.deinit();
        self.allocator.free(self.worker_threads);
        self.allocator.free(self.worker_threads);
        self.freeSymbolCache();
        self.freeSymbolCache();


        if (self.stat_calc) |stat_calc| {
        if (self.stat_calc) |stat_calc| {
            stat_calc.deinit();
            stat_calc.deinit();
            self.allocator.destroy(stat_calc);
            self.allocator.destroy(stat_calc);
        }
        }


        const completed = self.tasks_completed.load(.seq_cst);
        const completed = self.tasks_completed.load(.seq_cst);
        const total_time = self.total_processing_time.load(.seq_cst);
        const total_time = self.total_processing_time.load(.seq_cst);
        if (completed > 0) {
        if (completed > 0) {
            const avg_time_ns = total_time / completed;
            const avg_time_ns = total_time / completed;
            std.log.info("Performance: {} tasks completed, avg time: {d:.3}us", .{ completed, @as(f64, @floatFromInt(avg_time_ns)) / 1000.0 });
            std.log.info("Performance: {} tasks completed, avg time: {d:.3}us", .{ completed, @as(f64, @floatFromInt(avg_time_ns)) / 1000.0 });
        }
        }
    }
    }


    pub fn run(self: *SignalEngine) !void {
    pub fn run(self: *SignalEngine) !void {
        try self.startWorkerThreads();
        try self.startWorkerThreads();
        try self.startProcessingThread();
        try self.startProcessingThread();
        try self.trade_handler.start();
        try self.trade_handler.start();
        try self.startBatchThread();
        try self.startBatchThread();
    }
    }


    fn startWorkerThreads(self: *SignalEngine) !void {
    fn startWorkerThreads(self: *SignalEngine) !void {
        for (0..self.num_worker_threads) |i| {
        for (0..self.num_worker_threads) |i| {
            self.worker_threads[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, workerThreadFunction, .{ self, i });
            self.worker_threads[i] = try std.Thread.spawn(.{ .allocator = self.allocator }, workerThreadFunction, .{ self, i });
        }
        }
@@ -281,144 +293,209 @@ pub const SignalEngine = struct {
@@ -281,144 +293,209 @@ pub const SignalEngine = struct {
    fn processingThreadFunction(self: *SignalEngine) void {
    fn processingThreadFunction(self: *SignalEngine) void {
        std.log.info("Signal processing thread started", .{});
        std.log.info("Signal processing thread started", .{});


        while (!self.should_stop.load(.seq_cst)) {
        while (self.run_flag.load(.seq_cst)) {
            self.batch_queue_mutex.lock();
            self.batch_queue_mutex.lock();
            while (self.batch_result_queue.items.len == 0 and !self.should_stop.load(.seq_cst)) {
            while (self.batch_result_queue.items.len == 0 and self.run_flag.load(.seq_cst)) {
                self.batch_condition.wait(&self.batch_queue_mutex);
                self.batch_condition.wait(&self.batch_queue_mutex);
            }
            }
            if (self.should_stop.load(.seq_cst)) {
            if (!self.run_flag.load(.seq_cst)) {
                self.batch_queue_mutex.unlock();
                self.batch_queue_mutex.unlock();
                break;
                break;
            }
            }


            var batch_result = self.batch_result_queue.orderedRemove(0);
            var batch_result = self.batch_result_queue.orderedRemove(0);
            self.batch_queue_mutex.unlock();
            self.batch_queue_mutex.unlock();


            self.processSignalsParallel(&batch_result.percentage_change) catch |err| {
            self.processSignalsParallel(&batch_result.percentage_change) catch |err| {
                std.log.err("Error processing signals: {}", .{err});
                std.log.err("Error processing signals: {}", .{err});
            };
            };
        }
        }


        std.log.info("Signal processing thread stopped", .{});
        std.log.info("Signal processing thread stopped", .{});
    }
    }


    fn processSignalsParallel(self: *SignalEngine, pct_results: *GPUPercentageChangeResultBatch) !void {
    fn processSignalsParallel(self: *SignalEngine, pct_results: *GPUPercentageChangeResultBatch) !void {
        _ = pct_results;
        _ = pct_results;
        try self.generateSignalsFromCsv();
        try self.generateSignalsFromCsv();
    }
    }


    fn processTaskChunk(_: *SignalEngine, task: ProcessingTask, out_signals: *std.ArrayList(TradingSignal)) !void {
    fn processTaskChunk(_: *SignalEngine, task: ProcessingTask, out_signals: *std.ArrayList(TradingSignal)) !void {
        const chunk_len = task.end_idx - task.start_idx;
        const chunk_len = task.end_idx - task.start_idx;
        if (chunk_len == 0) return;
        if (chunk_len == 0) return;


        analyze_trading_signals_with_liquidity_simd(
            task.rsi_values[task.start_idx..].ptr,
            task.bid_percentages[task.start_idx..].ptr,
            task.ask_percentages[task.start_idx..].ptr,
            task.spread_percentages[task.start_idx..].ptr,
            task.bid_volumes[task.start_idx..].ptr,
            task.ask_volumes[task.start_idx..].ptr,
            task.best_bids[task.start_idx..].ptr,
            task.best_asks[task.start_idx..].ptr,
            task.position_sizes[task.start_idx..].ptr,
            task.has_positions[task.start_idx..].ptr,
            @intCast(chunk_len),
            task.decisions[task.start_idx..].ptr,
        );

        for (task.start_idx..task.end_idx) |i| {
            const decision = task.decisions[i];
            if (!decision.spread_valid) continue;

            const symbol_name = task.symbol_names[i];
            const rsi_value = task.rsi_values[i];

            if (decision.should_generate_buy) {
                try out_signals.append(.{
                    .symbol_name = symbol_name,
                    .signal_type = .BUY,
                    .rsi_value = rsi_value,
                    .orderbook_percentage = task.bid_percentages[i],
                    .timestamp = @as(i64, @intCast(std.time.nanoTimestamp())),
                    .signal_strength = decision.signal_strength,
                    .leverage = 1.0,
                });
            }

            if (decision.should_generate_sell) {
                try out_signals.append(.{
                    .symbol_name = symbol_name,
                    .signal_type = .SELL,
                    .rsi_value = rsi_value,
                    .orderbook_percentage = task.ask_percentages[i],
                    .timestamp = @as(i64, @intCast(std.time.nanoTimestamp())),
                    .signal_strength = decision.signal_strength,
                    .leverage = 1.0,
                });
            }
        }
    }

    fn generateSignalsFromCsv(self: *SignalEngine) !void {
        var file = std.fs.cwd().openFile(self.csv_file_path, .{ .mode = .read_only }) catch |err| {
            if (err == error.FileNotFound) {
                if (!self.csv_missing_warned) {
                    self.csv_missing_warned = true;
                    std.log.warn("CSV file {s} not found; waiting for aggregator to create it", .{ self.csv_file_path });
                }
                return;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size < self.csv_file_position) {
            self.csv_file_position = 0;
            self.csv_header_processed = false;
        }

        if (stat.size == self.csv_file_position) {
            return;
        }

        try file.seekTo(self.csv_file_position);
        const remaining = stat.size - self.csv_file_position;
        if (remaining == 0) return;

        var buffer = try self.allocator.alloc(u8, remaining);
        defer self.allocator.free(buffer);
        const bytes_read = try file.readAll(buffer);
        self.csv_file_position += bytes_read;

        var header_seen = self.csv_header_processed;
        var it = std.mem.splitScalar(u8, buffer[0..bytes_read], '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimRight(u8, line_raw, "\r");
            if (line.len == 0) continue;
            if (!header_seen) {
                header_seen = true;
                if (std.mem.startsWith(u8, line, "timestamp_ms")) {
                    continue;
                }
            }

            self.handleCsvLine(line) catch |err| {
                std.log.warn("Failed to handle CSV line: {}", .{err});
            };
        }

        self.csv_header_processed = header_seen;
    }

    fn handleCsvLine(self: *SignalEngine, line: []const u8) !void {
        var parts = std.mem.splitScalar(u8, line, ',');
        _ = parts.next() orelse return; // timestamp
        const symbol_slice = parts.next() orelse return;
        _ = parts.next(); // open
        _ = parts.next(); // last
        const pct_slice = parts.next() orelse return;

        if (pct_slice.len == 0) return;

        const pct_change = std.fmt.parseFloat(f32, pct_slice) catch {
            return;
        };

        const symbol_name = try self.internSymbolName(symbol_slice);
        try self.evaluateCsvSignal(symbol_name, pct_change);
    }

    fn internSymbolName(self: *SignalEngine, raw_name: []const u8) ![]const u8 {
        if (self.symbol_name_cache.get(raw_name)) |existing| {
            return existing;
        }

        const duped = try self.allocator.dupe(u8, raw_name);
        const gop = try self.symbol_name_cache.getOrPut(duped);
        if (!gop.found_existing) {
            gop.key_ptr.* = duped;
            gop.value_ptr.* = duped;
            return duped;
        } else {
            self.allocator.free(duped);
            return gop.value_ptr.*;
        }
    }

    fn evaluateCsvSignal(self: *SignalEngine, symbol_name: []const u8, pct_change: f32) !void {
        const positive_threshold: f32 = 5.0;
        const negative_threshold: f32 = -5.0;
        const default_leverage: f32 = 1.0;
        const magnitude = @abs(pct_change);
        const strength = if (magnitude == 0.0) 0.5 else @min(1.0, magnitude / 20.0);
        const side = self.trade_handler.getPositionSide(symbol_name);

        if (pct_change >= positive_threshold and side != .long) {
            const signal = TradingSignal{
                .symbol_name = symbol_name,
                .signal_type = .BUY,
                .rsi_value = pct_change,
                .orderbook_percentage = pct_change,
                .timestamp = @as(i64, @intCast(std.time.nanoTimestamp())),
                .signal_strength = strength,
                .leverage = default_leverage,
            };
            try self.trade_handler.addSignal(signal);
        } else if (pct_change <= negative_threshold and side != .short) {
            const signal = TradingSignal{
                .symbol_name = symbol_name,
                .signal_type = .SELL,
                .rsi_value = pct_change,
                .orderbook_percentage = pct_change,
                .timestamp = @as(i64, @intCast(std.time.nanoTimestamp())),
                .signal_strength = strength,
                .leverage = default_leverage,
            };
            try self.trade_handler.addSignal(signal);
        }
    }

    fn freeSymbolCache(self: *SignalEngine) void {
        var it = self.symbol_name_cache.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.symbol_name_cache.deinit();
    }
};
