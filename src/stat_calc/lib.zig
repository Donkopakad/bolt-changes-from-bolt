const std = @import("std");
const SymbolMap = @import("../symbol-map.zig").SymbolMap;
const types = @import("../types.zig");
const Symbol = types.Symbol;
const OHLC = types.OHLC;
const ERR = @import("../errors.zig");
const StatCalcError = @import("../errors.zig").StatCalcError;
const DeviceInfo = types.DeviceInfo;
const GPUOHLCDataBatch = types.GPUOHLCDataBatch;
const GPUPercentageChangeDeviceBatch = types.GPUPercentageChangeDeviceBatch;
const GPUPercentageChangeResultBatch = types.GPUPercentageChangeResultBatch;
const MAX_SYMBOLS = types.MAX_SYMBOLS;
const GPUBatchResult = types.GPUBatchResult;

pub const KERNEL_SUCCESS = ERR.KernelError{ .code = 0, .message = "Success" };

extern "c" fn cuda_wrapper_init_device(device_id: c_int) ERR.KernelError;
extern "c" fn cuda_wrapper_reset_device() ERR.KernelError;
extern "c" fn cuda_wrapper_get_device_count(count: *c_int) ERR.KernelError;
extern "c" fn cuda_wrapper_get_device_info(device_id: c_int, info: *DeviceInfo) ERR.KernelError;
extern "c" fn cuda_wrapper_select_best_device(best_device_id: *c_int) ERR.KernelError;

extern "c" fn cuda_wrapper_allocate_memory(
    d_ohlc_batch: **GPUOHLCDataBatch,
    d_pct_result: **GPUPercentageChangeDeviceBatch,
) ERR.KernelError;

extern "c" fn cuda_wrapper_free_memory(
    d_ohlc_batch: ?*GPUOHLCDataBatch,
    d_pct_result: ?*GPUPercentageChangeDeviceBatch,
) ERR.KernelError;

extern "c" fn cuda_wrapper_run_percentage_change_batch(
    d_ohlc_batch_ptr: *GPUOHLCDataBatch,
    d_pct_results_ptr: *GPUPercentageChangeDeviceBatch,
    h_ohlc_batch: *const GPUOHLCDataBatch,
    h_pct_results: *GPUPercentageChangeDeviceBatch,
    num_symbols: c_int,
) ERR.KernelError;

pub const StatCalc = struct {
    allocator: std.mem.Allocator,
    device_id: c_int,

    d_ohlc_batch: ?*GPUOHLCDataBatch,
    d_pct_result: ?*GPUPercentageChangeDeviceBatch,

    h_pct_device: GPUPercentageChangeDeviceBatch,

    pub fn init(allocator: std.mem.Allocator, device_id: c_int) !StatCalc {
        var calc = StatCalc{
            .allocator = allocator,
            .device_id = device_id,
            .d_ohlc_batch = null,
            .d_pct_result = null,
            .h_pct_device = std.mem.zeroes(GPUPercentageChangeDeviceBatch),
        };

        try calc.initCUDADevice();
        try calc.allocateDeviceMemory();

        return calc;
    }

    pub fn deinit(self: *StatCalc) void {
        const kerr = cuda_wrapper_free_memory(
            self.d_ohlc_batch,
            self.d_pct_result,
        );
        if (kerr.code != 0) {
            std.log.err("CUDA free memory failed via wrapper: {} ({s})", .{ kerr.code, kerr.message });
        }

        self.d_ohlc_batch = null;
        self.d_pct_result = null;

        const kerr_reset = cuda_wrapper_reset_device();
        if (kerr_reset.code != 0) {
            std.log.err("CUDA device reset failed via wrapper: {} ({s})", .{ kerr_reset.code, kerr_reset.message });
        }
    }

    fn initCUDADevice(self: *StatCalc) !void {
        const kerr = cuda_wrapper_init_device(self.device_id);
        if (kerr.code != 0) {
            std.log.err("Failed to set CUDA device via wrapper: {} ({s})", .{ kerr.code, kerr.message });
            return StatCalcError.CUDAInitFailed;
        }

        var info: DeviceInfo = undefined;
        const kerr_info = cuda_wrapper_get_device_info(self.device_id, &info);
        if (kerr_info.code != 0) {
            std.log.err("Failed to get device info via wrapper: {} ({s})", .{ kerr_info.code, kerr_info.message });
            return StatCalcError.CUDAGetPropertiesFailed;
        }

        std.log.info("Using CUDA device: {s}", .{info.name});
        std.log.info("Compute capability: {}.{}", .{ info.major, info.minor });
        std.log.info("Global memory: {} MB", .{info.totalGlobalMem / (1024 * 1024)});
    }

    fn allocateDeviceMemory(self: *StatCalc) !void {
        var d_ohlc_batch_ptr: ?*GPUOHLCDataBatch = null;
        var d_pct_result_ptr: ?*GPUPercentageChangeDeviceBatch = null;

        std.log.info("Attempting to allocate GPU memory...", .{});

        const kerr = cuda_wrapper_allocate_memory(
            @ptrCast(&d_ohlc_batch_ptr),
            @ptrCast(&d_pct_result_ptr),
        );

        if (kerr.code != 0) {
            std.log.err("CUDA memory allocation failed via wrapper: {} ({s})", .{ kerr.code, kerr.message });
            return StatCalcError.CUDAMemoryAllocationFailed;
        }

        if (d_ohlc_batch_ptr == null) {
            std.log.err("d_ohlc_batch_ptr is null after allocation", .{});
            return StatCalcError.CUDAMemoryAllocationFailed;
        }

        if (d_pct_result_ptr == null) {
            std.log.err("d_pct_result_ptr is null after allocation", .{});
            return StatCalcError.CUDAMemoryAllocationFailed;
        }

        self.d_ohlc_batch = d_ohlc_batch_ptr;
        self.d_pct_result = d_pct_result_ptr;
@@ -142,108 +143,114 @@ pub const StatCalc = struct {
        const max_symbols_to_process = @min(symbol_count, MAX_SYMBOLS);

        var symbols_slice = try self.allocator.alloc(Symbol, max_symbols_to_process);
        defer self.allocator.free(symbols_slice);
        var symbol_names = try self.allocator.alloc([]const u8, max_symbols_to_process);
        defer self.allocator.free(symbol_names);

        var iterator = symbol_map.iterator();
        var all_idx: usize = 0;

        while (iterator.next()) |entry| {
            if (all_idx >= max_symbols_to_process) {
                break;
            }
            symbols_slice[all_idx] = entry.value_ptr.*;
            symbol_names[all_idx] = entry.key_ptr.*;
            all_idx += 1;
        }

        if (symbol_count > MAX_SYMBOLS) {
            std.log.warn("Total symbols ({}) exceeds MAX_SYMBOLS ({}), processing only first {} symbols", .{ symbol_count, MAX_SYMBOLS, max_symbols_to_process });
        }

        const num_symbols_to_process = all_idx;

        var result = GPUPercentageChangeResultBatch{
            .device = std.mem.zeroes(GPUPercentageChangeDeviceBatch),
            .symbols = [_][]const u8{&[_]u8{}} ** MAX_SYMBOLS,
            .count = num_symbols_to_process,
        };

        if (num_symbols_to_process > 0) {
            result.device = try self.calculatePercentageChangeBatch(symbols_slice[0..num_symbols_to_process]);
            for (0..num_symbols_to_process) |i| {
                result.symbols[i] = symbol_names[i];
            }
        }

        return GPUBatchResult{
            .percentage_change = result,
        };
    }

    fn calculatePercentageChangeBatch(self: *StatCalc, symbols: []const Symbol) !GPUPercentageChangeDeviceBatch {
        const num_symbols = @min(symbols.len, MAX_SYMBOLS);
        if (num_symbols == 0) return self.h_pct_device;

        var h_ohlc_batch_zig = GPUOHLCDataBatch{
            .close_prices = [_][15]f32{[_]f32{0.0} ** 15} ** MAX_SYMBOLS,
            .counts = [_]u32{0} ** MAX_SYMBOLS,
        };

        for (0..num_symbols) |i| {
            h_ohlc_batch_zig.counts[i] = @intCast(symbols[i].count);
            var data_idx: usize = 0;
            var circ_buffer_start_idx = symbols[i].head;
            if (symbols[i].count < 15) {
                circ_buffer_start_idx = 0;
            }

            for (0..symbols[i].count) |j| {
                if (data_idx >= 15) break;
                const current_ohlc_idx = (circ_buffer_start_idx + j) % 15;
                h_ohlc_batch_zig.close_prices[i][data_idx] = @floatCast(symbols[i].ticker_queue[current_ohlc_idx].close_price);
                data_idx += 1;
            }
        }

        self.h_pct_device = std.mem.zeroes(GPUPercentageChangeDeviceBatch);

        if (self.d_ohlc_batch == null) {
            std.log.err("Failed to allocate memory for d_ohlc_batch", .{});
            return StatCalcError.CUDAMemoryAllocationFailed;
        }

        const kerr = cuda_wrapper_run_percentage_change_batch(
            self.d_ohlc_batch.?,
            self.d_pct_result.?,
            &h_ohlc_batch_zig,
            &self.h_pct_device,
            @intCast(num_symbols),
        );

        if (kerr.code != 0) {
            std.log.err("Percentage change kernel execution failed via wrapper: {} ({s})", .{ kerr.code, kerr.message });
            return StatCalcError.CUDAKernelExecutionFailed;
        }

        return self.h_pct_device;
    }

    pub fn getDeviceInfo(self: *StatCalc) !void {
        var info: DeviceInfo = undefined;
        const kerr = cuda_wrapper_get_device_info(self.device_id, &info);
        if (kerr.code != 0) {
            std.log.err("Failed to get device info via wrapper: {} ({s})", .{ kerr.code, kerr.message });
            return StatCalcError.CUDAGetPropertiesFailed;
        }

        std.log.info("=== CUDA Device Information ===", .{});
        std.log.info("Device Name: {s}", .{info.name});
        std.log.info("Compute Capability: {}.{}", .{ info.major, info.minor });
        std.log.info("Total Global Memory: {} MB", .{@divTrunc(info.totalGlobalMem, 1024 * 1024)});
        std.log.info("==============================", .{});
    }

    pub fn warmUp(self: *StatCalc) !void {
        var dummy_symbol = Symbol.init();
        const dummy_ohlc = OHLC{
            .open_price = 100.0,
            .high_price = 105.0,
            .low_price = 99.0,
            .close_price = 103.0,
            .volume = 1000.0,
