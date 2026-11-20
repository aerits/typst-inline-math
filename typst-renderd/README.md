# typst-renderd

Persistent Rust renderer for Typst math previews. It communicates over stdin
and stdout using one JSON object per line:

```json
{"id":1,"math":"x^2 + y","size":"1em","foreground":"#d0d0d0"}
```

The matching response contains `id`, `svg`, and `error`. SVG is intended to be
written by the Emacs client to a temporary file and displayed with Emacs' SVG
image support.

## Nix

Build the renderer with `nix build`, then run `./result/bin/typst-renderd`, or
use `nix run` to build and run it directly. For example:

```sh
echo '{"id":1,"math":"x^2 + y"}' | nix run
```

Enter the development shell with `nix develop` to get Rust, Cargo, rustfmt,
Clippy, rust-analyzer, and the native build dependencies. Run `cargo build`
or `cargo test` inside the shell.

The flake supports x86_64 and aarch64 Linux, plus Apple Silicon macOS. `flake.lock` pins
Nixpkgs, while `Cargo.lock` pins Rust dependencies. Update Nixpkgs with
`nix flake update`.

When using a Git checkout, add `flake.nix` and `flake.lock` to Git so Nix
includes them in the flake source.
