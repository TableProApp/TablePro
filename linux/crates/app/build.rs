use std::path::PathBuf;

fn main() {
    let resources_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources");
    glib_build_tools::compile_resources(
        &[&resources_dir],
        resources_dir.join("app.gresource.xml").to_str().expect("utf8 path"),
        "app.gresource",
    );
}
