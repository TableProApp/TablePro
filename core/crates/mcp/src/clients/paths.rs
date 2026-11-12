// `${VAR:-default}` and `${VAR}` take the variable when it is set and not
// empty, as a shell does; a leading `~` then becomes `home`.
pub fn expand_path(path: &str, home: &str, variable: impl Fn(&str) -> Option<String>) -> String {
    let mut out = String::with_capacity(path.len());
    let mut rest = path;
    while let Some(open) = rest.find("${") {
        out.push_str(&rest[..open]);
        let after = &rest[open + 2..];
        let Some(close) = after.find('}') else {
            out.push_str(&rest[open..]);
            rest = "";
            break;
        };
        let (name, default) = match after[..close].split_once(":-") {
            Some((name, default)) => (name, default),
            None => (&after[..close], ""),
        };
        match variable(name).filter(|value| !value.is_empty()) {
            Some(value) => out.push_str(&value),
            None => out.push_str(default),
        }
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    let home = home.trim_end_matches('/');
    if out == "~" {
        return if home.is_empty() {
            "/".to_owned()
        } else {
            home.to_owned()
        };
    }
    match out.strip_prefix("~/") {
        Some(below) => format!("{home}/{below}"),
        None => out,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn a_tilde_is_the_home_folder() {
        assert_eq!(
            expand_path("~/.cursor/mcp.json", "/home/ana", none),
            "/home/ana/.cursor/mcp.json"
        );
        assert_eq!(expand_path("~", "/home/ana/", none), "/home/ana");
        assert_eq!(expand_path("/etc/~x", "/home/ana", none), "/etc/~x");
    }

    #[test]
    fn a_variable_wins_over_its_default_unless_empty() {
        let set = |name: &str| (name == "XDG_CONFIG_HOME").then(|| "/cfg".to_owned());
        let empty = |_: &str| Some(String::new());

        assert_eq!(
            expand_path("${XDG_CONFIG_HOME:-~/.config}/zed/settings.json", "/home/ana", set),
            "/cfg/zed/settings.json"
        );
        assert_eq!(
            expand_path("${XDG_CONFIG_HOME:-~/.config}/zed/settings.json", "/home/ana", empty),
            "/home/ana/.config/zed/settings.json"
        );
        assert_eq!(
            expand_path("${CLAUDE_CONFIG_DIR:-~}/.claude.json", "/home/ana", none),
            "/home/ana/.claude.json"
        );
    }

    #[test]
    fn an_unclosed_variable_is_left_as_written() {
        assert_eq!(expand_path("/a/${B", "/home/ana", none), "/a/${B");
    }
}
