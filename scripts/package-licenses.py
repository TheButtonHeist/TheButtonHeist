#!/usr/bin/env python3
"""Include project and dependency licenses in a binary distribution."""

import argparse
from pathlib import Path
import shutil
import sys


ROOT = Path(__file__).resolve().parents[1]


def package(output: Path, checkouts: list[Path]) -> None:
    own = output / "ButtonHeist"
    own.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "LICENSE", own / "LICENSE")
    for checkout in checkouts:
        files = sorted(path for path in checkout.iterdir() if path.is_file()
                       and path.name.upper().startswith(("LICENSE", "NOTICE")))
        if not any(path.name.upper().startswith("LICENSE") for path in files):
            raise ValueError(f"Dependency has no license: {checkout}")
        destination = output / checkout.name
        destination.mkdir(parents=True, exist_ok=True)
        for source in files:
            shutil.copy2(source, destination / source.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("checkouts", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        package(args.output, args.checkouts)
    except (OSError, ValueError) as error:
        sys.exit(f"License packaging failed: {error}")
