#!/usr/bin/env python3
"""Generates Ladle's design tokens and themes from apron-web.

The sources are apron-web's src/lib/design/tokens.css and rail.css (the tokens, both modes) and
src/lib/ui/appearance.svelte.ts (the premade themes and the theme CSS limits) at the commit pinned
in tools/design/UPSTREAM, read with `git show`, so the output depends on the pin and not on the
clone's working tree or branch. The clone is ~/Developer/forks/apron-web; APRON_WEB overrides
it. A pin the clone lacks is fetched from its origin first. Two files come out:

- Packages/ApronKit/Sources/ApronKit/WebTokens.swift: every declaration as written, dark and
  light, aliases kept as `var()`, the premade themes' CSS, and the names Ladle applies.
  `ResolvedTheme` reads them, so a theme moves an alias as the browser does.
- Ladle/Design/Tokens.swift: one accessor per token Ladle uses, read from the active theme.

    tools/design/tokens.py           write both files
    tools/design/tokens.py --check   exit 1 if either differs from a fresh generation

The check also says when the clone's origin/main has moved past the pin.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "tools/design/UPSTREAM"
OUT = ROOT / "Ladle/Design/Tokens.swift"
KIT_OUT = ROOT / "Packages/ApronKit/Sources/ApronKit/WebTokens.swift"
WEB = Path(os.environ.get("APRON_WEB", Path.home() / "Developer/forks/apron-web"))

# Tokens the app has no use for: stacking order (SwiftUI orders by view tree), focus rings (iOS
# draws its own focus), web-only widths and the CSS filter. Font stacks are read as themes' fonts.
SKIP = re.compile(
    r"^(font-|z-|focus-ring|focus-offset|ap-|hover-lift|text-field-ios|nudge-w|toast-max-w|"
    r"pref-|iframe-max-h|timeline-max-w)"
)
# The font tokens a theme sets that Ladle applies (TextRole's faces).
FONTS = ["font-sans", "font-chat", "font-mono"]


def pinned_commit():
    for line in PIN.read_text().splitlines():
        if line.startswith("apron-web "):
            return line.split()[1]
    sys.exit("tokens.py: no 'apron-web <commit>' line in " + str(PIN))


def git(*args):
    return subprocess.run(["git", "-C", str(WEB), *args], capture_output=True, text=True)


def ensure(commit):
    """Fetches the clone's origin when it lacks the pinned commit."""
    if git("cat-file", "-e", f"{commit}^{{commit}}").returncode == 0:
        return
    print(f"tokens.py: fetching origin into {WEB} for {commit[:7]}", file=sys.stderr)
    git("fetch", "--quiet", "origin")
    if git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
        sys.exit(f"tokens.py: {WEB} has no commit {commit}, even after fetching; set APRON_WEB to an apron-web clone")


def source(commit, path):
    result = git("show", f"{commit}:{path}")
    if result.returncode != 0:
        sys.exit(f"tokens.py: {path} at {commit[:7]}: {result.stderr.strip()}")
    return result.stdout


def declarations(block):
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    return {k: " ".join(v.split()) for k, v in re.findall(r"--([\w-]+)\s*:\s*([^;]+);", block)}


def block(css, selector):
    start = css.index(selector)
    depth, i = 0, css.index("{", start)
    for j in range(i, len(css)):
        depth += {"{": 1, "}": -1}.get(css[j], 0)
        if depth == 0:
            return css[i + 1 : j]
    raise ValueError(selector)


def resolve(name, theme):
    value = theme[name].strip()
    while (m := re.fullmatch(r"var\(--([\w-]+)\)", value)) :
        value = theme[m.group(1)].strip()
    return value


def kind(value):
    """What Ladle reads a token's value as, or None for a value the generator does not know."""
    if re.fullmatch(r"#[0-9a-fA-F]{6}|rgba\(.*\)|color-mix\(in srgb, var\(--[\w-]+\) \d+%, transparent\)", value):
        return "color"
    if re.fullmatch(r"0 \d+px \d+px rgba\(.*\)", value):
        return "shadow"
    if re.fullmatch(r"\d+(?:\.\d+)?px", value):
        return "length"
    if re.fullmatch(r"\d+(?:\.\d+)?(?:ms|s)", value):
        return "duration"
    if re.fullmatch(r"\d+%", value):
        return "fraction"
    if re.fullmatch(r"0?\.\d+", value):
        return "number"
    if re.fullmatch(r"cubic-bezier\([^)]*\)", value):
        return "curve"
    return None


KEYWORDS = {"private", "default", "public", "internal", "static"}


def camel(name):
    if name[0].isdigit():
        return "s" + name.replace("-", "_")
    head, *rest = name.split("-")
    word = head + "".join(p[:1].upper() + p[1:] for p in rest)
    return f"`{word}`" if word in KEYWORDS else word


GROUPS = [
    ("text-", "TextSize", "Text sizes in points at the Large Dynamic Type setting (`--text-*`)."),
    ("leading-", "Leading", "Line heights in points at the Large setting (`--leading-*`)."),
    ("space-", "Space", "The 4 pt spacing scale, with two half steps (`--space-*`)."),
    ("radius-", "Radius", "Corner radii; nothing interactive has a sharp corner (`--radius-*`)."),
    ("avatar-", "AvatarSize", "Avatar diameters (`--avatar-*`)."),
    ("control-", "Control", "Control box heights (`--control-*`). Ladle pads each to `Size.touchTarget`."),
    ("duration-", "Duration", "Motion durations in seconds (`--duration-*`)."),
    ("opacity-", "Opacity", "Fades (`--opacity-*`)."),
    ("", "Size", "Sizes the client is responsible for, in points."),
]


def swift_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def premade_themes(commit):
    """apron-web's THEMES as (id, name, css), each css as themeCss() writes it."""
    ts = source(commit, "src/lib/ui/appearance.svelte.ts")
    example = re.search(r"const COLOR_EXAMPLE = `([^`]*)`;", ts)
    template = re.search(r"function themeCss\([^)]*\): string \{\s*return `([^`]*)`;\s*\}", ts)
    themes = re.search(r"export const THEMES = \[(.*?)\] as const;", ts, re.S)
    if not (example and template and themes):
        sys.exit("tokens.py: appearance.svelte.ts no longer has COLOR_EXAMPLE, themeCss and THEMES as the generator reads them")
    entry = re.compile(
        r"\{\s*id: '([^']+)',\s*name: '([^']+)',\s*css: themeCss\(\s*\{\s*sans: '([^']*)',\s*chat: '([^']*)',\s*mono: '([^']*)'\s*\}"
        r"(?:,\s*`([^`]*)`)?\s*\)\s*\}"
    )
    found = entry.findall(themes.group(1))
    if len(found) != themes.group(1).count("id: '"):
        sys.exit("tokens.py: a premade theme in appearance.svelte.ts is not in the shape the generator reads")
    out = []
    for theme_id, name, sans, chat, mono, colors in found:
        css = template.group(1)
        for key, value in (("fonts.sans", sans), ("fonts.chat", chat), ("fonts.mono", mono), ("colors", colors or example.group(1))):
            css = css.replace("${" + key + "}", value)
        if "${" in css:
            sys.exit("tokens.py: themeCss has a placeholder the generator does not fill")
        out.append((theme_id, name, css))
    limits = {}
    for constant in ("THEME_CSS_MAX", "THEME_VARS_MAX"):
        m = re.search(rf"const {constant} = (\d+);", ts)
        if not m:
            sys.exit(f"tokens.py: appearance.svelte.ts has no {constant}")
        limits[constant] = int(m.group(1))
    unsafe = re.search(r"export const UNSAFE_VALUE = /(.*)/i;", ts)
    if not unsafe:
        sys.exit("tokens.py: appearance.svelte.ts has no UNSAFE_VALUE")
    return out, limits, unsafe.group(1)


def generate(commit):
    tokens_css = source(commit, "src/lib/design/tokens.css")
    rail_css = source(commit, "src/lib/design/rail.css")
    dark = declarations(block(tokens_css, ":root {"))
    dark.update(declarations(block(rail_css, ":root {")))
    media_light = declarations(block(block(tokens_css, "@media (prefers-color-scheme: light) {"), ":root:not"))
    chosen_light = {k: v for k, v in declarations(block(tokens_css, ":root[data-theme='light'] {")).items() if k != "color-scheme"}
    if media_light != chosen_light:
        sys.exit("tokens.py: tokens.css's two light blocks disagree; apron-web's tokens.test.ts should have caught it")

    colors, shadows, groups, extra, applied = [], [], {g[1]: [] for g in GROUPS}, [], []
    for name in dark:
        if SKIP.match(name):
            continue
        applied.append(name)
        k = kind(resolve(name, dark))
        if k == "color":
            colors.append(name)
        elif k == "shadow":
            shadows.append(name)
        elif k in ("length", "duration"):
            group = next(g for prefix, g, _ in GROUPS if name.startswith(prefix))
            key = name[len(next(p for p, g, _ in GROUPS if g == group)):]
            groups[group].append((key, name, k))
        elif k == "number":
            groups["Opacity"].append((name.removeprefix("opacity-"), name, k))
        elif k == "fraction":
            extra.append(f"    /// `--{name}`, dark and light.\n    static var {camel(name)}: Themed<Double> {{ ActiveTheme.fraction(\"--{name}\") }}")
        elif k == "curve":
            extra.append(f"    /// `--{name}`.\n    static var {camel(name)}: Curve {{ ActiveTheme.curve(\"--{name}\") }}")
        else:
            sys.exit(f"tokens.py: --{name}: {dark[name]!r} is a value the generator does not know; add a rule or skip it")

    header = [
        "// Generated by tools/design/tokens.py from apron-web src/lib/design/tokens.css, rail.css and",
        f"// src/lib/ui/appearance.svelte.ts at {commit}. Do not edit; run tools/design/tokens.py.",
        "",
    ]
    lines = header + [
        "import ApronKit",
        "import CoreGraphics",
        "",
        "/// apron-web's design tokens as the active theme sets them (`ActiveTheme`), both modes. Dark is",
        "/// the reference mode; light is its equal. Under the Apron theme they are tokens.css's own.",
        "///",
        "/// Two hues have jobs. `accent` (rust) is what you can do: buttons, the composer's Send, a",
        "/// mention of you. `denim` is where you can go: links, threads, the New line, a moved message's",
        "/// destination. Every other color is a status and always carries a word beside it, never a",
        "/// color alone. `private` always comes with its lock.",
        "enum Tokens {",
        "    /// Colors as dark and light pairs.",
        "    enum Color {",
    ]
    for name in colors:
        lines.append(f"        static var {camel(name)}: Themed<RGBA> {{ ActiveTheme.color(\"--{name}\") }}")
    lines += ["    }", "", "    /// Shadows as y offset, blur radius and color, per mode.", "    enum Shadow {"]
    for name in shadows:
        lines.append(f"        static var {camel(name.removeprefix('shadow-'))}: Themed<ShadowToken> {{ ActiveTheme.shadow(\"--{name}\") }}")
    lines.append("    }")
    for _, group, doc in GROUPS:
        lines += ["", f"    /// {doc}", f"    enum {group} {{"]
        for key, name, k in groups[group]:
            if k == "length":
                lines.append(f"        static var {camel(key)}: CGFloat {{ ActiveTheme.length(\"--{name}\") }}")
            else:
                lines.append(f"        static var {camel(key)}: Double {{ ActiveTheme.number(\"--{name}\") }}")
        lines.append("    }")
    lines += [""] + extra + ["}", ""]

    themes, limits, unsafe = premade_themes(commit)
    light = {**dark, **media_light}

    def table(values):
        return ["        " + f"{swift_string('--' + k)}: {swift_string(v)}," for k, v in values.items()]

    kit = header + [
        "/// apron-web's tokens and premade themes, as written. `ResolvedTheme` reads them.",
        "public enum WebTokens {",
        "    /// The apron-web commit these come from.",
        f"    public static let commit = {swift_string(commit)}",
        "",
        "    /// Every token tokens.css and rail.css declare on the root, dark (the reference mode).",
        "    static let dark: [String: String] = [",
        *table(dark),
        "    ]",
        "",
        "    /// The same in light: dark's, with tokens.css's light block over them.",
        "    static let light: [String: String] = [",
        *table(light),
        "    ]",
        "",
        "    /// The tokens Ladle applies from a theme: those `Tokens` reads, and the three font stacks.",
        "    public static let applied: Set<String> = [",
        *[f"        {swift_string('--' + name)}," for name in applied + FONTS],
        "    ]",
        "",
        "    /// apron-web's `THEME_CSS_MAX` and `THEME_VARS_MAX`.",
        f"    public static let themeCSSMax = {limits['THEME_CSS_MAX']}",
        f"    public static let themeVarsMax = {limits['THEME_VARS_MAX']}",
        "    /// apron-web's `UNSAFE_VALUE`, matched without case.",
        f"    static let unsafeValue = #\"{unsafe}\"#",
        "",
        "    /// apron-web's `THEMES`, in its order: id, name, and the CSS its Preferences shows.",
        "    static let themes: [(id: String, name: String, css: String)] = [",
        *[f"        ({swift_string(i)}, {swift_string(n)}, {swift_string(c)})," for i, n, c in themes],
        "    ]",
        "}",
        "",
    ]
    return "\n".join(lines), "\n".join(kit)


def main():
    commit = pinned_commit()
    ensure(commit)
    outputs = dict(zip((OUT, KIT_OUT), generate(commit)))
    if sys.argv[1:] == ["--check"]:
        head = git("rev-parse", "origin/main").stdout.strip()
        if head and head != commit and git("merge-base", "--is-ancestor", commit, head).returncode == 0:
            print(f"tokens.py: note: apron-web's origin/main is at {head}, the pin is {commit}; review the design changes and move the pin")
        for path, text in outputs.items():
            if not path.exists() or path.read_text() != text:
                sys.exit(f"tokens.py: {path.relative_to(ROOT)} differs from apron-web at the pinned commit; run tools/design/tokens.py")
        print(f"tokens.py: Tokens.swift and WebTokens.swift match apron-web {commit[:7]}")
    else:
        for path, text in outputs.items():
            path.write_text(text)
            print(f"tokens.py: wrote {path.relative_to(ROOT)} from apron-web {commit[:7]}")


if __name__ == "__main__":
    main()
