#!/usr/bin/env python3
"""Render the gitignored resources-personal/ overlay from config.local.json.

Shared by tools/build.sh and tools/build.ps1 so the two platform wrappers
can't drift on how the overlay is generated. Never prints the token.

    python tools/render_overlay.py config.local.json
"""

import json
import sys
import xml.sax.saxutils as sax

PROPERTY_KEYS = (
    ("serverUrl", "string"),
    ("watchToken", "string"),
    ("glanceTitle", "string"),
    ("useMmol", "boolean"),
    ("useNsThresholds", "boolean"),
    ("diagnostics", "boolean"),
    ("lowThreshold", "number"),
    ("highThreshold", "number"),
    ("urgentLow", "number"),
    ("urgentHigh", "number"),
)


def render_value(value, kind):
    if kind == "boolean":
        return "true" if value else "false"
    return sax.escape(str(value))


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: render_overlay.py <config.local.json>\n")
        return 2

    with open(sys.argv[1]) as f:
        cfg = json.load(f)

    lines = ['<?xml version="1.0" encoding="utf-8"?>', "<properties>"]
    for key, kind in PROPERTY_KEYS:
        if key not in cfg:
            continue
        lines.append(
            '    <property id="{}" type="{}">{}</property>'.format(
                key, kind, render_value(cfg[key], kind)
            )
        )
    lines.append("</properties>")

    import os

    os.makedirs("resources-personal", exist_ok=True)
    with open("resources-personal/properties.xml", "w") as f:
        f.write("\n".join(lines) + "\n")

    with open("resources-personal/strings.xml", "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<strings>\n"
            '    <string id="BuildVariant">personal</string>\n'
            "</strings>\n"
        )

    print("Wrote resources-personal/properties.xml and strings.xml (token not shown)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
