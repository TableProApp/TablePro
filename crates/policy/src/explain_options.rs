use sqlparser::ast::{Expr, UtilityOption, Value};

pub(crate) fn analyze_option_enabled(options: &[UtilityOption]) -> bool {
    options.iter().any(|option| {
        (option.name.value.eq_ignore_ascii_case("analyze") || option.name.value.eq_ignore_ascii_case("analyse"))
            && !option.arg.as_ref().is_some_and(is_disabled_option_arg)
    })
}

fn is_disabled_option_arg(arg: &Expr) -> bool {
    match arg {
        Expr::Value(value) => match &value.value {
            Value::Boolean(flag) => !flag,
            Value::Number(number, _) => number.parse::<f64>().is_ok_and(|n| n == 0.0),
            Value::SingleQuotedString(text) | Value::DoubleQuotedString(text) => is_disabled_word(text),
            _ => false,
        },
        Expr::Identifier(ident) => is_disabled_word(&ident.value),
        _ => false,
    }
}

fn is_disabled_word(text: &str) -> bool {
    matches!(text.to_ascii_lowercase().as_str(), "false" | "off" | "0" | "no")
}
