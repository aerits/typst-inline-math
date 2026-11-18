//! Shared JSONL protocol for the Typst preview renderer.

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct RenderRequest {
    pub id: u64,
    /// Native Typst math, used by typst-inline-math-mode.
    pub math: Option<String>,
    /// LaTeX math, rendered by MiTeX when --mitex-package is enabled.
    pub latex: Option<String>,
    #[serde(default = "default_size")]
    pub size: String,
    #[serde(default = "default_foreground")]
    pub foreground: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Response {
    pub id: u64,
    pub svg: Option<String>,
    pub error: Option<String>,
}

pub fn default_size() -> String { "1em".into() }
pub fn default_foreground() -> String { "#000000".into() }

