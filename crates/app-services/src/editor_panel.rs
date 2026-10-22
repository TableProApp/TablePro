#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelMode {
    Hidden,
    Docked,
    Maximized,
}

#[derive(Clone, Copy, Debug)]
pub struct EditorPanel {
    mode: PanelMode,
    height: i32,
}

impl Default for EditorPanel {
    fn default() -> Self {
        Self {
            mode: PanelMode::Docked,
            height: 240,
        }
    }
}

impl EditorPanel {
    pub fn mode(&self) -> PanelMode {
        self.mode
    }

    pub fn show(&mut self, visible: bool) {
        self.mode = if visible { PanelMode::Docked } else { PanelMode::Hidden };
    }

    pub fn toggle(&mut self) {
        self.show(self.mode == PanelMode::Hidden);
    }

    pub fn toggle_maximized(&mut self) {
        self.mode = if self.mode == PanelMode::Maximized {
            PanelMode::Docked
        } else {
            PanelMode::Maximized
        };
    }

    pub fn resized(&mut self, height: i32) {
        if self.mode == PanelMode::Docked {
            self.height = height.clamp(120, 800);
        }
    }

    pub fn divider(&self, available: i32) -> i32 {
        let available = available.max(0);
        let editor_min = available.min(160);
        let panel_max = (available - editor_min).max(0);
        available - self.height.min(panel_max)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hiding_and_maximizing_keep_the_docked_size() {
        let mut panel = EditorPanel::default();
        panel.resized(320);
        assert_eq!(panel.divider(700), 380);
        panel.toggle_maximized();
        panel.resized(700);
        assert_eq!(panel.mode(), PanelMode::Maximized);
        panel.toggle_maximized();
        assert_eq!(panel.divider(700), 380);
        panel.toggle();
        panel.resized(0);
        assert_eq!(panel.mode(), PanelMode::Hidden);
        panel.toggle();
        assert_eq!(panel.mode(), PanelMode::Docked);
        assert_eq!(panel.divider(700), 380);
    }

    #[test]
    fn resizing_is_bounded_and_small_allocations_keep_editor_space() {
        let mut panel = EditorPanel::default();
        panel.resized(i32::MAX);
        assert_eq!(panel.divider(1200), 400);
        assert_eq!(panel.divider(300), 160);
        assert_eq!(panel.divider(-1), 0);
        panel.resized(i32::MIN);
        assert_eq!(panel.divider(700), 580);
    }

    #[test]
    fn hiding_a_maximized_panel_restores_the_editor_on_reopen() {
        let mut panel = EditorPanel::default();
        panel.toggle_maximized();
        panel.toggle();
        panel.toggle();
        assert_eq!(panel.mode(), PanelMode::Docked);
    }
}
