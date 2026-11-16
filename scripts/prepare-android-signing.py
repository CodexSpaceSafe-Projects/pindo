#!/usr/bin/env python3
"""Create an Android release identity once; keep its private files outside Git."""
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
target = root / "work/android-signing"
target.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(target, 0o700)
payload = target / "github-secret.json"
keystore = target / "pindo-release.p12"
certificate = root / "android/release-certificate.pem"
if payload.exists() or keystore.exists() or certificate.exists():
    raise SystemExit("Signing identity already exists. Restore it; never regenerate an update key.")
java_home = os.environ.get("JAVA_HOME")
keytool = str(Path(java_home) / "bin/keytool") if java_home else shutil.which("keytool")
if not keytool:
    raise SystemExit("Install JDK 17 and set JAVA_HOME first.")
password = secrets.token_urlsafe(36)
env = dict(os.environ, PINDO_KEY_PASSWORD=password)
subprocess.run([
    keytool, "-genkeypair", "-noprompt", "-storetype", "PKCS12", "-keystore", str(keystore),
    "-alias", "pindo", "-keyalg", "RSA", "-keysize", "3072", "-validity", "14600",
    "-dname", "CN=Pindo Android, O=Pindo", "-storepass:env", "PINDO_KEY_PASSWORD",
    "-keypass:env", "PINDO_KEY_PASSWORD",
], env=env, check=True, capture_output=True)
os.chmod(keystore, 0o600)
with os.fdopen(os.open(payload, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
    json.dump({"keystore": base64.b64encode(keystore.read_bytes()).decode(),
               "password": password, "alias": "pindo"}, file)
subprocess.run([
    keytool, "-exportcert", "-rfc", "-keystore", str(keystore), "-alias", "pindo",
    "-storepass:env", "PINDO_KEY_PASSWORD", "-file", str(certificate),
], env=env, check=True, capture_output=True)
print("Private signing identity created in work/android-signing/ (ignored by Git).")
print("Back up this folder securely. Never upload it as a repository file or build artifact.")
print("Set GitHub Actions secret PINDO_ANDROID_SIGNING to the contents of github-secret.json.")
print("With an authenticated GitHub CLI:")
print("gh secret set PINDO_ANDROID_SIGNING --repo CodexSpaceSafe-Projects/pindo < work/android-signing/github-secret.json")
