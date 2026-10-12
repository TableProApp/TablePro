//! The built-in type OIDs the codecs dispatch on. They are fixed in the
//! PostgreSQL catalog (`pg_type.dat`) and never change between releases,
//! which is why a pattern can name them where postgres-types' `Type`
//! constants cannot appear.

use postgres_protocol::Oid;

pub(crate) const BOOL: Oid = 16;
pub(crate) const BYTEA: Oid = 17;
pub(crate) const CHAR: Oid = 18;
pub(crate) const NAME: Oid = 19;
pub(crate) const INT8: Oid = 20;
pub(crate) const INT2: Oid = 21;
pub(crate) const INT4: Oid = 23;
pub(crate) const REGPROC: Oid = 24;
pub(crate) const TEXT: Oid = 25;
pub(crate) const OID: Oid = 26;
pub(crate) const TID: Oid = 27;
pub(crate) const XID: Oid = 28;
pub(crate) const CID: Oid = 29;
pub(crate) const JSON: Oid = 114;
pub(crate) const XML: Oid = 142;
pub(crate) const POINT: Oid = 600;
pub(crate) const LSEG: Oid = 601;
pub(crate) const PATH: Oid = 602;
pub(crate) const BOX: Oid = 603;
pub(crate) const POLYGON: Oid = 604;
pub(crate) const LINE: Oid = 628;
pub(crate) const CIDR: Oid = 650;
pub(crate) const FLOAT4: Oid = 700;
pub(crate) const FLOAT8: Oid = 701;
pub(crate) const UNKNOWN: Oid = 705;
pub(crate) const CIRCLE: Oid = 718;
pub(crate) const MACADDR8: Oid = 774;
pub(crate) const MONEY: Oid = 790;
pub(crate) const MACADDR: Oid = 829;
pub(crate) const INET: Oid = 869;
pub(crate) const BPCHAR: Oid = 1042;
pub(crate) const VARCHAR: Oid = 1043;
pub(crate) const DATE: Oid = 1082;
pub(crate) const TIME: Oid = 1083;
pub(crate) const TIMESTAMP: Oid = 1114;
pub(crate) const TIMESTAMPTZ: Oid = 1184;
pub(crate) const INTERVAL: Oid = 1186;
pub(crate) const TIMETZ: Oid = 1266;
pub(crate) const BIT: Oid = 1560;
pub(crate) const VARBIT: Oid = 1562;
pub(crate) const NUMERIC: Oid = 1700;
pub(crate) const REGPROCEDURE: Oid = 2202;
pub(crate) const REGOPER: Oid = 2203;
pub(crate) const REGOPERATOR: Oid = 2204;
pub(crate) const REGCLASS: Oid = 2205;
pub(crate) const REGTYPE: Oid = 2206;
pub(crate) const UUID: Oid = 2950;
pub(crate) const PG_LSN: Oid = 3220;
pub(crate) const TSVECTOR: Oid = 3614;
pub(crate) const TSQUERY: Oid = 3615;
pub(crate) const REGCONFIG: Oid = 3734;
pub(crate) const REGDICTIONARY: Oid = 3769;
pub(crate) const JSONB: Oid = 3802;
pub(crate) const REGNAMESPACE: Oid = 4089;
pub(crate) const REGROLE: Oid = 4096;
pub(crate) const REGCOLLATION: Oid = 4191;
pub(crate) const XID8: Oid = 5069;

/// The OID-alias types, whose binary form is the OID they name.
pub(crate) const REG_TYPES: [Oid; 11] = [
    REGPROC,
    REGPROCEDURE,
    REGOPER,
    REGOPERATOR,
    REGCLASS,
    REGTYPE,
    REGCONFIG,
    REGDICTIONARY,
    REGNAMESPACE,
    REGROLE,
    REGCOLLATION,
];

#[cfg(test)]
mod tests {
    use postgres_types::Type;

    use super::*;

    #[test]
    fn the_constants_match_postgres_types() {
        let pairs = [
            (BOOL, Type::BOOL),
            (BYTEA, Type::BYTEA),
            (CHAR, Type::CHAR),
            (NAME, Type::NAME),
            (INT8, Type::INT8),
            (INT2, Type::INT2),
            (INT4, Type::INT4),
            (TEXT, Type::TEXT),
            (OID, Type::OID),
            (TID, Type::TID),
            (XID, Type::XID),
            (JSON, Type::JSON),
            (XML, Type::XML),
            (POINT, Type::POINT),
            (PATH, Type::PATH),
            (BOX, Type::BOX),
            (CIDR, Type::CIDR),
            (FLOAT4, Type::FLOAT4),
            (FLOAT8, Type::FLOAT8),
            (MACADDR8, Type::MACADDR8),
            (MONEY, Type::MONEY),
            (MACADDR, Type::MACADDR),
            (INET, Type::INET),
            (BPCHAR, Type::BPCHAR),
            (VARCHAR, Type::VARCHAR),
            (DATE, Type::DATE),
            (TIME, Type::TIME),
            (TIMESTAMP, Type::TIMESTAMP),
            (TIMESTAMPTZ, Type::TIMESTAMPTZ),
            (INTERVAL, Type::INTERVAL),
            (TIMETZ, Type::TIMETZ),
            (BIT, Type::BIT),
            (VARBIT, Type::VARBIT),
            (NUMERIC, Type::NUMERIC),
            (REGCLASS, Type::REGCLASS),
            (UUID, Type::UUID),
            (PG_LSN, Type::PG_LSN),
            (TSVECTOR, Type::TS_VECTOR),
            (JSONB, Type::JSONB),
            (XID8, Type::XID8),
        ];
        for (oid, ty) in pairs {
            assert_eq!(oid, ty.oid(), "{ty}");
        }
    }
}
