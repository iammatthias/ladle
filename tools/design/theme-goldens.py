#!/usr/bin/env python3
"""Writes ApronKit's theme goldens from apron-web's own code at the pinned commit.

Copies src/lib/ui/appearance.svelte.ts and theme-colors.ts at tools/design/UPSTREAM's commit into
a temporary directory (storage stubbed, since it only saves), runs theme-goldens.ts there with bun,
and writes Packages/ApronKit/Tests/ApronKitTests/Fixtures/themes/apron-web.json. ThemeTests holds
ApronKit's port of parseThemeCss and deriveTokens to it.

    tools/design/theme-goldens.py           write the fixture
    tools/design/theme-goldens.py --check   exit 1 if it differs from a fresh run
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import tokens  # noqa: E402

OUT = tokens.ROOT / "Packages/ApronKit/Tests/ApronKitTests/Fixtures/themes/apron-web.json"


def run():
    commit = tokens.pinned_commit()
    tokens.ensure(commit)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        appearance = tokens.source(commit, "src/lib/ui/appearance.svelte.ts")
        if "from './storage';" not in appearance:
            sys.exit("theme-goldens.py: appearance.svelte.ts no longer imports './storage' as the stub expects")
        # Outside Svelte a $state rune is its initial value.
        appearance = re.sub(r"\$state(<[^>]*>)?\(", "(", appearance.replace("from './storage';", "from './storage-stub';"))
        (work / "appearance.svelte.ts").write_text(appearance)
        (work / "theme-colors.ts").write_text(tokens.source(commit, "src/lib/ui/theme-colors.ts"))
        (work / "storage-stub.ts").write_text("export const loadAppearance = () => null;\nexport const saveAppearance = () => {};\n")
        shutil.copy(Path(__file__).with_name("theme-goldens.ts"), work / "goldens.ts")
        result = subprocess.run(
            ["bun", str(work / "goldens.ts")], capture_output=True, text=True, cwd=work
        )
        if result.returncode != 0:
            sys.exit("theme-goldens.py: bun failed: " + result.stderr.strip())
        return result.stdout


def main():
    text = run()
    if sys.argv[1:] == ["--check"]:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit(f"theme-goldens.py: {OUT.relative_to(tokens.ROOT)} differs from apron-web; run tools/design/theme-goldens.py")
        print("theme-goldens.py: the theme goldens match apron-web")
    else:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(text)
        print(f"theme-goldens.py: wrote {OUT.relative_to(tokens.ROOT)}")


if __name__ == "__main__":
    main()
