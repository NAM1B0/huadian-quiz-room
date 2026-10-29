"""Package a real unsigned arm64 Xcode archive for AltStore to re-sign."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

archive, output = map(Path, sys.argv[1:3])
app = archive / "Products/Applications/HuadianQuiz.app"
assert app.is_dir(), "Missing compiled iOS app"
with (app / "Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert info["CFBundleIdentifier"] == "io.github.nam1b0.huadianquiz"
assert info["CFBundleShortVersionString"] == "1.0.4"
assert info["DTPlatformName"] == "iphoneos", "Simulator builds cannot be sideloaded"
assert int(info["MinimumOSVersion"].split(".")[0]) >= 26
assert info["UIDeviceFamily"] == [1]
assert "arm64" in subprocess.check_output(["lipo", "-archs", str(app / info["CFBundleExecutable"])], text=True)
bank = json.loads((app / "bank.json").read_text())
assert len(bank["questions"]) == 563 and len(bank["groups"]) == 18
assert (app / "题库原文.pdf").is_file()
assert not list(app.rglob("*.sqlite3")) and not list(app.rglob("study.json")), "Personal data must not ship"
output.mkdir(parents=True, exist_ok=True)
staging = output / "staging" / "Payload"
staging.mkdir(parents=True, exist_ok=True)
shutil.copytree(app, staging / app.name)
ipa = output / "huadian-quiz-room-v1.0.4-ios26.ipa"
subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staging), str(ipa)], check=True)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(output / (ipa.name + ".sha256")).write_text(digest + "  " + ipa.name + "\n")
(output / "build-info.json").write_text(json.dumps({"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "minimumOS": info["MinimumOSVersion"], "sdk": info["DTSDKName"], "bundleID": info["CFBundleIdentifier"], "architecture": "arm64", "signing": "Unsigned; re-sign with AltStore Classic", "sha256": digest}, indent=2))
print(ipa, ipa.stat().st_size, digest)
