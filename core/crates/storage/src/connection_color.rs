use serde::{Deserialize, Serialize};

/// A colour the user puts on a connection to tell it apart at a glance.
///
/// The set is libadwaita's accent palette rather than a free colour
/// picker: the names are what GNOME already calls these colours in
/// Settings, they read on both light and dark, and a fixed set
/// serializes as a name that keeps meaning when the palette shifts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionColor {
    Blue,
    Teal,
    Green,
    Yellow,
    Orange,
    Red,
    Pink,
    Purple,
    Slate,
}

impl ConnectionColor {
    pub const ALL: [ConnectionColor; 9] = [
        ConnectionColor::Blue,
        ConnectionColor::Teal,
        ConnectionColor::Green,
        ConnectionColor::Yellow,
        ConnectionColor::Orange,
        ConnectionColor::Red,
        ConnectionColor::Pink,
        ConnectionColor::Purple,
        ConnectionColor::Slate,
    ];

    /// The name as it is stored and as a UI action addresses it. The
    /// user-facing label is translated where it is shown, not here.
    pub fn id(self) -> &'static str {
        match self {
            ConnectionColor::Blue => "blue",
            ConnectionColor::Teal => "teal",
            ConnectionColor::Green => "green",
            ConnectionColor::Yellow => "yellow",
            ConnectionColor::Orange => "orange",
            ConnectionColor::Red => "red",
            ConnectionColor::Pink => "pink",
            ConnectionColor::Purple => "purple",
            ConnectionColor::Slate => "slate",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|colour| colour.id() == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_colour_round_trips_through_its_id() {
        for colour in ConnectionColor::ALL {
            assert_eq!(ConnectionColor::from_id(colour.id()), Some(colour));
        }
    }

    #[test]
    fn an_id_from_a_newer_build_is_not_guessed_at() {
        assert_eq!(ConnectionColor::from_id("chartreuse"), None);
    }

    #[test]
    fn a_colour_is_stored_under_its_id() {
        let json = serde_json::to_string(&ConnectionColor::Slate).expect("serialize");

        assert_eq!(json, "\"slate\"");
        assert_eq!(
            serde_json::from_str::<ConnectionColor>(&json).expect("deserialize"),
            ConnectionColor::Slate
        );
    }
}
