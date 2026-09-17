//
//  PluginMetadataRegistry+OracleSystemSchemas.swift
//  TablePro
//

import Foundation

extension PluginMetadataRegistry {
    /// The schemas Oracle creates and maintains itself. The core is the `ORACLE_MAINTAINED = 'Y'` set measured from
    /// `ALL_USERS` on Oracle AI Database 26ai Free; the rest are the predefined accounts the 19c and 11.2 Security
    /// Guides list for options that image leaves out, since `ORACLE_MAINTAINED` only exists from 12.1.0.2. Schemas
    /// named with a release number, such as `APEX_240200`, cannot be listed by name.
    static let oracleSystemSchemaNames: [String] = [
        "ANONYMOUS", "APEX_PUBLIC_USER", "APPQOSSYS", "ASMSNMP", "AUDSYS", "BAASSYS", "CTXSYS",
        "DBSFWUSER", "DBSNMP", "DGPDB_INT", "DIP", "DVF", "DVSYS", "EXFSYS", "FLOWS_FILES",
        "GGSHAREDCAP", "GGSYS", "GSMADMIN_INTERNAL", "GSMCATUSER", "GSMROOTUSER", "GSMUSER", "LBACSYS",
        "MDDATA", "MDSYS", "MGMT_VIEW", "OJVMSYS", "OLAPSYS", "ORACLE_OCM", "ORDDATA", "ORDPLUGINS",
        "ORDSYS", "OUTLN", "OWBSYS", "REMOTE_SCHEDULER_AGENT", "SI_INFORMTN_SCHEMA", "SPATIAL_CSW_ADMIN_USR",
        "SPATIAL_WFS_ADMIN_USR", "SYS", "SYS$UMF", "SYSBACKUP", "SYSDG", "SYSKM", "SYSMAN", "SYSRAC",
        "SYSTEM", "VECSYS", "WKPROXY", "WKSYS", "WK_TEST", "WMSYS", "XDB", "XS$NULL"
    ]
}
