const std = @import("std");
const testing = std.testing;
const ere = @import("ere_zig");

/// Populated by `zig build download-fixtures`: ere's own fixtures for each
/// zkVM. Tests that need them skip when the files are absent.
const fixture_dir = "test/fixtures";
const max_fixture_bytes: std.Io.Limit = .limited(16 << 20);

const zkvm_openvm: u32 = 0;
const zkvm_sp1: u32 = 1;
const zkvm_zisk: u32 = 2;

/// Eight zero KoalaBear words pack to a canonical SP1 verifying key.
const sp1_zero_vk = [_]u8{0} ** 32;

const Fixture = struct { kind: u32, name: []const u8 };
const fixtures = [_]Fixture{
    .{ .kind = zkvm_openvm, .name = "openvm" },
    .{ .kind = zkvm_sp1, .name = "sp1" },
    .{ .kind = zkvm_zisk, .name = "zisk" },
};

const Verifier = struct {
    const c = ere.c;

    handle: *c.EreVerifier,

    fn init(kind: u32, program_vk: []const u8) !Verifier {
        var handle: ?*c.EreVerifier = null;
        const status = c.ere_verifier_new(kind, program_vk.ptr, program_vk.len, &handle);
        if (status != c.ERE_OK) return statusError(status);
        return .{ .handle = handle orelse return error.NullHandle };
    }

    fn deinit(self: *Verifier) void {
        c.ere_verifier_free(self.handle);
    }

    fn verify(self: Verifier, allocator: std.mem.Allocator, proof: []const u8) ![]u8 {
        var ptr: [*c]u8 = null;
        var len: usize = 0;
        const status = c.ere_verifier_verify(self.handle, proof.ptr, proof.len, &ptr, &len);
        defer c.ere_bytes_free(ptr, len);
        if (status != c.ERE_OK) return statusError(status);
        const public_values: []const u8 = if (ptr != null) ptr[0..len] else &.{};
        return allocator.dupe(u8, public_values);
    }
};

fn statusError(status: i32) anyerror {
    return switch (status) {
        ere.c.ERE_ERR_NULL_PTR => error.NullPointer,
        ere.c.ERE_ERR_BAD_KIND => error.BadKind,
        ere.c.ERE_ERR_DECODE_PROGRAM_VK => error.DecodeProgramVk,
        ere.c.ERE_ERR_DECODE_PROOF => error.DecodeProof,
        ere.c.ERE_ERR_VERIFY => error.Verify,
        ere.c.ERE_ERR_INTERNAL => error.Internal,
        else => error.UnknownStatus,
    };
}

fn readFixture(allocator: std.mem.Allocator, fixture: Fixture, file: []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ fixture_dir, fixture.name, file });
    defer allocator.free(path);

    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, max_fixture_bytes) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

test "targets without the library report available = false" {
    if (ere.available) return error.SkipZigTest;
    try testing.expect(!ere.available);
}

test "rejects an unknown zkvm kind" {
    if (!ere.available) return error.SkipZigTest;
    try testing.expectError(error.BadKind, Verifier.init(7, &sp1_zero_vk));
}

test "rejects a malformed program verifying key" {
    if (!ere.available) return error.SkipZigTest;
    try testing.expectError(error.DecodeProgramVk, Verifier.init(zkvm_sp1, sp1_zero_vk[0..31]));
}

test "reports the zkvm kind of a verifier" {
    if (!ere.available) return error.SkipZigTest;

    var verifier = try Verifier.init(zkvm_sp1, &sp1_zero_vk);
    defer verifier.deinit();

    var kind: u32 = 99;
    try testing.expectEqual(ere.c.ERE_OK, ere.c.ere_verifier_zkvm_kind(verifier.handle, &kind));
    try testing.expectEqual(zkvm_sp1, kind);
}

test "rejects a malformed proof" {
    if (!ere.available) return error.SkipZigTest;

    var verifier = try Verifier.init(zkvm_sp1, &sp1_zero_vk);
    defer verifier.deinit();

    try testing.expectError(error.DecodeProof, verifier.verify(testing.allocator, "not a proof"));
}

test "returns the public values of ere's fixture proofs" {
    if (!ere.available) return error.SkipZigTest;

    for (fixtures) |fixture| {
        const program_vk = try readFixture(testing.allocator, fixture, "program_vk.bin") orelse return error.SkipZigTest;
        defer testing.allocator.free(program_vk);
        const proof = try readFixture(testing.allocator, fixture, "proof.bin") orelse return error.SkipZigTest;
        defer testing.allocator.free(proof);
        const expected = try readFixture(testing.allocator, fixture, "public_values.bin") orelse return error.SkipZigTest;
        defer testing.allocator.free(expected);

        var verifier = try Verifier.init(fixture.kind, program_vk);
        defer verifier.deinit();

        const public_values = try verifier.verify(testing.allocator, proof);
        defer testing.allocator.free(public_values);

        try testing.expectEqualSlices(u8, expected, public_values);
    }
}

test "rejects a fixture proof with one flipped byte" {
    if (!ere.available) return error.SkipZigTest;

    for (fixtures) |fixture| {
        const program_vk = try readFixture(testing.allocator, fixture, "program_vk.bin") orelse return error.SkipZigTest;
        defer testing.allocator.free(program_vk);
        const proof = try readFixture(testing.allocator, fixture, "proof.bin") orelse return error.SkipZigTest;
        defer testing.allocator.free(proof);

        var verifier = try Verifier.init(fixture.kind, program_vk);
        defer verifier.deinit();

        proof[proof.len / 2] ^= 0x01;
        const result = verifier.verify(testing.allocator, proof);
        if (result) |public_values| {
            testing.allocator.free(public_values);
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.DecodeProof, error.Verify => {},
            else => return err,
        }
    }
}
