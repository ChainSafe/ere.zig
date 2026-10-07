//! ere's prebuilt EIP-8025 execution proof verifier for Zig consumers.
//!
//! `c` is the translated `ere_verifier.h` of the fetched archive:
//! `ere_verifier_new` binds a verifier to a program verifying key,
//! `ere_verifier_verify` returns the public values a proof commits to, and
//! `ere_bytes_free` releases them. On targets without a published library
//! `available` is false and referencing `c` is a compile error, so gate every
//! use on `available` first.
//!
//! A verifier handle may be shared across threads for concurrent verify calls.
//! `ere_verifier_free` must not overlap with them.

const build_options = @import("build_options");

/// ere release the archives come from.
pub const ere_version = "v0.19.1";

pub const available: bool = build_options.available;

pub const c = if (available)
    @import("c")
else
    @compileError("ere's verifier has no build for this target; check `available` first");
