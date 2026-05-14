#!/usr/bin/env python3
"""Render ansible/inventory.yml from inventory.yml.j2.

Reads a JSON context produced by scripts/deploy.sh from Bicep deployment
outputs, applies it to the Jinja2 template, and writes the result.

Usage:
    render-inventory.py <context.json> <template.j2> <output.yml>
"""
from __future__ import annotations

import json
import sys

from jinja2 import Template


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write(
            "usage: render-inventory.py <context.json> <template.j2> <output.yml>\n"
        )
        return 2

    ctx_path, tmpl_path, out_path = sys.argv[1:4]

    with open(ctx_path, "r", encoding="utf-8") as f:
        ctx = json.load(f)

    with open(tmpl_path, "r", encoding="utf-8") as f:
        tmpl = Template(f.read(), trim_blocks=True, lstrip_blocks=True)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(tmpl.render(**ctx))

    return 0


if __name__ == "__main__":
    sys.exit(main())
