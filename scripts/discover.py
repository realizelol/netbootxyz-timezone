#!/usr/bin/env python3

import json
import os
import re
import sys

import yaml


CONFIG_FILE = "config.yml"
ENDPOINTS_FILE = "endpoints.yml"


def load_yaml(filename):
    with open(filename, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def parse_release_path(path):
    """
    Erwartet z.B.:

        /ubuntu-squash/releases/download/22-8770cb66/

    oder:

        /debian-squash/releases/download/2026.1-f03c4b56/

    Gibt zurück:

        ("ubuntu-squash", "22-8770cb66")

    """

    path = str(path).strip().rstrip("/")

    match = re.match(
        r"^/([^/]+)/releases/download/([^/]+)$",
        path,
    )

    if not match:
        return None

    return match.group(1), match.group(2)


def version_sort_key(version):
    """
    Sortiert Versionsnummern möglichst sinnvoll.

    Beispiele:

        22
        23
        24
        2026.1
        2026.2
    """

    parts = re.findall(r"\d+|[A-Za-z]+", str(version))

    result = []

    for part in parts:
        if part.isdigit():
            result.append((0, int(part)))
        else:
            result.append((1, part.lower()))

    return result


def main():

    print("============================================================")
    print("Live timezone initrd - Target Discovery")
    print("============================================================")
    print()

    config = load_yaml(CONFIG_FILE)
    endpoint_data = load_yaml(ENDPOINTS_FILE)

    endpoints = endpoint_data.get("endpoints")

    if not isinstance(endpoints, dict):
        print(
            "FEHLER: endpoints.yml enthält kein gültiges "
            "'endpoints:' Dictionary.",
            file=sys.stderr,
        )
        sys.exit(1)

    targets_config = config.get("targets", [])

    if not isinstance(targets_config, list):
        print(
            "FEHLER: config.yml: 'targets' muss eine Liste sein.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(
        f"Gefundene Endpoints insgesamt: {len(endpoints)}"
    )
    print()

    targets = []

    for target in targets_config:

        if not isinstance(target, dict):
            print(
                "WARNING: Ungültiges Target übersprungen."
            )
            continue

        wanted_os = str(
            target.get("os", "")
        ).strip().lower()

        flavors = target.get("flavors", [])

        if not wanted_os:
            print(
                "WARNING: Target ohne 'os' übersprungen."
            )
            continue

        if not isinstance(flavors, list):
            print(
                f"WARNING: {wanted_os}: "
                "'flavors' muss eine Liste sein."
            )
            continue

        for wanted_flavor in flavors:

            wanted_flavor = str(
                wanted_flavor
            ).strip().lower()

            print(
                f"Suche Endpoint für "
                f"{wanted_os}/{wanted_flavor} ..."
            )

            matches = []

            for endpoint_name, endpoint in endpoints.items():

                if not isinstance(endpoint, dict):
                    continue

                endpoint_os = str(
                    endpoint.get("os", "")
                ).strip().lower()

                endpoint_flavor = str(
                    endpoint.get("flavor", "")
                ).strip().lower()

                if endpoint_os != wanted_os:
                    continue

                if endpoint_flavor != wanted_flavor:
                    continue

                files = endpoint.get("files", [])

                if not isinstance(files, list):
                    continue

                if "initrd" not in files:
                    continue

                parsed_path = parse_release_path(
                    endpoint.get("path", "")
                )

                if not parsed_path:
                    print(
                        f"WARNING: {endpoint_name}: "
                        f"Release-Pfad konnte nicht "
                        f"interpretiert werden: "
                        f"{endpoint.get('path', '')}"
                    )
                    continue

                repository, release = parsed_path

                version = str(
                    endpoint.get(
                        "version",
                        release,
                    )
                )

                matches.append(
                    {
                        "endpoint": endpoint_name,
                        "endpoint_data": endpoint,
                        "repository": repository,
                        "release": release,
                        "version": version,
                    }
                )

            if not matches:

                print(
                    f"WARNING: Kein Endpoint für "
                    f"{wanted_os}/{wanted_flavor} gefunden"
                )
                print()

                continue

            # Neueste Version auswählen.
            matches.sort(
                key=lambda item: version_sort_key(
                    item["version"]
                ),
                reverse=True,
            )

            selected = matches[0]

            endpoint_name = selected["endpoint"]
            version = selected["version"]
            release = selected["release"]
            repository = selected["repository"]

            source_url = (
                "https://github.com/"
                "netbootxyz/"
                f"{repository}/"
                "releases/download/"
                f"{release}/initrd"
            )

            release_tag = (
                f"{wanted_os}-"
                f"{wanted_flavor}-"
                f"{release}"
            )

            result = {
                "os": wanted_os,
                "flavor": wanted_flavor,
                "endpoint": endpoint_name,
                "version": version,
                "release": release,
                "repository": repository,
                "source_url": source_url,
                "release_tag": release_tag,
            }

            targets.append(result)

            print(
                f"OK: {wanted_os}/{wanted_flavor}"
            )
            print(
                f"    Endpoint : {endpoint_name}"
            )
            print(
                f"    Version  : {version}"
            )
            print(
                f"    Release  : {release}"
            )
            print(
                f"    Repo     : {repository}"
            )
            print(
                f"    Source   : {source_url}"
            )
            print(
                f"    Tag      : {release_tag}"
            )
            print()

    if not targets:

        print(
            "FEHLER: Keine passenden Targets gefunden.",
            file=sys.stderr,
        )

        sys.exit(1)

    print("============================================================")
    print("Gefundene Targets")
    print("============================================================")

    for target in targets:
        print(
            f"- {target['os']}/{target['flavor']} "
            f"-> {target['version']} "
            f"({target['release']})"
        )

    print()

    # JSON für GitHub Actions.
    matrix = json.dumps(
        targets,
        separators=(",", ":"),
    )

    # GitHub Output.
    github_output = os.environ.get("GITHUB_OUTPUT")

    if not github_output:
        print(
            "FEHLER: GITHUB_OUTPUT ist nicht gesetzt.",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(
        github_output,
        "a",
        encoding="utf-8",
    ) as f:

        f.write(
            f"matrix={matrix}\n"
        )


if __name__ == "__main__":
    main()
