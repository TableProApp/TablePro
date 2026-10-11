use sqlx::postgres::{PgTypeInfo, PgTypeKind, PgValueFormat, PgValueRef};
use sqlx::{TypeInfo, ValueRef};
use tablepro_core::Value;

pub(super) const MAX_ARRAY_TEXT_BYTES: usize = 16 * 1024 * 1024;
// PostgreSQL sends int2vector and oidvector in array wire format, but their text input accepts only
// space-separated values, so array text for them could not be imported again.
const INT2VECTOR_OID: u32 = 22;
const OIDVECTOR_OID: u32 = 30;
const BIT_OID: u32 = 1560;
const VARBIT_OID: u32 = 1562;
const MACADDR8_OID: u32 = 774;
const MACADDR_OID: u32 = 829;
const INET_OID: u32 = 869;
const CIDR_OID: u32 = 650;
const PG_LSN_OID: u32 = 3220;
const XML_OID: u32 = 142;

pub(crate) fn decode(raw: &PgValueRef<'_>) -> Option<Value> {
    let info = raw.type_info();
    let PgTypeKind::Array(element) = info.kind() else {
        return None;
    };
    let element_oid = element.oid()?.0;
    let value_oid = base_oid(element)?;
    let text_element = is_text_element(element);
    match raw.format() {
        PgValueFormat::Binary => {
            let bytes = raw.as_bytes().ok()?;
            let text = match info.oid()?.0 {
                INT2VECTOR_OID | OIDVECTOR_OID => decode_vector(bytes, element_oid),
                _ => decode_binary_with_oid(bytes, element_oid, value_oid, text_element),
            }?;
            Some(Value::Text(text))
        }
        PgValueFormat::Text => raw.as_str().ok().map(|text| Value::Text(text.into())),
    }
}

pub(super) fn is_text_element(info: &PgTypeInfo) -> bool {
    let mut current = info;
    loop {
        match current.kind() {
            PgTypeKind::Enum(_) => return true,
            PgTypeKind::Domain(base) => current = base,
            // ponytail: PgTypeInfo omits custom namespaces; if unrelated
            // simple types named citext are used, verify extension membership by OID.
            PgTypeKind::Simple => {
                return current.name().eq_ignore_ascii_case("citext")
                    || current.oid().is_some_and(|oid| oid.0 == XML_OID);
            }
            _ => return false,
        }
    }
}

fn base_oid(info: &PgTypeInfo) -> Option<u32> {
    match info.kind() {
        PgTypeKind::Domain(base) => base_oid(base),
        _ => info.oid().map(|oid| oid.0),
    }
}

fn decode_vector(bytes: &[u8], expected_oid: u32) -> Option<String> {
    let mut reader = Reader { remaining: bytes };
    let count = reader.integer()?;
    let flags = reader.integer()?;
    let oid = reader.integer()? as u32;
    if count != 1 || flags != 0 || oid != expected_oid {
        return None;
    }
    let length = usize::try_from(reader.integer()?).ok()?;
    if reader.integer()? != 0 {
        return None;
    }
    let mut elements = Vec::with_capacity(vector_capacity(length, reader.remaining.len())?);
    for _ in 0..length {
        let length = reader.integer()?;
        elements.push(element_text(oid, false, read_bounded_element(&mut reader, length)?)?);
    }
    reader.remaining.is_empty().then(|| elements.join(" "))
}

fn vector_capacity(length: usize, payload_bytes: usize) -> Option<usize> {
    (length <= payload_bytes / 4).then_some(length)
}

struct Reader<'a> {
    remaining: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let (value, remaining) = self.remaining.split_at_checked(count)?;
        self.remaining = remaining;
        Some(value)
    }

    fn integer(&mut self) -> Option<i32> {
        Some(i32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }
}

struct Dimension {
    length: usize,
    lower: i32,
    upper: i32,
}

fn read_dimensions(reader: &mut Reader<'_>, count: usize) -> Option<(Vec<Dimension>, usize)> {
    let mut dimensions = Vec::with_capacity(count);
    let mut total = if count == 0 { 0_usize } else { 1 };
    for _ in 0..count {
        let length = reader.integer()?;
        let lower = reader.integer()?;
        if length <= 0 {
            return None;
        }
        let upper = lower.checked_add(length - 1)?;
        let length = usize::try_from(length).ok()?;
        total = total.checked_mul(length)?;
        dimensions.push(Dimension { length, lower, upper });
    }
    (total <= reader.remaining.len() / 4).then_some((dimensions, total))
}

#[cfg(test)]
fn decode_binary(bytes: &[u8], expected_oid: u32, text_element: bool) -> Option<String> {
    decode_binary_with_oid(bytes, expected_oid, expected_oid, text_element)
}

fn decode_binary_with_oid(bytes: &[u8], expected_oid: u32, value_oid: u32, text_element: bool) -> Option<String> {
    let mut reader = Reader { remaining: bytes };
    let count = reader.integer()?;
    let flags = reader.integer()?;
    let oid = reader.integer()? as u32;
    if !(0..=6).contains(&count)
        || !matches!(flags, 0 | 1)
        || oid != expected_oid
        || (!text_element && !supported(value_oid))
    {
        return None;
    }
    let (dimensions, total) = read_dimensions(&mut reader, count as usize)?;
    let mut output = String::new();
    if dimensions.iter().any(|dimension| dimension.lower != 1) {
        for dimension in &dimensions {
            output.push_str(&format!("[{}:{}]", dimension.lower, dimension.upper));
        }
        output.push('=');
    }
    if total == 0 {
        output.push_str("{}");
    } else {
        append_dimension(
            &mut reader,
            &dimensions,
            value_oid,
            text_element,
            flags == 1,
            &mut output,
        )?;
    }
    reader.remaining.is_empty().then_some(output)
}

fn append_dimension(
    reader: &mut Reader<'_>,
    dimensions: &[Dimension],
    oid: u32,
    text_element: bool,
    allows_null: bool,
    output: &mut String,
) -> Option<()> {
    let (dimension, rest) = dimensions.split_first()?;
    output.push('{');
    for index in 0..dimension.length {
        if index > 0 {
            output.push(',');
        }
        if rest.is_empty() {
            let length = reader.integer()?;
            if length == -1 && allows_null {
                output.push_str("NULL");
            } else {
                let bytes = read_bounded_element(reader, length)?;
                append_quoted(output, &element_text(oid, text_element, bytes)?)?;
            }
        } else {
            append_dimension(reader, rest, oid, text_element, allows_null, output)?;
        }
        if output.len() >= MAX_ARRAY_TEXT_BYTES {
            return None;
        }
    }
    output.push('}');
    Some(())
}

fn read_bounded_element<'a>(reader: &mut Reader<'a>, length: i32) -> Option<&'a [u8]> {
    let length = usize::try_from(length).ok()?;
    if length > MAX_ARRAY_TEXT_BYTES {
        return None;
    }
    reader.take(length)
}

fn append_quoted(output: &mut String, text: &str) -> Option<()> {
    let escapes = text.bytes().filter(|byte| matches!(byte, b'"' | b'\\')).count();
    let length = output
        .len()
        .checked_add(text.len())?
        .checked_add(escapes)?
        .checked_add(2)?;
    if length > MAX_ARRAY_TEXT_BYTES {
        return None;
    }
    output.push('"');
    for character in text.chars() {
        if matches!(character, '"' | '\\') {
            output.push('\\');
        }
        output.push(character);
    }
    output.push('"');
    Some(())
}

fn supported(oid: u32) -> bool {
    matches!(
        oid,
        16 | 17
            | 19
            | 20
            | 21
            | 23
            | 25
            | 26
            | 700
            | 701
            | 1042
            | 1043
            | 1082
            | 1083
            | 1114
            | 1184
            | 1186
            | 1266
            | XML_OID
            | BIT_OID
            | VARBIT_OID
            | 1700
            | 2950
            | MACADDR_OID
            | MACADDR8_OID
            | INET_OID
            | CIDR_OID
            | PG_LSN_OID
    )
}

fn element_text(oid: u32, text_element: bool, bytes: &[u8]) -> Option<String> {
    if text_element {
        return Some(std::str::from_utf8(bytes).ok()?.into());
    }
    Some(match oid {
        16 => match bytes {
            [0] => "f".into(),
            [1] => "t".into(),
            _ => return None,
        },
        17 => format!(
            "\\x{}",
            bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>()
        ),
        19 | 25 | 1042 | 1043 if !bytes.contains(&0) => std::str::from_utf8(bytes).ok()?.into(),
        BIT_OID | VARBIT_OID => {
            crate::decode::decode_pg_binary_text(if oid == BIT_OID { "BIT" } else { "VARBIT" }, bytes)?
        }
        MACADDR_OID => crate::decode::decode_pg_binary_text("MACADDR", bytes)?,
        MACADDR8_OID => crate::decode::decode_pg_binary_text("MACADDR8", bytes)?,
        INET_OID => crate::decode::decode_pg_binary_text("INET", bytes)?,
        CIDR_OID => crate::decode::decode_pg_binary_text("CIDR", bytes)?,
        20 => i64::from_be_bytes(bytes.try_into().ok()?).to_string(),
        21 => i16::from_be_bytes(bytes.try_into().ok()?).to_string(),
        23 => i32::from_be_bytes(bytes.try_into().ok()?).to_string(),
        26 => u32::from_be_bytes(bytes.try_into().ok()?).to_string(),
        700 => {
            let value = f32::from_be_bytes(bytes.try_into().ok()?);
            if value.is_finite() {
                value.to_string()
            } else {
                float_text(f64::from(value))
            }
        }
        701 => float_text(f64::from_be_bytes(bytes.try_into().ok()?)),
        1700 => match crate::numeric::decode_binary(bytes)? {
            Value::Decimal(value) => value.to_string(),
            Value::Text(value) => value,
            _ => return None,
        },
        2950 => uuid::Uuid::from_slice(bytes).ok()?.to_string(),
        PG_LSN_OID => crate::decode::decode_pg_binary_text("PG_LSN", bytes)?,
        1082 | 1083 | 1114 | 1184 | 1186 | 1266 => temporal_element(oid, bytes)?,
        _ => return None,
    })
}

fn temporal_element(oid: u32, bytes: &[u8]) -> Option<String> {
    let value = match oid {
        1082 => crate::temporal::decode_temporal(bytes, "DATE")?,
        1083 | 1266 => crate::temporal::decode_time(bytes, oid == 1266)?,
        1114 => crate::temporal::decode_temporal(bytes, "TIMESTAMP")?,
        1184 => crate::temporal::decode_temporal(bytes, "TIMESTAMPTZ")?,
        1186 => return crate::decode::decode_pg_binary_text("INTERVAL", bytes),
        _ => return None,
    };
    crate::temporal::array_text(value)
}

fn float_text(value: f64) -> String {
    if value.is_nan() {
        "NaN".into()
    } else if value == f64::INFINITY {
        "Infinity".into()
    } else if value == f64::NEG_INFINITY {
        "-Infinity".into()
    } else {
        value.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(values: &[u32]) -> Vec<u8> {
        values.iter().flat_map(|value| value.to_be_bytes()).collect()
    }

    #[test]
    fn value_contract_vectors_render_space_separated_elements_and_refuse_other_headers() {
        let empty = words(&[1, 0, 21, 0, 0]);
        let pair = [words(&[1, 0, 21, 2, 0, 2]), vec![0, 1], words(&[2]), vec![0x80, 0]].concat();
        let oids = [words(&[1, 0, 26, 2, 0, 4, 0, 4]), vec![0xff; 4]].concat();
        assert_eq!(decode_vector(&empty, 21).as_deref(), Some(""));
        assert_eq!(decode_vector(&pair, 21).as_deref(), Some("1 -32768"));
        assert_eq!(decode_vector(&oids, 26).as_deref(), Some("0 4294967295"));
        assert_eq!(decode_vector(&pair, 26), None);
        for header in [
            [0, 0, 21, 0, 0],
            [2, 0, 21, 0, 0],
            [1, 1, 21, 0, 0],
            [1, 0, 21, 0, 1],
            [1, 0, 21, 1, 0],
        ] {
            assert_eq!(decode_vector(&words(&header), 21), None, "{header:?}");
        }
        assert_eq!(decode_vector(&[empty.clone(), vec![0]].concat(), 21), None);
    }

    #[test]
    fn value_contract_vector_capacity_is_bounded_by_element_length_words() {
        assert_eq!(vector_capacity(2, 8), Some(2));
        assert_eq!(vector_capacity(3, 8), None);
        assert_eq!(vector_capacity(usize::MAX, 8), None);
    }

    #[test]
    fn value_contract_temporal_array_elements_reject_malformed_payloads() {
        for (oid, length) in [(1082, 4), (1083, 8), (1114, 8), (1184, 8), (1186, 16), (1266, 12)] {
            for size in 0..24 {
                assert_eq!(
                    temporal_element(oid, &vec![0; size]).is_some(),
                    size == length,
                    "{oid}: {size}"
                );
            }
            assert_eq!(decode_binary(&wire(oid, &[], &[]), oid, false).as_deref(), Some("{}"));
            assert_eq!(
                decode_binary(&wire(oid, &[(1, 1)], &[None]), oid, false).as_deref(),
                Some("{NULL}")
            );
        }
        assert_eq!(temporal_element(9999, &[]), None);
        assert_eq!(temporal_element(1083, &(-1_i64).to_be_bytes()), None);
        assert_eq!(temporal_element(1082, &(i32::MIN + 1).to_be_bytes()), None);
        assert_eq!(temporal_element(1082, &(i32::MAX - 1).to_be_bytes()), None);
        assert_eq!(temporal_element(1114, &(i64::MAX - 1).to_be_bytes()), None);
        assert_eq!(temporal_element(1184, &(i64::MIN + 1).to_be_bytes()), None);
        for (value, text) in [(i32::MIN, "-infinity"), (i32::MAX, "infinity")] {
            assert_eq!(temporal_element(1082, &value.to_be_bytes()).as_deref(), Some(text));
        }
        for oid in [1114, 1184] {
            for (value, text) in [(i64::MIN, "-infinity"), (i64::MAX, "infinity")] {
                assert_eq!(temporal_element(oid, &value.to_be_bytes()).as_deref(), Some(text));
            }
        }
    }

    fn wire(oid: u32, dimensions: &[(i32, i32)], elements: &[Option<&[u8]>]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for word in [dimensions.len() as i32, i32::from(elements.contains(&None)), oid as i32] {
            bytes.extend_from_slice(&word.to_be_bytes());
        }
        for (length, lower) in dimensions {
            bytes.extend_from_slice(&length.to_be_bytes());
            bytes.extend_from_slice(&lower.to_be_bytes());
        }
        for element in elements {
            bytes.extend_from_slice(&element.map_or(-1, |value| value.len() as i32).to_be_bytes());
            if let Some(value) = element {
                bytes.extend_from_slice(value);
            }
        }
        bytes
    }

    #[test]
    fn value_contract_bit_arrays_decode_binary_elements_and_refuse_nul_text() {
        for (oid, value, expected) in [
            (BIT_OID, &[0, 0, 0, 5, 0b1010_0000][..], "{\"10100\"}"),
            (VARBIT_OID, &[0, 0, 0, 3, 0b1010_0000][..], "{\"101\"}"),
        ] {
            assert_eq!(
                decode_binary(&wire(oid, &[(1, 1)], &[Some(value)]), oid, false).as_deref(),
                Some(expected)
            );
        }
        for oid in [19, 25, 1042, 1043] {
            assert_eq!(
                decode_binary(&wire(oid, &[(1, 1)], &[Some(b"a\0b")]), oid, false),
                None,
                "OID {oid}"
            );
        }
    }

    #[test]
    fn value_contract_array_null_empty_and_escaped_text_stay_distinct() {
        assert_eq!(decode_binary(&wire(25, &[], &[]), 25, false).as_deref(), Some("{}"));
        let bytes = wire(
            25,
            &[(5, 1)],
            &[None, Some(b"NULL"), Some(b""), Some(b"a\\\"b"), Some("漢字".as_bytes())],
        );
        assert_eq!(
            decode_binary(&bytes, 25, false).as_deref(),
            Some(r#"{NULL,"NULL","","a\\\"b","漢字"}"#)
        );
        let integer = 1_i32.to_be_bytes();
        let bytes = wire(
            23,
            &[(2, 0), (2, -1)],
            &[Some(&integer), None, Some(&integer), Some(&integer)],
        );
        assert_eq!(
            decode_binary(&bytes, 23, false).as_deref(),
            Some(r#"[0:1][-1:0]={{"1",NULL},{"1","1"}}"#)
        );
    }

    #[test]
    fn value_contract_enum_array_labels_quote_null_text_and_preserve_sql_null() {
        let bytes = wire(
            9001,
            &[(6, 1)],
            &[
                Some(b"NULL"),
                Some(b""),
                Some(b"a,b"),
                Some(b"a\"b"),
                Some("東京".as_bytes()),
                None,
            ],
        );

        assert_eq!(
            decode_binary(&bytes, 9001, true).as_deref(),
            Some(r#"{"NULL","","a,b","a\"b","東京",NULL}"#)
        );
        assert_eq!(element_text(9001, true, &[0xff]), None);
    }

    #[test]
    fn value_contract_pg_lsn_arrays_decode_maximum_and_null_elements() {
        let zero = 0_u64.to_be_bytes();
        let low_max = u64::from(u32::MAX).to_be_bytes();
        let high_one = (1_u64 << 32).to_be_bytes();
        let maximum = u64::MAX.to_be_bytes();
        let bytes = wire(
            PG_LSN_OID,
            &[(5, 0)],
            &[Some(&zero), Some(&low_max), Some(&high_one), Some(&maximum), None],
        );
        assert_eq!(
            decode_binary(&bytes, PG_LSN_OID, false).as_deref(),
            Some("[0:4]={\"0/0\",\"0/FFFFFFFF\",\"1/0\",\"FFFFFFFF/FFFFFFFF\",NULL}")
        );
    }

    #[test]
    fn value_contract_macaddr_arrays_decode_binary_elements_and_sql_null() {
        let mac = [0x08, 0x00, 0x2b, 0x01, 0x02, 0x03];
        let bytes = wire(MACADDR_OID, &[(2, 0)], &[Some(&mac), None]);
        assert_eq!(
            decode_binary(&bytes, MACADDR_OID, false).as_deref(),
            Some(r#"[0:1]={"08:00:2b:01:02:03",NULL}"#)
        );
        assert_eq!(element_text(MACADDR_OID, false, &[0; 5]), None);
    }

    #[test]
    fn value_contract_macaddr8_arrays_decode_eight_octets_null_and_bounds() {
        let mac = [0x08, 0x00, 0x2b, 0x01, 0x02, 0x03, 0x04, 0x05];
        let bytes = wire(MACADDR8_OID, &[(2, 0)], &[Some(&mac), None]);
        assert_eq!(
            decode_binary(&bytes, MACADDR8_OID, false).as_deref(),
            Some(r#"[0:1]={"08:00:2b:01:02:03:04:05",NULL}"#)
        );
        assert_eq!(element_text(MACADDR8_OID, false, &[0; 7]), None);
    }

    #[test]
    fn value_contract_inet_and_cidr_arrays_decode_network_bytes() {
        let ipv4_inet = [2, 24, 0, 4, 192, 0, 2, 1];
        let ipv6_inet = [3, 64, 0, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
        let inet = wire(INET_OID, &[(2, 0)], &[Some(&ipv4_inet), Some(&ipv6_inet)]);
        assert_eq!(
            decode_binary(&inet, INET_OID, false).as_deref(),
            Some(r#"[0:1]={"192.0.2.1/24","2001:db8::1/64"}"#)
        );

        let ipv4_cidr = [2, 24, 1, 4, 192, 0, 2, 0];
        let ipv6_cidr = [3, 32, 1, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let cidr = wire(CIDR_OID, &[(2, -1)], &[Some(&ipv4_cidr), Some(&ipv6_cidr)]);
        assert_eq!(
            decode_binary(&cidr, CIDR_OID, false).as_deref(),
            Some(r#"[-1:0]={"192.0.2.0/24","2001:db8::/32"}"#)
        );
    }

    #[test]
    fn value_contract_domain_array_decodes_elements_by_base_type_oid() {
        let uuid = uuid::Uuid::parse_str("123e4567-e89b-12d3-a456-426614174000").unwrap();
        let bytes = wire(9002, &[(2, 1)], &[Some(uuid.as_bytes()), None]);

        assert_eq!(
            decode_binary_with_oid(&bytes, 9002, 2950, false).as_deref(),
            Some(r#"{"123e4567-e89b-12d3-a456-426614174000",NULL}"#)
        );
        assert_eq!(decode_binary_with_oid(&bytes, 9003, 2950, false), None);
    }

    #[test]
    fn value_contract_malformed_array_dimensions_lengths_types_and_elements_are_refused() {
        let valid = wire(25, &[(1, 1)], &[Some(b"value")]);
        for length in 0..valid.len() {
            assert_eq!(decode_binary(&valid[..length], 25, false), None);
        }
        assert_eq!(decode_binary(&valid, 23, false), None);
        for (offset, word) in [
            (0, -1_i32),
            (0, 7),
            (4, 2),
            (12, 0),
            (12, i32::MAX),
            (20, -2),
            (20, i32::MAX),
        ] {
            let mut bytes = valid.clone();
            bytes[offset..offset + 4].copy_from_slice(&word.to_be_bytes());
            assert_eq!(decode_binary(&bytes, 25, false), None, "{offset}: {word}");
        }
        let mut trailing = valid;
        trailing.push(0);
        assert_eq!(decode_binary(&trailing, 25, false), None);
        let mut forbidden_null = wire(25, &[(1, 1)], &[None]);
        forbidden_null[4..8].copy_from_slice(&0_i32.to_be_bytes());
        assert_eq!(decode_binary(&forbidden_null, 25, false), None);
        for bytes in [
            wire(25, &[(2, i32::MAX)], &[None, None]),
            wire(25, &[(i32::MAX, 1); 6], &[]),
            wire(25, &[(1, 1)], &[Some(&[255])]),
            wire(25, &[(1, 1)], &[Some(b"a\0b")]),
        ] {
            assert_eq!(decode_binary(&bytes, 25, false), None);
        }
        assert_eq!(decode_binary(&wire(9999, &[], &[]), 9999, false), None);
        assert_eq!(element_text(16, false, &[2]), None);
        assert_eq!(element_text(23, false, &[1, 2]), None);
    }

    #[test]
    fn value_contract_array_header_mutations_and_maximum_depth_are_bounded() {
        let bytes = wire(25, &[(1, i32::MIN); 6], &[Some(b"value")]);
        assert!(decode_binary(&bytes, 25, false).is_some());
        for offset in 0..bytes.len() {
            for replacement in [0, 1, 127, 128, 254, 255] {
                let mut mutated = bytes.clone();
                mutated[offset] = replacement;
                let _ = decode_binary(&mutated, 25, false);
            }
        }
        let mut state = 12345_u32;
        for length in 0..128 {
            let mut bytes = vec![0; length];
            for byte in &mut bytes {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                *byte = (state >> 24) as u8;
            }
            let _ = decode_binary(&bytes, 25, false);
        }
    }

    #[test]
    fn value_contract_expanded_array_text_has_an_explicit_size_bound() {
        assert_eq!(MAX_ARRAY_TEXT_BYTES, 16_777_216);
        let mut output = String::new();
        assert!(append_quoted(&mut output, &"x".repeat(MAX_ARRAY_TEXT_BYTES)).is_none());
        assert!(output.is_empty());
        assert!(append_quoted(&mut output, &"\\".repeat(MAX_ARRAY_TEXT_BYTES / 2)).is_none());
        assert!(output.is_empty());
        assert_eq!(append_quoted(&mut output, &"x".repeat(16_777_214)), Some(()));
        assert_eq!(output.len(), 16_777_216);
    }

    #[test]
    fn value_contract_array_wire_limits_are_checked_before_decoding() {
        let payload = vec![b'x'; 16_777_217];
        let mut reader = Reader { remaining: &payload };
        assert_eq!(read_bounded_element(&mut reader, 16_777_217), None);
        assert_eq!(reader.remaining.len(), payload.len());
        assert_eq!(read_bounded_element(&mut reader, 16_777_216).unwrap().len(), 16_777_216);
        assert_eq!(reader.remaining.len(), 1);
        assert_eq!(read_bounded_element(&mut reader, -1), None);
        let bytes = wire(25, &[(2, 1)], &[Some(b"")]);
        let mut reader = Reader {
            remaining: &bytes[12..],
        };
        assert!(read_dimensions(&mut reader, 1).is_none());
    }

    #[test]
    fn value_contract_dimension_product_must_fit_element_length_words() {
        for (payload_bytes, expected) in [(7, false), (8, true)] {
            let mut bytes = words(&[2, 1]);
            bytes.extend(vec![0; payload_bytes]);
            let mut reader = Reader { remaining: &bytes };
            assert_eq!(read_dimensions(&mut reader, 1).is_some(), expected, "{payload_bytes}");
        }
    }
}
