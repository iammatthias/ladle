#!/usr/bin/env -S uv run --quiet --with fonttools --with brotli python3
"""Converts the faces apron-web carries for its themes into fonts Ladle bundles.

apron-web ships Recursive (cut to its casual sans and casual mono) and Nunito as WOFF2, each in a
Latin and a Latin Extended file that src/lib/design/fonts.css joins with `unicode-range`. Every
file names itself the same (the Recursive ones all "Recursive Sans Linear Light"), and iOS has no
`unicode-range`. So each file becomes a TrueType font with a name of its own, "Apron <face>" for
the Latin one and "Apron <face> Ext" for the other, which `BundledFonts` puts behind it as a
cascade. Glyphs, metrics and the `wght` axis are untouched. The licences (OFL 1.1) come along.

The sources are read at the commit in tools/design/UPSTREAM, as tokens.py reads tokens.css.

    tools/design/fonts.py           write Ladle/Fonts
    tools/design/fonts.py --check   exit 1 if Ladle/Fonts differs from a fresh conversion
"""
import io
import subprocess
import sys
from pathlib import Path

from fontTools.ttLib import TTFont

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import tokens  # noqa: E402

OUT = tokens.ROOT / "Ladle/Fonts"
SOURCE = "src/lib/assets/fonts"
# The web file, and the family it becomes here: fonts.css's family for the Latin file.
FACES = {
    "recursive-casual-latin.woff2": "Apron Recursive Casual",
    "recursive-casual-latin-ext.woff2": "Apron Recursive Casual Ext",
    "recursive-mono-casual-latin.woff2": "Apron Rec Mono Casual",
    "recursive-mono-casual-latin-ext.woff2": "Apron Rec Mono Casual Ext",
    "nunito-latin.woff2": "Apron Nunito",
    "nunito-latin-ext.woff2": "Apron Nunito Ext",
}
LICENCES = ["OFL-Recursive.txt", "OFL-Nunito.txt"]


def blob(commit, path):
    result = subprocess.run(["git", "-C", str(tokens.WEB), "show", f"{commit}:{path}"], capture_output=True)
    if result.returncode != 0:
        sys.exit(f"fonts.py: {path} at {commit[:7]}: {result.stderr.decode().strip()}")
    return result.stdout


def convert(data, family):
    font = TTFont(io.BytesIO(data), recalcTimestamp=False)
    font.flavor = None
    postscript = family.replace(" ", "")
    for record in list(font["name"].names):
        if record.nameID in (1, 4, 16, 21):
            record.string = family
        elif record.nameID in (2, 17, 22):
            record.string = "Regular"
        elif record.nameID == 6:
            record.string = postscript
        elif record.nameID == 3:
            record.string = f"{postscript};apron-web"
        elif record.nameID == 25:
            record.string = postscript
    if "fvar" in font:
        for instance in font["fvar"].instances:
            instance.postscriptNameID = 0xFFFF
    out = io.BytesIO()
    font.save(out, reorderTables=True)
    return out.getvalue()


def outputs():
    commit = tokens.pinned_commit()
    tokens.ensure(commit)
    files = {f"{family.replace(' ', '')}.ttf": convert(blob(commit, f"{SOURCE}/{name}"), family) for name, family in FACES.items()}
    for licence in LICENCES:
        files[licence] = blob(commit, f"{SOURCE}/{licence}")
    return commit, files


def main():
    commit, files = outputs()
    if sys.argv[1:] == ["--check"]:
        present = {p.name for p in OUT.iterdir()} if OUT.exists() else set()
        stale = [name for name, data in files.items() if not (OUT / name).exists() or (OUT / name).read_bytes() != data]
        if stale or present != set(files):
            sys.exit(f"fonts.py: Ladle/Fonts differs from apron-web {commit[:7]} ({', '.join(stale or sorted(present ^ set(files)))}); run tools/design/fonts.py")
        print(f"fonts.py: Ladle/Fonts matches apron-web {commit[:7]}")
        return
    OUT.mkdir(exist_ok=True)
    for name, data in files.items():
        (OUT / name).write_bytes(data)
    print(f"fonts.py: wrote {len(files)} files to Ladle/Fonts from apron-web {commit[:7]}")


if __name__ == "__main__":
    main()
