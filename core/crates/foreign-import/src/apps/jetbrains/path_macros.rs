use std::path::Path;

// The IDE writes `$USER_HOME$` into SSH key paths, certificate paths and recent projects.
pub(crate) fn expand(path: &str, home: &Path) -> String {
    path.replace("$USER_HOME$", &home.to_string_lossy())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_user_home_macro_becomes_the_home_folder_wherever_it_appears() {
        let home = Path::new("/home/me");
        assert_eq!(expand("$USER_HOME$/.ssh/id_ed25519", home), "/home/me/.ssh/id_ed25519");
        assert_eq!(expand("/keys/$USER_HOME$", home), "/keys//home/me");
        assert_eq!(expand("$APPLICATION_CONFIG_DIR$/x", home), "$APPLICATION_CONFIG_DIR$/x");
    }
}
