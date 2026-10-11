use sqlx::Decode;
use sqlx::mysql::{MySql, MySqlValueRef};
use tablepro_core::Value;

pub(crate) fn bit_value(raw: MySqlValueRef<'_>) -> Option<Value> {
    bits(<&[u8] as Decode<MySql>>::decode(raw).ok()?)
}

pub(crate) fn geometry_value(raw: MySqlValueRef<'_>) -> Option<Value> {
    <&[u8] as Decode<MySql>>::decode(raw)
        .ok()
        .map(|bytes| Value::Bytes(bytes.to_vec()))
}

fn bits(bytes: &[u8]) -> Option<Value> {
    if bytes.is_empty() || bytes.len() > 8 {
        return None;
    }
    let mut word = [0u8; 8];
    word.get_mut(8 - bytes.len()..)?.copy_from_slice(bytes);
    let number = u64::from_be_bytes(word);
    Some(i64::try_from(number).map_or_else(|_| Value::Bytes(bytes.to_vec()), Value::Int))
}

#[cfg(test)]
mod tests {
    use super::bits;
    use tablepro_core::Value;

    #[test]
    fn value_contract_bit_payloads_become_integers_until_they_pass_i64() {
        assert_eq!(bits(&[0xaa]), Some(Value::Int(170)));
        assert_eq!(bits(&[0x01, 0x00]), Some(Value::Int(256)));
        assert_eq!(
            bits(&[0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            Some(Value::Int(i64::MAX))
        );
        assert_eq!(
            bits(&[0x80, 0, 0, 0, 0, 0, 0, 0]),
            Some(Value::Bytes(vec![0x80, 0, 0, 0, 0, 0, 0, 0]))
        );
    }

    #[test]
    fn value_contract_bit_payloads_outside_the_protocol_width_are_refused() {
        assert_eq!(bits(&[]), None);
        assert_eq!(bits(&[0; 9]), None);
    }
}
