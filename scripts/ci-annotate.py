"""Expose Swift diagnostics in the GitHub Actions summary and annotations."""
import os
import re
import sys
from pathlib import Path


def escape(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


workspace = os.environ.get("GITHUB_WORKSPACE", "")
pattern = re.compile(r"^(.+?\.swift):(\d+)(?::(\d+))?: error: (.+)$")
diagnostics = set()
summary = []
tails = []
for argument in sys.argv[1:]:
    path = Path(argument)
    if not path.is_file():
        continue
    lines = path.read_text(errors="replace").splitlines()
    tails.append(f"{path.name}:\n" + "\n".join(lines[-30:]))
    for line in lines:
        match = pattern.match(line)
        if not match or match.groups() in diagnostics:
            continue
        diagnostics.add(match.groups())
        filename, row, column, message = match.groups()
        if workspace and filename.startswith(workspace + "/"):
            filename = filename[len(workspace) + 1:]
        property_path = escape(filename).replace(",", "%2C").replace(":", "%3A")
        location = f"{filename}:{row}" + (f":{column}" if column else "")
        properties = f"file={property_path},line={row}" + (f",col={column}" if column else "")
        print(f"::error {properties}::{escape(message)}")
        summary.append(f"{location}: {message}")

if not summary and tails:
    message = tails[-1][-6000:]
    print(f"::error::{escape(message)}")
    summary.append(message)

if summary and os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
        output.write("### Build diagnostics\n\n```text\n")
        output.write("\n".join(summary[:30]).replace("```", "'''"))
        output.write("\n```\n")
