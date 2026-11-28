use tablepro_core::column::ColumnKind;
use tablepro_core::grid::DateFormat as CoreDateFormat;
use tablepro_linux_platform::settings::DateFormat;

/// The core's grid date format for the app's setting.
pub(super) fn core_format(format: DateFormat) -> CoreDateFormat {
    match format {
        DateFormat::Iso => CoreDateFormat::Iso,
        DateFormat::IsoDate => CoreDateFormat::IsoDate,
        DateFormat::UsLong => CoreDateFormat::UsLong,
        DateFormat::UsShort => CoreDateFormat::UsShort,
        DateFormat::EuLong => CoreDateFormat::EuLong,
        DateFormat::EuShort => CoreDateFormat::EuShort,
    }
}

pub(super) fn width_text(canonical: &str, kind: &ColumnKind, format: DateFormat) -> String {
    tablepro_core::grid::date_display::width_text(canonical, kind, core_format(format))
}
