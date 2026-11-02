//! Writes the C# declarations of `src/window_abi.rs` to the file named by
//! the first argument. windows/AGENTS.md, Bindings, runs it.

use std::error::Error;

fn main() -> Result<(), Box<dyn Error>> {
    let output = std::env::args().nth(1).ok_or("usage: csbindgen <output .cs file>")?;
    csbindgen::Builder::default()
        .input_extern_file(concat!(env!("CARGO_MANIFEST_DIR"), "/src/window_abi.rs"))
        .csharp_dll_name("tablepro_ffi")
        .csharp_namespace("TablePro.Interop.Native")
        .csharp_class_name("WindowMethods")
        .csharp_class_accessibility("internal")
        .generate_csharp_file(output)?;
    Ok(())
}
