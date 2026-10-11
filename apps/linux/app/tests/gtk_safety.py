#!/usr/bin/env python3
import ctypes
import csv
import hashlib
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pyatspi
import gtk_workbook
import gtk_parameters
import gtk_xml
import gtk_ux
import gtk_input
import gtk_shard

APP_NAME = "BookiE"
CONNECTION_NAME = "Safety SQLite"
CONNECTION_B_NAME = "Safety SQLite B"
BROKEN_CONNECTION_NAME = "Broken SQLite"
MYSQL_CONNECTION_NAME = "Safety MySQL"
MYSQL_CONNECTION_ID = "c38e2d93-4314-4c18-b192-08f164386e09"
MONGODB_CONNECTION_NAME = "Safety MongoDB"
MONGODB_CONNECTION_ID = "d87c89b2-3e9c-4c36-9662-c75c69f513ab"
CLICKHOUSE_CONNECTION_NAME = "Safety ClickHouse"
CLICKHOUSE_CONNECTION_ID = "31e33a85-4cbd-42ec-8f54-c66be5630f17"
POSTGRES_CONNECTION_NAME = "Safety PostgreSQL"
POSTGRES_CONNECTION_ID = "0b6d4a52-3d1a-4f0e-8f6c-5f3f0c2a9e11"
POSTGRES_MTLS_CONNECTION_NAME = "PostgreSQL mTLS"
POSTGRES_MTLS_CONNECTION_ID = "02a95df6-b1bb-419d-9a15-8d484ba729c3"
POSTGRES_SSH_AUDIT_CONNECTION_NAME = "PostgreSQL SSH audit refusal"
POSTGRES_SSH_AUDIT_CONNECTION_ID = "1c971938-9732-433e-a9bf-ae64e94794da"
POSTGRES_SSH_SETUP_FAILURE_CONNECTION_NAME = "PostgreSQL SSH setup failure"
POSTGRES_SSH_SETUP_FAILURE_CONNECTION_ID = "ee8f8451-05cf-4c21-8c7f-f37c8c96e251"
MCP_DISCONNECT_TEST_TOKEN = "bookie-gtk-mcp-disconnect-test-token"
MCP_HTTP_PORT = int(os.environ.get("TABLEPRO_TEST_MCP_HTTP_PORT", "17432"))
WAIT_SECONDS = float(os.environ.get("TABLEPRO_GTK_WAIT_SECONDS", "15"))
POLL_SECONDS = 0.05
FILE_CHOOSER_ROLES = (pyatspi.ROLE_FILE_CHOOSER, pyatspi.ROLE_DIALOG)
SWITCH_ROLES = tuple(
    role
    for role in (getattr(pyatspi, "ROLE_SWITCH", None), pyatspi.ROLE_TOGGLE_BUTTON, pyatspi.ROLE_CHECK_BOX)
    if role is not None
)
PASSPHRASE_ROLES = (pyatspi.ROLE_PASSWORD_TEXT, pyatspi.ROLE_TEXT)
SETTLE_SECONDS = 3.0


def storage_dir_name():
    return os.environ.get("TABLEPRO_GTK_STORAGE_DIR", "tablepro")


def descendants(node):
    yield node
    try:
        children = list(node)
    except Exception:
        return
    for child in children:
        yield from descendants(child)


def node_name(node):
    try:
        return node.name or ""
    except Exception:
        return ""


def node_role(node):
    try:
        return node.getRole()
    except Exception:
        return pyatspi.ROLE_INVALID


def role_matches(node, role):
    if role is None:
        return True
    if isinstance(role, tuple):
        return node_role(node) in role
    return node_role(node) == role


def application_node():
    desktop = pyatspi.Registry.getDesktop(0)
    for application in desktop:
        names = {node_name(application)}
        names.update(node_name(node) for node in descendants(application))
        if APP_NAME in names or any(CONNECTION_NAME in name for name in names):
            return application
    return None


def desktop_applications():
    return list(pyatspi.Registry.getDesktop(0))


def find_node(name=None, role=None):
    for application in desktop_applications():
        for node in descendants(application):
            if name is not None and node_name(node) != name:
                continue
            if not role_matches(node, role):
                continue
            return node
    return None


def find_within(root, name=None, role=None):
    for node in descendants(root):
        if name is not None and node_name(node) != name:
            continue
        if not role_matches(node, role):
            continue
        return node
    return None


def wait_within(root, name=None, role=None, present=True, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        node = find_within(root, name=name, role=role)
        if (node is not None) == present:
            return node
        time.sleep(POLL_SECONDS)
    expectation = "appear" if present else "disappear"
    raise AssertionError(
        f"expected {name!r} to {expectation} inside {node_name(root)!r}:\n{accessible_snapshot()}"
    )


def invoke_named_action(anchor_lookup, anchor_name, action_name):
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        anchor = anchor_lookup()
        if anchor is not None:
            for node in descendants(anchor):
                if node_name(node) == action_name:
                    try:
                        invoke(node)
                        return
                    except AssertionError:
                        break
        time.sleep(POLL_SECONDS)
    raise AssertionError(
        f"no action {action_name!r} within {anchor_name!r}:\n{accessible_snapshot()}"
    )


def invoke_named_action_within_node(root, anchor_name, action_name):
    invoke_named_action(
        lambda: find_within(root, name=anchor_name, role=pyatspi.ROLE_LIST_ITEM),
        anchor_name,
        action_name,
    )


def set_editor_text_within(root, sql):
    candidates = []
    for node in descendants(root):
        if node_role(node) != pyatspi.ROLE_TEXT:
            continue
        try:
            editable = node.queryEditableText()
            candidates.append((node, editable))
        except Exception:
            continue
    if not candidates:
        raise AssertionError(f"no SQL editor inside {node_name(root)!r}:\n{accessible_snapshot()}")
    node, editable = max(candidates, key=lambda candidate: candidate[0].queryText().characterCount)
    editable.setTextContents(sql)
    return node


def run_sql_within(root, sql):
    set_editor_text_within(root, sql)
    invoke(wait_within(root, name="Run", role=pyatspi.ROLE_PUSH_BUTTON))


def find_node_containing(text, role=None):
    for application in desktop_applications():
        for node in descendants(application):
            if not role_matches(node, role):
                continue
            if text in node_name(node):
                return node
    return None


def wait_for_node_containing(text, role=None, present=True, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        node = find_node_containing(text, role=role)
        if (node is not None) == present:
            return node
        time.sleep(POLL_SECONDS)
    expectation = "appear" if present else "disappear"
    raise AssertionError(
        f"expected an accessible name containing {text!r} to {expectation}:\n{accessible_snapshot()}"
    )


def find_frame_containing(text):
    for application in desktop_applications():
        for node in descendants(application):
            if node_role(node) != pyatspi.ROLE_FRAME:
                continue
            if text in node_name(node):
                return node
    return None


def wait_for_frame_containing(text, present=True, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        node = find_frame_containing(text)
        if (node is not None) == present:
            return node
        time.sleep(POLL_SECONDS)
    expectation = "appear" if present else "disappear"
    raise AssertionError(
        f"expected a window title containing {text!r} to {expectation}:\n{accessible_snapshot()}"
    )


def accessible_snapshot():
    applications = desktop_applications()
    if not applications:
        return "application unavailable"
    entries = []
    for application in applications:
        for node in descendants(application):
            name = node_name(node)
            if not name:
                continue
            try:
                role_name = node.getRoleName()
            except Exception:
                role_name = "unknown"
            try:
                extents = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                bounds = f" [{extents.x},{extents.y} {extents.width}x{extents.height}]"
            except Exception:
                bounds = ""
            try:
                action = node.queryAction()
                actions = f" actions={[action.getName(index) for index in range(action.nActions)]}"
            except Exception:
                actions = ""
            entries.append(f"{role_name}: {name}{bounds}{actions}")
    return "\n".join(entries)


def wait_for_node(name=None, role=None, present=True, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        node = find_node(name=name, role=role)
        if (node is not None) == present:
            return node
        time.sleep(POLL_SECONDS)
    expectation = "appear" if present else "disappear"
    raise AssertionError(f"expected accessible node {name!r} to {expectation}:\n{accessible_snapshot()}")


def invoke(node):
    candidates = []
    candidate = node
    for _ in range(3):
        if candidate is None:
            break
        candidates.append(candidate)
        try:
            candidate = candidate.parent
        except Exception:
            break
    for candidate in candidates:
        try:
            action = candidate.queryAction()
            for index in range(action.nActions):
                action_name = action.getName(index).lower()
                if action_name in {"click", "activate", "press", "toggle", "default.activate"} and action.doAction(index):
                    return
        except Exception:
            continue
    raise AssertionError(f"no invokable action for {node_name(node)!r}")


def invoke_export_file_chooser_response():
    button = find_node(name="Choose File…", role=pyatspi.ROLE_PUSH_BUTTON)
    if button is not None:
        invoke(button)
        return

    dialog = wait_for_node(name="Export connections", role=pyatspi.ROLE_ALERT)
    try:
        actions = dialog.queryAction()
        names = [actions.getName(index) for index in range(actions.nActions)]
    except Exception as error:
        raise AssertionError("export dialog has no accessible default response") from error
    assert "default.activate" in names, (
        "export dialog did not expose its default Choose File response: "
        f"{names!r}"
    )
    invoke(dialog)


def invoke_named_action_within(anchor_name, action_name):
    invoke_named_action(
        lambda: find_node(name=anchor_name, role=pyatspi.ROLE_LIST_ITEM),
        anchor_name,
        action_name,
    )


def invoke_accessible_action(action_name):
    applications = desktop_applications()
    if not applications:
        raise AssertionError("application unavailable")
    for application in applications:
        for node in descendants(application):
            try:
                actions = node.queryAction()
                for index in range(actions.nActions):
                    if actions.getName(index) == action_name and actions.doAction(index):
                        return
            except Exception:
                continue
    raise AssertionError(f"no accessible action {action_name!r}:\n{accessible_snapshot()}")


def press_x11_key(name, modifiers=(), presses=1):
    if gtk_input.uses_atspi_input():
        gtk_input.press_key(name, modifiers, presses)
        return
    class XWindowAttributes(ctypes.Structure):
        _fields_ = [
            ("x", ctypes.c_int),
            ("y", ctypes.c_int),
            ("width", ctypes.c_int),
            ("height", ctypes.c_int),
            ("border_width", ctypes.c_int),
            ("depth", ctypes.c_int),
            ("visual", ctypes.c_void_p),
            ("root", ctypes.c_ulong),
            ("window_class", ctypes.c_int),
            ("bit_gravity", ctypes.c_int),
            ("win_gravity", ctypes.c_int),
            ("backing_store", ctypes.c_int),
            ("backing_planes", ctypes.c_ulong),
            ("backing_pixel", ctypes.c_ulong),
            ("save_under", ctypes.c_int),
            ("colormap", ctypes.c_ulong),
            ("map_installed", ctypes.c_int),
            ("map_state", ctypes.c_int),
            ("all_event_masks", ctypes.c_long),
            ("your_event_mask", ctypes.c_long),
            ("do_not_propagate_mask", ctypes.c_long),
            ("override_redirect", ctypes.c_int),
            ("screen", ctypes.c_void_p),
        ]

    x11 = ctypes.CDLL("libX11.so.6")
    xtst = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
    x11.XStringToKeysym.restype = ctypes.c_ulong
    x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XKeysymToKeycode.restype = ctypes.c_uint
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XQueryTree.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
        ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XWindowAttributes)]
    x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    display = x11.XOpenDisplay(None)
    if not display:
        raise AssertionError("X11 display is unavailable")
    try:
        keysym = x11.XStringToKeysym(name.encode("ascii"))
        keycode = x11.XKeysymToKeycode(display, keysym)
        if keycode == 0:
            raise AssertionError(f"X11 key is unavailable: {name}")
        root = x11.XDefaultRootWindow(display)
        returned_root = ctypes.c_ulong()
        returned_parent = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        child_count = ctypes.c_uint()
        status = x11.XQueryTree(
            display,
            root,
            ctypes.byref(returned_root),
            ctypes.byref(returned_parent),
            ctypes.byref(children),
            ctypes.byref(child_count),
        )
        if status == 0 or child_count.value == 0:
            raise AssertionError("X11 application window is unavailable")
        try:
            focus_window = None
            for index in range(child_count.value - 1, -1, -1):
                attributes = XWindowAttributes()
                if x11.XGetWindowAttributes(display, children[index], ctypes.byref(attributes)) and attributes.map_state == 2:
                    focus_window = children[index]
                    break
            if focus_window is None:
                raise AssertionError("viewable X11 application window is unavailable")
            x11.XSetInputFocus(display, focus_window, 2, 0)
        finally:
            x11.XFree(children)
        modifier_codes = []
        for modifier in modifiers:
            modifier_keysym = x11.XStringToKeysym(modifier.encode("ascii"))
            modifier_code = x11.XKeysymToKeycode(display, modifier_keysym)
            if modifier_code == 0:
                raise AssertionError(f"X11 modifier is unavailable: {modifier}")
            modifier_codes.append(modifier_code)
        for modifier_code in modifier_codes:
            xtst.XTestFakeKeyEvent(display, modifier_code, 1, 0)
        for _ in range(presses):
            xtst.XTestFakeKeyEvent(display, keycode, 1, 0)
            xtst.XTestFakeKeyEvent(display, keycode, 0, 0)
        for modifier_code in reversed(modifier_codes):
            xtst.XTestFakeKeyEvent(display, modifier_code, 0, 0)
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)


def set_editor_text(sql):
    application = application_node()
    if application is None:
        raise AssertionError("application is not available")
    candidates = []
    for node in descendants(application):
        if node_role(node) != pyatspi.ROLE_TEXT:
            continue
        try:
            editable = node.queryEditableText()
            candidates.append((node, editable))
        except Exception:
            continue
    if not candidates:
        raise AssertionError("SQL editor text control was not found")
    node, editable = max(candidates, key=lambda candidate: candidate[0].queryText().characterCount)
    editable.setTextContents(sql)
    return node


def database_row_count(path):
    with sqlite3.connect(path) as connection:
        return connection.execute("SELECT COUNT(*) FROM safety_items").fetchone()[0]


def wait_for_database_count(path, expected, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if database_row_count(path) == expected:
            return
        time.sleep(POLL_SECONDS)
    actual = database_row_count(path)
    raise AssertionError(f"expected {expected} database rows, found {actual}")


def assert_database_count_stable(path, expected, seconds=SETTLE_SECONDS):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        actual = database_row_count(path)
        if actual != expected:
            raise AssertionError(f"expected {expected} database rows for {seconds}s, found {actual}")
        time.sleep(POLL_SECONDS)


def set_text_by_name(name, text, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for application in desktop_applications():
            for node in descendants(application):
                if node_name(node) != name or node_role(node) not in {
                    pyatspi.ROLE_TEXT, pyatspi.ROLE_PASSWORD_TEXT,
                }:
                    continue
                try:
                    editable = node.queryEditableText()
                except Exception:
                    continue
                editable.setTextContents(text)
                return
        time.sleep(POLL_SECONDS)
    raise AssertionError(f"no editable text control named {name!r}:\n{accessible_snapshot()}")


def set_visible_editable_within(anchor_name, anchor_role, text, action_name="Save"):
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        anchor = find_node(name=anchor_name, role=anchor_role)
        if anchor is not None and find_within(anchor, name=action_name, role=pyatspi.ROLE_PUSH_BUTTON):
            for node in descendants(anchor):
                try:
                    extents = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
                    if extents.width <= 1 or extents.height <= 1:
                        continue
                    editable = node.queryEditableText()
                    editable.setTextContents(text)
                    return node
                except Exception:
                    continue
        time.sleep(POLL_SECONDS)
    raise AssertionError(f"no visible editable control within {anchor_name!r}:\n{accessible_snapshot()}")


def show_file_chooser_location(chooser):
    # The chooser window may be visible before its inner GTK widget has
    # registered its AT-SPI action. Wait briefly for it, then use the standard
    # shortcut on builds that omit the action entirely.
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        for node in descendants(chooser):
            try:
                actions = node.queryAction()
            except Exception:
                continue
            for index in range(actions.nActions):
                if actions.getName(index) == "show_location" and actions.doAction(index):
                    return
        time.sleep(POLL_SECONDS)
    press_x11_key("l", ("Control_L",))


def choose_import_bundle(path):
    invoke_accessible_action("welcome.import-bundle")
    chooser = wait_for_node(name="Import connections", role=FILE_CHOOSER_ROLES)
    show_file_chooser_location(chooser)
    location = set_visible_editable_within(
        "Import connections", FILE_CHOOSER_ROLES, str(path), action_name="Open",
    )
    invoke(location)
    open_button = wait_within(chooser, name="Open", role=pyatspi.ROLE_PUSH_BUTTON)
    deadline = time.monotonic() + WAIT_SECONDS
    while not open_button.getState().contains(pyatspi.STATE_SENSITIVE) and time.monotonic() < deadline:
        time.sleep(POLL_SECONDS)
    if not open_button.getState().contains(pyatspi.STATE_SENSITIVE):
        raise AssertionError(f"GTK chooser did not resolve the bundle path {str(path)!r}")
    invoke(open_button)


def database_ids(path):
    with sqlite3.connect(path) as connection:
        return [row[0] for row in connection.execute("SELECT id FROM safety_items ORDER BY id")]


def database_tables(path):
    with sqlite3.connect(path) as connection:
        return {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }


def write_fixture(base, audit_available=True, environment="prod", mcp_token=False):
    home = base / "home"
    config = base / "config"
    data = base / "data"
    cache = base / "cache"
    state = base / "state"
    runtime = base / "runtime"
    for directory in [home, config, cache, state, runtime]:
        directory.mkdir(parents=True)
    runtime.chmod(0o700)
    if audit_available:
        data.mkdir(parents=True)
    else:
        data.write_text("audit unavailable", encoding="utf-8")

    database = base / "safety.sqlite"
    database_b = base / "safety-b.sqlite"
    # `note` is the only editable column: `id` is the primary key, which
    # inline editing refuses. Scenarios that only count or list ids are
    # unaffected because it is nullable.
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE safety_items (id INTEGER PRIMARY KEY, note TEXT)")
    with sqlite3.connect(database_b) as connection:
        connection.execute("CREATE TABLE safety_items (id INTEGER PRIMARY KEY, note TEXT)")

    tablepro_config = config / storage_dir_name()
    tablepro_config.mkdir(parents=True)
    if mcp_token:
        token_config = config / "tablepro"
        token_config.mkdir(parents=True, exist_ok=True)
        token_path = token_config / "mcp-tokens.json"
        token_path.write_text(
            json.dumps(
                [
                    {
                        "id": "c001e8dc-42d0-46eb-9b3c-b34d96d27ec9",
                        "name": "GTK disconnect acceptance",
                        "token_hash": hashlib.sha256(MCP_DISCONNECT_TEST_TOKEN.encode("utf-8")).hexdigest(),
                        "permissions": "read_write",
                        "connection_allowlist": ["d4f5e246-c40a-4a30-90f2-39e93e94d920"],
                        "created_at": "2026-10-09T00:00:00Z",
                        "expires_at": None,
                        "revoked": False,
                    }
                ]
            ),
            encoding="utf-8",
        )
        token_path.chmod(0o600)
    connections = {
        "version": 1,
        "connections": [
            {
                "id": "d4f5e246-c40a-4a30-90f2-39e93e94d920",
                "name": CONNECTION_NAME,
                "driver_id": "sqlite",
                "host": "",
                "port": 0,
                "database": str(database),
                "username": "",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            },
            {
                "id": "66a8b513-d771-4fe7-8ee0-ec1099254cb1",
                "name": CONNECTION_B_NAME,
                "driver_id": "sqlite",
                "host": "",
                "port": 0,
                "database": str(database_b),
                "username": "",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            },
            {
                "id": "6ff0268f-84cc-44f5-aeb4-a5d7609fb0fc",
                "name": BROKEN_CONNECTION_NAME,
                "driver_id": "sqlite",
                "host": "",
                "port": 0,
                "database": str(base / "missing" / "broken.sqlite"),
                "username": "",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            }
        ],
    }
    mysql_port = os.environ.get("TABLEPRO_GTK_MYSQL_PORT")
    if mysql_port:
        connections["connections"].append(
            {
                "id": MYSQL_CONNECTION_ID,
                "name": MYSQL_CONNECTION_NAME,
                "driver_id": "mysql",
                "host": os.environ.get("TABLEPRO_GTK_MYSQL_HOST", "127.0.0.1"),
                "port": int(mysql_port),
                "database": "bookie_test",
                "username": "root",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            }
        )
    mongodb_port = os.environ.get("TABLEPRO_GTK_MONGODB_PORT")
    if mongodb_port:
        connections["connections"].append(
            {
                "id": MONGODB_CONNECTION_ID,
                "name": MONGODB_CONNECTION_NAME,
                "driver_id": "mongodb",
                "host": os.environ.get("TABLEPRO_GTK_MONGODB_HOST", "127.0.0.1"),
                "port": int(mongodb_port),
                "database": "bookie_test",
                "username": "",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            }
        )
    clickhouse_port = os.environ.get("TABLEPRO_GTK_CLICKHOUSE_PORT")
    if clickhouse_port:
        connections["connections"].append(
            {
                "id": CLICKHOUSE_CONNECTION_ID,
                "name": CLICKHOUSE_CONNECTION_NAME,
                "driver_id": "clickhouse",
                "host": os.environ.get("TABLEPRO_GTK_CLICKHOUSE_HOST", "127.0.0.1"),
                "port": int(clickhouse_port),
                "database": "default",
                "username": "default",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            }
        )
    postgres_port = os.environ.get("TABLEPRO_GTK_POSTGRES_PORT")
    if postgres_port:
        connections["connections"].append(
            {
                "id": POSTGRES_CONNECTION_ID,
                "name": POSTGRES_CONNECTION_NAME,
                "driver_id": "postgres",
                "host": os.environ.get("TABLEPRO_GTK_POSTGRES_HOST", "127.0.0.1"),
                "port": int(postgres_port),
                "database": "bookie_test",
                "username": "postgres",
                "use_tls": False,
                "tls_mode": "disabled",
                "read_only": False,
                "auth_mode": "password",
                "environment": environment,
            }
        )
    postgres_mtls_port = os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_PORT")
    if postgres_mtls_port:
        connections["connections"].append(
            {
                "id": POSTGRES_MTLS_CONNECTION_ID,
                "name": POSTGRES_MTLS_CONNECTION_NAME,
                "driver_id": "postgres",
                "host": os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_HOST", "localhost"),
                "port": int(postgres_mtls_port),
                "database": os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_DB", "tablepro"),
                "username": os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_USER", "tablepro_mtls"),
                "use_tls": True,
                "tls_mode": "verify_full",
                "tls_root_cert": os.environ["TABLEPRO_GTK_POSTGRES_MTLS_CA"],
                "tls_client_cert": os.environ["TABLEPRO_GTK_POSTGRES_MTLS_CERT"],
                "tls_client_key": os.environ["TABLEPRO_GTK_POSTGRES_MTLS_KEY"],
                "read_only": True,
                "auth_mode": "password",
                "environment": environment,
            }
        )
        password = os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_PASSWORD")
        if password:
            subprocess.run(
                [
                    "secret-tool",
                    "store",
                    "--label=BookiE GTK PostgreSQL mTLS fixture",
                    "xdg:schema",
                    "com.tablepro.linux.Password",
                    "connection-id",
                    POSTGRES_MTLS_CONNECTION_ID,
                    "kind",
                    "db_password",
                ],
                input=password,
                text=True,
                check=True,
                capture_output=True,
            )
    postgres_ssh_audit_port = os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_PORT")
    if postgres_ssh_audit_port:
        ssh_audit = {
            "host": os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_HOST", "127.0.0.1"),
            "port": int(postgres_ssh_audit_port),
            "username": os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_USER", "tunnel"),
            "auth": {
                "kind": "private_key",
                "path": os.environ["TABLEPRO_GTK_POSTGRES_SSH_AUDIT_KEY"],
                "has_passphrase": False,
            },
        }
        second_hop = os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_HOST")
        if second_hop:
            ssh_audit["jump"] = {
                "host": second_hop,
                "port": int(os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_PORT", "22")),
                "username": os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_USER", "tunnel"),
                "auth": {
                    "kind": "private_key",
                    "path": os.environ["TABLEPRO_GTK_POSTGRES_SSH_AUDIT_KEY"],
                    "has_passphrase": False,
                },
            }
        connections["connections"].append(
            {
                "id": POSTGRES_SSH_AUDIT_CONNECTION_ID,
                "name": POSTGRES_SSH_AUDIT_CONNECTION_NAME,
                "driver_id": "postgres",
                "host": os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_DB_HOST", "db.tablepro.test"),
                "port": int(os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_DB_PORT", "5432")),
                "database": "tablepro",
                "username": "tablepro",
                "use_tls": True,
                "tls_mode": "verify_full",
                "tls_root_cert": os.environ["TABLEPRO_GTK_POSTGRES_SSH_AUDIT_CA"],
                "tls_client_cert": None,
                "tls_client_key": None,
                "read_only": os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_READ_ONLY", "true").lower() != "false",
                "auth_mode": "password",
                "environment": environment,
                "ssh": ssh_audit,
            }
        )
        password = os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_PASSWORD")
        if password:
            subprocess.run(
                [
                    "secret-tool",
                    "store",
                    "--label=BookiE GTK PostgreSQL SSH audit fixture",
                    "xdg:schema",
                    "com.tablepro.linux.Password",
                    "connection-id",
                    POSTGRES_SSH_AUDIT_CONNECTION_ID,
                    "kind",
                    "db_password",
                ],
                input=password,
                text=True,
                check=True,
                capture_output=True,
            )
        setup_failure = json.loads(json.dumps(connections["connections"][-1]))
        setup_failure["id"] = POSTGRES_SSH_SETUP_FAILURE_CONNECTION_ID
        setup_failure["name"] = POSTGRES_SSH_SETUP_FAILURE_CONNECTION_NAME
        setup_failure["ssh"]["port"] = 1
        connections["connections"].append(setup_failure)
        if password:
            subprocess.run(
                [
                    "secret-tool",
                    "store",
                    "--label=BookiE GTK PostgreSQL SSH setup failure fixture",
                    "xdg:schema",
                    "com.tablepro.linux.Password",
                    "connection-id",
                    POSTGRES_SSH_SETUP_FAILURE_CONNECTION_ID,
                    "kind",
                    "db_password",
                ],
                input=password,
                text=True,
                check=True,
                capture_output=True,
            )
    (tablepro_config / "connections.json").write_text(json.dumps(connections), encoding="utf-8")
    (tablepro_config / "preferences.json").write_text(
        json.dumps(
            {
                "default_page_size": 100,
                "confirm_destructive": True,
                "editor_font_size": 12,
                "history_retention_days": 30,
                "query_timeout_secs": 60,
            }
        ),
        encoding="utf-8",
    )

    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(config),
            "XDG_DATA_HOME": str(data),
            "XDG_CACHE_HOME": str(cache),
            "XDG_STATE_HOME": str(state),
            "XDG_RUNTIME_DIR": str(runtime),
            "GSETTINGS_BACKEND": "keyfile",
            "RUST_LOG": "tablepro_app=debug",
            **gtk_input.display_environment(),
        }
    )
    return database, environment


def start_application(binary, environment, restored=False):
    environment["G_DEBUG"] = "fatal-criticals"
    process = subprocess.Popen(
        [str(binary)],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        if restored == "empty":
            wait_for_node(name="BookiE", role=pyatspi.ROLE_FRAME)
        elif restored == "welcome":
            wait_for_node(name=CONNECTION_NAME)
        elif restored:
            wait_for_frame_containing(" — BookiE")
        else:
            wait_for_node(name=CONNECTION_NAME)
        return process
    except Exception:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise AssertionError(f"application did not expose its expected window: {stderr}")


def stop_application(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    stderr = process.stderr.read() if process.stderr is not None else ""
    if process.returncode not in {0, -signal.SIGTERM}:
        raise AssertionError(f"application exited with {process.returncode}: {stderr}")
    return stderr


def open_editor():
    invoke_named_action_within(CONNECTION_NAME, "Open connection")
    invoke(wait_for_node(name="Open SQL editor"))
    wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)


def run_sql(sql):
    set_editor_text(sql)
    invoke(wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON))


def run_scenario(binary, scenario):
    base = Path(tempfile.mkdtemp(prefix=f"tablepro-{scenario.__name__}-"))
    process = None
    failure = None
    stderr = ""
    try:
        database, environment = write_fixture(
            base,
            audit_available=getattr(scenario, "audit_available", True),
            environment=getattr(scenario, "environment", "prod"),
            mcp_token=getattr(scenario, "mcp_token", False),
        )
        process = start_application(binary, environment)
        if getattr(scenario, "requires_editor", True):
            open_editor()
        def restart(before_start=None, empty=False):
            nonlocal process, stderr
            invoke_accessible_action("win.quit")
            process.wait(timeout=WAIT_SECONDS)
            if process.returncode != 0:
                raise RuntimeError("graceful quit failed")
            stderr += stop_application(process)
            wait_for_frame_containing(" — BookiE", present=False)
            if before_start is not None:
                before_start(environment)
            restored = "empty" if empty else "welcome" if before_start else True
            process = start_application(binary, environment, restored=restored)

        if getattr(scenario, "needs_restart", False):
            scenario(database, base, restart)
        else:
            scenario(database, base)
    except Exception as error:
        failure = error
    finally:
        artifact_dir = None
        if os.environ.get("TABLEPRO_GTK_ARTIFACT_DIR"):
            artifact_dir = Path(os.environ["TABLEPRO_GTK_ARTIFACT_DIR"])
            artifact_dir.mkdir(parents=True, exist_ok=True)
        if failure is not None and artifact_dir is not None:
            (artifact_dir / f"{scenario.__name__}-accessibility.txt").write_text(
                accessible_snapshot(), encoding="utf-8"
            )
            if shutil.which("scrot"):
                subprocess.run(
                    ["scrot", str(artifact_dir / f"{scenario.__name__}.png")],
                    check=False,
                )
        if process is not None:
            stderr += stop_application(process)
        if artifact_dir is not None:
            (artifact_dir / f"{scenario.__name__}-stderr.txt").write_text(stderr, encoding="utf-8")
            (artifact_dir / f"{scenario.__name__}-result.json").write_text(json.dumps({
                "scenario": scenario.__name__, "status": "passed" if failure is None else "failed",
                "error": str(failure) if failure is not None else None,
            }) + "\n", encoding="utf-8")
        shutil.rmtree(base, ignore_errors=True)
    if failure is not None:
        raise AssertionError(f"{failure}\napplication stderr:\n{stderr}") from failure


def dismissed_approval_denies(database, _base):
    run_sql("INSERT INTO safety_items(id) VALUES (1)")
    wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON)
    time.sleep(SETTLE_SECONDS / 3)
    if find_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON) is None:
        raise AssertionError("the approval dialog closed before the harness dismissed it")
    press_x11_key("Escape")
    wait_for_node(name="Approve once", present=False)
    assert_database_count_stable(database, 0)


def mcp_client_disconnect_cancels_pending_approval(database, base):
    journal = base / "data" / storage_dir_name() / "audit.jsonl"
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not journal.is_file():
        time.sleep(POLL_SECONDS)
    assert journal.is_file(), "the approval test requires an available audit journal"
    initial_records = [
        json.loads(line)["event"] for line in journal.read_text(encoding="utf-8").splitlines()
    ]
    initial_operation_ids = {event["operation_id"] for event in initial_records}

    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "execute_write",
                "arguments": {
                    "connection_id": "d4f5e246-c40a-4a30-90f2-39e93e94d920",
                    "sql": "INSERT INTO safety_items(id) VALUES (99)",
                    "preview": False,
                    "token": MCP_DISCONNECT_TEST_TOKEN,
                },
            },
        }
    ).encode("utf-8")
    deadline = time.monotonic() + WAIT_SECONDS
    client = None
    while time.monotonic() < deadline:
        try:
            client = socket.create_connection(("127.0.0.1", MCP_HTTP_PORT), timeout=2)
            break
        except OSError:
            time.sleep(POLL_SECONDS)
    assert client is not None, "the installed app's MCP HTTP listener did not start"
    try:
        request = (
            b"POST /mcp HTTP/1.1\r\n"
            + f"Host: 127.0.0.1:{MCP_HTTP_PORT}\r\n".encode("ascii")
            + b"Content-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\n".encode("ascii")
            + b"Connection: keep-alive\r\n\r\n"
            + body
        )
        client.sendall(request)
        wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON)
        wait_for_node_containing("INSERT INTO safety_items(id) VALUES (99)")
    finally:
        client.close()

    wait_for_node(name="Approve once", present=False)
    assert_database_count_stable(database, 0)

    deadline = time.monotonic() + WAIT_SECONDS
    new_events = []
    while time.monotonic() < deadline:
        records = [json.loads(line)["event"] for line in journal.read_text(encoding="utf-8").splitlines()]
        new_events = [
            event
            for event in records
            if event["operation_id"] not in initial_operation_ids
            and event.get("principal", {}).get("kind") == "agent"
        ]
        if len(new_events) == 1 and new_events[0].get("phase") == "outcome":
            break
        time.sleep(POLL_SECONDS)

    assert len(new_events) == 1, f"expected one terminal audit event for the cancelled approval, got {new_events!r}"
    outcome = new_events[0]
    assert outcome["phase"] == "outcome"
    assert outcome["terminal_status"] == "cancelled", outcome
    assert outcome["approval_outcome"] == "denied", outcome
    assert outcome["error_category"] == "cancelled", outcome
    assert MCP_DISCONNECT_TEST_TOKEN not in json.dumps(new_events), "the audit must not contain the MCP token"


mcp_client_disconnect_cancels_pending_approval.mcp_token = True
mcp_client_disconnect_cancels_pending_approval.environment = "dev"


def malformed_sql_is_blocked_before_approval(database, _base):
    run_sql("SELECT 'unterminated")
    wait_for_node_containing("unterminated quote or comment")
    wait_for_node(name="Approve once", present=False)
    assert_database_count_stable(database, 0)


def unparseable_routine_requests_human_approval(database, _base):
    run_sql("CREATE PROCEDURE p() SELECT 1")
    wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON)
    wait_for_node_containing("Class: Unparseable")
    wait_for_node_containing("CREATE PROCEDURE p() SELECT 1")
    invoke(wait_for_node(name="Deny", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Approve once", present=False)
    assert_database_count_stable(database, 0)


def mysql_unparseable_routine_dialog_denial_preserves_database(database, _base):
    container = os.environ["TABLEPRO_GTK_MYSQL_CONTAINER"]
    open_saved_connection(MYSQL_CONNECTION_NAME)
    wait_for_frame_containing(f"{MYSQL_CONNECTION_NAME} — BookiE")
    invoke(wait_for_node(name="Open SQL editor"))
    wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)

    denied_name = "bookie_gtk_unparseable_denied"
    run_sql(f"CREATE PROCEDURE {denied_name}() SELECT 1")
    wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON)
    wait_for_node_containing("Class: Unparseable")
    wait_for_node_containing(f"CREATE PROCEDURE {denied_name}() SELECT 1")
    invoke(wait_for_node(name="Deny", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Approve once", present=False)
    assert_mysql_routine_count(container, denied_name, 0)

    approved_name = "bookie_gtk_unparseable_approved"
    run_sql(f"CREATE PROCEDURE {approved_name}() SELECT 1")
    wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON)
    wait_for_node_containing("Class: Unparseable")
    wait_for_node_containing(f"CREATE PROCEDURE {approved_name}() SELECT 1")
    invoke(wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Approve once", present=False)
    wait_for_mysql_routine_count(container, approved_name, 1)
    assert_database_count_stable(database, 0, seconds=0.2)


def mysql_routine_count(container, routine_name):
    result = subprocess.run(
        [
            "docker",
            "exec",
            container,
            "mysql",
            "--user=root",
            "--password=tablepro_test",
            "--batch",
            "--skip-column-names",
            "bookie_test",
            "--execute",
            "SELECT COUNT(*) FROM information_schema.routines "
            f"WHERE routine_schema = DATABASE() AND routine_name = '{routine_name}'",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return int(result.stdout.strip())


def wait_for_mysql_routine_count(container, routine_name, expected, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if mysql_routine_count(container, routine_name) == expected:
            return
        time.sleep(POLL_SECONDS)
    actual = mysql_routine_count(container, routine_name)
    raise AssertionError(f"expected {expected} MySQL routines named {routine_name}, found {actual}")


def assert_mysql_routine_count(container, routine_name, expected):
    actual = mysql_routine_count(container, routine_name)
    assert actual == expected, f"expected {expected} MySQL routines named {routine_name}, found {actual}"


def approve_once_prompts_again(database, _base):
    run_sql("INSERT INTO safety_items(id) VALUES (1)")
    invoke(wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Approve once", present=False)
    wait_for_database_count(database, 1)

    run_sql("INSERT INTO safety_items(id) VALUES (2)")
    wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON)
    invoke(wait_for_node(name="Deny", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Approve once", present=False)
    assert_database_count_stable(database, 1)


def audit_failure_denies(database, _base):
    invoke_named_action_within(CONNECTION_NAME, "Open connection")
    wait_for_node(name="Connection failed")
    wait_for_node_containing("audit intent could not be persisted")
    wait_for_node(name="Open SQL editor", present=False)
    assert_database_count_stable(database, 0)


audit_failure_denies.audit_available = False
audit_failure_denies.requires_editor = False


def audit_journal_loss_after_connection_denies_mutation(database, base):
    journal = base / "data" / storage_dir_name() / "audit.jsonl"
    assert journal.is_file(), "the audit journal must start available"
    journal.unlink()
    journal.mkdir()

    run_sql("INSERT INTO safety_items(id) VALUES (1)")
    wait_for_node(name="Approve once", present=False, timeout=2)
    assert_database_count_stable(database, 0)


def bundle_export_records_sanitized_audit_outcome(_database, base):
    export_path = base / "home" / "review-only.bundle"
    invoke_accessible_action("win.disconnect")
    invoke_accessible_action("welcome.export-bundle")
    invoke_export_file_chooser_response()
    chooser = wait_for_node(name="Export connections", role=FILE_CHOOSER_ROLES)
    set_visible_editable_within("Export connections", FILE_CHOOSER_ROLES, str(export_path))
    invoke(wait_within(chooser, name="Save", role=pyatspi.ROLE_PUSH_BUTTON))

    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not export_path.exists():
        time.sleep(POLL_SECONDS)
    assert export_path.exists(), "connection bundle export was not created"

    journal_path = base / "data" / storage_dir_name() / "audit.jsonl"
    deadline = time.monotonic() + WAIT_SECONDS
    events = []
    while time.monotonic() < deadline:
        if journal_path.exists():
            records = [json.loads(line) for line in journal_path.read_text(encoding="utf-8").splitlines()]
            events = [
                record["event"] for record in records
                if record["event"].get("decision_rule") == "connection_bundle_export"
            ]
            if len(events) == 2:
                break
        time.sleep(POLL_SECONDS)

    assert len(events) == 2, f"expected one export intent and outcome, got {events!r}"
    assert [event["phase"] for event in events] == ["intent", "outcome"]
    assert events[0]["operation_id"] == events[1]["operation_id"]
    assert [event["terminal_status"] for event in events] == ["pending", "succeeded"]
    assert all(event["administrative_action"]["affected_count"] == 3 for event in events)
    assert all(event["connection_id"] == "00000000-0000-0000-0000-000000000000" for event in events)
    assert all(event["connection_name"] == "local_settings" for event in events)
    assert all(str(export_path) not in json.dumps(event) for event in events), (
        "the audit record must not contain the exported file path"
    )


def bundle_import_records_sanitized_audit_outcome(_database, base):
    import_path = base / "home" / "review-only.bookie-connections"
    incoming_id = "c6f8f3a4-c7d5-4a39-80e1-2cb50308a8bb"
    bundle = {
        "format": "tablepro.connection-bundle",
        "version": 1,
        "producer": "BookiE GTK fixture",
        "exported_at": "2026-10-07T00:00:00Z",
        "payload": {
            "kind": "plaintext",
            "body": {
                "connections": [{
                    "id": incoming_id,
                    "name": "Imported SQLite Review",
                    "driver_id": "sqlite",
                    "host": "",
                    "port": 0,
                    "database": str(base / "imported.sqlite"),
                    "username": "",
                    "tls_mode": "disabled",
                    "read_only": False,
                    "auth_mode": "password",
                    "environment": "local",
                }],
                "organization": {},
                "secrets": [],
            },
        },
    }
    import_path.write_text(json.dumps(bundle), encoding="utf-8")

    invoke_accessible_action("win.disconnect")
    choose_import_bundle(import_path)
    wait_for_node(name="Imported SQLite Review")

    config_path = base / "config" / storage_dir_name() / "connections.json"
    current_connections = json.loads(config_path.read_text(encoding="utf-8"))["connections"]
    assert all(record["id"] != incoming_id for record in current_connections), (
        "opening the preview must not save its connection before confirmation"
    )
    journal_path = base / "data" / storage_dir_name() / "audit.jsonl"
    if journal_path.exists():
        records = [json.loads(line) for line in journal_path.read_text(encoding="utf-8").splitlines()]
        assert all(
            record["event"].get("decision_rule") != "connection_bundle_import"
            for record in records
        ), "opening the preview must not start its audited operation before confirmation"

    invoke(wait_for_node(name="Import", role=pyatspi.ROLE_PUSH_BUTTON))

    deadline = time.monotonic() + WAIT_SECONDS
    imported = None
    while time.monotonic() < deadline:
        records = json.loads(config_path.read_text(encoding="utf-8"))["connections"]
        imported = next((record for record in records if record["id"] == incoming_id), None)
        if imported is not None:
            break
        time.sleep(POLL_SECONDS)
    assert imported is not None, "confirmed bundle connection was not saved"
    assert imported["name"] == "Imported SQLite Review"
    assert any(record["name"] == CONNECTION_NAME for record in records), "import removed an unmentioned local connection"

    deadline = time.monotonic() + WAIT_SECONDS
    events = []
    while time.monotonic() < deadline:
        if journal_path.exists():
            records = [json.loads(line) for line in journal_path.read_text(encoding="utf-8").splitlines()]
            events = [
                record["event"] for record in records
                if record["event"].get("decision_rule") == "connection_bundle_import"
            ]
            if len(events) == 2:
                break
        time.sleep(POLL_SECONDS)

    assert len(events) == 2, f"expected one import intent and outcome, got {events!r}"
    assert [event["phase"] for event in events] == ["intent", "outcome"]
    assert events[0]["operation_id"] == events[1]["operation_id"]
    assert [event["terminal_status"] for event in events] == ["pending", "succeeded"]
    assert all(event["administrative_action"]["affected_count"] == 1 for event in events)
    assert all(event["connection_id"] == "00000000-0000-0000-0000-000000000000" for event in events)
    assert all(event["connection_name"] == "local_settings" for event in events)
    serialized_events = json.dumps(events)
    assert str(import_path) not in serialized_events, "the audit record must not contain the imported file path"
    assert "Imported SQLite Review" not in serialized_events, "the audit record must not contain the imported connection name"


def encrypted_bundle_round_trip_restores_credentials(_database, base):
    bundle_path = base / "home" / "encrypted-review.bundle"
    passphrase = "fixture bundle passphrase"
    exported_secret = "fixture exported database secret"
    changed_secret = "fixture replacement database secret"
    attributes = [
        "xdg:schema", "com.tablepro.linux.Password",
        "connection-id", "d4f5e246-c40a-4a30-90f2-39e93e94d920",
        "kind", "db_password",
    ]

    def store_secret(value):
        subprocess.run(
            ["secret-tool", "store", "--label=BookiE encrypted bundle GTK fixture", *attributes],
            input=value, text=True, check=True, capture_output=True,
        )

    def load_secret():
        return subprocess.run(
            ["secret-tool", "lookup", *attributes],
            text=True, check=True, capture_output=True,
        ).stdout.rstrip("\n")

    store_secret(exported_secret)
    invoke_accessible_action("win.disconnect")
    invoke_accessible_action("welcome.export-bundle")
    set_text_by_name("Passphrase (optional)", passphrase)
    invoke_export_file_chooser_response()
    chooser = wait_for_node(name="Export connections", role=FILE_CHOOSER_ROLES)
    set_visible_editable_within("Export connections", FILE_CHOOSER_ROLES, str(bundle_path))
    invoke(wait_within(chooser, name="Save", role=pyatspi.ROLE_PUSH_BUTTON))

    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not bundle_path.exists():
        time.sleep(POLL_SECONDS)
    assert bundle_path.exists(), "encrypted connection bundle export was not created"
    encoded_bundle = bundle_path.read_text(encoding="utf-8")
    assert exported_secret not in encoded_bundle, "exported credential appeared in bundle plaintext"
    assert passphrase not in encoded_bundle, "bundle passphrase appeared in bundle plaintext"

    subprocess.run(["secret-tool", "clear", *attributes], check=True, capture_output=True)
    store_secret(changed_secret)

    def open_import_dialog():
        choose_import_bundle(bundle_path)

    open_import_dialog()
    wait_for_node(name="Passphrase", role=PASSPHRASE_ROLES)
    set_text_by_name("Passphrase", "incorrect passphrase")
    invoke(wait_for_node(name="Unlock", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node_containing("wrong", timeout=WAIT_SECONDS)
    wait_for_node(name="Imported SQLite Review", present=False)

    wait_for_node(name="Passphrase", role=PASSPHRASE_ROLES)
    set_text_by_name("Passphrase", passphrase)
    invoke(wait_for_node(name="Unlock", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Safety SQLite")
    replace = wait_for_node(name="Replace saved passwords", role=SWITCH_ROLES)
    assert not replace.getState().contains(pyatspi.STATE_CHECKED), "credential replacement should start disabled"
    extents = replace.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
    gtk_ux.x11_click(extents.x + extents.width // 2, extents.y + extents.height // 2, button=1)
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not replace.getState().contains(pyatspi.STATE_CHECKED):
        time.sleep(POLL_SECONDS)
    assert replace.getState().contains(pyatspi.STATE_CHECKED), "credential replacement switch did not become enabled"
    invoke(wait_for_node(name="Import", role=pyatspi.ROLE_PUSH_BUTTON))

    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        if load_secret() == exported_secret:
            break
        time.sleep(POLL_SECONDS)
    assert load_secret() == exported_secret, "confirmed encrypted import did not restore the bundled database credential"

    journal_path = base / "data" / storage_dir_name() / "audit.jsonl"
    deadline = time.monotonic() + WAIT_SECONDS
    events = []
    while time.monotonic() < deadline:
        if journal_path.exists():
            records = [json.loads(line) for line in journal_path.read_text(encoding="utf-8").splitlines()]
            events = [record["event"] for record in records if record["event"].get("decision_rule") in {
                "connection_bundle_export", "connection_bundle_import"
            }]
            if len(events) == 4:
                break
        time.sleep(POLL_SECONDS)
    assert len(events) == 4, f"expected encrypted export and import audit intent/outcome pairs, got {events!r}"
    assert [event["phase"] for event in events] == ["intent", "outcome", "intent", "outcome"]
    assert [event["terminal_status"] for event in events] == ["pending", "succeeded", "pending", "succeeded"]
    serialized_events = json.dumps(events)
    assert str(bundle_path) not in serialized_events, "bundle audit records must not contain the file path"
    assert exported_secret not in serialized_events and changed_secret not in serialized_events
    assert passphrase not in serialized_events, "bundle audit records must not contain the passphrase"


def choose_export_format(label, keys):
    invoke_accessible_action("win.export-csv")
    combo = wait_for_node(name="Format", role=pyatspi.ROLE_COMBO_BOX)
    for _ in range(20):
        if combo.getState().contains(pyatspi.STATE_FOCUSED):
            break
        press_x11_key("Tab")
        time.sleep(POLL_SECONDS)
    else:
        raise AssertionError(f"export format is not keyboard reachable: {accessible_snapshot()}")
    for attempt in range(3):
        press_x11_key("space")
        wait_for_node(name=label)
        time.sleep(0.5)
        for key in keys:
            press_x11_key(key)
        press_x11_key("Return")
        try:
            wait_within(combo, name=label, timeout=8)
            break
        except AssertionError:
            if attempt == 2 or find_node(name="Format", role=pyatspi.ROLE_COMBO_BOX) is None:
                raise
    wait_for_node(name="CSV options", present=False)
    invoke(wait_for_node(name="Export…", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Export Results", role=FILE_CHOOSER_ROLES)


def named_parameter_binds_a_value(database, _base):
    run_sql("INSERT INTO safety_items(id) VALUES (:id)")
    wait_for_node(name=":id")
    set_text_by_name(":id", "7")
    invoke(wait_for_node(name="Run with values", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Run with values", present=False)
    wait_for_database_count(database, 1)
    assert database_ids(database) == [7], f"expected the bound value, found {database_ids(database)}"


named_parameter_binds_a_value.environment = "local"


def activate_sidebar_group(name):
    if find_node(name="Search tables", role=pyatspi.ROLE_TOGGLE_BUTTON).getState().contains(pyatspi.STATE_CHECKED) is False:
        invoke(wait_for_node(name="Search tables", role=pyatspi.ROLE_TOGGLE_BUTTON))
    for _ in range(40):
        group = find_node(name=name, role=pyatspi.ROLE_LIST_ITEM)
        if group is not None and group.getState().contains(pyatspi.STATE_FOCUSED):
            press_x11_key("Return")
            return
        press_x11_key("Tab")
        time.sleep(POLL_SECONDS)
    raise AssertionError(f"the sidebar row {name!r} is not keyboard reachable:\n{accessible_snapshot()}")


def wait_for_node_showing(name, showing):
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        node = find_node(name=name, role=pyatspi.ROLE_LIST_ITEM)
        visible = node is not None and node.getState().contains(pyatspi.STATE_SHOWING)
        if visible == showing:
            return
        time.sleep(POLL_SECONDS)
    raise AssertionError(f"expected {name!r} showing={showing}:\n{accessible_snapshot()}")


def sidebar_tables_group_collapses_and_expands(database, _base):
    wait_for_node_showing("safety_items", True)
    activate_sidebar_group("Tables")
    wait_for_node_showing("safety_items", False)
    activate_sidebar_group("Tables")
    wait_for_node_showing("safety_items", True)


sidebar_tables_group_collapses_and_expands.environment = "local"


def press_x11_text(text):
    for character in text:
        name = {" ": "space", "_": "underscore", "-": "minus"}.get(character, character)
        press_x11_key(name)
        time.sleep(POLL_SECONDS)


def favorites_path(base):
    return base / "config" / storage_dir_name() / "favorites.json"


def wait_for_favorites(base, predicate, description, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    path = favorites_path(base)
    last = None
    while time.monotonic() < deadline:
        if path.exists():
            try:
                last = json.loads(path.read_text(encoding="utf-8")).get("favorites", [])
            except json.JSONDecodeError:
                last = None
            if last is not None and predicate(last):
                return last
        time.sleep(POLL_SECONDS)
    raise AssertionError(f"{description}; favorites file held {last!r}")


def favorite_round_trips_through_open_quickly(_database, base):
    set_editor_text("SELECT 42 AS answer")
    press_x11_key("d", modifiers=["Control_L"])
    wait_for_node(name="Name")
    set_text_by_name("Name", "smoke favorite")
    invoke(wait_for_node(name="Save", role=pyatspi.ROLE_PUSH_BUTTON))

    saved = wait_for_favorites(
        base,
        lambda favorites: any(entry["name"] == "smoke favorite" for entry in favorites),
        "the favorite was not written",
    )
    entry = next(item for item in saved if item["name"] == "smoke favorite")
    assert entry["sql"] == "SELECT 42 AS answer", f"unexpected statement: {entry['sql']!r}"
    assert "last_used_at" not in entry, "a new favorite must not look used"

    press_x11_key("p", modifiers=["Control_L"])
    wait_for_node(name="smoke favorite")
    press_x11_text("smoke")
    # SearchEntry debounces filtering and rebuilds the rows. The favorite is
    # already present before filtering, so waiting for its name alone can
    # activate a detached accessibility node. Wait for the actual result set,
    # then perform exactly one action against its current row.
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        window = find_node(name="Open quickly", role=pyatspi.ROLE_FRAME)
        names = [] if window is None else [
            node_name(node) for node in descendants(window)
            if node_role(node) == pyatspi.ROLE_LIST_ITEM
        ]
        if names == ["smoke favorite"]:
            break
        time.sleep(POLL_SECONDS)
    else:
        raise AssertionError(f"Open quickly did not finish filtering: {accessible_snapshot()}")
    invoke_named_action_within("smoke favorite", "Open smoke favorite")
    wait_for_node(name="Open quickly", role=pyatspi.ROLE_FRAME, present=False)
    wait_for_favorites(
        base,
        lambda favorites: any(item.get("last_used_at") for item in favorites),
        "opening the favorite did not record a use",
    )


favorite_round_trips_through_open_quickly.environment = "local"


def open_saved_connection(name):
    invoke(wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
    invoke_named_action_within(name, "Open connection")


def open_saved_connection_within(root, name):
    invoke(wait_within(root, name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
    invoke_named_action_within_node(root, name, "Open connection")


def successful_switch_keeps_database_ownership(database, base):
    run_sql("CREATE TABLE ownership_old (id INTEGER PRIMARY KEY); INSERT INTO safety_items(id) VALUES (11)")
    wait_for_database_count(database, 1)

    open_saved_connection(CONNECTION_B_NAME)
    wait_for_node(name=f"{CONNECTION_B_NAME} — BookiE", role=pyatspi.ROLE_FRAME)
    invoke(wait_for_node(name="Open SQL editor"))
    wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
    run_sql("CREATE TABLE ownership_new (id INTEGER PRIMARY KEY); INSERT INTO safety_items(id) VALUES (22)")

    database_b = base / "safety-b.sqlite"
    wait_for_database_count(database_b, 1)
    assert database_ids(database) == [11], f"old database changed after switch: {database_ids(database)}"
    assert database_ids(database_b) == [22], f"new database did not receive the write: {database_ids(database_b)}"
    assert "ownership_old" in database_tables(database)
    assert "ownership_new" not in database_tables(database)
    assert "ownership_new" in database_tables(database_b)
    assert "ownership_old" not in database_tables(database_b)


successful_switch_keeps_database_ownership.environment = "local"


def failed_switch_preserves_the_old_workspace(database, _base):
    open_saved_connection(BROKEN_CONNECTION_NAME)
    wait_for_node(name="Connection failed")
    invoke(wait_for_node(name="Close", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Connection failed", present=False)

    # The original editor remains attached to the original connection.
    run_sql("INSERT INTO safety_items(id) VALUES (33)")
    wait_for_database_count(database, 1)
    assert database_ids(database) == [33]


failed_switch_preserves_the_old_workspace.environment = "local"


def running_query_is_cancelled_before_switch(database, base):
    run_sql(
        "WITH RECURSIVE counter(value) AS "
        "(VALUES(0) UNION ALL SELECT value + 1 FROM counter WHERE value < 1000000000) "
        "SELECT sum(value) FROM counter"
    )
    wait_for_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON)
    open_saved_connection(CONNECTION_B_NAME)
    invoke(wait_for_node(name="Cancel queries and switch", role=pyatspi.ROLE_PUSH_BUTTON))

    wait_for_node(name=f"{CONNECTION_B_NAME} — BookiE", role=pyatspi.ROLE_FRAME)
    invoke(wait_for_node(name="Open SQL editor"))
    wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
    run_sql("INSERT INTO safety_items(id) VALUES (44)")
    database_b = base / "safety-b.sqlite"
    wait_for_database_count(database_b, 1)
    assert database_ids(database) == [], "the cancelled old query must not mutate its database"
    assert database_ids(database_b) == [44]


running_query_is_cancelled_before_switch.environment = "local"


def current_page_csv_export_is_pk_ordered(database, base):
    # The notes carry every character CSV has to quote: a separator, a
    # quote, and a line break. A page export that got the escaping wrong
    # would come back as a different number of rows or columns.
    awkward = {
        1: "a,b",
        2: 'say "hi"',
        3: "line1\nline2",
        4: "trailing backslash \\",
    }
    with sqlite3.connect(database) as connection:
        connection.executemany(
            "INSERT INTO safety_items(id, note) VALUES (?, ?)",
            ((identifier, awkward.get(identifier)) for identifier in range(150, 0, -1)),
        )

    invoke_named_action_within("safety_items", "Open safety_items")
    # The total comes from COUNT(*). SQLite used to decode that column as
    # NULL, so the label silently dropped the "of 150" half; asserting the
    # full label keeps that from regressing.
    wait_for_node(name="Rows 1 – 100 of 150")
    invoke_accessible_action("win.export-csv")
    marker_field = wait_for_node(name="Text that means NULL", role=pyatspi.ROLE_TEXT)
    marker_text = marker_field.queryText()
    assert marker_text.getText(0, marker_text.characterCount) == "\\N", (
        "the export dialog must show the marker written for SQL NULL"
    )
    invoke(wait_for_node(name="Export…", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Export Results", role=FILE_CHOOSER_ROLES)
    set_visible_editable_within(
        "Export Results",
        FILE_CHOOSER_ROLES,
        str(base / "home" / "current-page.csv"),
    )
    invoke(wait_for_node(name="Save", role=pyatspi.ROLE_PUSH_BUTTON))

    export = base / "home" / "current-page.csv"
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not export.exists():
        time.sleep(POLL_SECONDS)
    if not export.exists():
        raise AssertionError(f"current-page export was not written:\n{accessible_snapshot()}")
    with export.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.reader(handle))
    assert rows[0] == ["id", "note"], f"unexpected CSV header: {rows[0]!r}"
    exported_ids = [int(row[0]) for row in rows[1:]]
    assert exported_ids == list(range(1, 101)), (
        f"expected the first PK-ordered page only, found {len(exported_ids)} rows: "
        f"{exported_ids[:5]}…{exported_ids[-5:]}"
    )
    exported_notes = {int(row[0]): row[1] for row in rows[1:]}
    assert all(exported_notes[identifier] == "\\N" for identifier in range(5, 101)), (
        "CSV file export must use the displayed null marker for SQL NULL cells"
    )
    for identifier, note in awkward.items():
        assert exported_notes[identifier] == note, (
            f"row {identifier} lost its text through the CSV export: "
            f"{exported_notes[identifier]!r} != {note!r}"
        )


current_page_csv_export_is_pk_ordered.environment = "local"


def current_page_json_export_preserves_values(database, base):
    notes = {1: 'a,"b"\n\\', 2: "Grüße 東京", 3: "", 4: None}
    blobs = {1: b"\x00\xffA", 2: b"", 3: b"hello"}
    with sqlite3.connect(database) as connection:
        connection.execute("ALTER TABLE safety_items ADD COLUMN payload BLOB")
        connection.executemany(
            "INSERT INTO safety_items(id, note, payload) VALUES (?, ?, ?)",
            ((i, notes.get(i), blobs.get(i)) for i in range(150, 0, -1)),
        )
    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node(name="Rows 1 – 100 of 150")
    invoke_accessible_action("win.export-json")
    invoke(wait_for_node(name="Export…", role=pyatspi.ROLE_PUSH_BUTTON))
    export = base / "home" / "current-page.json"
    set_visible_editable_within("Export Results", FILE_CHOOSER_ROLES, str(export))
    invoke(wait_for_node(name="Save", role=pyatspi.ROLE_PUSH_BUTTON))
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not export.exists():
        time.sleep(POLL_SECONDS)
    assert export.exists(), "JSON export was not created"
    rows = json.loads(export.read_text(encoding="utf-8"))
    assert rows == [
        {"id": i, "note": notes.get(i), "payload": "\\x" + blobs[i].hex() if i in blobs else None}
        for i in range(1, 101)
    ], f"JSON export lost values or page order: {rows[:5]}"


current_page_json_export_preserves_values.environment = "local"


def restart_restores_active_editor_and_connection(database, base, restart):
    database_b = base / "safety-b.sqlite"
    with sqlite3.connect(database_b) as connection:
        connection.executemany("INSERT INTO safety_items(id) VALUES (?)", [(1,), (2,), (3,)])
    open_saved_connection(CONNECTION_B_NAME)
    wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node(name="Rows 1 – 3 of 3")
    invoke_accessible_action("win.open-editor")
    wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
    query = "/*" + "Grüße 東京🙂 " * 30000 + "*/\nINSERT INTO safety_items(id, note) VALUES (901, 'restored editor')"
    set_editor_text(query)
    # Close immediately: the normal close path must flush pending workspace saves.
    restart()
    window = wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    wait_within(window, name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
    texts = []
    for node in descendants(window):
        if node_role(node) == pyatspi.ROLE_TEXT:
            try:
                texts.append(node.queryText().getText(0, -1))
            except Exception:
                pass
    assert query in texts, f"active editor text was not restored: {texts}"
    assert database_ids(database_b) == [1, 2, 3], "restoration executed the saved query"
    invoke(wait_within(window, name="Run", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_database_count(database_b, 4)
    assert database_ids(database_b) == [1, 2, 3, 901]
    assert database_ids(database) == [], "restored editor wrote to the other connection"
    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node_containing("Rows 1 – 3")


restart_restores_active_editor_and_connection.environment = "local"
restart_restores_active_editor_and_connection.needs_restart = True


def restart_with_a_deleted_connection_opens_the_welcome_list(database, base, restart):
    open_saved_connection(CONNECTION_B_NAME)
    wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node_containing("Rows")
    config_path = base / "config" / storage_dir_name() / "connections.json"

    def delete_connection_b(_environment):
        state = json.loads(config_path.read_text(encoding="utf-8"))
        state["connections"] = [record for record in state["connections"] if record["name"] != CONNECTION_B_NAME]
        config_path.write_text(json.dumps(state), encoding="utf-8")

    restart(delete_connection_b)
    wait_for_node(name=CONNECTION_NAME)
    wait_for_node(name=CONNECTION_B_NAME, present=False)
    assert find_node(name=f"{CONNECTION_B_NAME} — BookiE") is None, "a deleted connection was reopened"
    assert database_ids(base / "safety-b.sqlite") == [], "restoring a deleted connection must not touch its database"


restart_with_a_deleted_connection_opens_the_welcome_list.environment = "local"
restart_with_a_deleted_connection_opens_the_welcome_list.needs_restart = True


def a_bundle_from_one_profile_imports_unchanged_into_an_empty_second_profile(database, base, restart):
    bundle_path = base / "home" / "two-profile.bundle"
    passphrase = "two profile passphrase"
    config_path = base / "config" / storage_dir_name() / "connections.json"
    def without_usage(records):
        return {
            record["id"]: {key: value for key, value in record.items() if key != "last_opened_at"}
            for record in records
        }

    original = without_usage(json.loads(config_path.read_text(encoding="utf-8"))["connections"])
    invoke_accessible_action("win.disconnect")
    invoke_accessible_action("welcome.export-bundle")
    set_text_by_name("Passphrase (optional)", passphrase)
    invoke_export_file_chooser_response()
    chooser = wait_for_node(name="Export connections", role=FILE_CHOOSER_ROLES)
    set_visible_editable_within("Export connections", FILE_CHOOSER_ROLES, str(bundle_path))
    invoke(wait_within(chooser, name="Save", role=pyatspi.ROLE_PUSH_BUTTON))
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and not bundle_path.exists():
        time.sleep(POLL_SECONDS)
    assert bundle_path.exists(), "the connection bundle was not exported"

    second_config = base / "profile2" / "config" / storage_dir_name() / "connections.json"

    def empty_second_profile(environment):
        for kind in ("config", "data"):
            (base / "profile2" / kind).mkdir(parents=True)
        environment["XDG_CONFIG_HOME"] = str(base / "profile2" / "config")
        environment["XDG_DATA_HOME"] = str(base / "profile2" / "data")

    restart(empty_second_profile, empty=True)
    assert not second_config.exists() or not json.loads(second_config.read_text(encoding="utf-8"))["connections"]
    choose_import_bundle(bundle_path)
    wait_for_node(name="Passphrase", role=PASSPHRASE_ROLES)
    set_text_by_name("Passphrase", passphrase)
    invoke(wait_for_node(name="Unlock", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name=CONNECTION_NAME)
    invoke(wait_for_node(name="Import", role=pyatspi.ROLE_PUSH_BUTTON))
    deadline = time.monotonic() + WAIT_SECONDS
    imported = {}
    while time.monotonic() < deadline and len(imported) < len(original):
        if second_config.exists():
            imported = without_usage(json.loads(second_config.read_text(encoding="utf-8"))["connections"])
        time.sleep(POLL_SECONDS)
    assert imported == original, f"the second profile differs from the first: {imported!r} != {original!r}"
    assert json.loads(config_path.read_text(encoding="utf-8"))["connections"], "the first profile lost its connections"


a_bundle_from_one_profile_imports_unchanged_into_an_empty_second_profile.environment = "local"
a_bundle_from_one_profile_imports_unchanged_into_an_empty_second_profile.needs_restart = True


def pending_edits_gate_a_connection_switch(database, base):
    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node(name="No rows on this page")
    invoke(wait_for_node(name="Insert row", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="1 unsaved change")

    open_saved_connection(CONNECTION_B_NAME)
    wait_for_node(name="Save changes before switching?")
    invoke(wait_for_node(name="Stay", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Save changes before switching?", present=False)
    wait_for_frame_containing(f"{CONNECTION_NAME} — BookiE")
    wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE", present=False)
    wait_for_node(name="1 unsaved change")
    assert_database_count_stable(database, 0)

    open_saved_connection(CONNECTION_B_NAME)
    wait_for_node(name="Save changes before switching?")
    invoke(wait_for_node(name="Discard and switch", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    wait_for_node(name="1 unsaved change", present=False)
    assert database_ids(database) == [], (
        f"a discarded pending row reached the old database: {database_ids(database)}"
    )

    invoke(wait_for_node(name="Open SQL editor"))
    wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
    run_sql("INSERT INTO safety_items(id) VALUES (55)")
    database_b = base / "safety-b.sqlite"
    wait_for_database_count(database_b, 1)
    assert database_ids(database_b) == [55]
    assert database_ids(database) == [], "the old connection stayed writable after the switch"


pending_edits_gate_a_connection_switch.environment = "local"


def a_browse_tab_reads_the_new_connection_after_a_switch(database, base):
    database_b = base / "safety-b.sqlite"
    with sqlite3.connect(database) as connection:
        connection.executemany(
            "INSERT INTO safety_items(id) VALUES (?)",
            ((identifier,) for identifier in range(1, 8)),
        )
    with sqlite3.connect(database_b) as connection:
        connection.executemany(
            "INSERT INTO safety_items(id) VALUES (?)",
            ((identifier,) for identifier in range(1, 4)),
        )

    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node_containing("Rows 1 – 7")

    open_saved_connection(CONNECTION_B_NAME)
    wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    wait_for_node_containing("Rows 1 – 7", present=False)

    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node_containing("Rows 1 – 3")
    assert database_ids(database) == list(range(1, 8)), "the old database changed after the switch"
    assert database_ids(database_b) == [1, 2, 3]


a_browse_tab_reads_the_new_connection_after_a_switch.environment = "local"


def two_windows_hold_two_connections(database, base):
    database_b = base / "safety-b.sqlite"

    invoke_accessible_action("win.new-window")
    second_window = wait_for_node(name="BookiE", role=pyatspi.ROLE_FRAME)
    invoke_named_action_within_node(second_window, CONNECTION_B_NAME, "Open connection")
    second_window = wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    invoke(wait_within(second_window, name="Open SQL editor"))
    wait_within(second_window, name="Run", role=pyatspi.ROLE_PUSH_BUTTON)

    first_window = find_frame_containing(f"{CONNECTION_NAME} — BookiE")
    assert first_window is not None, (
        f"the first window lost its connection when the second one connected:\n{accessible_snapshot()}"
    )

    run_sql_within(second_window, "INSERT INTO safety_items(id) VALUES (77)")
    wait_for_database_count(database_b, 1)
    assert database_ids(database) == [], "the second window wrote to the first window's database"

    run_sql_within(first_window, "INSERT INTO safety_items(id) VALUES (88)")
    wait_for_database_count(database, 1)

    assert database_ids(database) == [88], f"first window database: {database_ids(database)}"
    assert database_ids(database_b) == [77], f"second window database: {database_ids(database_b)}"


two_windows_hold_two_connections.environment = "local"


def switched_connection_keeps_workspace_tabs_after_debounce(database, _base):
    with sqlite3.connect(database) as connection:
        connection.executemany(
            "INSERT INTO safety_items(id) VALUES (?)",
            ((identifier,) for identifier in range(1, 6)),
        )

    invoke_named_action_within("safety_items", "Open safety_items")
    wait_for_node_containing("Rows 1 – 5")

    open_saved_connection(CONNECTION_B_NAME)
    wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")
    time.sleep(0.7)

    open_saved_connection(CONNECTION_NAME)
    wait_for_frame_containing(f"{CONNECTION_NAME} — BookiE")
    wait_for_node_containing("Rows 1 – 5")


switched_connection_keeps_workspace_tabs_after_debounce.environment = "local"


def switching_one_window_leaves_the_other_windows_edits(database, base):
    database_b = base / "safety-b.sqlite"

    invoke_accessible_action("win.new-window")
    second_window = wait_for_node(name="BookiE", role=pyatspi.ROLE_FRAME)
    invoke_named_action_within_node(second_window, CONNECTION_B_NAME, "Open connection")
    second_window = wait_for_frame_containing(f"{CONNECTION_B_NAME} — BookiE")

    invoke_named_action_within_node(second_window, "safety_items", "Open safety_items")
    wait_within(second_window, name="No rows on this page")
    invoke(wait_within(second_window, name="Insert row", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_within(second_window, name="1 unsaved change")

    first_window = find_frame_containing(f"{CONNECTION_NAME} — BookiE")
    assert first_window is not None, f"the first window disappeared:\n{accessible_snapshot()}"
    open_saved_connection_within(first_window, CONNECTION_B_NAME)
    time.sleep(SETTLE_SECONDS / 3)
    assert find_node(name="Save changes before switching?") is None, (
        f"switching a clean window prompted for another window's edits:\n{accessible_snapshot()}"
    )
    wait_within(second_window, name="1 unsaved change")

    invoke(wait_within(second_window, name="Save"))
    wait_for_database_count(database_b, 1)
    assert database_ids(database) == [], (
        f"the second window's pending edit reached the first database: {database_ids(database)}"
    )
    assert database_ids(database_b) == [1], f"second window database: {database_ids(database_b)}"


switching_one_window_leaves_the_other_windows_edits.environment = "local"


def sql_character_warnings_leave_query_unchanged(database, base):
    sql = "SELECT '🙂；' AS value；"
    editor = set_editor_text(sql)
    invoke(wait_for_node(name="SQL warnings (1)", role=pyatspi.ROLE_TOGGLE_BUTTON))
    warning = wait_for_node(name="； (U+FF1B): consider ; (U+003B)", role=pyatspi.ROLE_PUSH_BUTTON)
    invoke(warning)
    text = editor.queryText()
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline and text.getNSelections() == 0:
        time.sleep(0.05)
    assert text.getNSelections() == 1, "warning did not select its source range"
    assert text.getText(0, -1) == sql, "warning navigation changed SQL"
    start, end = text.getSelection(0)
    assert text.getText(start, end) == "；", "warning selected the wrong Unicode range"
    run_sql("SELECT '🙂；' AS value;")
    wait_for_node(name="SQL warnings (1)", present=False)
    wait_for_node(name="🙂；")
    assert_database_count_stable(database, 0, seconds=0.2)


sql_character_warnings_leave_query_unchanged.environment = "local"


def jump_to_column_keyboard_search(database, base):
    run_sql('SELECT 1 AS duplicate, 2 AS duplicate, 3 AS "Grüße 東京"')
    wait_for_node(name="3")
    press_x11_key("j", ("Control_L", "Shift_L"))
    search = wait_for_node(name="Search columns")
    wait_for_node(name="1 · duplicate")
    wait_for_node(name="2 · duplicate")
    search.queryEditableText().setTextContents("東京")
    time.sleep(0.3)
    press_x11_key("Return")
    wait_for_node(name="Search columns", present=False)
    press_x11_key("j", ("Control_L", "Shift_L"))
    search = wait_for_node(name="Search columns")
    search.queryEditableText().setTextContents("not-a-column")
    wait_for_node(name="No matching columns")
    press_x11_key("Return")
    wait_for_node(name="Search columns")
    press_x11_key("Escape")
    wait_for_node(name="Search columns", present=False)
    assert_database_count_stable(database, 0, seconds=0.2)


jump_to_column_keyboard_search.environment = "local"


def committed_editor_ddl_refreshes_sidebar(database, base):
    run_sql("CREATE TABLE catalog_probe (id INTEGER PRIMARY KEY)")
    wait_for_node(name="catalog_probe")
    run_sql("DROP TABLE catalog_probe")
    wait_for_node(name="catalog_probe", present=False)
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT count(*) FROM sqlite_master WHERE name = 'catalog_probe'").fetchone()[0] == 0


committed_editor_ddl_refreshes_sidebar.environment = "local"


def new_connection_form_keeps_title_and_help_text_visible(_database, _base):
    invoke(wait_for_node(name="New connection", role=pyatspi.ROLE_PUSH_BUTTON))
    wait_for_node(name="Connect to PostgreSQL")
    # PostgreSQL is the documented default. Keep the complete help strings
    # visible in the rendered form; this driver also exposes the socket row.
    tls_help = wait_for_node(name="How the client encrypts and verifies the server")
    wait_for_node(name="Block writes at the policy layer")
    help_width = tls_help.queryComponent().getExtents(pyatspi.DESKTOP_COORDS).width
    assert help_width >= 350, f"TLS help text has too little layout width: {help_width}px"


new_connection_form_keeps_title_and_help_text_visible.environment = "local"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: gtk_safety.py /path/to/tablepro-app")
    binary = Path(sys.argv[1]).resolve()
    if not binary.is_file():
        raise SystemExit(f"application binary not found: {binary}")
    scenarios = [
        jump_to_column_keyboard_search,
        committed_editor_ddl_refreshes_sidebar,
        new_connection_form_keeps_title_and_help_text_visible,
        sql_character_warnings_leave_query_unchanged,
        malformed_sql_is_blocked_before_approval,
        unparseable_routine_requests_human_approval,
        dismissed_approval_denies,
        mcp_client_disconnect_cancels_pending_approval,
        approve_once_prompts_again,
        audit_failure_denies,
        audit_journal_loss_after_connection_denies_mutation,
        bundle_export_records_sanitized_audit_outcome,
        bundle_import_records_sanitized_audit_outcome,
        encrypted_bundle_round_trip_restores_credentials,
        named_parameter_binds_a_value,
        favorite_round_trips_through_open_quickly,
        successful_switch_keeps_database_ownership,
        failed_switch_preserves_the_old_workspace,
        running_query_is_cancelled_before_switch,
        current_page_csv_export_is_pk_ordered,
        current_page_json_export_preserves_values,
        restart_restores_active_editor_and_connection,
        pending_edits_gate_a_connection_switch,
        a_browse_tab_reads_the_new_connection_after_a_switch,
        two_windows_hold_two_connections,
        switched_connection_keeps_workspace_tabs_after_debounce,
        switching_one_window_leaves_the_other_windows_edits,
        sidebar_tables_group_collapses_and_expands,
        restart_with_a_deleted_connection_opens_the_welcome_list,
        a_bundle_from_one_profile_imports_unchanged_into_an_empty_second_profile,
    ]
    if os.environ.get("TABLEPRO_GTK_MYSQL_CONTAINER"):
        scenarios.append(mysql_unparseable_routine_dialog_denial_preserves_database)
    scenarios.extend(gtk_workbook.scenarios(sys.modules[__name__]))
    scenarios.extend(gtk_parameters.scenarios(sys.modules[__name__]))
    scenarios.extend(gtk_xml.scenarios(sys.modules[__name__]))
    scenarios.extend(gtk_ux.scenarios(sys.modules[__name__]))
    selected = os.environ.get("TABLEPRO_GTK_SCENARIO")
    if selected:
        names = set(selected.split(","))
        scenarios = [scenario for scenario in scenarios if scenario.__name__ in names]
        if {scenario.__name__ for scenario in scenarios} != names:
            raise SystemExit(f"unknown GTK scenario in: {selected}")
    scenarios = gtk_shard.select(scenarios, os.environ.get("TABLEPRO_GTK_SHARD", ""))
    # The merge gate sets TABLEPRO_GTK_SCENARIO_RETRIES=1 so one start-up flake (TEST-31) does not
    # fail a run; the nightly soak leaves it unset and stays retry-free. A retry is always printed.
    retries = int(os.environ.get("TABLEPRO_GTK_SCENARIO_RETRIES", "0"))
    for scenario in scenarios:
        for attempt in range(retries + 1):
            try:
                run_scenario(binary, scenario)
                break
            except AssertionError as error:
                if attempt == retries:
                    raise
                first = str(error).splitlines()[0][:300]
                print(f"RETRY: {scenario.__name__} failed once, running it again: {first}")
        print(f"passed: {scenario.__name__}")


if __name__ == "__main__":
    main()
