# Apron for iOS

A native iOS client for the [Apron chat protocol](https://github.com/apron-chat) v9: one
identity per server, several servers, bearer-token sign-in. Swift 6 and SwiftUI, Apple
frameworks only.

Phase 1 is the protocol core, `Packages/ApronKit`, gated by the protocol's client conformance
fixtures. The app itself is a placeholder until phase 2.

```sh
swift test --package-path Packages/ApronKit   # protocol core and fixture gate, no simulator
./build.sh build                               # the iOS app
./build.sh test                                # app tests on the "Apron iPhone" simulator
```

`AGENTS.md` has the layout, the rules, and the sign-in design.
