#!/usr/bin/env python3
"""Compile a String Catalog (.xcstrings) into per-language Localizable.strings.

The Command Line Tools ship no `xcstringstool`, so the raw-swiftc build path has
no way to bundle the catalog. macOS reads plain-text `.strings` from `<lang>.lproj`
at runtime, so we generate those directly from the catalog JSON.

Usage: xcstrings-compile.py <Localizable.xcstrings> <output Resources dir>
Prints the space-separated list of compiled language codes on stdout (for the
caller to feed into CFBundleLocalizations).
"""
import json, os, sys


def esc(s: str) -> str:
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t"))


def main() -> None:
    catalog, outdir = sys.argv[1], sys.argv[2]
    doc = json.load(open(catalog))
    source = doc.get("sourceLanguage", "en")
    strings = doc["strings"]

    languages = {source}
    for info in strings.values():
        languages.update(info.get("localizations", {}).keys())

    warnings = 0
    for lang in sorted(languages):
        lines = [f"/* Generated from {os.path.basename(catalog)} - do not edit */"]
        for key, info in strings.items():
            if info.get("shouldTranslate") is False and lang != source:
                continue
            entry = info.get("localizations", {}).get(lang)
            if entry and "variations" in entry:
                print(f"WARN: '{key}' has plural/device variations ({lang}); "
                      "not handled by this compiler", file=sys.stderr)
                warnings += 1
            if entry and "stringUnit" in entry:
                value = entry["stringUnit"].get("value", key)
            elif lang == source:
                value = key  # source language: the key is the English value
            else:
                continue     # untranslated: omit so runtime falls back to source
            lines.append(f'"{esc(key)}" = "{esc(value)}";')
        lproj = os.path.join(outdir, f"{lang}.lproj")
        os.makedirs(lproj, exist_ok=True)
        with open(os.path.join(lproj, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        print(f"  {lang}.lproj/Localizable.strings ({len(lines) - 1} entries)",
              file=sys.stderr)

    if warnings:
        print(f"{warnings} unhandled variation(s)", file=sys.stderr)
    print(" ".join(sorted(languages)))


if __name__ == "__main__":
    main()
