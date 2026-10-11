pub(crate) fn decode_pg_binary_text(type_name: &str, bytes: &[u8]) -> Option<String> {
    match type_name {
        "INTERVAL" => decode_interval(bytes),
        "BIT" | "VARBIT" => decode_bit_string(bytes),
        "MACADDR" => decode_macaddr(bytes),
        "MACADDR8" => decode_macaddr8(bytes),
        "INET" => decode_inet(bytes, false),
        "CIDR" => decode_inet(bytes, true),
        "PG_LSN" => decode_pg_lsn(bytes),
        _ => None,
    }
}

fn decode_macaddr(bytes: &[u8]) -> Option<String> {
    let [a, b, c, d, e, f] = bytes else {
        return None;
    };
    Some(format!("{a:02x}:{b:02x}:{c:02x}:{d:02x}:{e:02x}:{f:02x}"))
}

fn decode_macaddr8(bytes: &[u8]) -> Option<String> {
    let [a, b, c, d, e, f, g, h] = bytes else {
        return None;
    };
    Some(format!(
        "{a:02x}:{b:02x}:{c:02x}:{d:02x}:{e:02x}:{f:02x}:{g:02x}:{h:02x}"
    ))
}

fn decode_bit_string(bytes: &[u8]) -> Option<String> {
    let bit_length = usize::try_from(i32::from_be_bytes(bytes.get(..4)?.try_into().ok()?)).ok()?;
    let byte_length = bit_length.checked_add(7)? / 8;
    if bytes.len() != 4 + byte_length {
        return None;
    }
    if bit_length % 8 != 0 {
        let unused = 8 - bit_length % 8;
        if bytes[4 + byte_length - 1] & ((1_u8 << unused) - 1) != 0 {
            return None;
        }
    }
    Some(
        (0..bit_length)
            .map(|index| {
                let mask = 1 << (7 - index % 8);
                if bytes[4 + index / 8] & mask == 0 { '0' } else { '1' }
            })
            .collect(),
    )
}

fn decode_interval(bytes: &[u8]) -> Option<String> {
    if bytes.len() != 16 {
        return None;
    }
    let microseconds = i64::from_be_bytes(bytes[0..8].try_into().ok()?);
    let days = i32::from_be_bytes(bytes[8..12].try_into().ok()?);
    let months = i32::from_be_bytes(bytes[12..16].try_into().ok()?);
    Some(format_interval(months, days, microseconds))
}

fn format_interval(months: i32, days: i32, microseconds: i64) -> String {
    let explicit_sign = months < 0 || days < 0 || microseconds < 0;
    let years = months / 12;
    let months = months % 12;
    let mut parts = Vec::new();
    push_counted(&mut parts, years, "year", "years", explicit_sign);
    push_counted(&mut parts, months, "mon", "mons", explicit_sign);
    push_counted(&mut parts, days, "day", "days", explicit_sign);
    if microseconds != 0 || parts.is_empty() {
        parts.push(format_interval_time(microseconds, explicit_sign));
    }
    parts.join(" ")
}

fn push_counted(parts: &mut Vec<String>, count: i32, singular: &str, plural: &str, explicit_sign: bool) {
    if count == 0 {
        return;
    }
    let label = if count.unsigned_abs() == 1 { singular } else { plural };
    let sign = if explicit_sign && count.is_positive() { "+" } else { "" };
    parts.push(format!("{sign}{count} {label}"));
}

fn format_interval_time(microseconds: i64, explicit_sign: bool) -> String {
    let negative = microseconds < 0;
    let magnitude = microseconds.unsigned_abs();
    let hours = magnitude / 3_600_000_000;
    let sign = if negative {
        "-"
    } else if explicit_sign {
        "+"
    } else {
        ""
    };
    if hours > i32::MAX as u64 {
        return format!("{sign}{}.{:06} seconds", magnitude / 1_000_000, magnitude % 1_000_000);
    }
    let remainder = magnitude % 3_600_000_000;
    let minutes = remainder / 60_000_000;
    let remainder = remainder % 60_000_000;
    let seconds = remainder / 1_000_000;
    let micros = remainder % 1_000_000;
    if micros == 0 {
        format!("{sign}{hours:02}:{minutes:02}:{seconds:02}")
    } else {
        let fraction = format!("{micros:06}");
        format!(
            "{sign}{hours:02}:{minutes:02}:{seconds:02}.{}",
            fraction.trim_end_matches('0')
        )
    }
}

fn decode_inet(bytes: &[u8], force_prefix: bool) -> Option<String> {
    let &[family, bits, flags, length, ..] = bytes else {
        return None;
    };
    let length = usize::from(length);
    if bytes.len() != 4 + length {
        return None;
    }
    let address = &bytes[4..];
    let (host, max_bits) = match family {
        2 => {
            let octets: [u8; 4] = address.try_into().ok()?;
            (std::net::Ipv4Addr::from(octets).to_string(), 32)
        }
        3 => {
            let octets: [u8; 16] = address.try_into().ok()?;
            (std::net::Ipv6Addr::from(octets).to_string(), 128)
        }
        _ => return None,
    };
    if u16::from(bits) > max_bits || flags > 1 {
        return None;
    }
    if force_prefix || u16::from(bits) != max_bits {
        Some(format!("{host}/{bits}"))
    } else {
        Some(host)
    }
}

fn decode_pg_lsn(bytes: &[u8]) -> Option<String> {
    let lsn = u64::from_be_bytes(bytes.try_into().ok()?);
    Some(format!("{:X}/{:X}", lsn >> 32, lsn as u32))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_contract_bit_strings_keep_leading_zeroes_and_reject_malformed_wire_values() {
        assert_eq!(
            decode_bit_string(&[0, 0, 0, 10, 0b0010_1101, 0b1000_0000]).as_deref(),
            Some("0010110110")
        );
        assert_eq!(decode_bit_string(&[0, 0, 0, 0]), Some(String::new()));
        assert_eq!(decode_bit_string(&[0, 0, 0, 1, 0b1000_0001]), None);
        assert_eq!(decode_bit_string(&[0, 0, 0, 9, 0b1010_1010]), None);
        assert_eq!(decode_bit_string(&[0xff, 0xff, 0xff, 0xff]), None);
    }

    #[test]
    fn value_contract_macaddr_requires_six_bytes_and_uses_postgres_lowercase_text() {
        assert_eq!(
            decode_pg_binary_text("MACADDR", &[0x08, 0x00, 0x2b, 0x01, 0x02, 0x03]).as_deref(),
            Some("08:00:2b:01:02:03")
        );
        assert_eq!(decode_macaddr(&[0x08, 0x00, 0x2b, 0x01, 0x02]), None);
        assert_eq!(decode_macaddr(&[0x08, 0x00, 0x2b, 0x01, 0x02, 0x03, 0x04]), None);
    }

    #[test]
    fn value_contract_macaddr8_requires_eight_bytes_and_uses_postgres_lowercase_text() {
        assert_eq!(
            decode_pg_binary_text("MACADDR8", &[0x08, 0x00, 0x2b, 0xff, 0xfe, 0x01, 0x02, 0x03]).as_deref(),
            Some("08:00:2b:ff:fe:01:02:03")
        );
        assert_eq!(decode_macaddr8(&[0x08, 0x00, 0x2b, 0xff, 0xfe, 0x01, 0x02]), None);
        assert_eq!(
            decode_macaddr8(&[0x08, 0x00, 0x2b, 0xff, 0xfe, 0x01, 0x02, 0x03, 0x04]),
            None
        );
    }

    #[test]
    fn value_contract_extreme_intervals_and_malformed_network_values_do_not_panic() {
        for days in [i32::MIN, -1, 0, 1, i32::MAX] {
            for micros in [i64::MIN, -1, 0, 1, i64::MAX] {
                assert!(decode_interval(&interval_bytes(i32::MIN, days, micros)).is_some());
            }
        }
        for prefix in 33..=255 {
            assert_eq!(decode_inet(&[2, prefix, 0, 4, 192, 0, 2, 1], false), None);
        }
        for length in 0..64 {
            for byte in 0..=255 {
                for kind in ["INTERVAL", "INET", "CIDR", "PG_LSN"] {
                    let _ = decode_pg_binary_text(kind, &vec![byte; length]);
                }
            }
        }
    }

    fn interval_bytes(months: i32, days: i32, microseconds: i64) -> [u8; 16] {
        let mut bytes = [0_u8; 16];
        bytes[0..8].copy_from_slice(&microseconds.to_be_bytes());
        bytes[8..12].copy_from_slice(&days.to_be_bytes());
        bytes[12..16].copy_from_slice(&months.to_be_bytes());
        bytes
    }

    #[test]
    fn value_contract_interval_extremes_and_mixed_signs_are_unambiguous() {
        for (months, days, micros, expected) in [
            (-1, 2, 3, "-1 mon +2 days +00:00:00.000003"),
            (1, -2, 3, "+1 mon -2 days +00:00:00.000003"),
            (1, 2, -3, "+1 mon +2 days -00:00:00.000003"),
            (0, 0, i64::MIN, "-9223372036854.775808 seconds"),
            (0, 0, i64::MAX, "9223372036854.775807 seconds"),
            (0, 0, i64::from(i32::MAX) * 3_600_000_000, "2147483647:00:00"),
        ] {
            assert_eq!(
                decode_interval(&interval_bytes(months, days, micros)).as_deref(),
                Some(expected)
            );
        }
        for length in 0..32 {
            assert_eq!(decode_interval(&vec![0; length]).is_some(), length == 16);
        }
    }

    #[test]
    fn value_contract_interval_query_duration_matches_postgres_style() {
        assert_eq!(
            decode_pg_binary_text("INTERVAL", &interval_bytes(0, 0, 1_234_567)).as_deref(),
            Some("00:00:01.234567")
        );
        assert_eq!(
            decode_pg_binary_text("INTERVAL", &interval_bytes(0, 0, 3_723_000_000)).as_deref(),
            Some("01:02:03")
        );
        assert_eq!(
            decode_pg_binary_text("INTERVAL", &interval_bytes(0, 3, 0)).as_deref(),
            Some("3 days")
        );
        assert_eq!(
            decode_pg_binary_text(
                "INTERVAL",
                &interval_bytes(14, 3, 4 * 3_600_000_000 + 5 * 60_000_000 + 6_000_000)
            )
            .as_deref(),
            Some("1 year 2 mons 3 days 04:05:06")
        );
        assert_eq!(
            decode_pg_binary_text("INTERVAL", &interval_bytes(0, 0, 0)).as_deref(),
            Some("00:00:00")
        );
        assert_eq!(
            decode_pg_binary_text("INTERVAL", &interval_bytes(0, 0, -3_600_000_000)).as_deref(),
            Some("-01:00:00")
        );
    }

    #[test]
    fn value_contract_inet_and_cidr_use_postgres_text() {
        let inet = [2, 32, 0, 4, 192, 0, 2, 1];
        assert_eq!(decode_pg_binary_text("INET", &inet).as_deref(), Some("192.0.2.1"));
        let cidr = [2, 24, 1, 4, 192, 0, 2, 0];
        assert_eq!(decode_pg_binary_text("CIDR", &cidr).as_deref(), Some("192.0.2.0/24"));
        let mut ipv6 = vec![3, 128, 0, 16];
        ipv6.extend_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        assert_eq!(decode_pg_binary_text("INET", &ipv6).as_deref(), Some("2001:db8::1"));
    }

    #[test]
    fn value_contract_pg_lsn_uses_uppercase_hex() {
        let bytes = 0x0000_0000_016B_3748_u64.to_be_bytes();
        assert_eq!(decode_pg_binary_text("PG_LSN", &bytes).as_deref(), Some("0/16B3748"));
    }

    #[test]
    fn value_contract_unknown_binary_types_stay_undecoded() {
        assert_eq!(decode_pg_binary_text("INT4RANGE", &[1, 2, 3, 4]), None);
        assert_eq!(decode_pg_binary_text("INTERVAL", &[0, 1, 2]), None);
    }

    #[test]
    fn value_contract_bit_wire_lengths_pin_byte_boundaries_and_padding() {
        for (length, payload, expected) in [
            (0_i32, vec![], ""),
            (1, vec![0x80], "1"),
            (7, vec![0xaa], "1010101"),
            (8, vec![0xa5], "10100101"),
            (9, vec![0xa5, 0x80], "101001011"),
            (16, vec![0xa5, 0x5a], "1010010101011010"),
            (17, vec![0xa5, 0x5a, 0x80], "10100101010110101"),
        ] {
            let mut bytes = length.to_be_bytes().to_vec();
            bytes.extend_from_slice(&payload);
            for kind in ["BIT", "VARBIT"] {
                assert_eq!(decode_pg_binary_text(kind, &bytes).as_deref(), Some(expected));
                let mut extra = bytes.clone();
                extra.push(0);
                assert_eq!(decode_pg_binary_text(kind, &extra), None);
                assert_eq!(decode_pg_binary_text(kind, &bytes[..bytes.len() - 1]), None);
            }
        }
        for length in 1..8 {
            for padding_bit in 0..(8 - length) {
                let bytes = [0, 0, 0, length, 0x80 | (1 << padding_bit)];
                assert_eq!(decode_pg_binary_text("VARBIT", &bytes), None);
            }
        }
        for length in 0..4 {
            assert_eq!(decode_pg_binary_text("BIT", &vec![0; length]), None);
        }
    }

    #[test]
    fn value_contract_network_prefixes_families_flags_and_lengths_are_checked() {
        for (prefix, expected) in [(0, "192.0.2.1/0"), (31, "192.0.2.1/31"), (32, "192.0.2.1")] {
            let bytes = [2, prefix, 0, 4, 192, 0, 2, 1];
            assert_eq!(decode_pg_binary_text("INET", &bytes).as_deref(), Some(expected));
        }
        for prefix in [0, 127, 128] {
            let mut bytes = vec![3, prefix, 0, 16];
            bytes.extend_from_slice(&[0; 16]);
            let expected = if prefix == 128 {
                "::".into()
            } else {
                format!("::/{prefix}")
            };
            assert_eq!(decode_pg_binary_text("INET", &bytes), Some(expected));
            bytes[2] = 1;
            assert_eq!(decode_pg_binary_text("CIDR", &bytes), Some(format!("::/{prefix}")));
        }
        let mut ipv6 = vec![3, 129, 0, 16];
        ipv6.extend_from_slice(&[0; 16]);
        assert_eq!(decode_pg_binary_text("INET", &ipv6), None);
        for bytes in [
            vec![],
            vec![2, 32, 0],
            vec![2, 32, 0, 3, 1, 2, 3],
            vec![2, 32, 2, 4, 192, 0, 2, 1],
            vec![4, 32, 0, 4, 192, 0, 2, 1],
            vec![3, 32, 0, 4, 192, 0, 2, 1],
            vec![2, 32, 0, 4, 192, 0, 2, 1, 0],
        ] {
            assert_eq!(decode_pg_binary_text("INET", &bytes), None);
        }
    }

    #[test]
    fn value_contract_lsn_preserves_both_halves_and_requires_eight_bytes() {
        for (value, expected) in [
            (0_u64, "0/0"),
            (u32::MAX as u64, "0/FFFFFFFF"),
            (1_u64 << 32, "1/0"),
            (u64::MAX, "FFFFFFFF/FFFFFFFF"),
        ] {
            assert_eq!(
                decode_pg_binary_text("PG_LSN", &value.to_be_bytes()).as_deref(),
                Some(expected)
            );
        }
        for length in 0..16 {
            assert_eq!(decode_pg_binary_text("PG_LSN", &vec![0; length]).is_some(), length == 8);
        }
    }
}
