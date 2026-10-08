#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fetch exact locked sources, or --verify them without changing a checkout."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], text=True).strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    lock = json.loads((ROOT / "Vendor/dependencies.lock.json").read_text())
    for dep in lock["dependencies"]:
        path = ROOT / dep["path"]
        created = not (path / ".git").exists()
        if created:
            if args.verify:
                raise SystemExit(f"Missing checkout: {path}")
            subprocess.run(["git", "clone", "--no-checkout", "--filter=blob:none", dep["repository"], str(path)], check=True)
        if not args.verify:
            if not created and git(path, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=untracked"):
                raise SystemExit(f"Refusing to change modified vendor checkout: {path}")
            subprocess.run(["git", "-C", str(path), "fetch", "--depth=1", "origin", dep["commit"]], check=True)
            subprocess.run(["git", "-C", str(path), "checkout", "--detach", dep["commit"]], check=True)
            subprocess.run(["git", "-C", str(path), "submodule", "update", "--init", "--recursive", "--depth=1"], check=True)
        if git(path, "rev-parse", "HEAD") != dep["commit"]:
            raise SystemExit(f"Wrong revision: {path}")
        # Ignore untracked build output, but never ship modified tracked upstream code.
        if git(path, "diff", "--ignore-submodules=untracked", "HEAD", "--", "."):
            raise SystemExit(f"Modified vendor source: {path}")
        for module in dep["submodules"]:
            child = path / module["path"]
            if git(child, "rev-parse", "HEAD") != module["commit"]:
                raise SystemExit(f"Wrong submodule revision: {child}")
            if git(child, "diff", "--ignore-submodules=untracked", "HEAD", "--", "."):
                raise SystemExit(f"Modified submodule source: {child}")
        print(f"Pinned {dep['path']} at {dep['commit']}")

if __name__ == "__main__":
    main()
