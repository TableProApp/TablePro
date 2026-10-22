use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Preferences {
    pub default_page_size: u64,
    pub confirm_destructive: bool,
    pub editor_font_size: u32,
    #[serde(default = "default_history_retention_days")]
    pub history_retention_days: u32,
    #[serde(default = "default_query_timeout_secs")]
    pub query_timeout_secs: u32,
    #[serde(default = "default_csv_include_header")]
    pub csv_include_header: bool,
    #[serde(default)]
    pub color_scheme: ColorSchemePref,
    #[serde(default)]
    pub theme: ThemePref,
    #[serde(default)]
    pub editor_font_family: String,
    #[serde(default)]
    pub editor_vim_mode: bool,
    #[serde(default)]
    pub null_display: NullDisplayPref,
    #[serde(default = "default_open_tables_in_preview_tab")]
    pub open_tables_in_preview_tab: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NullDisplayPref {
    #[default]
    Standard,
    Symbol,
    Parenthesized,
}

impl NullDisplayPref {
    pub const ALL: [Self; 3] = [Self::Standard, Self::Symbol, Self::Parenthesized];

    pub fn key(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Symbol => "symbol",
            Self::Parenthesized => "parenthesized",
        }
    }

    pub fn from_key(key: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|style| style.key() == key)
            .unwrap_or_default()
    }

    pub fn index(self) -> u32 {
        Self::ALL.iter().position(|style| *style == self).unwrap_or(0) as u32
    }

    pub fn from_index(index: u32) -> Self {
        Self::ALL.get(index as usize).copied().unwrap_or_default()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ColorSchemePref {
    #[default]
    System,
    Light,
    Dark,
}

impl ColorSchemePref {
    pub const ALL: [Self; 3] = [Self::System, Self::Light, Self::Dark];

    pub fn key(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub fn from_key(key: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|scheme| scheme.key() == key)
            .unwrap_or_default()
    }

    pub fn index(self) -> u32 {
        Self::ALL.iter().position(|scheme| *scheme == self).unwrap_or(0) as u32
    }

    pub fn from_index(index: u32) -> Self {
        Self::ALL.get(index as usize).copied().unwrap_or_default()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThemePref {
    #[default]
    Default,
    Ledger,
    Catppuccin,
    Tokyo,
    Gruvbox,
}

impl ThemePref {
    pub const ALL: [Self; 5] = [
        Self::Default,
        Self::Ledger,
        Self::Catppuccin,
        Self::Tokyo,
        Self::Gruvbox,
    ];

    pub fn key(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Ledger => "ledger",
            Self::Catppuccin => "catppuccin",
            Self::Tokyo => "tokyo",
            Self::Gruvbox => "gruvbox",
        }
    }

    pub fn from_key(key: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|theme| theme.key() == key)
            .unwrap_or_default()
    }

    pub fn index(self) -> u32 {
        Self::ALL.iter().position(|theme| *theme == self).unwrap_or(0) as u32
    }

    pub fn from_index(index: u32) -> Self {
        Self::ALL.get(index as usize).copied().unwrap_or_default()
    }
}

fn default_history_retention_days() -> u32 {
    30
}

fn default_query_timeout_secs() -> u32 {
    60
}

fn default_csv_include_header() -> bool {
    true
}

fn default_open_tables_in_preview_tab() -> bool {
    true
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            default_page_size: 1_000,
            confirm_destructive: true,
            editor_font_size: 12,
            history_retention_days: default_history_retention_days(),
            query_timeout_secs: default_query_timeout_secs(),
            csv_include_header: default_csv_include_header(),
            color_scheme: ColorSchemePref::default(),
            theme: ThemePref::default(),
            editor_font_family: String::new(),
            editor_vim_mode: false,
            null_display: NullDisplayPref::default(),
            open_tables_in_preview_tab: default_open_tables_in_preview_tab(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_preferences_file_from_before_the_setting_keeps_the_preview_tab_on() {
        let prefs: Preferences =
            serde_json::from_str(r#"{"default_page_size":1000,"confirm_destructive":true,"editor_font_size":12}"#)
                .unwrap();
        assert!(prefs.open_tables_in_preview_tab);
    }
    #[test]
    fn theme_rows_and_keys_agree_and_unknown_keys_fall_back() {
        for (position, theme) in ThemePref::ALL.into_iter().enumerate() {
            assert_eq!(ThemePref::from_index(position as u32), theme);
            assert_eq!(ThemePref::from_key(theme.key()), theme);
        }
        assert_eq!(ThemePref::from_key("neon"), ThemePref::Default);
        assert_eq!(ThemePref::from_index(99), ThemePref::Default);
        let old: Preferences =
            serde_json::from_str(r#"{"default_page_size":1000,"confirm_destructive":true,"editor_font_size":12}"#)
                .unwrap();
        assert_eq!(old.theme, ThemePref::Default);
    }

    #[test]
    fn null_display_rows_and_keys_agree_and_unknown_keys_fall_back() {
        for (position, style) in NullDisplayPref::ALL.into_iter().enumerate() {
            assert_eq!(style.index() as usize, position);
            assert_eq!(NullDisplayPref::from_index(position as u32), style);
            assert_eq!(NullDisplayPref::from_key(style.key()), style);
        }
        assert_eq!(NullDisplayPref::from_key("nonsense"), NullDisplayPref::Standard);
    }
    #[test]
    fn an_old_preferences_file_without_a_color_scheme_loads_with_the_system_default() {
        let parsed: Preferences =
            serde_json::from_str(r#"{"default_page_size":50,"confirm_destructive":true,"editor_font_size":12}"#)
                .unwrap();
        assert_eq!(parsed.color_scheme, ColorSchemePref::System);
    }
}
