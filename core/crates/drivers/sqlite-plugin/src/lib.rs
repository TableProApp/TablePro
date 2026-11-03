// The core's SQLite driver as a library the app downloads. The same driver linked into the app goes through
// `tablepro_driver_abi::CoreDriver` without these exports.

tablepro_driver_abi::export_driver!(
    tablepro_driver_abi::CoreDriver<tablepro_driver_sqlite::SqliteDriver>,
    c"sqlite"
);

pub type Driver = tablepro_driver_abi::CoreDriver<tablepro_driver_sqlite::SqliteDriver>;
