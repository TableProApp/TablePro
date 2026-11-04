use super::{ShellConstructor, ShellSyntaxError, ShellValue};

/// Refuse a helper called with arguments it cannot take, so a filter or
/// a statement fails before anything is sent. The driver turns what
/// passes into a value; an id, a UUID and hex are checked here because
/// their form is all there is to check.
pub(crate) fn check_helper(kind: ShellConstructor, args: &[ShellValue], at: usize) -> Result<(), ShellSyntaxError> {
    use ShellValue::{Number, Object, String};

    let (accepted, expected) = match kind {
        ShellConstructor::ObjectId => (
            args.is_empty() || matches!(args, [String(hex)] if is_hex(hex, 24)),
            "nothing, or 24 hex digits in quotes",
        ),
        ShellConstructor::Date => (
            matches!(args, [] | [String(_)] | [Number(_)]),
            "nothing, a date in quotes or milliseconds since 1970",
        ),
        ShellConstructor::Int32 | ShellConstructor::Int64 | ShellConstructor::Double | ShellConstructor::Decimal128 => {
            (matches!(args, [Number(_) | String(_)]), "one number")
        }
        ShellConstructor::Timestamp => (
            matches!(args, [Number(_), Number(_)] | [Object(_)]),
            "seconds and an increment",
        ),
        ShellConstructor::Uuid => (
            matches!(args, []) || matches!(args, [String(text)] if uuid::Uuid::parse_str(text).is_ok()),
            "nothing, or a UUID in quotes",
        ),
        ShellConstructor::BinData => (matches!(args, [Number(_), String(_)]), "a subtype and base64 in quotes"),
        ShellConstructor::HexData => (
            matches!(args, [Number(_), String(hex)] if hex.len() % 2 == 0 && is_hex(hex, hex.len())),
            "a subtype and hex digits in quotes",
        ),
        ShellConstructor::MinKey | ShellConstructor::MaxKey => (args.is_empty(), "nothing"),
        ShellConstructor::RegExp => (
            matches!(args, [String(_)] | [String(_), String(_)]),
            "a pattern and flags in quotes",
        ),
        ShellConstructor::Code => (matches!(args, [String(_)]), "JavaScript in quotes"),
    };
    match accepted {
        true => Ok(()),
        false => Err(ShellSyntaxError::HelperArguments {
            at,
            helper: kind.name(),
            expected,
        }),
    }
}

fn is_hex(text: &str, length: usize) -> bool {
    text.len() == length && text.bytes().all(|byte| byte.is_ascii_hexdigit())
}
