/// Each language `CodeHighlighter` scans with the shared scanner: its comments, strings and words,
/// after highlight.js's grammars of the same names. Diff, shell sessions, Markdown, XML, CSS and
/// SCSS have scanners of their own.
extension Grammar {
    private typealias Q = Quote

    private static let doubleQuoted = Q(open: "\"", close: "\"")
    private static let singleQuoted = Q(open: "'", close: "'")
    private static let cComments: [(open: String, close: String)] = [("/*", "*/")]

    private static func cLike(keywords: String, types: String = "", literals: String = "true false null",
                              titleAfter: String = "", typeAfter: String = "class struct enum interface") -> Grammar {
        var grammar = Grammar()
        grammar.lineComments = ["//"]
        grammar.blockComments = cComments
        grammar.quotes = [doubleQuoted, singleQuoted]
        grammar.keywords = words(keywords)
        grammar.types = words(types)
        grammar.literals = words(literals)
        grammar.titleAfter = words(titleAfter)
        grammar.typeAfter = words(typeAfter)
        return grammar
    }

    private static let cKeywords = """
    auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static \
    struct switch typedef union volatile while _Alignas _Alignof _Atomic _Bool _Generic _Noreturn _Static_assert _Thread_local
    """
    private static let cTypes = "int char short long float double void signed unsigned bool size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE printf malloc free"

    private static let jsKeywords = """
    as async await break case catch class const continue debugger default delete do else export extends finally for from \
    function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield
    """
    private static let jsTypes = "Array Boolean Date Error JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap console document window globalThis require module"
    private static let jsLiterals = "true false null undefined NaN Infinity"

    static let all: [String: Grammar] = {
        var all: [String: Grammar] = [:]

        var bash = Grammar()
        bash.lineComments = ["#"]
        bash.commentNeedsSpace = true
        bash.quotes = [doubleQuoted, Q(open: "'", close: "'", escapes: false, multiline: true)]
        bash.quotes[0].multiline = true
        bash.keywords = words("if then else elif fi for while until do done case esac in function select return break continue local export readonly declare time")
        bash.types = words("alias cd echo eval exec exit printf pwd read set shift source test trap type ulimit umask unset wait cat grep sed awk ls mkdir rm cp mv curl git sudo")
        bash.literals = words("true false")
        bash.variableSigils = ["$"]
        bash.titleAfter = ["function"]
        bash.identifierExtra = ["-"]
        all["bash"] = bash

        all["c"] = cLike(keywords: cKeywords, types: cTypes, literals: "true false NULL", typeAfter: "struct enum union")
        all["c"]!.preprocessor = true
        all["cpp"] = cLike(keywords: cKeywords + """
         alignas alignof and catch class concept consteval constexpr constinit co_await co_return co_yield decltype delete \
        explicit export friend mutable namespace new noexcept not operator or override final private protected public \
        requires static_assert static_cast dynamic_cast reinterpret_cast const_cast template this thread_local throw try \
        typeid typename using virtual
        """, types: cTypes + " std string vector map set unique_ptr shared_ptr optional auto wchar_t char8_t char16_t char32_t cout cin endl",
            literals: "true false nullptr NULL", typeAfter: "class struct enum union namespace")
        all["cpp"]!.preprocessor = true

        var csharp = cLike(keywords: """
        abstract as async await base break case catch checked class const continue default delegate do else enum event explicit \
        extern finally fixed for foreach get goto if implicit in init interface internal is lock namespace new operator out \
        override params private protected public readonly record ref required return sealed set sizeof stackalloc static struct \
        switch this throw try typeof unchecked unsafe using var virtual void volatile when where while yield
        """, types: "bool byte char decimal double dynamic float int long object sbyte short string uint ulong ushort nint nuint Console Task List Dictionary",
            literals: "true false null", typeAfter: "class struct enum interface record namespace")
        csharp.preprocessor = true
        csharp.quotes.insert(Q(open: "\"\"\"", close: "\"\"\"", escapes: false, multiline: true), at: 0)
        all["csharp"] = csharp

        var dockerfile = bash
        dockerfile.keywords = words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell as")
        dockerfile.caseInsensitive = true
        dockerfile.keywordsLeadLines = true
        dockerfile.types = []
        dockerfile.titleAfter = []
        all["dockerfile"] = dockerfile

        var elixir = Grammar()
        elixir.lineComments = ["#"]
        elixir.quotes = [Q(open: "\"\"\"", close: "\"\"\"", multiline: true), Q(open: "\"", close: "\"", multiline: true), singleQuoted]
        elixir.keywords = words("after alias and case catch cond def defexception defguard defimpl defmacro defmacrop defmodule defp defprotocol defstruct do else end fn for if import in not or quote raise receive require rescue super throw try unless unquote use when with")
        elixir.literals = words("true false nil")
        elixir.types = words("Enum Map List String Kernel IO Process GenServer Agent Task Supervisor Keyword")
        elixir.symbols = true
        elixir.metaSigils = ["@"]
        elixir.identifierExtra = ["?", "!"]
        elixir.titleAfter = words("def defp defmacro defmacrop defguard")
        elixir.typeAfter = words("defmodule defprotocol defimpl")
        all["elixir"] = elixir

        var go = cLike(keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
                       types: "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any append cap close copy delete len make new panic print println recover",
                       literals: "true false nil iota", titleAfter: "func", typeAfter: "type")
        go.quotes.append(Q(open: "`", close: "`", escapes: false, multiline: true))
        go.quotes.removeAll { $0.open == "'" }
        go.characters = true
        all["go"] = go

        var graphql = Grammar()
        graphql.lineComments = ["#"]
        graphql.quotes = [Q(open: "\"\"\"", close: "\"\"\"", multiline: true), doubleQuoted]
        graphql.keywords = words("query mutation subscription fragment on type interface union enum input scalar schema extend directive implements repeatable")
        graphql.types = words("Int Float String Boolean ID")
        graphql.literals = words("true false null")
        graphql.variableSigils = ["$"]
        graphql.metaSigils = ["@"]
        graphql.typeAfter = words("type interface union enum input scalar fragment")
        all["graphql"] = graphql

        var haskell = Grammar()
        haskell.lineComments = ["--"]
        haskell.blockComments = [("{-", "-}")]
        haskell.nestedComments = true
        haskell.quotes = [doubleQuoted]
        haskell.characters = true
        haskell.identifierExtra = ["'"]
        haskell.keywords = words("as case class data default deriving do else family forall foreign hiding if import in infix infixl infixr instance let mdo module newtype of proc qualified rec then type where")
        haskell.types = words("Bool Char Double Either Float IO Int Integer Maybe String Just Nothing Left Right Show Eq Ord Functor Monad map filter foldr putStrLn print return")
        haskell.literals = words("True False")
        haskell.typeAfter = words("data newtype type class instance module")
        all["haskell"] = haskell

        var ini = Grammar()
        ini.lineComments = [";", "#"]
        ini.commentNeedsSpace = true
        ini.quotes = [Q(open: "\"\"\"", close: "\"\"\"", multiline: true), Q(open: "'''", close: "'''", escapes: false, multiline: true), doubleQuoted, Q(open: "'", close: "'", escapes: false)]
        ini.literals = words("true false on off yes no")
        ini.keys = .bare("=")
        ini.sections = true
        all["ini"] = ini

        all["java"] = cLike(keywords: """
        abstract assert break case catch class const continue default do else enum exports extends final finally for goto if \
        implements import instanceof interface module native new non-sealed package permits private protected public record \
        requires return sealed static strictfp super switch synchronized this throw throws transient try var void volatile while yield
        """, types: "boolean byte char double float int long short String Object Integer Long Double Boolean List Map Set ArrayList HashMap System Override",
            literals: "true false null", typeAfter: "class enum interface record extends implements")
        all["java"]!.metaSigils = ["@"]

        var javascript = cLike(keywords: jsKeywords, types: jsTypes, literals: jsLiterals, titleAfter: "function", typeAfter: "class extends new")
        javascript.quotes.append(Q(open: "`", close: "`", multiline: true))
        all["javascript"] = javascript

        var json = Grammar()
        json.lineComments = ["//"]
        json.blockComments = cComments
        json.quotes = [doubleQuoted, singleQuoted]
        json.literals = words("true false null")
        json.keys = .quoted
        all["json"] = json

        var kotlin = cLike(keywords: """
        abstract actual annotation as break by catch class companion const constructor continue crossinline data delegate do \
        dynamic else enum expect external field final finally for fun get if import in infix init inline inner interface \
        internal is lateinit noinline object open operator out override package private protected public reified return sealed \
        set super suspend tailrec this throw try typealias val value var vararg when where while
        """, types: "Any Boolean Byte Char Double Float Int Long Nothing Short String Unit Array List Map Set MutableList println listOf mapOf setOf",
            literals: "true false null", titleAfter: "fun", typeAfter: "class interface object typealias")
        kotlin.quotes.insert(Q(open: "\"\"\"", close: "\"\"\"", escapes: false, multiline: true), at: 0)
        kotlin.quotes.removeAll { $0.open == "'" }
        kotlin.characters = true
        kotlin.metaSigils = ["@"]
        all["kotlin"] = kotlin

        var lua = Grammar()
        lua.blockComments = [("--[[", "]]")]
        lua.lineComments = ["--"]
        lua.quotes = [Q(open: "[[", close: "]]", escapes: false, multiline: true), doubleQuoted, singleQuoted]
        lua.keywords = words("and break do else elseif end for function goto if in local not or repeat return then until while")
        lua.types = words("print pairs ipairs require tostring tonumber type table string math os io error pcall setmetatable getmetatable self")
        lua.literals = words("true false nil")
        lua.titleAfter = ["function"]
        all["lua"] = lua

        var makefile = Grammar()
        makefile.lineComments = ["#"]
        makefile.quotes = [doubleQuoted, singleQuoted]
        makefile.keywords = words("define endef undefine ifdef ifndef ifeq ifneq else endif include -include sinclude override export unexport private vpath")
        makefile.types = words("subst patsubst strip findstring filter filter-out sort word wordlist words firstword lastword dir notdir suffix basename addsuffix addprefix join wildcard realpath abspath error warning shell origin flavor foreach if or and call eval file value")
        makefile.variableSigils = ["$"]
        makefile.targets = true
        makefile.identifierExtra = ["-"]
        all["makefile"] = makefile

        var nix = Grammar()
        nix.lineComments = ["#"]
        nix.blockComments = cComments
        nix.quotes = [Q(open: "''", close: "''", escapes: false, multiline: true), Q(open: "\"", close: "\"", multiline: true)]
        nix.keywords = words("assert else if in inherit let or rec then with")
        nix.types = words("builtins import fetchurl fetchTarball fetchGit map toString derivation abort throw baseNameOf dirOf isNull removeAttrs")
        nix.literals = words("true false null")
        nix.identifierExtra = ["-", "'"]
        all["nix"] = nix

        var php = cLike(keywords: """
        abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty \
        enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if \
        implements include include_once instanceof insteadof interface isset list match namespace new or print private \
        protected public readonly require require_once return static switch throw trait try unset use var while xor yield
        """, types: "bool int float string mixed void never iterable object self parent", literals: "true false null TRUE FALSE NULL",
            titleAfter: "function fn", typeAfter: "class interface trait enum extends implements new")
        php.lineComments = ["//", "#"]
        php.variableSigils = ["$"]
        php.metaWords = ["<?php", "<?=", "?>"]
        all["php"] = php

        var protobuf = cLike(keywords: "syntax edition package import option message enum service rpc returns stream repeated optional required oneof map reserved extend extensions to max weak public",
                             types: "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes",
                             literals: "true false", typeAfter: "message enum service")
        protobuf.titleAfter = ["rpc"]
        all["protobuf"] = protobuf

        var python = Grammar()
        python.lineComments = ["#"]
        python.quotes = [Q(open: "\"\"\"", close: "\"\"\"", multiline: true), Q(open: "'''", close: "'''", multiline: true), doubleQuoted, singleQuoted]
        python.stringPrefixes = words("r u b f br rb fr rf")
        python.keywords = words("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield")
        python.types = words("abs all any bool bytes callable dict dir enumerate filter float format frozenset getattr hasattr id input int isinstance iter len list map max min next object open print range repr reversed round set setattr slice sorted staticmethod str sum super tuple type zip self cls")
        python.literals = words("True False None")
        python.metaSigils = ["@"]
        python.titleAfter = ["def"]
        python.typeAfter = ["class"]
        all["python"] = python

        var ruby = Grammar()
        ruby.lineComments = ["#"]
        ruby.blockComments = [("=begin", "=end")]
        ruby.quotes = [Q(open: "\"", close: "\"", multiline: true), singleQuoted, Q(open: "`", close: "`")]
        ruby.keywords = words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield __FILE__ __LINE__")
        ruby.types = words("puts print require require_relative attr_accessor attr_reader attr_writer include extend raise lambda proc loop Array Hash String Integer Kernel")
        ruby.literals = words("true false nil")
        ruby.symbols = true
        ruby.variableSigils = ["@", "$"]
        ruby.identifierExtra = ["?", "!"]
        ruby.titleAfter = ["def"]
        ruby.typeAfter = words("class module")
        all["ruby"] = ruby

        var rust = cLike(keywords: """
        as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref \
        return self Self static struct super trait type union unsafe use where while yield macro_rules
        """, types: "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box Rc Arc HashMap HashSet Some None Ok Err",
            literals: "true false", titleAfter: "fn", typeAfter: "struct enum trait impl type union mod")
        rust.nestedComments = true
        rust.quotes = [Q(open: "\"", close: "\"", multiline: true)]
        rust.stringPrefixes = words("b r br")
        rust.characters = true
        rust.macros = true
        rust.metaSigils = ["#"]
        all["rust"] = rust

        var sql = Grammar()
        sql.lineComments = ["--", "#"]
        sql.blockComments = cComments
        sql.quotes = [Q(open: "'", close: "'", escapes: false, multiline: true), doubleQuoted, Q(open: "`", close: "`", escapes: false)]
        sql.caseInsensitive = true
        sql.keywords = words("""
        add all alter and any as asc begin between by case cascade check column commit constraint create cross database default \
        delete desc distinct drop else end except exists explain foreign from full group having if in index inner insert \
        intersect into is join key left like limit not null offset on or order outer primary references replace returning \
        right rollback select set table then transaction trigger truncate union unique update using values view when where with
        """)
        sql.types = words("bigint binary bit blob boolean char date datetime decimal double float int integer json jsonb numeric real serial smallint text time timestamp uuid varchar avg count max min sum coalesce now lower upper")
        sql.literals = words("true false")
        sql.keywords.remove("null")
        sql.literals.insert("null")
        all["sql"] = sql

        var swift = cLike(keywords: """
        actor any associatedtype async await borrowing break case catch class consume consuming continue convenience default \
        defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in \
        indirect infix init inout internal is isolated lazy let mutating nonisolated nonmutating open operator optional \
        override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self \
        set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet
        """, types: "Any AnyObject Array Bool Character Dictionary Double Error Float Int Int8 Int16 Int32 Int64 Never Optional Result Set String Substring UInt UInt8 UInt16 UInt32 UInt64 Void print min max abs",
            literals: "true false nil", titleAfter: "func", typeAfter: "class struct enum protocol extension actor typealias")
        swift.nestedComments = true
        swift.quotes = [Q(open: "\"\"\"", close: "\"\"\"", multiline: true), doubleQuoted]
        swift.metaSigils = ["@", "#"]
        all["swift"] = swift

        var typescript = javascript
        typescript.keywords.formUnion(words("abstract declare enum implements interface keyof namespace private protected public readonly satisfies type infer is asserts override"))
        typescript.types.formUnion(words("any boolean never number object string symbol unknown void bigint Record Partial Readonly Pick Omit"))
        typescript.typeAfter.formUnion(words("interface type enum implements"))
        typescript.metaSigils = ["@"]
        all["typescript"] = typescript

        var yaml = Grammar()
        yaml.lineComments = ["#"]
        yaml.commentNeedsSpace = true
        yaml.quotes = [doubleQuoted, Q(open: "'", close: "'", escapes: false)]
        yaml.literals = words("true false null yes no on off True False Null")
        yaml.keys = .bare(":")
        yaml.yamlMarkers = true
        yaml.metaSigils = ["&", "*", "!"]
        yaml.identifierExtra = ["-"]
        all["yaml"] = yaml

        return all
    }()
}
