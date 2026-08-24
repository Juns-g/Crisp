#!/usr/bin/env python3
"""Update Crisp's release cask without rewriting unrelated Ruby content."""

from __future__ import annotations

import argparse
import os
import re
import stat
import tempfile
from pathlib import Path


BINARY_STANZA = 'binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"'
VERSION_LINE = re.compile(r'^(?P<indent>\s*)version\s+"[^"]*"\s*$')
SHA_LINE = re.compile(r'^(?P<indent>\s*)sha256\s+"[^"]*"\s*$')
APP_LINE = re.compile(r'^(?P<indent>\s*)app\s+"Crisp\.app"\s*$')
BINARY_LINE = re.compile(
    r'^\s*binary\s+"#\{appdir\}/Crisp\.app/Contents/MacOS/crispctl"\s*$'
)
BLOCK_OPEN_LINE = re.compile(r"^(?!\s*#)\s*.*\bdo(?:\s+\|[^|]*\|)?\s*$")
SAFE_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]*$")
SAFE_SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")


class CaskTransformError(ValueError):
    pass


def _line_body(line: str) -> str:
    return line.rstrip("\r\n")


def _line_ending(line: str) -> str:
    return line[len(_line_body(line)) :]


def _ruby_code_contains_brace(line: str) -> bool:
    quote = None
    escaped = False
    for character in line:
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            continue

        if character == "#":
            break
        if character in ('"', "'"):
            quote = character
        elif character in "{}":
            return True

    if quote is not None:
        raise CaskTransformError("unterminated Ruby quoted string")
    return False


def transform(content: str, version: str, sha256: str) -> str:
    if not SAFE_VERSION.fullmatch(version):
        raise CaskTransformError(f"unsafe version value: {version!r}")
    if not SAFE_SHA256.fullmatch(sha256):
        raise CaskTransformError("sha256 must contain exactly 64 hex characters")

    newline_styles = set(re.findall(r"\r\n|\r|\n", content))
    if newline_styles not in ({"\n"}, {"\r\n"}):
        raise CaskTransformError("mixed or ambiguous newline style")

    lines = content.splitlines(keepends=True)
    if not lines:
        raise CaskTransformError("cask is empty")
    preliminary_app_indexes = [
        index
        for index, line in enumerate(lines)
        if APP_LINE.fullmatch(_line_body(line))
    ]
    if any(not _line_ending(lines[index]) for index in preliminary_app_indexes):
        raise CaskTransformError("app stanza must end with a newline")
    if _line_body(lines[0]) != 'cask "crisp" do' or _line_body(lines[-1]) != "end":
        raise CaskTransformError('expected top-level cask "crisp" do wrapper')

    for line in lines[1:-1]:
        if _ruby_code_contains_brace(_line_body(line)):
            raise CaskTransformError("unsupported Ruby brace/block syntax")

    version_indexes = []
    sha_indexes = []
    app_indexes = []
    binary_indexes = []
    depth = 1
    for index, line in enumerate(lines[1:-1], start=1):
        body = _line_body(line)
        if re.fullmatch(r"\s*end\s*", body):
            if depth == 1:
                raise CaskTransformError("unexpected end inside top-level cask block")
            depth -= 1
            continue

        version_match = VERSION_LINE.fullmatch(body)
        sha_match = SHA_LINE.fullmatch(body)
        app_match = APP_LINE.fullmatch(body)
        binary_match = BINARY_LINE.fullmatch(body)
        if any((version_match, sha_match, app_match, binary_match)) and depth != 1:
            raise CaskTransformError(
                "release stanzas must be in the top-level cask block"
            )
        if version_match:
            version_indexes.append(index)
        if sha_match:
            sha_indexes.append(index)
        if app_match:
            app_indexes.append(index)
        if binary_match:
            binary_indexes.append(index)
        elif (
            not body.lstrip().startswith("#")
            and "Contents/MacOS/crispctl" in body
        ):
            raise CaskTransformError(
                "found an unrecognized crispctl cask stanza; refusing to guess"
            )
        if BLOCK_OPEN_LINE.fullmatch(body):
            depth += 1

    if depth != 1:
        raise CaskTransformError("unbalanced nested block in cask")

    for label, indexes in (
        ("version", version_indexes),
        ("sha256", sha_indexes),
        ('app "Crisp.app"', app_indexes),
    ):
        if len(indexes) != 1:
            raise CaskTransformError(
                f"expected exactly one {label} stanza, found {len(indexes)}"
            )

    app_index = app_indexes[0]

    version_index = version_indexes[0]
    sha_index = sha_indexes[0]
    version_match = VERSION_LINE.fullmatch(_line_body(lines[version_index]))
    sha_match = SHA_LINE.fullmatch(_line_body(lines[sha_index]))
    assert version_match is not None
    assert sha_match is not None
    lines[version_index] = (
        f'{version_match.group("indent")}version "{version}"'
        f"{_line_ending(lines[version_index])}"
    )
    lines[sha_index] = (
        f'{sha_match.group("indent")}sha256 "{sha256.lower()}"'
        f"{_line_ending(lines[sha_index])}"
    )

    app_match = APP_LINE.fullmatch(_line_body(lines[app_index]))
    assert app_match is not None
    newline = _line_ending(lines[app_index])

    without_binary = [
        line for index, line in enumerate(lines) if index not in set(binary_indexes)
    ]
    removed_before_app = sum(index < app_index for index in binary_indexes)
    insertion_index = app_index - removed_before_app + 1
    stanza = f'{app_match.group("indent")}{BINARY_STANZA}{newline}'
    without_binary.insert(insertion_index, stanza)
    return "".join(without_binary)


def update_file(path: Path, version: str, sha256: str) -> None:
    original = path.read_bytes().decode("utf-8", errors="strict")
    updated = transform(original, version, sha256)
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(updated.encode("utf-8", errors="strict"))
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("cask", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    arguments = parser.parse_args()
    try:
        update_file(arguments.cask, arguments.version, arguments.sha256)
    except (CaskTransformError, OSError, UnicodeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
