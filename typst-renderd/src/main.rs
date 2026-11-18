//! Persistent Typst-to-SVG renderer for editor integrations.
//!
//! The daemon uses JSON Lines over stdin/stdout.  Every request gets exactly
//! one response with the same `id`, so clients may safely pipeline requests.

use std::{io::{self, BufRead, Write}, sync::Arc};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use typst::{Library, LibraryExt, World, compile, diag::FileResult, foundations::{Bytes, Datetime, Duration}, syntax::{FileId, Source}, text::{Font, FontBook}};
use typst::utils::LazyHash;
use typst_kit::fonts::FontStore;
use typst_layout::PagedDocument;

#[derive(Debug, Deserialize)]
struct Request {
    id: u64,
    math: String,
    #[serde(default = "default_size")]
    size: String,
    #[serde(default = "default_foreground")]
    foreground: String,
}

#[derive(Debug, Serialize)]
struct Response {
    id: u64,
    svg: Option<String>,
    error: Option<String>,
}

fn default_size() -> String {
    "1em".into()
}

fn default_foreground() -> String {
    "#000000".into()
}

/// Build the self-contained document passed to Typst for one expression.
fn document(request: &Request) -> String {
    format!(
        "#set page(width: auto, height: auto, margin: (x: 0.12em, y: 0.42em), fill: none)\n\
         #set text(size: {size}, fill: rgb(\"{foreground}\"))\n\
         ${math}$\n",
        size = request.size,
        foreground = request.foreground,
        math = request.math,
    )
}

struct RenderWorld {
    library: LazyHash<Library>,
    fonts: Arc<FontStore>,
    source: Source,
}

impl World for RenderWorld {
    fn library(&self) -> &LazyHash<Library> { &self.library }
    fn book(&self) -> &LazyHash<FontBook> { self.fonts.book() }
    fn main(&self) -> FileId { self.source.id() }
    fn source(&self, id: FileId) -> FileResult<Source> { Ok((id == self.source.id()).then(|| self.source.clone()).unwrap()) }
    fn file(&self, _id: FileId) -> FileResult<Bytes> { Ok(Bytes::new(Vec::new())) }
    fn font(&self, index: usize) -> Option<Font> { self.fonts.font(index) }
    fn today(&self, _offset: Option<Duration>) -> Option<Datetime> { None }
}

fn render(fonts: Arc<FontStore>, request: &Request) -> Result<String> {
    let world = RenderWorld {
        library: LazyHash::new(Library::default()),
        fonts,
        source: Source::detached(document(request)),
    };
    let compiled = compile::<PagedDocument>(&world).output
        .map_err(|errors| anyhow::anyhow!(format!("{errors:?}")))?;
    let page = compiled.pages().first().ok_or_else(|| anyhow::anyhow!("Typst produced no page"))?;
    Ok(typst_svg::svg(page, &typst_svg::SvgOptions::default()))
}

fn main() -> Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut store = FontStore::new();
    // Typst's bundled New Computer Modern Math must come before arbitrary
    // system fonts; otherwise font fallback can select emoji glyphs for math.
    store.extend(typst_kit::fonts::embedded());
    store.extend(typst_kit::fonts::system());
    let fonts = Arc::new(store);

    for line in stdin.lock().lines() {
        let response = match line {
            Ok(line) => match serde_json::from_str::<Request>(&line) {
                Ok(request) => match render(fonts.clone(), &request) {
                    Ok(svg) => Response { id: request.id, svg: Some(svg), error: None },
                    Err(error) => Response { id: request.id, svg: None, error: Some(error.to_string()) },
                },
                Err(error) => Response { id: 0, svg: None, error: Some(format!("invalid request: {error}")) },
            },
            Err(error) => Response { id: 0, svg: None, error: Some(format!("stdin error: {error}")) },
        };
        serde_json::to_writer(&mut stdout, &response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }
    Ok(())
}
