import ApronKit
import XCTest

/// Fenced code as apron-web's `highlight.ts` (#16) highlights it, each language family read back
/// as its marked runs.
final class CodeHighlighterTests: XCTestCase {
    private struct Run: Equatable, CustomStringConvertible {
        var text: String
        var token: CodeToken
        init(_ text: String, _ token: CodeToken) {
            self.text = text
            self.token = token
        }

        var description: String { "\(token.rawValue) \(text.debugDescription)" }
    }

    private func runs(_ source: String, _ fence: String, file: StaticString = #filePath, line: UInt = #line) -> [Run] {
        guard let marked = CodeHighlighter.highlighted(source, fence: fence) else {
            XCTFail("\(fence) is not highlighted", file: file, line: line)
            return []
        }
        XCTAssertEqual(String(marked.characters), source, "the text stays as written", file: file, line: line)
        return marked.runs[CodeTokenKey.self].compactMap { token, range in token.map { Run(String(marked[range].characters), $0) } }
    }

    func testLanguagesAndAliasesInAnyCase() {
        XCTAssertEqual(CodeHighlighter.language(of: "typescript"), "typescript")
        XCTAssertEqual(CodeHighlighter.language(of: "TS"), "typescript")
        XCTAssertEqual(CodeHighlighter.language(of: "sh"), "bash")
        XCTAssertEqual(CodeHighlighter.language(of: "html"), "xml")
        XCTAssertEqual(CodeHighlighter.language(of: "c++"), "cpp")
        XCTAssertEqual(CodeHighlighter.language(of: "toml"), "ini")
        XCTAssertEqual(CodeHighlighter.language(of: "console"), "shell")
        XCTAssertNil(CodeHighlighter.language(of: "brainfuck"))
        XCTAssertNil(CodeHighlighter.language(of: "constructor"))
        XCTAssertNil(CodeHighlighter.language(of: ""))
        XCTAssertEqual(CodeHighlighter.languages.count, 32)
    }

    func testNoLanguageAnUnknownOneAndLongBlocksStayPlain() {
        XCTAssertNil(CodeHighlighter.highlighted("const a = 1", fence: nil))
        XCTAssertNil(CodeHighlighter.highlighted("+++", fence: "brainfuck"))
        XCTAssertNil(CodeHighlighter.highlighted(String(repeating: "x", count: 20_001), fence: "js"))
        XCTAssertNotNil(CodeHighlighter.highlighted(String(repeating: "x", count: 20_000), fence: "js"))
    }

    func testTheWebsExamples() {
        XCTAssertEqual(runs("const answer = 42; // why", "ts"), [Run("const", .keyword), Run("42", .number), Run("// why", .comment)])
        XCTAssertEqual(runs("-old\n+new", "diff"), [Run("-old", .deletion), Run("+new", .addition)])
        XCTAssertEqual(runs("def f(): pass", "python"), [Run("def", .keyword), Run("f", .title), Run("pass", .keyword)])
        XCTAssertEqual(runs("let x = \"y\"", "javascript"), [Run("let", .keyword), Run("\"y\"", .string)])
    }

    func testCFamily() {
        XCTAssertEqual(runs("func backoff(_ n: Int) -> Double { /* a /* nested */ note */ return nil }", "swift"), [
            Run("func", .keyword), Run("backoff", .title), Run("Int", .type), Run("Double", .type),
            Run("/* a /* nested */ note */", .comment), Run("return", .keyword), Run("nil", .number),
        ])
        XCTAssertEqual(runs("@MainActor struct Pane { let title = \"\"\"\nhi \\(x)\n\"\"\" }", "swift"), [
            Run("@MainActor", .meta), Run("struct", .keyword), Run("Pane", .type), Run("let", .keyword), Run("\"\"\"\nhi \\(x)\n\"\"\"", .string),
        ])
        XCTAssertEqual(runs("fn main<'a>() { let c = 'x'; println!(\"{}\", 0x1F_u8); }", "rust"), [
            Run("fn", .keyword), Run("main", .title), Run("let", .keyword), Run("'x'", .string), Run("println!", .type),
            Run("\"{}\"", .string), Run("0x1F_u8", .number),
        ])
        XCTAssertEqual(runs("func main() { s := `raw\nline`; return nil }", "go"), [
            Run("func", .keyword), Run("main", .title), Run("`raw\nline`", .string), Run("return", .keyword), Run("nil", .number),
        ])
        XCTAssertEqual(runs("#include <stdio.h>\nint main(void) { return 1.5e3; }", "c"), [
            Run("#include", .meta), Run("int", .type), Run("void", .type), Run("return", .keyword), Run("1.5e3", .number),
        ])
        XCTAssertEqual(runs("template <typename T> class Box {};", "cpp"), [
            Run("template", .keyword), Run("typename", .keyword), Run("class", .keyword), Run("Box", .type),
        ])
        XCTAssertEqual(runs("public record Point(int X); // c#", "cs"), [
            Run("public", .keyword), Run("record", .keyword), Run("Point", .type), Run("int", .type), Run("// c#", .comment),
        ])
        XCTAssertEqual(runs("@Override public String toString() { return null; }", "java"), [
            Run("@Override", .meta), Run("public", .keyword), Run("String", .type), Run("return", .keyword), Run("null", .number),
        ])
        XCTAssertEqual(runs("fun greet(name: String) = \"hi $name\"", "kt"), [
            Run("fun", .keyword), Run("greet", .title), Run("String", .type), Run("\"hi $name\"", .string),
        ])
        XCTAssertEqual(runs("const t = `a ${b}`; class A extends B {}", "jsx"), [
            Run("const", .keyword), Run("`a ${b}`", .string), Run("class", .keyword), Run("A", .type), Run("extends", .keyword), Run("B", .type),
        ])
        XCTAssertEqual(runs("interface Row { id: string }", "ts"), [Run("interface", .keyword), Run("Row", .type), Run("string", .type)])
        XCTAssertEqual(runs("<?php function hi($name) { echo 'hi'; } # done", "php"), [
            Run("<?php", .meta), Run("function", .keyword), Run("hi", .title), Run("$name", .attr), Run("echo", .keyword),
            Run("'hi'", .string), Run("# done", .comment),
        ])
        XCTAssertEqual(runs("message Ping { string id = 1; }", "proto"), [
            Run("message", .keyword), Run("Ping", .type), Run("string", .type), Run("1", .number),
        ])
    }

    func testHashCommentFamily() {
        XCTAssertEqual(runs("@cache\ndef area(r=2.5):  # m²\n    return f\"{r}\" if r else None", "py"), [
            Run("@cache", .meta), Run("def", .keyword), Run("area", .title), Run("2.5", .number), Run("# m²", .comment),
            Run("return", .keyword), Run("f\"{r}\"", .string), Run("if", .keyword), Run("else", .keyword), Run("None", .number),
        ])
        XCTAssertEqual(runs("def hi?(name) = puts :done, @count # ok", "rb"), [
            Run("def", .keyword), Run("hi?", .title), Run("puts", .type), Run(":done", .string), Run("@count", .attr), Run("# ok", .comment),
        ])
        XCTAssertEqual(runs("defmodule Chat do\n  @doc \"Hi\"\n  def hi, do: :ok # x\nend", "ex"), [
            Run("defmodule", .keyword), Run("Chat", .type), Run("do", .keyword), Run("@doc", .meta), Run("\"Hi\"", .string),
            Run("def", .keyword), Run("hi", .title), Run("do", .keyword), Run(":ok", .string), Run("# x", .comment), Run("end", .keyword),
        ])
        XCTAssertEqual(runs("{ pkgs ? import <nixpkgs> {} }: let x = ''\n  multi\n''; in true # c", "nix"), [
            Run("import", .type), Run("let", .keyword), Run("''\n  multi\n''", .string), Run("in", .keyword), Run("true", .number), Run("# c", .comment),
        ])
        XCTAssertEqual(runs("if [ -n \"$HOME\" ]; then echo ${USER} $# # done\nfi", "sh"), [
            Run("if", .keyword), Run("\"$HOME\"", .string), Run("then", .keyword), Run("echo", .type), Run("${USER}", .attr),
            Run("$#", .attr), Run("# done", .comment), Run("fi", .keyword),
        ])
        XCTAssertEqual(runs("FROM swift:6 AS build\n# deps\nRUN echo $HOME", "docker"), [
            Run("FROM", .keyword), Run("6", .number), Run("# deps", .comment), Run("RUN", .keyword), Run("$HOME", .attr),
        ])
        XCTAssertEqual(runs("CC := clang\nbuild: main.o\n\t$(CC) -o app $@ # link\nifeq ($(OS),mac)\nendif", "make"), [
            Run("build", .title), Run("$(CC)", .attr), Run("$@", .attr), Run("# link", .comment),
            Run("ifeq", .keyword), Run("$(OS)", .attr), Run("endif", .keyword),
        ], "an assignment is not a target")
        XCTAssertEqual(runs("query Room($id: ID!) @cached { room(id: $id) { title } } # q", "gql"), [
            Run("query", .keyword), Run("$id", .attr), Run("ID", .type), Run("@cached", .meta),
            Run("$id", .attr), Run("# q", .comment),
        ])
    }

    func testDashCommentFamily() {
        XCTAssertEqual(runs("SELECT count(*) FROM rooms WHERE title = 'it''s' AND log_id > 10 -- newest\nOR x IS NULL", "postgres"), [
            Run("SELECT", .keyword), Run("count", .type), Run("FROM", .keyword), Run("WHERE", .keyword), Run("'it''s'", .string),
            Run("AND", .keyword), Run("10", .number), Run("-- newest", .comment), Run("OR", .keyword), Run("IS", .keyword), Run("NULL", .number),
        ])
        XCTAssertEqual(runs("module Main where\n{- a {- b -} -}\nmain = putStrLn \"hi\" -- x\nf x' = 'c'", "hs"), [
            Run("module", .keyword), Run("Main", .type), Run("where", .keyword), Run("{- a {- b -} -}", .comment), Run("putStrLn", .type),
            Run("\"hi\"", .string), Run("-- x", .comment), Run("'c'", .string),
        ])
        XCTAssertEqual(runs("--[[ long\ncomment ]]\nlocal function f() return nil end -- x", "lua"), [
            Run("--[[ long\ncomment ]]", .comment), Run("local", .keyword), Run("function", .keyword), Run("f", .title),
            Run("return", .keyword), Run("nil", .number), Run("end", .keyword), Run("-- x", .comment),
        ])
    }

    func testDiff() {
        let source = "diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n context\n-old\n+new"
        XCTAssertEqual(runs(source, "patch"), [
            Run("diff --git a/x b/x", .comment), Run("index 1..2", .comment), Run("--- a/x", .comment), Run("+++ b/x", .comment),
            Run("@@ -1,2 +1,2 @@", .meta),
            Run("-old", .deletion), Run("+new", .addition),
        ])
    }

    func testDataFormats() {
        XCTAssertEqual(runs("{\"name\": \"Ada\", \"age\": 36, \"admin\": true, \"x\": null} // c", "jsonc"), [
            Run("\"name\"", .attr), Run("\"Ada\"", .string), Run("\"age\"", .attr), Run("36", .number), Run("\"admin\"", .attr),
            Run("true", .number), Run("\"x\"", .attr), Run("null", .number), Run("// c", .comment),
        ])
        XCTAssertEqual(runs("---\nname: ladle # app\nports:\n  - 443\n  - host: \"home\"\nenabled: true", "yml"), [
            Run("---", .meta), Run("name", .attr), Run("# app", .comment), Run("ports", .attr), Run("-", .number), Run("443", .number),
            Run("-", .number), Run("host", .attr), Run("\"home\"", .string), Run("enabled", .attr), Run("true", .number),
        ])
        XCTAssertEqual(runs("[server]\nport = 8080 ; main\nname = \"home\"\ntls = true", "toml"), [
            Run("[server]", .title), Run("port", .attr), Run("8080", .number), Run("; main", .comment), Run("name", .attr),
            Run("\"home\"", .string), Run("tls", .attr), Run("true", .number),
        ])
    }

    func testMarkup() {
        XCTAssertEqual(runs("<!DOCTYPE html>\n<a href=\"/x\" data-id='1'>hi</a><!-- c -->", "html"), [
            Run("<!DOCTYPE html>", .meta), Run("a", .attr), Run("href", .attr), Run("\"/x\"", .string), Run("data-id", .attr),
            Run("'1'", .string), Run("a", .attr), Run("<!-- c -->", .comment),
        ])
        XCTAssertEqual(runs("# Title\n> quoted\n- **bold** and *soft* `code` [link](https://x)\n```\n# not a title\n```", "md"), [
            Run("# Title", .title), Run("> quoted", .comment), Run("-", .number), Run("**bold**", .strong), Run("*soft*", .emphasis),
            Run("[link]", .string),
        ])
        XCTAssertEqual(runs("@media (min-width: 720px) { .pane > a:hover, #top { color: #fff !important; margin: -2px 1.5em; } }", "css"), [
            Run("@media", .keyword), Run("720px", .number), Run(".pane", .title), Run("a", .keyword),
            Run("#top", .title), Run("color", .attr), Run("#fff", .number), Run("!important", .keyword), Run("margin", .attr),
            Run("-2px", .number), Run("1.5em", .number),
        ])
        XCTAssertEqual(runs("$gap: 4px; // s\n.row { &:hover { gap: $gap; } }", "scss"), [
            Run("$gap", .attr), Run("4px", .number), Run("// s", .comment), Run(".row", .title), Run("gap", .attr), Run("$gap", .attr),
        ])
    }

    func testAShellSessionHighlightsItsCommandsAndNotItsOutput() {
        XCTAssertEqual(runs("$ echo \"hi\" # say\nhi\nuser@host:~$ cd /tmp", "console"), [
            Run("$ ", .meta), Run("echo", .type), Run("\"hi\"", .string), Run("# say", .comment), Run("user@host:~$ ", .meta), Run("cd", .type),
        ])
    }

    func testWhatNeverClosesEndsAtTheEnd() {
        XCTAssertEqual(runs("let s = \"open\nlet t = 1", "swift"), [
            Run("let", .keyword), Run("\"open", .string), Run("let", .keyword), Run("1", .number),
        ])
        XCTAssertEqual(runs("x /* never", "c"), [Run("/* never", .comment)])
        XCTAssertEqual(runs("<a href=\"x", "xml"), [Run("a", .attr), Run("href", .attr), Run("\"x", .string)])
        XCTAssertEqual(runs("a = '''open", "py"), [Run("'''open", .string)])
    }
}
