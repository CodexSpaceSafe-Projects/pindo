"""Expose Swift diagnostics in the GitHub Actions summary and annotations."""
import os
import re
import sys
from pathlib import Path


def escape(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


workspace = os.environ.get("GITHUB_WORKSPACE", "")
pattern = re.compile(r"^(.+?\.swift):(\d+):(\d+): error: (.+)$")
diagnostics = set()
summary = []
for argument in sys.argv[1:]:
    path = Path(argument)
    if not path.is_file():
        continue
    for line in path.read_text(errors="replace").splitlines():
        match = pattern.match(line)
        if not match or match.groups() in diagnostics:
            continue
        diagnostics.add(match.groups())
        filename, row, column, message = match.groups()
        if workspace and filename.startswith(workspace + "/"):
            filename = filename[len(workspace) + 1:]
        property_path = escape(filename).replace(",", "%2C").replace(":", "%3A")
        print(f"::error file={property_path},line={row},col={column}::{escape(message)}")
        summary.append(f"{filename}:{row}:{column}: {message}")

if summary and os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
        output.write("### Swift compilation errors\n\n```text\n")
        output.write("\n".join(summary[:30]).replace("```", "'''"))
        output.write("\n```\n")
