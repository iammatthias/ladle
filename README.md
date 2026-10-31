# Ladle

Ladle is a native iOS client for the [Apron chat protocol](https://github.com/apron-chat) v9: one
identity per server, several servers, bearer-token sign-in. Swift 6 and SwiftUI, Apple
frameworks only.

The protocol core and the session layer live in `Packages/ApronKit`, gated by the protocol's
client conformance fixtures, unit tests, and integration tests against the Rust server
(`aprond`). The app is a thin SwiftUI layer over it: servers, sign-in, rooms and threads, and a
timeline with a composer.

```sh
scripts/sync-fixtures.sh --check && swift test --package-path Packages/ApronKit   # the gate
APRON_REQUIRE_SERVER=1 swift test --package-path Packages/ApronKit               # fail, not skip, without aprond
./build.sh build                               # the iOS app
./build.sh test                                # app tests on the "Ladle iPhone" simulator
```

`AGENTS.md` has the layout, the rules, and the sign-in design.

The Ferrous and Gumball themes use the faces apron-web carries for them, bundled in
`Ladle/Fonts`: Recursive (The Recursive Project Authors, https://github.com/arrowtype/recursive) and Nunito (The
Nunito Project Authors, https://github.com/googlefonts/nunito), each under the SIL Open Font
License 1.1, whose text is beside them (`OFL-Recursive.txt`, `OFL-Nunito.txt`).
