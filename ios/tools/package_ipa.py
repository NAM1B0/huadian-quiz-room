"""Package a real unsigned arm64 Xcode archive for AltStore to re-sign."""
from pathlib import Path
import hashlib
import json
import plistlib
import os
import subprocess
import sys
import zipfile

archive, output = map(Path, sys.argv[1:3])
app = archive / "Products/Applications/HuadianQuiz.app"
assert app.is_dir(), "Missing compiled iOS app"
with (app / "Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert info["CFBundleIdentifier"] == "io.github.nam1b0.huadianquiz"
assert info["CFBundleShortVersionString"] == "1.0.4"
assert info["CFBundleVersion"] == "10403"
assert info["DTPlatformName"] == "iphoneos", "Simulator builds cannot be sideloaded"
assert int(info["MinimumOSVersion"].split(".")[0]) >= 26
assert info["UIDeviceFamily"] == [1]
assert "arm64" in subprocess.check_output(["lipo", "-archs", str(app / info["CFBundleExecutable"])], text=True)
bank = json.loads((app / "bank.json").read_text())
assert len(bank["questions"]) == 563 and len(bank["groups"]) == 18
pdf = app / "question-bank.pdf"
assert pdf.is_file()
assert pdf.read_bytes() == (Path(__file__).resolve().parents[2] / "source/题库原文.pdf").read_bytes(), "Bundled PDF differs from source"
assert not list(app.rglob("*.sqlite3")) and not list(app.rglob("study.json")), "Personal data must not ship"
output.mkdir(parents=True, exist_ok=True)
ipa = output / "huadian-quiz-room-v1.0.4-ios26-build10403.ipa"
# zipfile sets the ZIP UTF-8 flag for Chinese resource names. Some macOS
# archivers omit it, causing sideload extractors to rename the bundled PDF.
with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
    package.write(app.parent, "Payload")
    package.write(app, "Payload/" + app.name)
    for path in sorted(app.rglob("*")):
        name = "Payload/" + path.relative_to(app.parent).as_posix()
        assert name.isascii(), "Bundle filenames must survive Windows sideloading"
        if path.is_symlink():
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = path.lstat().st_mode << 16
            package.writestr(entry, os.readlink(path))
        else:
            package.write(path, name)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(output / (ipa.name + ".sha256")).write_text(digest + "  " + ipa.name + "\n")
(output / "build-info.json").write_text(json.dumps({"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "minimumOS": info["MinimumOSVersion"], "sdk": info["DTSDKName"], "bundleID": info["CFBundleIdentifier"], "architecture": "arm64", "signing": "Unsigned; re-sign with AltStore Classic", "sha256": digest, "pdfResource": pdf.name, "pdfSHA256": hashlib.sha256(pdf.read_bytes()).hexdigest()}, indent=2))
print(ipa, ipa.stat().st_size, digest)
