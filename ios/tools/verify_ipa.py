"""Verify the device binary, offline resources, and portable ZIP paths."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("ipa", type=Path)
parser.add_argument("--build", required=True)
args = parser.parse_args()
ipa = args.ipa
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
assert digest == ipa.with_name(ipa.name + ".sha256").read_text().split()[0], "IPA checksum mismatch"
with zipfile.ZipFile(ipa) as package:
    assert package.testzip() is None, "Invalid ZIP CRC"
    base = "Payload/HuadianQuiz.app/"
    names = package.namelist()
    assert all(name.isascii() for name in names), "Non-ASCII bundle path may break sideload extractors"
    info = plistlib.loads(package.read(base + "Info.plist"))
    assert info["CFBundleIdentifier"] == "io.github.nam1b0.huadianquiz"
    assert info["CFBundleShortVersionString"] == "1.0.4"
    assert info["CFBundleVersion"] == args.build
    assert info["MinimumOSVersion"] == "26.0" and info["DTPlatformName"] == "iphoneos"
    assert info["UIDeviceFamily"] == [1]
    bank = json.loads(package.read(base + "bank.json"))
    assert len(bank["questions"]) == 563 and len(bank["groups"]) == 18
    pdf = package.read(base + "question-bank.pdf")
    source = Path(__file__).resolve().parents[2] / "source" / "题库原文.pdf"
    assert pdf.startswith(b"%PDF") and pdf == source.read_bytes(), "PDF resource differs from original"
    assert base + "PrivacyInfo.xcprivacy" in names
    assert not any(name.endswith(("study.json", ".sqlite3", ".xctest")) or "/XCTest.framework/" in name for name in names)
    executable = base + info["CFBundleExecutable"]
    binary = package.read(executable)
    magic, cpu, _, filetype, count, _, _, _ = struct.unpack_from("<8I", binary)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 2, "Not an arm64 executable"
    cursor, platform = 32, None
    for _ in range(count):
        command, length = struct.unpack_from("<2I", binary, cursor)
        if command == 0x32:
            platform, minimum, _ = struct.unpack_from("<3I", binary, cursor + 8)
            assert platform == 2 and minimum == 26 << 16, "Not an iOS 26.0 device binary"
        cursor += length
    assert platform == 2
    assert package.getinfo(executable).external_attr >> 16 & 0o111, "Executable permission missing"
    print(json.dumps({"file": ipa.name, "bytes": ipa.stat().st_size, "sha256": digest,
                      "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                      "minimumOS": info["MinimumOSVersion"], "sdk": info["DTSDKName"],
                      "architecture": "arm64", "platform": "iOS device", "asciiPaths": True,
                      "pdfResource": "question-bank.pdf", "pdfSHA256": hashlib.sha256(pdf).hexdigest(),
                      "questions": 563, "privateData": False}, indent=2))
