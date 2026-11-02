use serde::{Deserialize, Serialize};

/// A symbol the user puts on a connection, from a fixed set so each one
/// is stored as a name that keeps meaning whatever icon theme draws it.
/// The theme's icon for each is the app's to pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionIcon {
    Server,
    Computer,
    Disk,
    Folder,
    Home,
    Cloud,
    Web,
    Terminal,
    Package,
    Lab,
    Tools,
    Star,
    Warning,
    Shield,
    Lock,
}

impl ConnectionIcon {
    pub const ALL: [ConnectionIcon; 15] = [
        ConnectionIcon::Server,
        ConnectionIcon::Computer,
        ConnectionIcon::Disk,
        ConnectionIcon::Folder,
        ConnectionIcon::Home,
        ConnectionIcon::Cloud,
        ConnectionIcon::Web,
        ConnectionIcon::Terminal,
        ConnectionIcon::Package,
        ConnectionIcon::Lab,
        ConnectionIcon::Tools,
        ConnectionIcon::Star,
        ConnectionIcon::Warning,
        ConnectionIcon::Shield,
        ConnectionIcon::Lock,
    ];

    pub fn id(self) -> &'static str {
        match self {
            ConnectionIcon::Server => "server",
            ConnectionIcon::Computer => "computer",
            ConnectionIcon::Disk => "disk",
            ConnectionIcon::Folder => "folder",
            ConnectionIcon::Home => "home",
            ConnectionIcon::Cloud => "cloud",
            ConnectionIcon::Web => "web",
            ConnectionIcon::Terminal => "terminal",
            ConnectionIcon::Package => "package",
            ConnectionIcon::Lab => "lab",
            ConnectionIcon::Tools => "tools",
            ConnectionIcon::Star => "star",
            ConnectionIcon::Warning => "warning",
            ConnectionIcon::Shield => "shield",
            ConnectionIcon::Lock => "lock",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|icon| icon.id() == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_icon_is_stored_under_its_id() {
        for icon in ConnectionIcon::ALL {
            let json = serde_json::to_string(&icon).expect("serialize");

            assert_eq!(json, format!("\"{}\"", icon.id()));
            assert_eq!(
                serde_json::from_str::<ConnectionIcon>(&json).expect("deserialize"),
                icon
            );
            assert_eq!(ConnectionIcon::from_id(icon.id()), Some(icon));
        }
    }

    #[test]
    fn an_icon_from_a_newer_build_is_not_guessed_at() {
        assert_eq!(ConnectionIcon::from_id("rocket"), None);
        assert!(serde_json::from_str::<ConnectionIcon>("\"rocket\"").is_err());
    }
}
