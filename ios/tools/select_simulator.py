"""Create the user's 6.1-inch iPhone model on an installed iOS 26+ runtime."""
import json
import os
import subprocess

def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True)

listing = json.loads(simctl("list", "--json"))
runtimes = [r for r in listing["runtimes"] if r.get("isAvailable") and "iOS" in r["name"] and int(r["version"].split(".")[0]) >= 26]
assert runtimes, "An iOS 26+ simulator runtime is required"
runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
device_type = next(d for d in listing["devicetypes"] if d["name"] == "iPhone 13 Pro")
device = simctl("create", "Huadian iPhone 13 Pro", device_type["identifier"], runtime["identifier"]).strip()
subprocess.run(["xcrun", "simctl", "boot", device], check=True)
subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100"], check=True)
with open(os.environ["GITHUB_ENV"], "a") as f:
    f.write("SIMULATOR_ID=" + device + "\n")
print("Testing iPhone 13 Pro /", runtime["name"], device)
