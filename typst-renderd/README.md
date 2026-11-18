# typst-renderd

Persistent Rust renderer for Typst math previews. It communicates over stdin
and stdout using one JSON object per line:

```json
{"id":1,"math":"x^2 + y","size":"1em","foreground":"#d0d0d0"}
```

The matching response contains `id`, `svg`, and `error`. SVG is intended to be
written by the Emacs client to a temporary file and displayed with Emacs' SVG
image support.
