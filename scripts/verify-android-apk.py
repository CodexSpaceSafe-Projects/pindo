#!/usr/bin/env python3
"""Reject Android releases with a changed identity, a debug flag or a version rollback."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk", type=Path)
parser.add_argument("--previous", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
build_tools = sdk / "build-tools/35.0.0"
def output(command):
    return subprocess.check_output([str(item) for item in command], text=True, stderr=subprocess.STDOUT)
cert = subprocess.check_output(["openssl", "x509", "-in", str(root / "android/release-certificate.pem"), "-outform", "DER"])
expected = hashlib.sha256(cert).hexdigest()
verified = output([build_tools / "apksigner", "verify", "--verbose", "--print-certs", args.apk])
certificates = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)", verified)
if certificates != [expected]:
    raise SystemExit("Release signing certificate does not match the permanent identity.")
badging = output([build_tools / "aapt", "dump", "badging", args.apk])
package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
if not package or package[1] != "com.pindo.app" or "application-debuggable" in badging:
    raise SystemExit("Expected the non-debuggable com.pindo.app release variant.")
record = {"applicationId": package[1], "versionCode": int(package[2]), "versionName": package[3],
          "certificateSha256": expected, "sha256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
          "sourceRevision": os.environ["PINDO_COMMIT_SHA"]}
if args.previous and args.previous.exists():
    previous = json.loads(args.previous.read_text())
    if any(previous[key] != record[key] for key in ("applicationId", "certificateSha256")):
        raise SystemExit("A published update identity has changed. Restore the original key.")
    if record["versionCode"] < previous["versionCode"] or (
        record["versionCode"] == previous["versionCode"] and record["sourceRevision"] != previous["sourceRevision"]
    ):
        raise SystemExit("Android versionCode must increase for a new source revision.")
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(record, indent=2) + "\n")
print("Verified permanent certificate, application ID, release flags and update version.")
