const std = @import("std");
const SymbolMap = @import("../symbol-map.zig").SymbolMap;
const types = @import("../types.zig");
const Symbol = types.Symbol;
const OHLC = types.OHLC;
const ERR = @import("../errors.zig");
const StatCalcError = @import("../errors.zig").StatCalcError;
const DeviceInfo = types.DeviceInfo;
const GPUOHLCDataBatch = types.GPUOHLCDataBatch;
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
    d_pct_result: **GPUPercentageChangeResultBatch,
) ERR.KernelError;

extern "c" fn cuda_wrapper_free_memory(
    d_ohlc_batch: ?*GPUOHLCDataBatch,
    d_pct_result: ?*GPUPercentageChangeResultBatch,
) ERR.KernelError;

extern "c" fn cuda_wrapper_run_percentage_change_batch(
    d_ohlc_batch_ptr: *GPUOHLCDataBatch,
    d_pct_results_ptr: *GPUPercentageChangeResultBatch,
    h_ohlc_batch: *const GPUOHLCDataBatch,
    h_pct_results: *GPUPercentageChangeResultBatch,
    num_symbols: c_int,
) ERR.KernelError;

pub const StatCalc = struct {
    allocator: std.mem.Allocator,
    device_id: c_int,

    d_ohlc_batch: ?*GPUOHLCDataBatch,
    d_pct_result: ?*GPUPercentageChangeResultBatch,

    h_pct_result: GPUPercentageChangeResultBatch,

    pub fn init(allocator: std.mem.Allocator, device_id: c_int) !StatCalc {
        var calc = StatCalc{
            .allocator = allocator,
            .device_id = device_id,
            .d_ohlc_batch = null,
            .d_pct_result = null,
            .h_pct_result = std.mem.zeroes(GPUPercentageChangeResultBatch),
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
        var d_pct_result_ptr: ?*GPUPercentageChangeResultBatch = null;

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

        std.log.info("GPU memory allocation successful", .{});
        std.log.info("  d_ohlc_batch: 0x{x}", .{@intFromPtr(self.d_ohlc_batch.?)});
        std.log.info("  d_pct_result: 0x{x}", .{@intFromPtr(self.d_pct_result.?)});
    }

    pub fn calculateSymbolMapBatch(self: *StatCalc, symbol_map: *const SymbolMap, _: u32) !GPUBatchResult {
        const symbol_count = symbol_map.count();
        if (symbol_count == 0) {
            std.log.warn("SymbolMap is empty, nothing to calculate", .{});
            return ERR.Dump.MarketDataEmpty;
        }

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

        const pct_results = if (num_symbols_to_process > 0)
            try self.calculatePercentageChangeBatch(symbols_slice[0..num_symbols_to_process])
        else
            std.mem.zeroes(GPUPercentageChangeResultBatch);

        return GPUBatchResult{
            .percentage_change = pct_results,
        };
    }

    fn calculatePercentageChangeBatch(self: *StatCalc, symbols: []const Symbol) !GPUPercentageChangeResultBatch {
        const num_symbols = @min(symbols.len, MAX_SYMBOLS);
        if (num_symbols == 0) return self.h_pct_result;

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
            } else {
                circ_buffer_start_idx = symbols[i].head;
            }

            for (0..symbols[i].count) |j| {
                if (data_idx >= 15) break;
                const current_ohlc_idx = (circ_buffer_start_idx + j) % 15;
                h_ohlc_batch_zig.close_prices[i][data_idx] = @floatCast(symbols[i].ticker_queue[current_ohlc_idx].close_price);
                data_idx += 1;
            }
        }

        self.h_pct_result = std.mem.zeroes(GPUPercentageChangeResultBatch);

        if (self.d_ohlc_batch == null) {
            std.log.err("Failed to allocate memory for d_ohlc_batch", .{});
            return StatCalcError.CUDAMemoryAllocationFailed;
        }

        const kerr = cuda_wrapper_run_percentage_change_batch(
            self.d_ohlc_batch.?,
            self.d_pct_result.?,
            &h_ohlc_batch_zig,
            &self.h_pct_result,
            @intCast(num_symbols),
        );

        if (kerr.code != 0) {
            std.log.err("Percentage change kernel execution failed via wrapper: {} ({s})", .{ kerr.code, kerr.message });
            return StatCalcError.CUDAKernelExecutionFailed;
        }

        return self.h_pct_result;
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
        };

        for (0..15) |_| {
            dummy_symbol.addTicker(dummy_ohlc);
        }
        std.debug.assert(dummy_symbol.count == 15);

        var symbols_slice = [_]Symbol{dummy_symbol};
        _ = try self.calculatePercentageChangeBatch(&symbols_slice);

        std.log.info("CUDA warm-up completed", .{});
    }
};

pub fn getCUDADeviceCount() !c_int {
    var device_count: c_int = 0;
    const kerr = cuda_wrapper_get_device_count(&device_count);
    if (kerr.code != 0) {
        std.log.err("Failed to get CUDA device count via wrapper: {} ({s})", .{ kerr.code, kerr.message });
        return StatCalcError.CUDAGetDeviceCountFailed;
    }
    return device_count;
}

pub fn selectBestCUDADevice() !c_int {
    var best_device: c_int = 0;
    const kerr = cuda_wrapper_select_best_device(&best_device);

    if (kerr.code == ERR.KERNEL_ERROR_NO_DEVICE.code) {
        return StatCalcError.NoCUDADevicesFound;
    }
    if (kerr.code != 0) {
        std.log.err("Failed to select best CUDA device via wrapper: {} ({s})", .{ kerr.code, kerr.message });
        return StatCalcError.CUDAGetDeviceCountFailed;
    }
    return best_device;
}
