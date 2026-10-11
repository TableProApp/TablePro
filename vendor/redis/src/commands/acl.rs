//! Defines types to use with the ACL commands.

use crate::errors::ParsingError;
use crate::types::{FromRedisValue, RedisWrite, ToRedisArgs, Value};

macro_rules! not_convertible_error {
    ($v:expr, $det:expr) => {
        ParsingError::from(format!("{:?} (response was {:?})", $det, $v))
    };
}

/// ACL rules are used in order to activate or remove a flag, or to perform a
/// given change to the user ACL, which under the hood are just single words.
#[derive(Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Rule {
    /// Enable the user: it is possible to authenticate as this user.
    On,
    /// Disable the user: it's no longer possible to authenticate with this
    /// user, however the already authenticated connections will still work.
    Off,

    /// Add the command to the list of commands the user can call.
    AddCommand(String),
    /// Remove the command to the list of commands the user can call.
    RemoveCommand(String),
    /// Add all the commands in such category to be called by the user.
    AddCategory(String),
    /// Remove the commands from such category the client can call.
    RemoveCategory(String),
    /// Alias for `+@all`. Note that it implies the ability to execute all the
    /// future commands loaded via the modules system.
    AllCommands,
    /// Alias for `-@all`.
    NoCommands,

    /// Add this password to the list of valid password for the user.
    AddPass(String),
    /// Remove this password from the list of valid passwords.
    RemovePass(String),
    /// Add this SHA-256 hash value to the list of valid passwords for the user.
    AddHashedPass(String),
    /// Remove this hash value from from the list of valid passwords
    RemoveHashedPass(String),
    /// All the set passwords of the user are removed, and the user is flagged
    /// as requiring no password: it means that every password will work
    /// against this user.
    NoPass,
    /// Flush the list of allowed passwords. Moreover removes the _nopass_ status.
    ResetPass,

    /// Add a pattern of keys that can be mentioned as part of commands.
    Pattern(String),
    /// Alias for `~*`.
    AllKeys,
    /// Flush the list of allowed keys patterns.
    ResetKeys,

    /// Pattern for pub/sub channels (returned prefixed with `&` by Redis)
    Channel(String),
    /// Reset Channels
    ResetChannels,
    /// Selector entries (returned by Redis under `(selectors)`).
    /// Only supported in Redis 7.2 and later
    Selector(Vec<Self>),

    /// Performs the following actions: `resetpass`, `resetkeys`, `off`, `-@all`.
    /// The user returns to the same state it has immediately after its creation.
    Reset,

    /// Raw text of [`ACL rule`][1]  that not enumerated above.
    ///
    /// [1]: https://redis.io/docs/manual/security/acl
    Other(String),
}

impl ToRedisArgs for Rule {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        use self::Rule::*;

        match self {
            On => out.write_arg(b"on"),
            Off => out.write_arg(b"off"),

            AddCommand(cmd) => out.write_arg_fmt(format_args!("+{cmd}")),
            RemoveCommand(cmd) => out.write_arg_fmt(format_args!("-{cmd}")),
            AddCategory(cat) => out.write_arg_fmt(format_args!("+@{cat}")),
            RemoveCategory(cat) => out.write_arg_fmt(format_args!("-@{cat}")),
            AllCommands => out.write_arg(b"allcommands"),
            NoCommands => out.write_arg(b"nocommands"),

            AddPass(pass) => out.write_arg_fmt(format_args!(">{pass}")),
            RemovePass(pass) => out.write_arg_fmt(format_args!("<{pass}")),
            AddHashedPass(pass) => out.write_arg_fmt(format_args!("#{pass}")),
            RemoveHashedPass(pass) => out.write_arg_fmt(format_args!("!{pass}")),
            NoPass => out.write_arg(b"nopass"),
            ResetPass => out.write_arg(b"resetpass"),

            Pattern(pat) => out.write_arg_fmt(format_args!("~{pat}")),
            AllKeys => out.write_arg(b"allkeys"),
            ResetKeys => out.write_arg(b"resetkeys"),
            Channel(pat) => out.write_arg_fmt(format_args!("&{pat}")),
            ResetChannels => out.write_arg(b"resetchannels"),
            Selector(sel) => out.write_arg_fmt(format_args!(
                "({})",
                sel.iter()
                    .flat_map(|r| r
                        .to_redis_args()
                        .into_iter()
                        .map(|x| String::from_utf8_lossy(&x).to_string()))
                    .collect::<Vec<String>>()
                    .join(" ")
            )),
            Reset => out.write_arg(b"reset"),

            Other(rule) => out.write_arg(rule.as_bytes()),
        }
    }
}

/// An info dictionary type storing Redis ACL information as multiple `Rule`.
/// This type collects key/value data returned by the [`ACL GETUSER`][1] command.
///
/// [1]: https://redis.io/commands/acl-getuser
#[derive(Debug, Default, Eq, PartialEq)]
pub struct AclInfo {
    /// Describes flag rules for the user. Represented by [`Rule::On`][1],
    /// [`Rule::Off`][2], [`Rule::AllKeys`][3], [`Rule::AllCommands`][4] and
    /// [`Rule::NoPass`][5].
    ///
    /// [1]: ./enum.Rule.html#variant.On
    /// [2]: ./enum.Rule.html#variant.Off
    /// [3]: ./enum.Rule.html#variant.AllKeys
    /// [4]: ./enum.Rule.html#variant.AllCommands
    /// [5]: ./enum.Rule.html#variant.NoPass
    pub flags: Vec<Rule>,
    /// Describes the user's passwords. Represented by [`Rule::AddHashedPass`][1].
    ///
    /// [1]: ./enum.Rule.html#variant.AddHashedPass
    pub passwords: Vec<Rule>,
    /// Describes capabilities of which commands the user can call.
    /// Represented by [`Rule::AddCommand`][1], [`Rule::AddCategory`][2],
    /// [`Rule::RemoveCommand`][3] and [`Rule::RemoveCategory`][4].
    ///
    /// [1]: ./enum.Rule.html#variant.AddCommand
    /// [2]: ./enum.Rule.html#variant.AddCategory
    /// [3]: ./enum.Rule.html#variant.RemoveCommand
    /// [4]: ./enum.Rule.html#variant.RemoveCategory
    pub commands: Vec<Rule>,
    /// Describes patterns of keys which the user can access. Represented by
    /// [`Rule::Pattern`][1].
    ///
    /// [1]: ./enum.Rule.html#variant.Pattern
    pub keys: Vec<Rule>,
    /// Describes pub/sub channel patterns. Represented by [`Rule::Channel`][1].
    ///
    /// [1]: ./enum.Rule.html#variant.Channel
    pub channels: Vec<Rule>,
    /// Describes selectors. Represented by [`Rule::Selector`][1].
    ///
    /// [1]: ./enum.Rule.html#variant.Selector
    pub selectors: Vec<Rule>,
}
impl AclInfo {
    fn handle_pair(&mut self, name: &Value, value: &Value) -> Result<(), ParsingError> {
        // Expect name to be a bulk string
        let key = match name {
            Value::BulkString(bs) => {
                // convert to owned String and trim optional surrounding quotes
                let mut s = std::str::from_utf8(bs)?.trim().to_owned();
                if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
                    s = s[1..s.len() - 1].to_owned();
                }
                s
            }
            _ => {
                return Err(not_convertible_error!(
                    name,
                    "Expect a bulk string key name"
                ));
            }
        };
        match key.as_str() {
            "flags" => {
                let f = value
                    .as_sequence()
                    .ok_or_else(|| {
                        not_convertible_error!(value, "Expect an array response of ACL flags")
                    })?
                    .iter()
                    .map(|flag| match flag {
                        Value::BulkString(flag) => match flag.as_slice() {
                            b"on" => Ok(Rule::On),
                            b"off" => Ok(Rule::Off),
                            b"allkeys" => Ok(Rule::AllKeys),
                            b"allcommands" => Ok(Rule::AllCommands),
                            b"nopass" => Ok(Rule::NoPass),
                            other => Ok(Rule::Other(String::from_utf8_lossy(other).into_owned())),
                        },
                        _ => Err(not_convertible_error!(
                            flag,
                            "Expect an arbitrary binary data"
                        )),
                    })
                    .collect::<Result<_, _>>()?;
                self.flags = f;
            }
            "passwords" => {
                let p = value
                    .as_sequence()
                    .ok_or_else(|| {
                        not_convertible_error!(value, "Expect an array response of ACL passwords")
                    })?
                    .iter()
                    .map(|pass| {
                        let s = String::from_redis_value_ref(pass)?;
                        Ok(Rule::AddHashedPass(s))
                    })
                    .collect::<Result<_, ParsingError>>()?;
                self.passwords = p;
            }
            "commands" => {
                let cmds = match value {
                    Value::BulkString(cmd) => std::str::from_utf8(cmd)?,
                    _ => {
                        return Err(not_convertible_error!(
                            value,
                            "Expect a valid UTF8 string for commands"
                        ));
                    }
                }
                .split_terminator(' ')
                .map(|cmd| match cmd {
                    x if x.starts_with("+@") => Ok(Rule::AddCategory(x[2..].to_owned())),
                    x if x.starts_with("-@") => Ok(Rule::RemoveCategory(x[2..].to_owned())),
                    x if x.starts_with('+') => Ok(Rule::AddCommand(x[1..].to_owned())),
                    x if x.starts_with('-') => Ok(Rule::RemoveCommand(x[1..].to_owned())),
                    _ => Err(not_convertible_error!(
                        cmd,
                        "Expect a command addition/removal"
                    )),
                })
                .collect::<Result<_, _>>()?;
                self.commands = cmds;
            }
            "keys" => {
                let parsed = match value {
                    Value::Array(arr) => arr
                        .iter()
                        .map(|pat| {
                            let s = String::from_redis_value_ref(pat)?;
                            match s.as_str() {
                                "*" => Ok(Rule::AllKeys),
                                _ => Ok(Rule::Pattern(s)),
                            }
                        })
                        .collect::<Result<_, ParsingError>>()?,
                    Value::BulkString(bs) => {
                        let mut s = std::str::from_utf8(bs)?;
                        s = s.trim();
                        if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
                            s = &s[1..s.len() - 1];
                        }
                        s.split_whitespace()
                            .map(|tok| {
                                let tok = if let Some(tok) = tok.strip_prefix('~') {
                                    tok
                                } else {
                                    tok
                                };
                                match tok {
                                    "*" => Ok(Rule::AllKeys),
                                    _ => Ok(Rule::Pattern(tok.to_owned())),
                                }
                            })
                            .collect::<Result<_, ParsingError>>()?
                    }
                    other => {
                        return Err(not_convertible_error!(
                            other,
                            "Expect an array or bulk-string of keys"
                        ));
                    }
                };
                self.keys = parsed;
            }
            "channels" => {
                let parsed = match value {
                    Value::Array(arr) | Value::Set(arr) => arr
                        .iter()
                        .map(|pat| {
                            let s = String::from_redis_value_ref(pat)?;
                            let s = if let Some(s) = s.strip_prefix('&') {
                                s.to_owned()
                            } else {
                                s
                            };
                            Ok(Rule::Channel(s))
                        })
                        .collect::<Result<_, ParsingError>>()?,
                    Value::BulkString(bs) => {
                        let mut s = std::str::from_utf8(bs)?;
                        s = s.trim();
                        if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
                            s = &s[1..s.len() - 1];
                        }
                        s.split_whitespace()
                            .map(|tok| {
                                let tok = if let Some(tok) = tok.strip_prefix('&') {
                                    tok
                                } else {
                                    tok
                                };
                                Ok(Rule::Channel(tok.to_owned()))
                            })
                            .collect::<Result<_, ParsingError>>()?
                    }
                    other => {
                        return Err(not_convertible_error!(
                            other,
                            "Expect an array or bulk-string of channels"
                        ));
                    }
                };
                self.channels = parsed;
            }
            "selectors" => {
                let parsed = match value {
                    // selectors can be returned as an array or a set of bulk-strings,
                    // or as an array of arrays where each inner array contains alternating
                    // key/value bulk-strings describing the selector. Accept both.
                    Value::Array(arr) | Value::Set(arr) => arr
                        .iter()
                        .map(|pat| {
                            let acl: Self = FromRedisValue::from_redis_value_ref(pat)?;
                            let selector = acl
                                .flags
                                .into_iter()
                                .chain(acl.commands)
                                .chain(acl.channels)
                                .chain(acl.keys)
                                .collect();
                            Ok(selector)
                        })
                        .collect::<Result<Vec<Vec<Rule>>, ParsingError>>()?,
                    other => {
                        return Err(not_convertible_error!(
                            other,
                            "Expect an array or bulk-string of selectors"
                        ));
                    }
                };
                self.selectors = parsed.into_iter().flatten().collect();
            }
            _ => {}
        }
        Ok(())
    }
}
impl FromRedisValue for AclInfo {
    fn from_redis_value(v: Value) -> Result<Self, ParsingError> {
        let mut acl = Self::default();
        // handle a single key/value pair (borrowed)
        // First, try RESP3 map/attribute forms using as_map_iter (borrowed iterator)
        if let Some(map_iter) = v.as_map_iter() {
            for (name, value) in map_iter {
                acl.handle_pair(name, value)?;
            }
        } else if let Some(seq) = v.as_sequence() {
            // Sequence (array or set) case: must be alternating key/value entries.
            if seq.len() % 2 != 0 {
                return Err(not_convertible_error!(v, ""));
            }
            for chunk in seq.as_chunks::<2>().0 {
                let name = &chunk[0];
                let value = &chunk[1];
                acl.handle_pair(name, value)?;
            }
        } else {
            return Err(not_convertible_error!(v, ""));
        }
        Ok(acl)
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    macro_rules! assert_args {
        ($rule:expr, $arg:expr) => {
            assert_eq!($rule.to_redis_args(), vec![$arg.to_vec()]);
        };
    }

    #[test]
    fn test_rule_to_arg() {
        use self::Rule::*;

        assert_args!(On, b"on");
        assert_args!(Off, b"off");
        assert_args!(AddCommand("set".to_owned()), b"+set");
        assert_args!(RemoveCommand("set".to_owned()), b"-set");
        assert_args!(AddCategory("hyperloglog".to_owned()), b"+@hyperloglog");
        assert_args!(RemoveCategory("hyperloglog".to_owned()), b"-@hyperloglog");
        assert_args!(AllCommands, b"allcommands");
        assert_args!(NoCommands, b"nocommands");
        assert_args!(AddPass("mypass".to_owned()), b">mypass");
        assert_args!(RemovePass("mypass".to_owned()), b"<mypass");
        assert_args!(
            AddHashedPass(
                "c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2".to_owned()
            ),
            b"#c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2"
        );
        assert_args!(
            RemoveHashedPass(
                "c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2".to_owned()
            ),
            b"!c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2"
        );
        assert_args!(NoPass, b"nopass");
        assert_args!(Pattern("pat:*".to_owned()), b"~pat:*");
        assert_args!(AllKeys, b"allkeys");
        assert_args!(ResetKeys, b"resetkeys");
        assert_args!(Reset, b"reset");
        assert_args!(Other("resetchannels".to_owned()), b"resetchannels");
        assert_args!(Channel("asynq:cancel".to_owned()), b"&asynq:cancel");
        assert_args!(
            Selector(vec![
                AddCommand("SET".to_string()),
                Pattern("key2".to_string())
            ]),
            b"(+SET ~key2)"
        );
    }

    #[test]
    fn test_from_redis_value() {
        let redis_value = Value::Array(vec![
            Value::BulkString("flags".into()),
            Value::Array(vec![
                Value::BulkString("on".into()),
                Value::BulkString("allchannels".into()),
            ]),
            Value::BulkString("passwords".into()),
            Value::Array(vec![]),
            Value::BulkString("commands".into()),
            Value::BulkString("-@all +get".into()),
            Value::BulkString("keys".into()),
            Value::Array(vec![Value::BulkString("pat:*".into())]),
            Value::BulkString("channels".into()),
            Value::Array(vec![Value::BulkString("&asynq:cancel".into())]),
            Value::BulkString("selectors".into()),
            Value::Array(vec![Value::Array(vec![
                Value::BulkString("commands".into()),
                Value::BulkString("-@all +get".into()),
                Value::BulkString("keys".into()),
                Value::BulkString("~key2".into()),
                Value::BulkString("channels".into()),
                Value::BulkString("".into()),
            ])]),
        ]);
        let acl_info = AclInfo::from_redis_value_ref(&redis_value).expect("Parse successfully");

        assert_eq!(
            acl_info,
            AclInfo {
                flags: vec![Rule::On, Rule::Other("allchannels".into())],
                passwords: vec![],
                commands: vec![
                    Rule::RemoveCategory("all".to_owned()),
                    Rule::AddCommand("get".to_owned()),
                ],
                keys: vec![Rule::Pattern("pat:*".to_owned())],
                channels: vec![Rule::Channel("asynq:cancel".to_owned())],
                selectors: vec![
                    Rule::RemoveCategory("all".to_owned()),
                    Rule::AddCommand("get".to_owned()),
                    Rule::Pattern("key2".to_owned()),
                ],
            }
        );
    }
}
