import ctypes
import os
import time

import pyatspi


def uses_atspi_input():
    return os.environ.get("GDK_BACKEND") == "wayland" or not os.environ.get("DISPLAY")


def keysym(name):
    xkb = ctypes.CDLL("libxkbcommon.so.0")
    xkb.xkb_keysym_from_name.argtypes = [ctypes.c_char_p, ctypes.c_int]
    xkb.xkb_keysym_from_name.restype = ctypes.c_uint32
    value = xkb.xkb_keysym_from_name(name.encode("ascii"), 0)
    if value == 0:
        raise AssertionError(f"key is unavailable: {name}")
    return value


def press_key(name, modifiers=(), presses=1):
    registry = pyatspi.Registry
    modifier_keys = [keysym(modifier) for modifier in modifiers]
    key = keysym(name)
    for modifier_key in modifier_keys:
        registry.generateKeyboardEvent(modifier_key, None, pyatspi.KEY_PRESS)
    for _ in range(presses):
        registry.generateKeyboardEvent(key, None, pyatspi.KEY_PRESSRELEASE)
    for modifier_key in reversed(modifier_keys):
        registry.generateKeyboardEvent(modifier_key, None, pyatspi.KEY_RELEASE)
    time.sleep(0.1)


def click(x, y, button=3, clicks=1):
    registry = pyatspi.Registry
    registry.generateMouseEvent(int(x), int(y), "abs")
    time.sleep(0.2)
    for _ in range(clicks):
        registry.generateMouseEvent(int(x), int(y), f"b{button}c")
        time.sleep(0.08)


def display_environment():
    display = os.environ.get("WAYLAND_DISPLAY")
    if not display or os.path.isabs(display):
        return {}
    return {"WAYLAND_DISPLAY": os.path.join(os.environ["XDG_RUNTIME_DIR"], display)}
