//! Driving a TablePro started on the test's own session bus.

use std::collections::HashMap;
use std::process::{Child, ExitStatus};
use std::time::{Duration, Instant};

use gio::prelude::*;

const APP_ID: &str = tablepro_app::config::APP_ID;
/// Long enough for a cold start under a loaded CI runner.
pub const WAIT: Duration = Duration::from_secs(30);
pub const CALL_TIMEOUT_MS: i32 = 5_000;

pub fn connect(address: &str) -> Result<gio::DBusConnection, String> {
    gio::DBusConnection::for_address_sync(
        address,
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        gio::Cancellable::NONE,
    )
    .map_err(|error| format!("could not connect to the test bus: {error}"))
}

pub fn activate(connection: &gio::DBusConnection, path: &str, action: &str) -> Result<(), String> {
    let no_parameter: Vec<glib::Variant> = Vec::new();
    let platform_data: HashMap<String, glib::Variant> = HashMap::new();
    let arguments = (action, no_parameter, platform_data).to_variant();
    connection
        .call_sync(
            Some(APP_ID),
            path,
            "org.gtk.Actions",
            "Activate",
            Some(&arguments),
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .map(drop)
        .map_err(|error| format!("{action} at {path} over D-Bus failed: {error}"))
}

pub fn name_has_owner(connection: &gio::DBusConnection) -> bool {
    connection
        .call_sync(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            Some(&(APP_ID,).to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.get::<(bool,)>())
        .is_some_and(|(owned,)| owned)
}

/// GtkApplication exports each window's actions at
/// `<object path>/window/<id>`, so the children of that node are the
/// open windows.
pub fn window_ids(connection: &gio::DBusConnection) -> Vec<String> {
    let Some((xml,)) = connection
        .call_sync(
            Some(APP_ID),
            &format!("{}/window", object_path()),
            "org.freedesktop.DBus.Introspectable",
            "Introspect",
            None,
            None,
            gio::DBusCallFlags::NONE,
            CALL_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.get::<(String,)>())
    else {
        return Vec::new();
    };
    xml.split("<node name=\"")
        .skip(1)
        .filter_map(|rest| rest.split('"').next())
        .map(str::to_owned)
        .collect()
}

/// GApplication's object path: the id with dots as slashes.
pub fn object_path() -> String {
    format!("/{}", APP_ID.replace('.', "/").replace('-', "_"))
}

pub fn wait_for_exit(child: &mut Child) -> Result<ExitStatus, String> {
    let deadline = Instant::now() + WAIT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("tablepro did not exit within {WAIT:?}"));
            }
            Err(error) => return Err(format!("could not wait for tablepro: {error}")),
        }
    }
}

pub fn wait_until(what: &str, mut ready: impl FnMut() -> bool) -> Result<(), String> {
    let deadline = Instant::now() + WAIT;
    while !ready() {
        if Instant::now() >= deadline {
            return Err(format!("timed out waiting for {what}"));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

pub fn wait_until_owned(address: &str) -> Result<(), String> {
    let connection = connect(address)?;
    wait_until("the application to own its name", || name_has_owner(&connection))
}
