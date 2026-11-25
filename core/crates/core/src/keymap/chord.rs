use std::fmt;

use super::KeymapError;

const NAMED_KEYS: [&str; 15] = [
    "left",
    "up",
    "right",
    "down",
    "pageup",
    "pagedown",
    "home",
    "end",
    "tab",
    "enter",
    "escape",
    "space",
    "backspace",
    "delete",
    "insert",
];
const PUNCTUATION: &str = "`-=[]\\;',./";
const HIGHEST_FUNCTION_KEY: u8 = 19;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Chord {
    pub key: String,
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub cmd: bool,
}

impl Chord {
    pub fn parse(text: &str) -> Result<Self, KeymapError> {
        let invalid = || KeymapError::InvalidChord {
            preset: String::new(),
            action: String::new(),
            chord: text.to_owned(),
        };
        let mut tokens: Vec<&str> = text.split('+').collect();
        let key = tokens.pop().filter(|key| is_key(key)).ok_or_else(invalid)?;
        let mut chord = Self {
            key: key.to_owned(),
            ctrl: false,
            shift: false,
            alt: false,
            cmd: false,
        };
        for token in tokens {
            let flag = match token {
                "ctrl" => &mut chord.ctrl,
                "shift" => &mut chord.shift,
                "alt" => &mut chord.alt,
                "cmd" => &mut chord.cmd,
                _ => return Err(invalid()),
            };
            if *flag {
                return Err(invalid());
            }
            *flag = true;
        }
        Ok(chord)
    }

    pub fn is_function_key(&self) -> bool {
        function_key_number(&self.key).is_some()
    }
}

impl fmt::Display for Chord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let modifiers = [
            (self.ctrl, "ctrl"),
            (self.shift, "shift"),
            (self.alt, "alt"),
            (self.cmd, "cmd"),
        ];
        for (held, name) in modifiers {
            if held {
                write!(f, "{name}+")?;
            }
        }
        f.write_str(&self.key)
    }
}

fn is_key(key: &str) -> bool {
    let mut characters = key.chars();
    match (characters.next(), characters.next()) {
        (Some(only), None) => only.is_ascii_lowercase() || only.is_ascii_digit() || PUNCTUATION.contains(only),
        _ => NAMED_KEYS.contains(&key) || function_key_number(key).is_some(),
    }
}

fn function_key_number(key: &str) -> Option<u8> {
    let digits = key.strip_prefix('f')?;
    if digits.starts_with('0') {
        return None;
    }
    digits
        .parse::<u8>()
        .ok()
        .filter(|number| (1..=HIGHEST_FUNCTION_KEY).contains(number))
}
