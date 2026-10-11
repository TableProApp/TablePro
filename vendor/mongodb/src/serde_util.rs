use std::time::Duration;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::{
    bson::{doc, Bson, Document},
    bson_util::get_u64,
    error::{Error, Result},
    serde_util,
};

pub(crate) mod duration_option_as_int_seconds {
    use super::*;

    pub(crate) fn serialize<S: Serializer>(
        val: &Option<Duration>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        match val {
            Some(duration) if duration.as_secs() > i32::MAX as u64 => serializer.serialize_i64(
                duration
                    .as_secs()
                    .try_into()
                    .map_err(serde::ser::Error::custom)?,
            ),
            #[allow(clippy::cast_possible_truncation)]
            Some(duration) => serializer.serialize_i32(duration.as_secs() as i32),
            None => serializer.serialize_none(),
        }
    }

    pub(crate) fn deserialize<'de, D>(
        deserializer: D,
    ) -> std::result::Result<Option<Duration>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let millis = Option::<u64>::deserialize(deserializer)?;
        Ok(millis.map(Duration::from_secs))
    }
}

pub(crate) fn serialize_duration_option_as_int_millis<S: Serializer>(
    val: &Option<Duration>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    match val {
        Some(duration) if duration.as_millis() > i32::MAX as u128 => serializer.serialize_i64(
            duration
                .as_millis()
                .try_into()
                .map_err(serde::ser::Error::custom)?,
        ),
        #[allow(clippy::cast_possible_truncation)]
        Some(duration) => serializer.serialize_i32(duration.as_millis() as i32),
        None => serializer.serialize_none(),
    }
}

pub(crate) fn deserialize_duration_option_from_u64_millis<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<Duration>, D::Error>
where
    D: Deserializer<'de>,
{
    let millis = Option::<u64>::deserialize(deserializer)?;
    Ok(millis.map(Duration::from_millis))
}

#[allow(clippy::trivially_copy_pass_by_ref)]
pub(crate) fn serialize_u32_option_as_i32<S: Serializer>(
    val: &Option<u32>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    match val {
        Some(ref val) => serde_util::serialize_u32_as_i32(val, serializer),
        None => serializer.serialize_none(),
    }
}

#[allow(clippy::trivially_copy_pass_by_ref)]
pub(crate) fn serialize_u32_option_as_batch_size<S: Serializer>(
    val: &Option<u32>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    match val {
        #[allow(clippy::cast_possible_wrap)]
        Some(val) if *val <= i32::MAX as u32 => (doc! {
            "batchSize": (*val as i32)
        })
        .serialize(serializer),
        None => Document::new().serialize(serializer),
        _ => Err(serde::ser::Error::custom(
            "batch size must be able to fit into a signed 32-bit integer",
        )),
    }
}

pub(crate) fn serialize_u64_option_as_i64<S: Serializer>(
    val: &Option<u64>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    match val {
        Some(ref v) => serde_util::serialize_u64_as_i64(v, serializer),
        None => serializer.serialize_none(),
    }
}

pub(crate) fn deserialize_u64_from_bson_number<'de, D>(
    deserializer: D,
) -> std::result::Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    let bson = Bson::deserialize(deserializer)?;
    get_u64(&bson)
        .ok_or_else(|| serde::de::Error::custom(format!("could not deserialize u64 from {bson:?}")))
}

pub(crate) fn deserialize_option_u64_from_bson_number<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<Bson>::deserialize(deserializer)?
        .map(|bson| {
            get_u64(&bson).ok_or_else(|| {
                serde::de::Error::custom(format!("could not deserialize u64 from {bson:?}"))
            })
        })
        .transpose()
}

pub(crate) fn serialize_error_as_string<S: Serializer>(
    val: &Error,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    serializer.serialize_str(&val.to_string())
}

pub(crate) fn serialize_result_error_as_string<S: Serializer, T: Serialize>(
    val: &Result<T>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    val.as_ref()
        .map_err(|e| e.to_string())
        .serialize(serializer)
}

#[cfg(test)]
pub(crate) fn deserialize_nonempty_vec<'de, D, T>(
    deserializer: D,
) -> std::result::Result<Option<Vec<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let vec: Vec<T> = Vec::deserialize(deserializer)?;
    if vec.is_empty() {
        return Err(serde::de::Error::custom(format!(
            "list provided for {} cannot be empty",
            std::any::type_name::<T>()
        )));
    }
    Ok(Some(vec))
}

#[cfg(test)]
pub(crate) fn serialize_indexed_map<S: Serializer, T: Serialize>(
    map: &std::collections::HashMap<usize, T>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    let string_map: std::collections::BTreeMap<_, _> = map
        .iter()
        .map(|(index, result)| (index.to_string(), result))
        .collect();
    string_map.serialize(serializer)
}

#[cfg(test)]
pub(crate) fn deserialize_indexed_map<'de, D, T>(
    deserializer: D,
) -> std::result::Result<Option<std::collections::HashMap<usize, T>>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    use std::{collections::HashMap, str::FromStr};

    let string_map: HashMap<String, T> = HashMap::deserialize(deserializer)?;
    Ok(Some(string_map.into_iter().try_fold(
        HashMap::new(),
        |mut map, (index, t)| {
            let index = usize::from_str(&index).map_err(serde::de::Error::custom)?;
            map.insert(index, t);
            Ok(map)
        },
    )?))
}

pub(crate) fn serialize_bool_or_true<S: Serializer>(
    val: &Option<bool>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    let val = val.unwrap_or(true);
    serializer.serialize_bool(val)
}

pub(crate) fn serialize_u32_as_i32<S: Serializer>(
    n: &u32,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    match i32::try_from(*n) {
        Ok(n) => n.serialize(serializer),
        Err(_) => Err(serde::ser::Error::custom(format!(
            "cannot serialize u32 {n} as i32"
        ))),
    }
}

pub(crate) fn serialize_u64_as_i64<S: Serializer>(
    n: &u64,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    match i64::try_from(*n) {
        Ok(n) => n.serialize(serializer),
        Err(_) => Err(serde::ser::Error::custom(format!(
            "cannot serialize u64 {n} as i64"
        ))),
    }
}
