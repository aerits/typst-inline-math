# ai slop warning
i didn't write any of the code, but the code is somewhat readable. the elisp code is not very readable, but it also has small scope that doesn't do that much.

# typst-inline-math

Inline Typst math previews for Emacs, backed by a persistent Rust SVG renderer.

## Build the renderer

```sh
cd typst-renderd
cargo build --release
```

The compiled binary is intentionally excluded from version control.  The Emacs
client looks for it at `typst-renderd/target/release/typst-renderd`, relative to
`typst-inline-math.el`.

## Doom Emacs setup

Place this directory in your Doom configuration and add the following to
`config.el`:

```elisp
(load! "typst-inline-math/typst-inline-math.el")
```

Enable `typst-inline-math-mode` in buffers where inline `$...$` math should be
rendered.  Multiline `$...$` math blocks are previewed one nonblank line at a
time, preserving the block's line-by-line layout.
