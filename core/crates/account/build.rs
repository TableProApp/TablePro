use std::path::PathBuf;

use openapiv3::OpenAPI;

const SPEC: &str = "openapi/v2.openapi-3.0.json";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo::rerun-if-changed={SPEC}");
    let spec: OpenAPI = serde_json::from_slice(&std::fs::read(SPEC)?)?;
    let mut settings = progenitor::GenerationSettings::new();
    settings
        .with_inner_type("crate::cloud_api::Bearer".parse()?)
        .with_hooks(progenitor::HooksMode::Expected);
    let tokens = progenitor::Generator::new(&settings).generate_tokens(&spec)?;
    let out = PathBuf::from(std::env::var("OUT_DIR")?).join("v2.rs");
    std::fs::write(out, tokens.to_string())?;
    Ok(())
}
