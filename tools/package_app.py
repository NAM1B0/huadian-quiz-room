"""Build a Windows release from public files, excluding all personal study data."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.0.0"
FILES = ("server.py", "bank.json", "launch.ps1", "启动华电题库.cmd", "使用说明.txt",
         "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT / "runtime")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "dist" / f"huadian-quiz-room-v{VERSION}-windows-x64.zip")
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    if not (runtime / "pythonw.exe").is_file() or not (runtime / "UPSTREAM.json").is_file():
        parser.error("Build the official runtime with tools/build_runtime.py first.")
    paths = [(ROOT / name, name) for name in FILES]
    for folder, suffixes in (("web", {".js", ".html", ".css", ".svg"}),
                             ("source", {".pdf"}), ("docs", {".png"}),
                             ("tools", {".py", ".json"})):
        paths.extend((p, p.relative_to(ROOT).as_posix()) for p in (ROOT / folder).rglob("*")
                     if p.is_file() and p.suffix in suffixes and "__pycache__" not in p.parts)
    paths.extend((p, "runtime/" + p.relative_to(runtime).as_posix()) for p in runtime.rglob("*")
                 if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc")
    archive = args.output.resolve()
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
        for path, name in sorted(paths, key=lambda item: item[1]):
            if path.is_symlink():
                raise ValueError(f"Refusing symlink: {path}")
            zipped.write(path, "华电题库练习室/" + name)
    with zipfile.ZipFile(archive) as zipped:
        assert zipped.testzip() is None
        assert not any("/data/" in n or ".sqlite3" in n or "/.git/" in n for n in zipped.namelist())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    print(json.dumps({"archive": str(archive), "files": len(paths), "bytes": archive.stat().st_size,
                      "sha256": digest}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
