#!/usr/bin/env python3
"""Extract the bash scripts that Panel.qml generates, so they can be tested
exactly as the plugin runs them.

The QML file is taken from $PLUGIN_QML, or from $PLUGIN_DIR/Panel.qml, or
from this checkout's Panel.qml.
"""
import os
import re
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
QML = pathlib.Path(
    os.environ.get("PLUGIN_QML")
    or (pathlib.Path(os.environ["PLUGIN_DIR"]) / "Panel.qml" if os.environ.get("PLUGIN_DIR") else HERE.parent / "Panel.qml")
)
src = QML.read_text()


def _read_property(name, fallback):
    m = re.search(r"%s:\s*(\d+)" % name, src)
    return m.group(1) if m else fallback


MAX_PAYLOAD_BYTES = _read_property("maxPayloadBytes", "6132")
MAX_RAW_BYTES = _read_property("maxRawBytes", "8191")


def body(fn):
    m = re.search(r"function %s\(field\) \{(.*?)\n  \}" % fn, src, re.S)
    text = m.group(1)
    # drop comment lines and the label/label ternary, they are not part of
    # the generated script
    text = "\n".join(
        l for l in text.splitlines()
        if not l.strip().startswith("//") and "var label" not in l and "var what" not in l
    )
    return text


def build(fn, field, label=None):
    text = body(fn)
    out = []
    for piece in re.finditer(r'"((?:[^"\\]|\\.)*)"|\+\s*(\w+(?:\.\w+)?)\s*\+|\+\s*field|\+\s*label', text):
        if piece.group(1) is not None:
            out.append(piece.group(1))
        else:
            token = piece.group(2)
            if token == "field":
                out.append(field)
            elif token == "label":
                out.append(label or "")
            elif token == "what":
                out.append("the to-do list" if field == "todos" else "the note")
            elif token == "root.secretReadCapBytes":
                out.append("1048576")
            elif token == "root.maxPayloadBytes":
                out.append(MAX_PAYLOAD_BYTES)
            elif token == "root.maxRawBytes":
                out.append(MAX_RAW_BYTES)
            else:
                raise SystemExit("unhandled interpolation: " + token)
    script = "".join(out)
    # unescape the JS string escapes
    return script.encode().decode("unicode_escape")


if __name__ == "__main__":
    fn = sys.argv[1]
    field = sys.argv[2]
    label = sys.argv[3] if len(sys.argv) > 3 else None
    sys.stdout.write(build(fn, field, label))
