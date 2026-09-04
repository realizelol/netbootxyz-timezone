#!/usr/bin/env python3

import os
import re
import sys
import yaml


ENDPOINTS_FILE = "endpoints.yml"


def version_key(version):
    return [
        int(x)
        for x in re.findall(r"\d+", str(version))
    ]


def main():
    with open(ENDPOINTS_FILE, "r", encoding="utf-8") as f:
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

        files = entry.get("files", [])

        if "initrd" not in files:
            continue

        version = str(entry.get("version", ""))

        matches.append({
            "name": name,
            "version": version,
            "path": path,
        })

    if not matches:
        print(
            "ERROR: Kein Linux-Mint-XFCE-Endpoint gefunden.",
            file=sys.stderr
        )
        sys.exit(1)

    matches.sort(
        key=lambda x: version_key(x["version"]),
        reverse=True
    )

    selected = matches[0]

    print("Gefundene Mint-XFCE-Endpoints:")
    print()

    for item in matches:
        print(
            f"  {item['name']} | "
            f"Version {item['version']} | "
            f"{item['path']}"
        )

    print()
    print("Ausgewählt:")
    print(
        f"  {selected['name']} | "
        f"Version {selected['version']} | "
        f"{selected['path']}"
    )

    path = selected["path"].strip("/")

    marker = "releases/download/"

    if marker not in path:
        print(
            f"ERROR: Unerwarteter Endpoint-Pfad: "
            f"{selected['path']}",
            file=sys.stderr
        )
        sys.exit(1)

    source_release = path.split(
        marker,
        1
    )[1].strip("/")

    source_url = (
        "https://github.com/"
        "netbootxyz/ubuntu-squash/releases/download/"
        f"{source_release}/initrd"
    )

    release_tag = f"mint-xfce-{source_release}"

    github_output = os.environ.get("GITHUB_OUTPUT")

    if github_output:
        with open(
            github_output,
            "a",
            encoding="utf-8"
        ) as f:
            f.write(
                f"endpoint={selected['name']}\n"
            )
            f.write(
                f"version={selected['version']}\n"
            )
            f.write(
                f"path={selected['path']}\n"
            )
            f.write(
                f"source_url={source_url}\n"
            )
            f.write(
                f"release_tag={release_tag}\n"
            )

    print()
    print(f"Endpoint   : {selected['name']}")
    print(f"Version    : {selected['version']}")
    print(f"Path       : {selected['path']}")
    print(f"Source URL : {source_url}")
    print(f"Release    : {release_tag}")


if __name__ == "__main__":
    main()
