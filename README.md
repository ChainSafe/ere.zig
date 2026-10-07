# ere.zig

[ere][]'s prebuilt EIP-8025 execution proof verifier,
`libere_verifier_c`, packaged for Zig. It downloads the archive that matches the build target from the
pinned ere release, translates `ere_verifier.h`, and exposes one module.

```zig
// build.zig.zon
.ere_zig = .{
    .url = "git+https://github.com/ChainSafe/ere.zig#<commit>",
    .hash = "...",
},
```

```zig
const ere = @import("ere_zig");

if (!ere.available) return error.VerifierUnavailable;
var handle: ?*ere.c.EreVerifier = null;
const status = ere.c.ere_verifier_new(zkvm_kind, vk.ptr, vk.len, &handle);
```

- `ere.c` is the translated header
- `ere.available` is false on targets without a published library (see [Targets](#targets)),
  and referencing `ere.c` there is a compile error, so gate use on `ere.available` first

## Targets

ere publishes `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu`.

- Linux links the archive statically with `-lunwind`. Zig's self-hosted x86_64 ELF linker cannot
  read the archive, so x86_64 Debug consumers must set `use_llvm` and `use_lld` on their compile
  step.
- macOS cannot link the archive statically with Zig's Mach-O linker. Native macOS builds strip the
  archive and turn it into a dylib with Apple's `ld`. Consumers install it beside their binary from
  the named lazy path `libere_verifier_c.dylib`; the module carries an `@loader_path` rpath for
  that. `-Ddylib=false` disables the dylib path, and cross builds for macOS report
  `available = false`.

## Testing

```bash
zig build download-fixtures   # ere's own per-zkVM fixtures into test/fixtures
zig build test
```

## Versions

| ere | SP1 | OpenVM | ZisK (proofman) |
| --- | --- | --- | --- |
| v0.19.1 | v6.6.0 | v2.1.0-preview | 1.3.1-alpha |

Proofs verify only with a library of the same SDK versions and a verifying key of the same guest
build ([ere-guests](https://github.com/eth-act/ere-guests) releases ship the `.vk` files).

[ere]: https://github.com/eth-act/ere
