use sha2::{Digest, Sha256};

// One credential per data folder: a packaged and a development build each run a server, and a token one replaces
// must not stay valid on the other. The folder is named as Windows compares paths, in any case.
pub(crate) fn mcp_token_target(prefix: &str, data_folder: &str) -> String {
    let folder = data_folder.trim_end_matches(['\\', '/']).to_uppercase();
    let digest = Sha256::digest(folder.as_bytes());
    let scope: String = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect();
    format!("{prefix}/mcp-token/{scope}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_folder_names_one_token_whatever_its_case_or_last_separator() {
        let target = mcp_token_target("TablePro", r"C:\Users\Ada\AppData\Local\TablePro");

        assert!(target.starts_with("TablePro/mcp-token/"), "{target}");
        assert_eq!(target.len(), "TablePro/mcp-token/".len() + 32);
        assert_eq!(
            target,
            mcp_token_target("TablePro", r"c:\users\ada\appdata\local\tablepro\")
        );
        assert_ne!(
            target,
            mcp_token_target("TablePro", r"C:\Users\Ada\AppData\Local\TablePro-Dev")
        );
    }
}
