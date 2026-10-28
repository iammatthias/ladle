#!/usr/bin/env python3
"""Generates Ladle/Design/Tokens.swift from apron-web's design tokens.

The source is apron-web's src/lib/design/tokens.css and rail.css at the commit pinned in
tools/design/UPSTREAM, read with `git show`, so the output depends on the pin and not on the
clone's working tree. APRON_WEB overrides the clone's path.

    tools/design/tokens.py           write Tokens.swift
    tools/design/tokens.py --check   exit 1 if Tokens.swift differs from a fresh generation

The check also says when the clone's HEAD has moved past the pin.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "tools/design/UPSTREAM"
OUT = ROOT / "Ladle/Design/Tokens.swift"
WEB = Path(os.environ.get("APRON_WEB", Path.home() / "Developer/forks/apron-server-go/.apron-web"))

# Tokens the app has no use for: font stacks (the app uses SF and SF Mono), stacking order (SwiftUI
# orders by view tree), focus rings (iOS draws its own focus), web-only widths and the CSS filter.
SKIP = re.compile(
    r"^(font-|z-|focus-ring|focus-offset|ap-|hover-lift|text-field-ios|nudge-w|toast-max-w|"
    r"pref-|iframe-max-h|timeline-max-w)"
)


def pinned_commit():
    for line in PIN.read_text().splitlines():
        if line.startswith("apron-web "):
            return line.split()[1]
    sys.exit("tokens.py: no 'apron-web <commit>' line in " + str(PIN))


def source(commit, path):
    return subprocess.run(
        ["git", "-C", str(WEB), "show", f"{commit}:{path}"], check=True, capture_output=True, text=True
    ).stdout


def declarations(block):
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    return dict(re.findall(r"--([\w-]+)\s*:\s*([^;]+);", block))


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


def color(value, theme):
    """An sRGB color as (rgb, alpha), or None when the value is not a color."""
    if m := re.fullmatch(r"#([0-9a-fA-F]{6})", value):
        return int(m.group(1), 16), 1.0
    if m := re.fullmatch(r"rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)", value):
        r, g, b, a = m.groups()
        return (int(r) << 16) | (int(g) << 8) | int(b), float(a)
    if m := re.fullmatch(r"color-mix\(in srgb, var\(--([\w-]+)\) (\d+)%, transparent\)", value):
        rgb, alpha = color(resolve(m.group(1), theme), theme)
        return rgb, alpha * int(m.group(2)) / 100
    return None


def shadow(value, theme):
    if m := re.fullmatch(r"0 (\d+)px (\d+)px (rgba\(.*\))", value):
        return int(m.group(1)), int(m.group(2)), color(m.group(3), theme)
    return None


KEYWORDS = {"private", "default", "public", "internal", "static"}


def camel(name):
    if name[0].isdigit():
        return "s" + name.replace("-", "_")
    head, *rest = name.split("-")
    word = head + "".join(p[:1].upper() + p[1:] for p in rest)
    return f"`{word}`" if word in KEYWORDS else word


def swift_color(c):
    rgb, alpha = c
    return f"RGBA(0x{rgb:06x}, {alpha:g})" if alpha != 1 else f"RGBA(0x{rgb:06x})"


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


def generate(commit):
    tokens_css = source(commit, "src/lib/design/tokens.css")
    rail_css = source(commit, "src/lib/design/rail.css")
    dark = declarations(block(tokens_css, ":root {"))
    dark.update(declarations(block(rail_css, ":root {")))
    media_light = declarations(block(block(tokens_css, "@media (prefers-color-scheme: light) {"), ":root:not"))
    chosen_light = {k: v for k, v in declarations(block(tokens_css, ":root[data-theme='light'] {")).items() if k != "color-scheme"}
    if media_light != chosen_light:
        sys.exit("tokens.py: tokens.css's two light blocks disagree; apron-web's tokens.test.ts should have caught it")
    light = {**dark, **media_light}

    colors, shadows, groups, extra = [], [], {g[1]: [] for g in GROUPS}, []
    for name in dark:
        if SKIP.match(name) or name == "color-scheme":
            continue
        d, l = resolve(name, dark), resolve(name, light)
        if (cd := color(d, dark)) is not None:
            colors.append((name, cd, color(l, light)))
        elif (sd := shadow(d, dark)) is not None:
            shadows.append((name, sd, shadow(l, light)))
        elif m := re.fullmatch(r"(\d+(?:\.\d+)?)(px|ms|s)", d):
            number = float(m.group(1)) / (1000 if m.group(2) == "ms" else 1)
            group = next(g for prefix, g, _ in GROUPS if name.startswith(prefix))
            key = name[len(next(p for p, g, _ in GROUPS if g == group)):]
            groups[group].append((key, number))
        elif m := re.fullmatch(r"(\d+)%", d):
            extra.append(f"    /// `--{name}`: dark {d}, light {l}.\n    static let {camel(name)} = Themed({int(d[:-1]) / 100:g}, {int(l[:-1]) / 100:g})")
        elif m := re.fullmatch(r"0?\.\d+", d):
            groups["Opacity"].append((name.removeprefix("opacity-"), float(d)))
        elif m := re.fullmatch(r"cubic-bezier\(([^)]*)\)", d):
            a, b, c, e = (float(x) for x in m.group(1).split(","))
            extra.append(f"    /// `--{name}`.\n    static let {camel(name)} = Curve({a:g}, {b:g}, {c:g}, {e:g})")
        else:
            sys.exit(f"tokens.py: --{name}: {d!r} is a value the generator does not know; add a rule or skip it")

    lines = [
        "// Generated by tools/design/tokens.py from apron-web src/lib/design/tokens.css and rail.css",
        f"// at {commit}. Do not edit; run tools/design/tokens.py.",
        "",
        "import CoreGraphics",
        "",
        "/// apron-web's design tokens, both themes. Dark is the reference theme; light is its equal.",
        "///",
        "/// Two hues have jobs. `accent` (rust) is what you can do: buttons, the composer's Send, a",
        "/// mention of you. `denim` is where you can go: links, threads, the New line, a moved message's",
        "/// destination. Every other color is a status and always carries a word beside it, never a",
        "/// color alone. `private` always comes with its lock.",
        "enum Tokens {",
        "    /// Colors as dark and light pairs.",
        "    enum Color {",
    ]
    for name, d, l in colors:
        lines.append(f"        static let {camel(name)} = Themed({swift_color(d)}, {swift_color(l)})")
    lines += ["    }", "", "    /// Shadows as y offset, blur radius and color, per theme.", "    enum Shadow {"]
    for name, (dy, db, dc), (ly, lb, lc) in shadows:
        lines.append(
            f"        static let {camel(name.removeprefix('shadow-'))} = Themed(ShadowToken(y: {dy}, blur: {db}, color: {swift_color(dc)}), "
            f"ShadowToken(y: {ly}, blur: {lb}, color: {swift_color(lc)}))"
        )
    lines.append("    }")
    for _, group, doc in GROUPS:
        lines += ["", f"    /// {doc}", f"    enum {group} {{"]
        kind = "Double" if group in ("Duration", "Opacity") else "CGFloat"
        for key, number in groups[group]:
            lines.append(f"        static let {camel(key)}: {kind} = {number:g}")
        lines.append("    }")
    lines += [""] + extra + ["}", ""]
    return "\n".join(lines)


def main():
    commit = pinned_commit()
    text = generate(commit)
    if sys.argv[1:] == ["--check"]:
        head = subprocess.run(["git", "-C", str(WEB), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if head and head != commit:
            print(f"tokens.py: note: apron-web is at {head}, the pin is {commit}; review the design changes and move the pin")
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit("tokens.py: Tokens.swift differs from tokens.css at the pinned commit; run tools/design/tokens.py")
        print(f"tokens.py: Tokens.swift matches apron-web {commit[:7]}")
    else:
        OUT.write_text(text)
        print(f"tokens.py: wrote {OUT.relative_to(ROOT)} from apron-web {commit[:7]}")


if __name__ == "__main__":
    main()
