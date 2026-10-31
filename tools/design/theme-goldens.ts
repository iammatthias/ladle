// Runs apron-web's own parseThemeCss over its premade themes and the cases its tests use, and prints
// the results as JSON: the golden values ApronKit's ThemeTests hold the Swift port to. Run through
// tools/design/theme-goldens.py, which copies the pinned sources beside this file.
import { parseThemeCss, THEMES } from './appearance.svelte';

const cases = [
	':root {\n\t/* fonts */\n\t--font-sans: "A B",\n\t\tserif;\n\t--accent: #f00;\n\t--font-sans: Inter\n}',
	'--bg-100: #000;',
	'--ink: light-dark(#000000, #ffffff);',
	'  /* nothing */  ',
	'body { color: red; }',
	'color: red;',
	':root { --a: x; } body { --b: y; }',
	'--font-sans: ;',
	'--bg: url(https://example.com/x.png);',
	'--bg: image-set("x.png" 1x);',
	'--font-sans: "unclosed;',
	'--a: x !important;',
	'--a: u\\72l(x);',
	'@import "x.css"; --a: b;',
	'--a: b; /* open',
	'--base-ground: red; --base-ink: #fff;',
	'--accent: red);',
	'--accent: rgb(1, 2, 3;',
	'--base-ground: light-dark(#fff, #000);',
	'x'.repeat(4001),
	'--base-ground: #ffffff; --base-ink: #000000; --base-accent: #8a2c08; --line: #123456;',
	'--base-ground: #000000; --base-ink: light-dark(#ffffff, #eeeeee)',
	'nope here is a long declaration without any colon in it at all',
	'--ok: 1; short',
	Array.from({ length: 101 }, (_, i) => `--t${i}: 1;`).join(' '),
	'--base-link: #12345;',
	'--base-accent: #abc;',
	'--x: "a;b";',
	"--font-sans: 'Comic Sans', \"x\";",
	'--a: (b))(;',
	'--z-menu: 9; --accent: SRC (x); --émoji: 1;',
	'--base-ground: #102030; --base-ink: #f0e0d0; --base-link: #3366cc;'
];

console.log(
	JSON.stringify(
		{
			themes: THEMES.map((theme) => ({ id: theme.id, name: theme.name, vars: parseThemeCss(theme.css).vars })),
			cases: cases.map((css) => ({ css, ...parseThemeCss(css) }))
		},
		null,
		1
	)
);
