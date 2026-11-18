# ai slop warning
i didn't write any of the code, but the code is somewhat readable. the elisp code is not very readable, but it also has small scope that doesn't do that much.

# typst-inline-math

Inline Typst math previews for Emacs, backed by a persistent Rust SVG renderer.

It also includes an Org replacement for `org-latex-preview-mode`.  Org LaTeX
fragments are sent directly to this persistent JSONL renderer:

```text
typst-renderd --mitex-package
```

With `--mitex-package`, `typst-renderd` uses the standard Typst package
resolver to load MiTeX and renders the LaTeX directly to SVG.  It does not
invoke a LaTeX executable.

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

## Org LaTeX previews

Load `org-latex-typst-preview.el` and enable
`org-latex-typst-preview-mode` instead of `org-latex-preview-mode`:

```elisp
(load! "typst-inline-math/org-latex-typst-preview.el")
(add-hook 'org-mode-hook #'org-latex-typst-preview-mode)
```

The mode supports
`$...$`, `$$...$$`, `\\(...\\)`, `\\[...\\]`, and LaTeX environments that
Org recognizes as fragments.  Point inside a fragment reveals its source for
editing; leaving it restores the SVG preview.
