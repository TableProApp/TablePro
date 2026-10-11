fn main() -> Result<(), Box<dyn std::error::Error>> {
    let schema_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../data");
    println!(
        "cargo:rerun-if-changed={}",
        schema_dir.join("com.tablepro.linux.gschema.xml").display()
    );
    let out_dir = std::path::PathBuf::from(std::env::var_os("OUT_DIR").ok_or("OUT_DIR is set")?);
    let status = std::process::Command::new("glib-compile-schemas")
        .arg("--strict")
        .arg("--targetdir")
        .arg(&out_dir)
        .arg(&schema_dir)
        .status()?;
    if !status.success() {
        return Err("GSettings schema compilation failed".into());
    }
    println!("cargo:rustc-env=TABLEPRO_GSETTINGS_SCHEMA_DIR={}", out_dir.display());

    glib_build_tools::compile_resources(
        &["../../data/resources"],
        "../../data/resources/resources.gresource.xml",
        "tablepro.gresource",
    );
    Ok(())
}
