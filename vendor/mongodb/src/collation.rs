use std::convert::TryFrom;

use serde::{Deserialize, Serialize};
use typed_builder::TypedBuilder;

use crate::error::{Error, ErrorKind};

/// A collation configuration. See the official MongoDB
/// [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more information on
/// each of the fields.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, Serialize, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct Collation {
    /// The ICU locale.
    ///
    /// See the list of supported languages and locales [here](https://www.mongodb.com/docs/manual/reference/collation-locales-defaults/#collation-languages-locales).
    #[builder(!default)]
    pub locale: String,

    /// The level of comparison to perform. Corresponds to [ICU Comparison Levels](http://userguide.icu-project.org/collation/concepts#TOC-Comparison-Levels).
    pub strength: Option<CollationStrength>,

    /// Whether to include a separate level for case differences. See [ICU Collation: CaseLevel](http://userguide.icu-project.org/collation/concepts#TOC-CaseLevel) for more information.
    pub case_level: Option<bool>,

    /// The sort order of case differences during tertiary level comparisons.
    pub case_first: Option<CollationCaseFirst>,

    /// Whether to compare numeric strings as numbers or strings.
    pub numeric_ordering: Option<bool>,

    /// Whether collation should consider whitespace and punctuation as base characters for
    /// purposes of comparison.
    pub alternate: Option<CollationAlternate>,

    /// Up to which characters are considered ignorable when `alternate` is "shifted". Has no
    /// effect if `alternate` is set to "non-ignorable".
    pub max_variable: Option<CollationMaxVariable>,

    /// Whether to check if text require normalization and to perform it.
    pub normalization: Option<bool>,

    /// Whether strings with diacritics sort from the back of the string.
    pub backwards: Option<bool>,
}

/// The level of comparison to perform. Corresponds to [ICU Comparison Levels](http://userguide.icu-project.org/collation/concepts#TOC-Comparison-Levels).
#[derive(Debug, Clone, Copy)]
#[non_exhaustive]
pub enum CollationStrength {
    /// Typically, this is used to denote differences between base characters (for example, "a" <
    /// "b").
    ///
    /// This is also called the level-1 strength.
    Primary,

    /// Accents in the characters are considered secondary differences (for example, "as" < "às" <
    /// "at").
    ///
    /// This is also called the level-2 strength.
    Secondary,

    /// Upper and lower case differences in characters are distinguished at the tertiary level (for
    /// example, "ao" < "Ao" < "aò").
    ///
    /// This is also called the level-3 strength.
    Tertiary,

    /// When punctuation is ignored at level 1-3, an additional level can be used to distinguish
    /// words with and without punctuation (for example, "ab" < "a-b" < "aB").
    ///
    /// This is also called the level-4 strength.
    Quaternary,

    /// When all other levels are equal, the identical level is used as a tiebreaker. The Unicode
    /// code point values of the NFD form of each string are compared at this level, just in
    /// case there is no difference at levels 1-4.
    ///
    /// This is also called the level-5 strength.
    Identical,
}

impl From<CollationStrength> for u32 {
    fn from(strength: CollationStrength) -> Self {
        match strength {
            CollationStrength::Primary => 1,
            CollationStrength::Secondary => 2,
            CollationStrength::Tertiary => 3,
            CollationStrength::Quaternary => 4,
            CollationStrength::Identical => 5,
        }
    }
}

impl TryFrom<u32> for CollationStrength {
    type Error = Error;

    fn try_from(level: u32) -> Result<Self, Self::Error> {
        Ok(match level {
            1 => CollationStrength::Primary,
            2 => CollationStrength::Secondary,
            3 => CollationStrength::Tertiary,
            4 => CollationStrength::Quaternary,
            5 => CollationStrength::Identical,
            _ => {
                return Err(ErrorKind::InvalidArgument {
                    message: (format!("invalid collation strength: {level}")),
                }
                .into())
            }
        })
    }
}

impl Serialize for CollationStrength {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let level = u32::from(*self);
        serializer.serialize_i32(level.try_into().map_err(serde::ser::Error::custom)?)
    }
}

impl<'de> Deserialize<'de> for CollationStrength {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let level = u32::deserialize(deserializer)?;
        Self::try_from(level).map_err(serde::de::Error::custom)
    }
}

impl std::fmt::Display for CollationStrength {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(&u32::from(*self), f)
    }
}

/// Setting that determines sort order of case differences during case tertiary level comparisons.
/// For more info, see <http://userguide.icu-project.org/collation/customization>.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum CollationCaseFirst {
    /// Uppercase sorts before lowercase.
    Upper,

    /// Lowercase sorts before uppercase.
    Lower,

    /// Default value. Similar to `Lower` with slight differences.
    /// See <http://userguide.icu-project.org/collation/customization> for details of differences.
    Off,
}

impl std::str::FromStr for CollationCaseFirst {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "upper" => Ok(CollationCaseFirst::Upper),
            "lower" => Ok(CollationCaseFirst::Lower),
            "off" => Ok(CollationCaseFirst::Off),
            _ => Err(ErrorKind::InvalidArgument {
                message: format!("invalid CollationCaseFirst: {s}"),
            }
            .into()),
        }
    }
}

impl CollationCaseFirst {
    /// Returns this [`CollationCaseFirst`] as a `&'static str`.
    pub fn as_str(&self) -> &'static str {
        match self {
            CollationCaseFirst::Upper => "upper",
            CollationCaseFirst::Lower => "lower",
            CollationCaseFirst::Off => "off",
        }
    }
}

impl std::fmt::Display for CollationCaseFirst {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self.as_str(), f)
    }
}

/// Setting that determines whether collation should consider whitespace and punctuation as base
/// characters for purposes of comparison.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum CollationAlternate {
    /// Whitespace and punctuation are considered base characters.
    NonIgnorable,

    /// Whitespace and punctuation are not considered base characters and are only distinguished at
    /// strength levels greater than 3.
    Shifted,
}

impl std::str::FromStr for CollationAlternate {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "non-ignorable" => Ok(CollationAlternate::NonIgnorable),
            "shifted" => Ok(CollationAlternate::Shifted),
            _ => Err(ErrorKind::InvalidArgument {
                message: format!("invalid collation alternate: {s}"),
            }
            .into()),
        }
    }
}

impl CollationAlternate {
    /// Returns this [`CollationAlternate`] as a `&'static str`.
    pub fn as_str(&self) -> &'static str {
        match self {
            CollationAlternate::NonIgnorable => "non-ignorable",
            CollationAlternate::Shifted => "shifted",
        }
    }
}

impl std::fmt::Display for CollationAlternate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self.as_str(), f)
    }
}

/// Field that determines up to which characters are considered ignorable when alternate: "shifted".
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum CollationMaxVariable {
    /// Both whitespace and punctuation are "ignorable", i.e. not considered base characters.
    Punct,

    /// Whitespace are "ignorable", i.e. not considered base characters
    Space,
}

impl std::str::FromStr for CollationMaxVariable {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "punct" => Ok(CollationMaxVariable::Punct),
            "space" => Ok(CollationMaxVariable::Space),
            _ => Err(ErrorKind::InvalidArgument {
                message: format!("invalid collation max variable: {s}"),
            }
            .into()),
        }
    }
}

impl CollationMaxVariable {
    /// Returns this [`CollationMaxVariable`] as a `&'static str`.
    pub fn as_str(&self) -> &'static str {
        match self {
            CollationMaxVariable::Punct => "punct",
            CollationMaxVariable::Space => "space",
        }
    }
}

impl std::fmt::Display for CollationMaxVariable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self.as_str(), f)
    }
}
