/// A value as the shell writes it: JSON's values, plus regular
/// expressions, the shell's type constructors and a bound parameter.
/// An object keeps its keys in the order written, which is the order the
/// server stores them in.
#[derive(Debug, Clone, PartialEq)]
pub enum ShellValue {
    Object(Vec<(String, ShellValue)>),
    Array(Vec<ShellValue>),
    String(String),
    Number(ShellNumber),
    Bool(bool),
    Null,
    Regex {
        pattern: String,
        flags: String,
    },
    Constructor {
        kind: ShellConstructor,
        args: Vec<ShellValue>,
    },
    /// `$1`, `$2`, ...: a value a generated statement binds. Typed text
    /// never holds one.
    Param(usize),
}

impl ShellValue {
    pub fn object(fields: Vec<(String, ShellValue)>) -> Self {
        Self::Object(fields)
    }

    pub fn string(text: impl Into<String>) -> Self {
        Self::String(text.into())
    }

    pub fn integer(value: i64) -> Self {
        Self::Number(ShellNumber::new(value.to_string()))
    }

    pub fn as_object(&self) -> Option<&[(String, ShellValue)]> {
        match self {
            Self::Object(fields) => Some(fields),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text),
            _ => None,
        }
    }

    /// The value of `key` in an object, by exact name. A key written twice
    /// has its last value, as the shell and the document sent both read
    /// it.
    pub fn field(&self, key: &str) -> Option<&ShellValue> {
        self.as_object()?
            .iter()
            .rev()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    /// Whether this is an object with no keys, the filter that matches
    /// every document.
    pub fn is_empty_object(&self) -> bool {
        self.as_object().is_some_and(<[_]>::is_empty)
    }

    /// Every key of every object inside this value, at any depth.
    pub fn keys(&self) -> Vec<&str> {
        let mut keys = Vec::new();
        self.collect_keys(&mut keys);
        keys
    }

    fn collect_keys<'a>(&'a self, keys: &mut Vec<&'a str>) {
        match self {
            Self::Object(fields) => {
                for (key, value) in fields {
                    keys.push(key);
                    value.collect_keys(keys);
                }
            }
            Self::Array(items) | Self::Constructor { args: items, .. } => {
                for item in items {
                    item.collect_keys(keys);
                }
            }
            _ => {}
        }
    }

    /// Every string inside this value, at any depth.
    pub fn strings(&self) -> Vec<&str> {
        let mut strings = Vec::new();
        self.collect_strings(&mut strings);
        strings
    }

    fn collect_strings<'a>(&'a self, strings: &mut Vec<&'a str>) {
        match self {
            Self::String(text) => strings.push(text),
            Self::Object(fields) => {
                for (_, value) in fields {
                    value.collect_strings(strings);
                }
            }
            Self::Array(items) | Self::Constructor { args: items, .. } => {
                for item in items {
                    item.collect_strings(strings);
                }
            }
            _ => {}
        }
    }
}

/// A number as written, sign included. The shell keeps an integer that
/// fits in 32 bits as an int, a larger one as a long, and anything with a
/// fraction or an exponent as a double.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ShellNumber {
    text: String,
}

impl ShellNumber {
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into() }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    /// The value when it is a whole number written without a fraction or
    /// an exponent, in decimal, hex, octal or binary.
    pub fn as_integer(&self) -> Option<i64> {
        let (negative, digits) = match self.text.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, self.text.strip_prefix('+').unwrap_or(&self.text)),
        };
        let lower = digits.to_ascii_lowercase();
        let magnitude = if let Some(hex) = lower.strip_prefix("0x") {
            i128::from_str_radix(hex, 16).ok()?
        } else if let Some(octal) = lower.strip_prefix("0o") {
            i128::from_str_radix(octal, 8).ok()?
        } else if let Some(binary) = lower.strip_prefix("0b") {
            i128::from_str_radix(binary, 2).ok()?
        } else if digits.bytes().all(|byte| byte.is_ascii_digit()) && !digits.is_empty() {
            digits.parse::<i128>().ok()?
        } else {
            return None;
        };
        i64::try_from(if negative { -magnitude } else { magnitude }).ok()
    }

    /// The value as a double, `Infinity` and `NaN` included.
    pub fn as_f64(&self) -> Option<f64> {
        match self.text.as_str() {
            "Infinity" | "+Infinity" => Some(f64::INFINITY),
            "-Infinity" => Some(f64::NEG_INFINITY),
            "NaN" | "-NaN" | "+NaN" => Some(f64::NAN),
            text => self
                .as_integer()
                .map(|integer| integer as f64)
                .or_else(|| text.parse().ok()),
        }
    }
}

/// The shell's helpers that make a value of a type JSON has no word for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShellConstructor {
    ObjectId,
    Date,
    Int32,
    Int64,
    Double,
    Decimal128,
    Timestamp,
    Uuid,
    BinData,
    HexData,
    MinKey,
    MaxKey,
    RegExp,
    Code,
}

impl ShellConstructor {
    /// The helper a name calls, in the spellings mongosh and the legacy
    /// shell take.
    pub fn named(name: &str) -> Option<Self> {
        Some(match name {
            "ObjectId" | "ObjectID" => Self::ObjectId,
            "ISODate" | "Date" => Self::Date,
            "NumberInt" | "Int32" => Self::Int32,
            "NumberLong" | "Long" => Self::Int64,
            "Double" => Self::Double,
            "NumberDecimal" | "Decimal128" => Self::Decimal128,
            "Timestamp" => Self::Timestamp,
            "UUID" => Self::Uuid,
            "BinData" => Self::BinData,
            "HexData" => Self::HexData,
            "MinKey" => Self::MinKey,
            "MaxKey" => Self::MaxKey,
            "RegExp" => Self::RegExp,
            "Code" => Self::Code,
            _ => return None,
        })
    }

    /// The name a value of this kind is written back with.
    pub fn name(self) -> &'static str {
        match self {
            Self::ObjectId => "ObjectId",
            Self::Date => "ISODate",
            Self::Int32 => "NumberInt",
            Self::Int64 => "NumberLong",
            Self::Double => "Double",
            Self::Decimal128 => "NumberDecimal",
            Self::Timestamp => "Timestamp",
            Self::Uuid => "UUID",
            Self::BinData => "BinData",
            Self::HexData => "HexData",
            Self::MinKey => "MinKey",
            Self::MaxKey => "MaxKey",
            Self::RegExp => "RegExp",
            Self::Code => "Code",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_number_reads_as_an_integer_only_when_it_is_written_as_one() {
        assert_eq!(ShellNumber::new("42").as_integer(), Some(42));
        assert_eq!(ShellNumber::new("-7").as_integer(), Some(-7));
        assert_eq!(ShellNumber::new("0x1F").as_integer(), Some(31));
        assert_eq!(ShellNumber::new("0b101").as_integer(), Some(5));
        assert_eq!(ShellNumber::new("1.0").as_integer(), None);
        assert_eq!(ShellNumber::new("1e3").as_integer(), None);
        assert_eq!(ShellNumber::new("99999999999999999999").as_integer(), None);
        assert_eq!(ShellNumber::new("1e3").as_f64(), Some(1000.0));
        assert!(ShellNumber::new("NaN").as_f64().is_some_and(f64::is_nan));
    }

    #[test]
    fn keys_and_strings_are_found_at_any_depth() {
        let value = ShellValue::object(vec![
            ("user".to_owned(), ShellValue::string("ann")),
            (
                "roles".to_owned(),
                ShellValue::Array(vec![ShellValue::object(vec![(
                    "pwd".to_owned(),
                    ShellValue::string("x"),
                )])]),
            ),
        ]);

        assert_eq!(value.keys(), ["user", "roles", "pwd"]);
        assert_eq!(value.strings(), ["ann", "x"]);
        assert_eq!(value.field("user"), Some(&ShellValue::string("ann")));
        assert!(ShellValue::Object(Vec::new()).is_empty_object());
    }

    #[test]
    fn a_helper_is_known_by_each_of_its_names() {
        assert_eq!(ShellConstructor::named("ISODate"), Some(ShellConstructor::Date));
        assert_eq!(ShellConstructor::named("NumberLong"), Some(ShellConstructor::Int64));
        assert_eq!(ShellConstructor::named("ObjectID"), Some(ShellConstructor::ObjectId));
        assert_eq!(ShellConstructor::named("eval"), None);
        assert_eq!(ShellConstructor::Decimal128.name(), "NumberDecimal");
    }
}
