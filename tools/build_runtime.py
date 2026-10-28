"""Download a pinned official CPython Windows runtime, without copying host data."""
import argparse
import hashlib
import io
import json
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "3.13.17"
URL = f"https://www.python.org/ftp/python/{VERSION}/python-{VERSION}-embed-amd64.zip"
SHA256 = "9e35319bffedab8b36ad44d8f377cb4f1733bcec257a0b6d04d94f01486ddb38"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "runtime")
    parser.add_argument("--archive", type=Path, help="Use a previously downloaded official ZIP")
    args = parser.parse_args()
    target = args.output.resolve()
    if target.exists() and any(target.iterdir()):
        parser.error("Output directory must be empty; choose a new --output path.")
    if args.archive:
        content = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(URL, timeout=90) as response:
            content = response.read()
    if hashlib.sha256(content).hexdigest() != SHA256:
        raise ValueError("Official CPython archive SHA-256 verification failed")
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        for entry in archive.infolist():
            (target / entry.filename).resolve().relative_to(target)
        if archive.testzip() is not None:
            raise ValueError("Damaged CPython archive")
        target.mkdir(parents=True, exist_ok=True)
        archive.extractall(target)
    (target / "UPSTREAM.json").write_text(json.dumps({
        "name": "CPython Windows embeddable package (64-bit)",
        "version": VERSION, "url": URL, "sha256": SHA256, "license": "LICENSE.txt",
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Verified portable Python {VERSION}: {target}")


if __name__ == "__main__":
    main()
