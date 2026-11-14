//! Decoder-only tests for zaudio/miniaudio. They never open an audio device or engine.
const std = @import("std");
const zaudio = @import("zaudio");

// zaudio's Decoder.readPCMFrames turns MA_AT_END into error.AtEnd and drops the frame count of the
// final partial read. Call miniaudio directly so every decoded frame is counted.
extern fn ma_decoder_read_pcm_frames(decoder: *zaudio.Decoder, frames_out: *anyopaque, frame_count: u64, frames_read: *u64) i32;

fn decodeAll(allocator: std.mem.Allocator, path: [:0]const u8, out_rate: *u32, out_channels: *u32) ![]f32 {
    // Ask for f32 and let the decoder keep the native channel count / rate (0 = native).
    const decoder = try zaudio.Decoder.createFromFile(path, zaudio.Decoder.Config.init(.float32, 0, 0));
    defer decoder.destroy();

    var format: zaudio.Format = .unknown;
    try decoder.getDataFormat(&format, &out_channels.*, &out_rate.*, null);
    try std.testing.expect(format == .float32);

    var samples: std.ArrayList(f32) = .empty;
    errdefer samples.deinit(allocator);

    var buf: [1024 * 2]f32 = undefined;
    const chunk_frames: u64 = buf.len / out_channels.*;
    while (true) {
        var n: u64 = 0;
        const res = ma_decoder_read_pcm_frames(decoder, &buf, chunk_frames, &n);
        // 0 = MA_SUCCESS, -17 = MA_AT_END (may still have returned frames)
        if (res != 0 and res != -17) return error.DecodeFailed;
        if (n == 0) break;
        try samples.appendSlice(allocator, buf[0 .. n * out_channels.*]);
    }
    return samples.toOwnedSlice(allocator);
}

fn rms(samples: []const f32) f64 {
    var acc: f64 = 0;
    for (samples) |s| acc += @as(f64, s) * s;
    return @sqrt(acc / @as(f64, @floatFromInt(@max(samples.len, 1))));
}

test "ogg vorbis decodes via zaudio" {
    const allocator = std.testing.allocator;
    zaudio.init(allocator);
    defer zaudio.deinit();

    var rate: u32 = 0;
    var channels: u32 = 0;
    const samples = try decodeAll(allocator, "assets/test/sine_440.ogg", &rate, &channels);
    defer allocator.free(samples);

    try std.testing.expectEqual(@as(u32, 48000), rate);
    try std.testing.expectEqual(@as(u32, 2), channels);

    const frames: f64 = @floatFromInt(samples.len / channels);
    try std.testing.expect(frames >= 48000.0 * 0.99 and frames <= 48000.0 * 1.01);
    try std.testing.expect(rms(samples) > 0.05);
}

test "wav still decodes via zaudio (regression guard)" {
    const allocator = std.testing.allocator;
    zaudio.init(allocator);
    defer zaudio.deinit();

    var rate: u32 = 0;
    var channels: u32 = 0;
    const samples = try decodeAll(allocator, "assets/test/sine_440.wav", &rate, &channels);
    defer allocator.free(samples);

    try std.testing.expectEqual(@as(u32, 48000), rate);
    try std.testing.expectEqual(@as(u32, 2), channels);
    try std.testing.expectEqual(@as(usize, 4800), samples.len / channels);
    try std.testing.expect(rms(samples) > 0.05);
}

// ---------------------------------------------------------------------------------------------
// Loop-seam / end-of-stream trimming tests.
//
// Fixture assets/test/loop_48017.ogg, encoded like the BGM pipeline:
//   ffmpeg -f lavfi -i "sine=f=330:r=48000,atrim=end_sample=48017" -ac 2 -c:a libvorbis -q:a 5 \
//          assets/test/loop_48017.ogg
// The Ogg final granule position (and ffprobe duration_ts) says 48017 frames. NOTE: the ffmpeg
// 4.4.2 used to generate it does NOT trim to that itself: `ffmpeg -i loop_48017.ogg -f null -`
// and `ffprobe -count_frames` both yield 48704 decoded frames (48 x ~1024 blocks, no end trim).
// So 48017 is the container-declared (correct) length, not what ffmpeg 4.4 outputs.
const loop_frames: u64 = 48017;
const loop_path: [:0]const u8 = "assets/test/loop_48017.ogg";

const DecodeResult = struct {
    first: []f32, // all samples from first pass
    first_frames: u64,
    after_seek: []f32,
    after_seek_frames: u64,
};

fn readAll(allocator: std.mem.Allocator, decoder: *zaudio.Decoder, channels: u32, out: *std.ArrayList(f32)) !u64 {
    var buf: [1000 * 2]f32 = undefined;
    const chunk_frames: u64 = buf.len / channels;
    var total: u64 = 0;
    while (true) {
        var n: u64 = 0;
        const res = ma_decoder_read_pcm_frames(decoder, &buf, chunk_frames, &n);
        if (res != 0 and res != -17) return error.DecodeFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0 .. n * channels]);
        total += n;
    }
    return total;
}

fn nativeConfig() zaudio.Decoder.Config {
    return zaudio.Decoder.Config.init(.float32, 0, 0);
}

test "ogg vorbis exact frame count, pull mode (createFromFile -> ma_stbvorbis_init_file)" {
    const allocator = std.testing.allocator;
    zaudio.init(allocator);
    defer zaudio.deinit();

    var rate: u32 = 0;
    var channels: u32 = 0;
    const samples = try decodeAll(allocator, loop_path, &rate, &channels);
    defer allocator.free(samples);
    const n: u64 = samples.len / channels;
    std.debug.print("\n[pull] frames={d} expected={d} delta={d}\n", .{ n, loop_frames, @as(i64, @intCast(n)) - @as(i64, @intCast(loop_frames)) });
    try std.testing.expectEqual(@as(u32, 2), channels);
    try std.testing.expectEqual(loop_frames, n);
}

// Push mode: createFromVfs with miniaudio's default VFS. ma_decoder_init_vfs() does not use the
// per-backend init_file hooks; it falls through to ma_decoder_init__internal() with
// ma_decoder__on_read_vfs/on_seek_vfs callbacks, which reaches ma_stbvorbis_init() (callback/push
// mode), exactly like the resource manager's data-stream path (ma_decoder_init_vfs at
// miniaudio.h ~73215). createFromFile() instead hits ma_stbvorbis_init_file() for ".ogg".
// seekToPCMFrames(0) on a stbvorbis backend re-initialises the decoder (as streamed looping does).
extern fn ma_default_vfs_init(vfs: *anyopaque, alloc_callbacks: ?*const anyopaque) i32;

test "ogg vorbis exact frame count, push mode via VFS callbacks, and after seek to 0" {
    const allocator = std.testing.allocator;
    zaudio.init(allocator);
    defer zaudio.deinit();

    var vfs_storage: [256]u8 align(16) = undefined;
    try std.testing.expectEqual(@as(i32, 0), ma_default_vfs_init(&vfs_storage, null));
    const vfs: *zaudio.Vfs = @ptrCast(&vfs_storage);

    const decoder = try zaudio.Decoder.createFromVfs(vfs, loop_path, nativeConfig());
    defer decoder.destroy();

    var channels: u32 = 0;
    try decoder.getDataFormat(null, &channels, null, null);
    try std.testing.expectEqual(@as(u32, 2), channels);

    var first: std.ArrayList(f32) = .empty;
    defer first.deinit(allocator);
    const n1 = try readAll(allocator, decoder, channels, &first);

    try decoder.seekToPCMFrames(0);

    var second: std.ArrayList(f32) = .empty;
    defer second.deinit(allocator);
    const n2 = try readAll(allocator, decoder, channels, &second);

    std.debug.print("\n[push] frames={d} after_seek={d} expected={d} delta={d}\n", .{ n1, n2, loop_frames, @as(i64, @intCast(n1)) - @as(i64, @intCast(loop_frames)) });

    // Seek-to-0 must reproduce the same stream.
    try std.testing.expectEqual(n1, n2);
    const check = @min(first.items.len, second.items.len, 64 * channels);
    for (first.items[0..check], second.items[0..check]) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-6);
    }

    // The real finding: stb_vorbis may ignore end-of-stream granule trimming.
    try std.testing.expectEqual(loop_frames, n1);
    try std.testing.expectEqual(loop_frames, n2);
}
