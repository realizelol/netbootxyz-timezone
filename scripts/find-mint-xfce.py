#!/usr/bin/env python3

import os
import re
import yaml


with open("endpoints.yml", "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)


endpoints = data.get("endpoints", {})

matches = []


for name, entry in endpoints.items():

    if not isinstance(entry, dict):
        continue

    if str(entry.get("os", "")).lower() != "mint":
        continue

    if str(entry.get("flavor", "")).lower() != "xfce":
        continue

    path = entry.get("path")

    if not path:
        continue

    if "initrd" not in entry.get("files", []):
        continue

    version = str(entry.get("version", ""))

    matches.append(
        {
            "name": name,
            "version": version,
            "path": path,
        }
    )


if not matches:
    raise SystemExit(
        "ERROR: Kein Linux Mint XFCE Endpoint gefunden."
    )


def version_key(item):
    return [
        int(x)
        for x in re.findall(
            r"\d+",
            item["version"]
        )
    ]


matches.sort(
    key=version_key,
    reverse=True
)


selected = matches[0]


print("Gefundene Mint XFCE Endpoints:")

for item in matches:
    print(
        item["name"],
        "|",
        item["version"],
        "|",
        item["path"]
    )


path = selected["path"].strip("/")

marker = "releases/download/"

if marker not in path:
    raise SystemExit(
        "ERROR: Unerwarteter Path: "
        + selected["path"]
    )


source_release = path.split(
    marker,
    1
)[1].strip("/")


source_url = (
    "https://github.com/"
    "netbootxyz/ubuntu-squash/"
    "releases/download/"
    + source_release
    + "/initrd"
)


release_tag = "mint-xfce-" + source_release


print()
print("Ausgewählt:")
print("Endpoint:", selected["name"])
print("Version:", selected["version"])
print("Source:", source_url)
print("Release:", release_tag)


output = os.environ.get("GITHUB_OUTPUT")

if output:

    with open(
        output,
        "a",
        encoding="utf-8"
    ) as f:

        f.write(
            "version="
            + selected["version"]
            + "\n"
        )

        f.write(
            "source_url="
            + source_url
            + "\n"
        )

        f.write(
            "release_tag="
            + release_tag
            + "\n"
        )
