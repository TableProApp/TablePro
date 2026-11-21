//
//  PluginMetadataRegistry+OracleSystemSchemas.swift
//  TablePro
//

import Foundation

extension PluginMetadataRegistry {
    // ORACLE_MAINTAINED on 26ai Free plus the 19c and 11.2 predefined accounts; APEX_240200-style names can't be listed.
    // OraclePlugin's seven lead, in its order, since registration puts a plugin's names before the curated ones.
    static let oracleSystemSchemaNames: [String] = [
        "SYS", "SYSTEM", "OUTLN", "DBSNMP", "APPQOSSYS", "WMSYS", "XDB",
        "ANONYMOUS", "APEX_PUBLIC_USER", "ASMSNMP", "AUDSYS", "BAASSYS", "CTXSYS",
        "DBSFWUSER", "DGPDB_INT", "DIP", "DVF", "DVSYS", "EXFSYS", "FLOWS_FILES",
        "GGSHAREDCAP", "GGSYS", "GSMADMIN_INTERNAL", "GSMCATUSER", "GSMROOTUSER", "GSMUSER", "LBACSYS",
        "MDDATA", "MDSYS", "MGMT_VIEW", "OJVMSYS", "OLAPSYS", "ORACLE_OCM", "ORDDATA", "ORDPLUGINS",
        "ORDSYS", "OWBSYS", "REMOTE_SCHEDULER_AGENT", "SI_INFORMTN_SCHEMA", "SPATIAL_CSW_ADMIN_USR",
        "SPATIAL_WFS_ADMIN_USR", "SYS$UMF", "SYSBACKUP", "SYSDG", "SYSKM", "SYSMAN", "SYSRAC",
        "VECSYS", "WKPROXY", "WKSYS", "WK_TEST", "XS$NULL"
    ]
}
