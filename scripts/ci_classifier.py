#!/usr/bin/env python3
"""Conservatively map changed repository paths to CI risk gates."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import PurePosixPath


GATES = (
    "powershell",
    "renderer",
    "manager",
    "package",
    "installer",
    "compose",
    "container",
    "container_arm64",
    "pages",
)

ALL_VALIDATION_GATES = GATES[:-1]

FAST_ONLY_SCRIPTS = {
    "scripts/check-links.ps1",
    "scripts/optimize-email-gifs.py",
    "scripts/test-asset-refresh.py",
    "scripts/test-gui-preview-personal-stats.mjs",
    "scripts/test-manager-accessibility.py",
    "scripts/test-manager-cache-verification.mjs",
    "scripts/test-manager-header-refresh.mjs",
    "scripts/test-manager-preview-refresh.mjs",
    "scripts/test-manager-update-indicator.mjs",
    "scripts/test-manager-user-email-overrides.mjs",
    "scripts/validate-branding.ps1",
    "scripts/validate-docs.ps1",
    "scripts/validate-release-history.ps1",
    "scripts/validate-repository.ps1",
    "scripts/validate-shell.sh",
    "scripts/validate-unraid-template.ps1",
}

RENDERER_TEST_MARKERS = (
    "binge-champion",
    "cache-diagnostics",
    "deleted-item-cache",
    "library-selection",
    "newsletter-integration",
    "recipient-watched",
    "renderer-collection",
    "sendall-recipient",
    "smtp-transport",
    "top-movie-genre",
    "user-exclusion",
)

RENDERER_RUNTIME_NAMES = {
    "cache-diagnostics.ps1",
    "deleteditemcache.ps1",
    "operation-lock.ps1",
    "smtp-transport.ps1",
    "tautweekly.ps1",
}

PACKAGED_GUIDES = {
    "docs/freebsd/readme.md",
    "docs/linux/readme.md",
    "docs/mac/readme.md",
    "docs/nas-docker/readme.md",
    "docs/windows/readme.md",
}

EXECUTABLE_SUFFIXES = {
    ".go",
    ".js",
    ".mjs",
    ".ps1",
    ".py",
    ".sh",
    ".yaml",
    ".yml",
}


def empty_result() -> dict[str, bool]:
    return {gate: False for gate in GATES}


def enable(result: dict[str, bool], *gates: str) -> None:
    for gate in gates:
        result[gate] = True


def enable_all_validation(result: dict[str, bool]) -> None:
    enable(result, *ALL_VALIDATION_GATES)


def classify_path(raw_path: str) -> dict[str, bool]:
    """Classify one path. Unknown executable inputs fail closed."""

    path = raw_path.replace("\\", "/").removeprefix("./").lower()
    result = empty_result()
    name = PurePosixPath(path).name
    suffix = PurePosixPath(path).suffix

    if path in {"scripts/ci_classifier.py", "scripts/test_ci_classifier.py"}:
        enable_all_validation(result)
        enable(result, "pages")
        return result

    if path == ".github/workflows/ci.yml":
        enable_all_validation(result)
        enable(result, "pages")
        return result
    if path == ".github/workflows/container.yml":
        enable(result, "container", "container_arm64")
        return result
    if path == ".github/workflows/release.yml":
        enable(result, "manager", "package", "installer", "container", "container_arm64")
        return result
    if path == ".github/workflows/pages.yml":
        enable(result, "pages")
        return result
    if path.startswith(".github/workflows/") or path.startswith(".github/actions/"):
        enable_all_validation(result)
        enable(result, "pages")
        return result

    if path.startswith("docs/"):
        enable(result, "pages")
        if path in PACKAGED_GUIDES:
            enable(result, "package")
        return result

    if path in {"license", "third_party_notices.md"}:
        enable(result, "package")
        return result

    if path == "ca_profile.xml" or path.startswith("templates/"):
        enable(result, "renderer", "package", "container")
        return result

    if path.startswith("manager/"):
        enable(result, "manager", "package", "installer", "container", "container_arm64")
        return result

    if path.startswith("installer/"):
        enable(result, "package", "installer")
        return result

    if path.startswith("platforms/"):
        enable(result, "package")

        if suffix == ".ps1":
            enable(result, "powershell")
        if name in RENDERER_RUNTIME_NAMES or "/assets-default/" in path:
            enable(result, "renderer")

        if (
            "/compose" in path
            or path.endswith("/my-tautulli.xml")
            or path.endswith("/tautweekly.env.example")
            or path.endswith("/runtime-profile.sh")
        ):
            enable(result, "compose")

        if path.startswith("platforms/nas-docker/app/") or path.startswith(
            "platforms/mac-docker/app/"
        ):
            enable(result, "container")

        if "dockerfile" in name or name in {
            ".dockerignore",
            "entrypoint.sh",
            "healthcheck.sh",
            "runtime-profile.sh",
            "run-as-user.sh",
            "run-mode.sh",
            "run-script.sh",
            "run-service.sh",
        }:
            enable(result, "container", "container_arm64")

        if path.startswith("platforms/nas-docker/") and (
            "dockerfile" in name or "/app/" in path
        ):
            enable(result, "container")
        return result

    if path.startswith("scripts/"):
        if path in FAST_ONLY_SCRIPTS:
            return result

        if path == "scripts/validate-platforms.ps1":
            enable_all_validation(result)
            return result

        if suffix == ".ps1":
            enable(result, "powershell")

        if any(marker in path for marker in RENDERER_TEST_MARKERS):
            enable(result, "powershell", "renderer")

        if any(
            marker in path
            for marker in (
                "build-releases",
                "linux-manager-package",
                "release-artifact",
                "release-reproducibility",
            )
        ):
            enable(result, "package")

        if "manager" in path:
            enable(result, "manager")
        if "windows-installer" in path:
            enable(result, "package", "installer")
        if "container" in path:
            enable(result, "compose", "container")
        if "container-image" in path or "manager-cross-build" in path:
            enable(result, "container_arm64")

        if not any(result.values()) and suffix in EXECUTABLE_SUFFIXES:
            enable_all_validation(result)
        return result

    if path.startswith(".github/issue_template/") or path in {
        ".github/pull_request_template.md",
        "agents.md",
        "changelog.md",
        "contributing.md",
        "readme.md",
    }:
        return result

    if suffix in EXECUTABLE_SUFFIXES:
        enable_all_validation(result)
    return result


def classify_paths(paths: list[str], scope: str = "auto") -> dict[str, bool]:
    result = empty_result()
    if scope == "full":
        enable(result, *GATES)
        return result
    if scope == "fast":
        return result

    for path in paths:
        path_result = classify_path(path)
        for gate, selected in path_result.items():
            result[gate] = result[gate] or selected
    return result


def changed_paths(base: str, head: str) -> list[str]:
    if base and set(base) == {"0"}:
        command = ["git", "ls-tree", "-r", "--name-only", head]
    else:
        command = ["git", "diff", "--name-only", "--diff-filter=ACMRD", base, head]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return [line.strip() for line in completed.stdout.splitlines() if line.strip()]


def write_github_output(path: str, result: dict[str, bool], files: list[str]) -> None:
    with open(path, "a", encoding="utf-8") as output:
        for gate in GATES:
            output.write(f"{gate}={'true' if result[gate] else 'false'}\n")
        output.write(f"files_json={json.dumps(files, separators=(',', ':'))}\n")


def write_summary(path: str, result: dict[str, bool], files: list[str], scope: str) -> None:
    selected = [gate for gate in GATES if result[gate]] or ["fast layer only"]
    with open(path, "a", encoding="utf-8") as summary:
        summary.write("## CI change classification\n\n")
        summary.write(f"Scope: `{scope}`  \n")
        summary.write(f"Changed paths: `{len(files)}`  \n")
        summary.write(f"Selected gates: {', '.join(f'`{gate}`' for gate in selected)}\n\n")
        if files:
            summary.write("<details><summary>Changed paths</summary>\n\n")
            summary.write("\n".join(f"- `{item}`" for item in files))
            summary.write("\n\n</details>\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--scope", choices=("auto", "fast", "full"), default="auto")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = parser.parse_args()

    files = changed_paths(args.base, args.head)
    result = classify_paths(files, args.scope)
    if args.github_output:
        write_github_output(args.github_output, result, files)
    if args.summary:
        write_summary(args.summary, result, files, args.scope)
    json.dump({"files": files, "gates": result}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
