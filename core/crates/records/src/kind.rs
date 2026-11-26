use std::fmt;

// 0051, Scopes and records.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Scope {
    Personal,
    History,
    Team,
}

impl Scope {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Personal => "personal",
            Self::History => "history",
            Self::Team => "team",
        }
    }
}

const PERSONAL: &[Scope] = &[Scope::Personal];
const TEAM: &[Scope] = &[Scope::Team];
const HISTORY: &[Scope] = &[Scope::History];
const PERSONAL_AND_TEAM: &[Scope] = &[Scope::Personal, Scope::Team];

// Every kind 0051's kind table names. Any other well-formed kind is an ordinary one this build does not know.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    Connection,
    Group,
    Tag,
    SshProfile,
    CredentialProfile,
    SavedQuery,
    SavedQueryFolder,
    FavouriteTable,
    FavouriteDatabase,
    TableFolder,
    TableFolderItem,
    MacosSettings,
    IosSettings,
    LinuxSettings,
    WindowsSettings,
    ConnectionProject,
    LibraryConnection,
    LibraryFolder,
    LibraryQuery,
    SecretEnvelope,
    HistoryEntry,
    KeyAccount,
    KeyDevice,
    KeyRecovery,
    KeyReset,
    KeyCancel,
    KeyRequest,
    KeySas,
    KeyVersion,
    KeyWrap,
    KeyRing,
    KeyMember,
}

impl Kind {
    pub const ALL: [Kind; 32] = [
        Self::Connection,
        Self::Group,
        Self::Tag,
        Self::SshProfile,
        Self::CredentialProfile,
        Self::SavedQuery,
        Self::SavedQueryFolder,
        Self::FavouriteTable,
        Self::FavouriteDatabase,
        Self::TableFolder,
        Self::TableFolderItem,
        Self::MacosSettings,
        Self::IosSettings,
        Self::LinuxSettings,
        Self::WindowsSettings,
        Self::ConnectionProject,
        Self::LibraryConnection,
        Self::LibraryFolder,
        Self::LibraryQuery,
        Self::SecretEnvelope,
        Self::HistoryEntry,
        Self::KeyAccount,
        Self::KeyDevice,
        Self::KeyRecovery,
        Self::KeyReset,
        Self::KeyCancel,
        Self::KeyRequest,
        Self::KeySas,
        Self::KeyVersion,
        Self::KeyWrap,
        Self::KeyRing,
        Self::KeyMember,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Connection => "connection",
            Self::Group => "group",
            Self::Tag => "tag",
            Self::SshProfile => "ssh_profile",
            Self::CredentialProfile => "credential_profile",
            Self::SavedQuery => "saved_query",
            Self::SavedQueryFolder => "saved_query_folder",
            Self::FavouriteTable => "favourite_table",
            Self::FavouriteDatabase => "favourite_database",
            Self::TableFolder => "table_folder",
            Self::TableFolderItem => "table_folder_item",
            Self::MacosSettings => "macos_settings",
            Self::IosSettings => "ios_settings",
            Self::LinuxSettings => "linux_settings",
            Self::WindowsSettings => "windows_settings",
            Self::ConnectionProject => "connection_project",
            Self::LibraryConnection => "library_connection",
            Self::LibraryFolder => "library_folder",
            Self::LibraryQuery => "library_query",
            Self::SecretEnvelope => "secret_envelope",
            Self::HistoryEntry => "history_entry",
            Self::KeyAccount => "key.account",
            Self::KeyDevice => "key.device",
            Self::KeyRecovery => "key.recovery",
            Self::KeyReset => "key.reset",
            Self::KeyCancel => "key.cancel",
            Self::KeyRequest => "key.request",
            Self::KeySas => "key.sas",
            Self::KeyVersion => "key.version",
            Self::KeyWrap => "key.wrap",
            Self::KeyRing => "key.ring",
            Self::KeyMember => "key.member",
        }
    }

    // `Ok(None)` is a well-formed kind this build does not know, which the engine keeps and sends back unchanged.
    pub fn parse(name: &str) -> Result<Option<Kind>, KindError> {
        if !well_formed(name) {
            return Err(KindError::Syntax);
        }
        Ok(Self::ALL.into_iter().find(|kind| kind.as_str() == name))
    }

    // The scopes the kind table gives the kind; an app writes it nowhere else.
    pub const fn scopes(self) -> &'static [Scope] {
        match self {
            Self::LibraryConnection | Self::LibraryFolder | Self::LibraryQuery | Self::KeyMember => TEAM,
            Self::HistoryEntry => HISTORY,
            Self::SecretEnvelope | Self::KeyVersion | Self::KeyWrap | Self::KeyRing => PERSONAL_AND_TEAM,
            _ => PERSONAL,
        }
    }

    pub const fn is_key(self) -> bool {
        matches!(
            self,
            Self::KeyAccount
                | Self::KeyDevice
                | Self::KeyRecovery
                | Self::KeyReset
                | Self::KeyCancel
                | Self::KeyRequest
                | Self::KeySas
                | Self::KeyVersion
                | Self::KeyWrap
                | Self::KeyRing
                | Self::KeyMember
        )
    }

    // History entries and key objects are created once (0051, Conflict rules).
    pub const fn is_create_once(self) -> bool {
        self.is_key() || matches!(self, Self::HistoryEntry)
    }

    pub const fn is_settings(self) -> bool {
        matches!(
            self,
            Self::MacosSettings | Self::IosSettings | Self::LinuxSettings | Self::WindowsSettings
        )
    }

    pub const fn is_team_library(self) -> bool {
        matches!(self, Self::LibraryConnection | Self::LibraryFolder | Self::LibraryQuery)
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum KindError {
    #[error("the kind is not lowercase letters, digits and `_` in at most two parts of 1 to 64 bytes")]
    Syntax,
}

impl KindError {
    pub const fn code(&self) -> &'static str {
        "records.bad_kind"
    }
}

// Every `key.*` kind is reserved, whether or not this build knows it, and so are the envelope, the history entry and
// the team library's kinds (0051, Kinds).
pub fn is_reserved(name: &str) -> bool {
    name.starts_with("key.")
        || Kind::ALL.into_iter().any(|kind| {
            kind.as_str() == name && (kind.is_create_once() || kind.is_team_library() || kind == Kind::SecretEnvelope)
        })
}

// Mirrors the server's `kind_not_in_scope`: a reserved kind only where the table gives it, the history scope only
// `history_entry`, and any other well-formed kind in the personal and team scopes.
pub fn admits(scope: Scope, name: &str) -> bool {
    if !well_formed(name) {
        return false;
    }
    match Kind::ALL.into_iter().find(|kind| kind.as_str() == name) {
        Some(kind) if is_reserved(name) => kind.scopes().contains(&scope),
        Some(_) => scope != Scope::History,
        None if name.starts_with("key.") => false,
        None => scope != Scope::History,
    }
}

// 0051, Kinds: lowercase ASCII letters, digits and `_`, starting with a letter, with at most one `.` between two such
// parts, 1 to 64 bytes.
pub fn well_formed(name: &str) -> bool {
    if name.is_empty() || name.len() > 64 {
        return false;
    }
    let mut parts = name.split('.');
    let first = parts.next().is_some_and(part);
    let second = parts.next().is_none_or(part);
    first && second && parts.next().is_none()
}

fn part(text: &str) -> bool {
    let mut bytes = text.bytes();
    bytes.next().is_some_and(|first| first.is_ascii_lowercase())
        && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_reads_back_by_its_name() {
        for kind in Kind::ALL {
            assert_eq!(Kind::parse(kind.as_str()), Ok(Some(kind)), "{kind}");
        }
    }

    #[test]
    fn a_well_formed_kind_no_one_knows_is_kept_and_a_malformed_one_is_refused() {
        assert_eq!(Kind::parse("query_snippet"), Ok(None));
        assert_eq!(Kind::parse("key.future"), Ok(None));
        for bad in [
            "",
            "Connection",
            "_tag",
            "a..b",
            "a.b.c",
            "key.",
            ".key",
            "a-b",
            "9lives",
            &"a".repeat(65),
        ] {
            assert_eq!(Kind::parse(bad), Err(KindError::Syntax), "{bad}");
        }
        assert_eq!(Kind::parse(&"a".repeat(64)), Ok(None));
    }

    #[test]
    fn reserved_kinds_go_only_where_the_kind_table_puts_them() {
        assert!(admits(Scope::Personal, "connection"));
        assert!(admits(Scope::Team, "connection"));
        assert!(!admits(Scope::History, "connection"));
        assert!(admits(Scope::History, "history_entry"));
        assert!(!admits(Scope::Personal, "history_entry"));
        assert!(!admits(Scope::Team, "history_entry"));
        assert!(admits(Scope::Team, "library_folder"));
        assert!(!admits(Scope::Personal, "library_folder"));
        assert!(admits(Scope::Personal, "secret_envelope"));
        assert!(admits(Scope::Team, "secret_envelope"));
        assert!(!admits(Scope::History, "secret_envelope"));
        assert!(admits(Scope::Personal, "key.account"));
        assert!(!admits(Scope::Team, "key.account"));
        assert!(admits(Scope::Team, "key.member"));
        assert!(!admits(Scope::Personal, "key.member"));
        assert!(admits(Scope::Team, "key.wrap"));
        assert!(!admits(Scope::Personal, "key.future"));
        assert!(admits(Scope::Team, "query_snippet"));
        assert!(!admits(Scope::History, "query_snippet"));
    }

    #[test]
    fn the_reserved_set_is_the_key_kinds_the_envelope_history_and_the_team_library() {
        let reserved: Vec<&str> = Kind::ALL
            .into_iter()
            .map(Kind::as_str)
            .filter(|name| is_reserved(name))
            .collect();

        assert_eq!(
            reserved,
            [
                "library_connection",
                "library_folder",
                "library_query",
                "secret_envelope",
                "history_entry",
                "key.account",
                "key.device",
                "key.recovery",
                "key.reset",
                "key.cancel",
                "key.request",
                "key.sas",
                "key.version",
                "key.wrap",
                "key.ring",
                "key.member",
            ]
        );
    }
}
