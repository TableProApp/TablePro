/// The levels Zoom In and Zoom Out step through.
pub(crate) const LEVELS: [f64; 15] = [
    0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
];
/// Best Fit, a pinch and Ctrl+scroll reach below the first level, so a
/// schema of hundreds of tables fits on screen.
pub(crate) const MIN: f64 = 0.02;
pub(crate) const MAX: f64 = 3.0;

pub(crate) fn clamp(zoom: f64) -> f64 {
    if zoom.is_finite() { zoom.clamp(MIN, MAX) } else { 1.0 }
}

/// The next level up from `zoom`.
pub(crate) fn step_in(zoom: f64) -> f64 {
    LEVELS.iter().copied().find(|level| *level > zoom + 1e-6).unwrap_or(MAX)
}

/// The next level down from `zoom`, or the lowest one.
pub(crate) fn step_out(zoom: f64) -> f64 {
    LEVELS
        .iter()
        .rev()
        .copied()
        .find(|level| *level < zoom - 1e-6)
        .unwrap_or(LEVELS[0])
}

/// The zoom that shows `content` whole in `viewport`, never past 100%.
pub(crate) fn fit(content: (f64, f64), viewport: (f64, f64)) -> f64 {
    let (content_width, content_height) = content;
    let (width, height) = viewport;
    if content_width <= 0.0 || content_height <= 0.0 || width <= 0.0 || height <= 0.0 {
        return 1.0;
    }
    clamp((width / content_width).min(height / content_height).min(1.0))
}

/// The zoom as the label shows it, rounded to a whole percent.
pub(crate) fn percent(zoom: f64) -> u32 {
    let rounded = (zoom * 100.0).round();
    if rounded.is_finite() && rounded >= 0.0 && rounded <= f64::from(u32::MAX) {
        rounded as u32
    } else {
        100
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zoom_steps_through_the_levels_and_stops_at_the_ends() {
        assert_eq!(step_in(1.0), 1.1);
        assert_eq!(step_out(1.0), 0.9);
        assert_eq!(step_in(1.05), 1.1, "between levels goes to the next one up");
        assert_eq!(step_out(1.05), 1.0);
        assert_eq!(step_in(MAX), MAX);
        assert_eq!(step_out(0.1), 0.1);
        assert_eq!(step_in(0.03), 0.1, "from below the levels, a fit's zoom");
    }

    #[test]
    fn fit_shows_the_whole_diagram_and_never_zooms_past_100() {
        assert_eq!(fit((2000.0, 1000.0), (1000.0, 1000.0)), 0.5);
        assert_eq!(fit((200.0, 100.0), (1000.0, 1000.0)), 1.0);
        assert_eq!(fit((1_000_000.0, 10.0), (100.0, 100.0)), MIN);
        assert_eq!(fit((0.0, 0.0), (100.0, 100.0)), 1.0);
    }

    #[test]
    fn percent_rounds_and_clamp_refuses_nonsense() {
        assert_eq!(percent(0.666), 67);
        assert_eq!(percent(1.0), 100);
        assert_eq!(clamp(f64::NAN), 1.0);
        assert_eq!(clamp(99.0), MAX);
        assert_eq!(clamp(0.0), MIN);
    }
}
