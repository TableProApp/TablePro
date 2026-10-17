use serde::{Deserialize, Serialize};
use uuid::Uuid;

const MIN_WINDOW_WIDTH: i32 = 480;
const MIN_WINDOW_HEIGHT: i32 = 320;
const MAX_WINDOW_SIDE: i32 = 16384;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct WindowState {
    pub width: i32,
    pub height: i32,
    pub maximized: bool,
    #[serde(default)]
    pub last_connection_id: Option<Uuid>,
}

impl Default for WindowState {
    fn default() -> Self {
        Self {
            width: 1200,
            height: 760,
            maximized: false,
            last_connection_id: None,
        }
    }
}

pub fn sane(mut state: WindowState) -> WindowState {
    state.width = state.width.clamp(MIN_WINDOW_WIDTH, MAX_WINDOW_SIDE);
    state.height = state.height.clamp(MIN_WINDOW_HEIGHT, MAX_WINDOW_SIDE);
    state
}

pub fn connection_id_to_restore(last_connection_id: Option<Uuid>, available: &[Uuid]) -> Option<Uuid> {
    let id = last_connection_id?;
    available.contains(&id).then_some(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_last_connection_id_deserializes_as_none() {
        let parsed: WindowState =
            serde_json::from_str(r#"{"width":800,"height":600,"maximized":false}"#).expect("legacy state");
        assert_eq!(parsed.last_connection_id, None);
        assert_eq!(parsed.width, 800);
    }

    #[test]
    fn restore_skips_an_unknown_or_absent_connection() {
        let id = Uuid::new_v4();
        assert_eq!(connection_id_to_restore(None, &[id]), None);
        assert_eq!(connection_id_to_restore(Some(id), &[]), None);
        assert_eq!(connection_id_to_restore(Some(Uuid::new_v4()), &[id]), None);
        assert_eq!(connection_id_to_restore(Some(id), &[id]), Some(id));
    }

    #[test]
    fn window_geometry_is_clamped_before_reaching_the_toolkit() {
        let state = WindowState {
            width: i32::MIN,
            height: i32::MAX,
            ..WindowState::default()
        };
        let state = sane(state);
        assert_eq!((state.width, state.height), (MIN_WINDOW_WIDTH, MAX_WINDOW_SIDE));
    }
}
