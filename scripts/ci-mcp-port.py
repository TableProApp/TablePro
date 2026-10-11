#!/usr/bin/env python3
import os
import sys
from pathlib import Path


def port_for_run(run_id, slot):
    if not 1 <= slot <= 11:
        raise ValueError("MCP port slot must be between 1 and 11")
    return 20000 + (run_id % 2500) * 16 + slot


def main():
    port = port_for_run(int(os.environ["GITHUB_RUN_ID"]), int(sys.argv[1]))
    with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as output:
        output.write(f"TABLEPRO_TEST_MCP_HTTP_PORT={port}\n")


if __name__ == "__main__":
    main()
