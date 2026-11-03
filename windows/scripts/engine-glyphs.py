#!/usr/bin/env python3
# Each macOS template SVG becomes one PathIcon path in a 16 by 16 box, so every glyph sits at the same size.

import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "apple" / "TablePro" / "Assets.xcassets"
OUT = ROOT / "windows" / "src" / "TablePro.App" / "Resources" / "EngineGlyphs.xaml"
BOX = 16.0

# The core's engine id, then the macOS asset that draws it.
ENGINES = {
    "cassandra": "cassandra",
    "clickhouse": "clickhouse",
    "duckdb": "duckdb",
    "mongodb": "mongodb",
    "mssql": "mssql",
    "mysql": "mysql",
    "postgres": "postgresql",
    "redis": "redis",
    "sqlite": "sqlite",
}

NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
ARGS = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def tokens(data):
    index = 0
    while index < len(data):
        char = data[index]
        if char in "MmLlHhVvCcSsQqTtAaZz":
            yield char
            index += 1
        elif char in " ,\t\r\n":
            index += 1
        else:
            match = NUMBER.match(data, index)
            if not match:
                raise ValueError(f"cannot read {data[index:index + 20]!r}")
            yield match.group(0)
            index = match.end()


# An arc's two flags may be written without a separator, as 011.
def commands(data):
    stream = list(tokens(data))
    index = 0
    command = None
    while index < len(stream):
        if stream[index][0].isalpha():
            command = stream[index]
            index += 1
            if command in "Zz":
                yield command, []
                continue
        if command is None:
            raise ValueError("a path starts with a number")
        count = ARGS[command.upper()]
        values = []
        while len(values) < count:
            text = stream[index]
            if command.upper() == "A" and len(values) in (3, 4) and len(text) > 1 and text[0] in "01" and text.lstrip("-+")[0] != ".":
                # A packed flag: its first digit is the flag and the rest is the next number.
                values.append(float(text[0]))
                stream[index] = text[1:]
                continue
            values.append(float(text))
            index += 1
        yield command, values
        # Numbers after a move continue as lines.
        if command == "M":
            command = "L"
        elif command == "m":
            command = "l"


# After the SVG 1.1 implementation notes, F.6.
def arc_to_curves(x1, y1, rx, ry, angle, large, sweep, x2, y2):
    if (x1, y1) == (x2, y2):
        return []
    if rx == 0 or ry == 0:
        return [(x1, y1, x2, y2, x2, y2)]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(angle % 360)
    cos, sin = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cos * dx + sin * dy
    y1p = -sin * dx + cos * dy
    scale = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if scale > 1:
        rx *= math.sqrt(scale)
        ry *= math.sqrt(scale)
    numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    factor = math.sqrt(max(0.0, numerator / denominator)) if denominator else 0.0
    if large == sweep:
        factor = -factor
    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx
    cx = cos * cxp - sin * cyp + (x1 + x2) / 2
    cy = sin * cxp + cos * cyp + (y1 + y2) / 2

    def angle_of(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        length = math.hypot(ux, uy) * math.hypot(vx, vy)
        value = math.acos(max(-1.0, min(1.0, dot / length)))
        return -value if ux * vy - uy * vx < 0 else value

    theta = angle_of(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    delta = angle_of((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi
    segments = max(1, math.ceil(abs(delta) / (math.pi / 2)))
    step = delta / segments
    alpha = 4 / 3 * math.tan(step / 4)
    curves = []
    for segment in range(segments):
        start = theta + segment * step
        end = start + step

        def point(t):
            return (
                cx + rx * math.cos(t) * cos - ry * math.sin(t) * sin,
                cy + rx * math.cos(t) * sin + ry * math.sin(t) * cos,
            )

        def tangent(t):
            return (
                -rx * math.sin(t) * cos - ry * math.cos(t) * sin,
                -rx * math.sin(t) * sin + ry * math.cos(t) * cos,
            )

        p0, p3 = point(start), point(end)
        t0, t3 = tangent(start), tangent(end)
        curves.append((
            p0[0] + alpha * t0[0], p0[1] + alpha * t0[1],
            p3[0] - alpha * t3[0], p3[1] - alpha * t3[1],
            p3[0], p3[1],
        ))
    return curves


def absolute(data):
    out = []
    x = y = start_x = start_y = 0.0
    last_control = None
    last_quad = None
    for command, v in commands(data):
        relative = command.islower()
        kind = command.upper()
        ox, oy = (x, y) if relative else (0.0, 0.0)
        if kind == "M":
            x, y = v[0] + ox, v[1] + oy
            start_x, start_y = x, y
            out.append(("M", [x, y]))
            last_control = last_quad = None
        elif kind == "L":
            x, y = v[0] + ox, v[1] + oy
            out.append(("L", [x, y]))
            last_control = last_quad = None
        elif kind == "H":
            x = v[0] + (x if relative else 0.0)
            out.append(("L", [x, y]))
            last_control = last_quad = None
        elif kind == "V":
            y = v[0] + (y if relative else 0.0)
            out.append(("L", [x, y]))
            last_control = last_quad = None
        elif kind in ("C", "S"):
            if kind == "C":
                c1 = (v[0] + ox, v[1] + oy)
                c2 = (v[2] + ox, v[3] + oy)
                end = (v[4] + ox, v[5] + oy)
            else:
                c1 = (2 * x - last_control[0], 2 * y - last_control[1]) if last_control else (x, y)
                c2 = (v[0] + ox, v[1] + oy)
                end = (v[2] + ox, v[3] + oy)
            out.append(("C", [*c1, *c2, *end]))
            last_control = c2
            last_quad = None
            x, y = end
        elif kind in ("Q", "T"):
            if kind == "Q":
                c = (v[0] + ox, v[1] + oy)
                end = (v[2] + ox, v[3] + oy)
            else:
                c = (2 * x - last_quad[0], 2 * y - last_quad[1]) if last_quad else (x, y)
                end = (v[0] + ox, v[1] + oy)
            out.append(("Q", [*c, *end]))
            last_quad = c
            last_control = None
            x, y = end
        elif kind == "A":
            end = (v[5] + ox, v[6] + oy)
            for curve in arc_to_curves(x, y, v[0], v[1], v[2], int(v[3]), int(v[4]), *end):
                out.append(("C", list(curve)))
            x, y = end
            last_control = last_quad = None
        elif kind == "Z":
            out.append(("Z", []))
            x, y = start_x, start_y
            last_control = last_quad = None
    return out


def transform_of(element):
    text = element.get("transform")
    matrix = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    if not text:
        return matrix
    for name, args in re.findall(r"(\w+)\(([^)]*)\)", text):
        values = [float(value) for value in NUMBER.findall(args)]
        if name == "scale":
            sx = values[0]
            sy = values[1] if len(values) > 1 else sx
            step = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        elif name == "translate":
            step = (1.0, 0.0, 0.0, 1.0, values[0], values[1] if len(values) > 1 else 0.0)
        elif name == "matrix":
            step = tuple(values)
        else:
            raise ValueError(f"no support for {name}")
        matrix = multiply(matrix, step)
    return matrix


def multiply(m, n):
    a, b, c, d, e, f = m
    a2, b2, c2, d2, e2, f2 = n
    return (
        a * a2 + c * b2,
        b * a2 + d * b2,
        a * c2 + c * d2,
        b * c2 + d * d2,
        a * e2 + c * f2 + e,
        b * e2 + d * f2 + f,
    )


def circle(element):
    cx, cy, r = (float(element.get(name, 0)) for name in ("cx", "cy", "r"))
    return f"M{cx - r} {cy}A{r} {r} 0 1 0 {cx + r} {cy}A{r} {r} 0 1 0 {cx - r} {cy}Z"


def shapes(element, matrix):
    tag = element.tag.split("}")[-1]
    matrix = multiply(matrix, transform_of(element))
    if tag == "path":
        yield absolute(element.get("d")), matrix
    elif tag == "circle":
        yield absolute(circle(element)), matrix
    elif tag in ("rect", "ellipse", "polygon", "polyline", "line"):
        raise ValueError(f"no support for <{tag}>")
    for child in element:
        yield from shapes(child, matrix)


def glyph(svg):
    root = ET.parse(svg).getroot()
    segments = []
    for path, matrix in shapes(root, (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)):
        a, b, c, d, e, f = matrix
        for command, values in path:
            points = [
                (a * values[i] + c * values[i + 1] + e, b * values[i] + d * values[i + 1] + f)
                for i in range(0, len(values), 2)
            ]
            segments.append((command, points))
    xs = [x for _, points in segments for x, _ in points]
    ys = [y for _, points in segments for _, y in points]
    left, top = min(xs), min(ys)
    width, height = max(xs) - left, max(ys) - top
    scale = BOX / max(width, height)
    shift_x = (BOX - width * scale) / 2
    shift_y = (BOX - height * scale) / 2
    parts = ["F1"]
    for command, points in segments:
        if command == "Z":
            parts.append("Z")
            continue
        coordinates = " ".join(
            f"{fmt((x - left) * scale + shift_x)},{fmt((y - top) * scale + shift_y)}" for x, y in points
        )
        parts.append(f"{command} {coordinates}")
    return " ".join(parts)


def fmt(value):
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def main():
    entries = []
    for engine, asset in ENGINES.items():
        svg = ASSETS / f"{asset}-icon.imageset" / f"{asset}.svg"
        entries.append(
            f'    <DataTemplate x:Key="EngineGlyph_{engine}">\n'
            f'        <PathIcon Data="{glyph(svg)}" />\n'
            f"    </DataTemplate>\n"
        )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Written by windows/scripts/engine-glyphs.py from apple/TablePro/Assets.xcassets. Do not edit. -->\n"
        "<ResourceDictionary\n"
        '    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"\n'
        '    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">\n'
        + "\n".join(entries)
        + "</ResourceDictionary>\n",
        encoding="utf-8",
    )
    print(f"wrote {len(entries)} glyphs to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    sys.exit(main())
