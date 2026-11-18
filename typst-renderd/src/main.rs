//! Persistent Typst-to-SVG renderer for editor integrations.
//!
//! The daemon uses JSON Lines over stdin/stdout.  Every request gets exactly
//! one response with the same `id`, so clients may safely pipeline requests.

use std::{io::{self, BufRead, Write}, sync::Arc};

use anyhow::Result;
use typst::{Library, LibraryExt, World, compile, diag::FileResult, foundations::{Bytes, Datetime, Duration}, syntax::{FileId, Source}, text::{Font, FontBook}};
use typst::utils::LazyHash;
use typst_kit::{fonts::FontStore, downloader::SystemDownloader, files::{FileLoader, FsRoot, SystemFiles}, packages::SystemPackages};
use typst_layout::PagedDocument;
use typst_renderd::{RenderRequest as Request, Response};

/// Build the self-contained document passed to Typst for one expression.
fn document(request: &Request, mitex_package: bool) -> String {
    let body = if mitex_package {
        let latex = request.latex.as_deref().unwrap_or_default();
        // MiTeX owns the conversion and evaluation.  This avoids coupling a
        // Rust converter version to the Typst package's internal helpers.
        format!(
            "#import \"@preview/mitex:0.2.7\": *\n#mi({})\n",
            serde_json::to_string(latex)
                .expect("serializing a Rust string cannot fail")
        )
    } else {
        format!("${}$\n", request.math.as_deref().unwrap_or_default())
    };
    format!(
        "#set page(width: auto, height: auto, margin: (x: 0.12em, y: 0.42em), fill: none)\n\
         #set text(size: {size}, fill: rgb(\"{foreground}\"))\n\
         {body}",
        size = request.size,
        foreground = request.foreground,
        body = body,
    )
}

struct RenderWorld {
    library: LazyHash<Library>,
    fonts: Arc<FontStore>,
    files: Arc<SystemFiles>,
    source: Source,
}

impl World for RenderWorld {
    fn library(&self) -> &LazyHash<Library> { &self.library }
    fn book(&self) -> &LazyHash<FontBook> { self.fonts.book() }
    fn main(&self) -> FileId { self.source.id() }
    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.source.id() { return Ok(self.source.clone()); }
        let bytes = self.files.load(id)?;
        Ok(Source::new(id, String::from_utf8_lossy(&bytes).into_owned()))
    }
    fn file(&self, id: FileId) -> FileResult<Bytes> { self.files.load(id) }
    fn font(&self, index: usize) -> Option<Font> { self.fonts.font(index) }
    fn today(&self, _offset: Option<Duration>) -> Option<Datetime> { None }
}

fn render(fonts: Arc<FontStore>, files: Arc<SystemFiles>, request: &Request, mitex_package: bool) -> Result<String> {
    let world = RenderWorld {
        library: LazyHash::new(Library::default()),
        fonts,
        files,
        source: Source::detached(document(request, mitex_package)),
    };
    let compiled = compile::<PagedDocument>(&world).output
        .map_err(|errors| anyhow::anyhow!(format!("{errors:?}")))?;
    let page = compiled.pages().first().ok_or_else(|| anyhow::anyhow!("Typst produced no page"))?;
    Ok(typst_svg::svg(page, &typst_svg::SvgOptions::default()))
}

fn main() -> Result<()> {
    let mitex_package = std::env::args().any(|argument| argument == "--mitex-package");
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut store = FontStore::new();
    // Typst's bundled New Computer Modern Math must come before arbitrary
    // system fonts; otherwise font fallback can select emoji glyphs for math.
    store.extend(typst_kit::fonts::embedded());
    store.extend(typst_kit::fonts::system());
    let fonts = Arc::new(store);
    let files = Arc::new(SystemFiles::new(
        FsRoot::new(std::env::current_dir()?),
        SystemPackages::new(SystemDownloader::new("typst-renderd")),
    ));

    for line in stdin.lock().lines() {
        let response = match line {
            Ok(line) => match serde_json::from_str::<serde_json::Value>(&line) {
                // A prior pipeline stage may send a protocol error response.
                // Preserve it instead of attempting to render it.
                Ok(value) if value.get("error").is_some() => {
                    serde_json::from_value::<Response>(value)
                        .unwrap_or(Response { id: 0, svg: None, error: Some("invalid pipeline response".into()) })
                }
                Ok(value) => match serde_json::from_value::<Request>(value) {
                Ok(request) => match render(fonts.clone(), files.clone(), &request, mitex_package) {
                    Ok(svg) => Response { id: request.id, svg: Some(svg), error: None },
                    Err(error) => Response { id: request.id, svg: None, error: Some(error.to_string()) },
                },
                Err(error) => Response { id: 0, svg: None, error: Some(format!("invalid request: {error}")) },
            },
                Err(error) => Response { id: 0, svg: None, error: Some(format!("invalid JSON: {error}")) },
            },
            Err(error) => Response { id: 0, svg: None, error: Some(format!("stdin error: {error}")) },
        };
        serde_json::to_writer(&mut stdout, &response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }
    Ok(())
}
