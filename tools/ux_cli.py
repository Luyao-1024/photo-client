#!/usr/bin/env python3
"""Run the real UX journey; see ux_journey.py and docs/local-first/ux-tests.md."""
import sys

try:
    from ux_journey import main
except ModuleNotFoundError as exc:
    if exc.name == "yaml":
        sys.exit("ux: PyYAML is required; install requirements-dev.txt")
    raise

sys.exit(main())
