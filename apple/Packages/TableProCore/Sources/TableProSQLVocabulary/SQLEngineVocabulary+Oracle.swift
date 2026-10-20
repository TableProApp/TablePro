import Foundation

public extension SQLEngineVocabulary {
    // The Oracle plugin's Structure type picker reads these groups too, so the picker and completion cannot disagree.
    static let oracleDataTypeCategories: [(name: String, types: [String])] = [
        ("Integer", ["NUMBER", "INTEGER", "INT", "SMALLINT"]),
        ("Float", ["FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION"]),
        ("String", ["VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "CLOB", "NCLOB", "LONG"]),
        ("Date", [
            "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE",
            "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND"
        ]),
        ("Binary", ["RAW", "LONG RAW", "BLOB", "BFILE"]),
        ("Boolean", ["BOOLEAN"]),
        ("JSON", ["JSON"]),
        ("Vector", ["VECTOR"]),
        ("XML", ["XMLTYPE"]),
        ("Spatial", ["SDO_GEOMETRY"]),
        ("Other", ["ROWID", "UROWID"])
    ]

    static let oracle = SQLEngineVocabulary(
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "LISTAGG",
            "CONCAT", "SUBSTR", "INSTR", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "LPAD", "RPAD",
            "INITCAP", "TRANSLATE",
            "SYSDATE", "SYSTIMESTAMP", "CURRENT_DATE", "CURRENT_TIMESTAMP",
            "ADD_MONTHS", "MONTHS_BETWEEN", "LAST_DAY", "NEXT_DAY",
            "EXTRACT", "TO_DATE", "TO_CHAR", "TO_NUMBER", "TO_TIMESTAMP",
            "TRUNC", "ROUND",
            "CEIL", "FLOOR", "ABS", "POWER", "SQRT", "MOD", "SIGN",
            "NVL", "NVL2", "DECODE", "COALESCE", "NULLIF",
            "GREATEST", "LEAST", "CAST",
            "SYS_GUID", "DBMS_RANDOM.VALUE", "USER", "SYS_CONTEXT"
        ],
        dataTypes: Set(oracleDataTypeCategories.flatMap(\.types)),
        tableOptions: [
            "TABLESPACE", "PCTFREE", "INITRANS"
        ]
    )
}
