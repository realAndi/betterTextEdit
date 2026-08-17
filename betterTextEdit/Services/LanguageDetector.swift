import Foundation

/// Works out what a document *is* from what's inside it.
///
/// A file on disk has a name to go on, so this never runs for one — `Untitled`
/// documents and files with an extension nobody recognises are the whole point.
/// Type a shebang, paste some JSON, or start a note with `# Heading`, and the
/// editor starts highlighting it, offers the preview, and suggests the right
/// extension when the document is finally saved.
///
/// Two kinds of evidence, in order:
///
/// 1. **Markers** — `#!/bin/bash`, `<?xml`, `<?php`, `<!DOCTYPE html`, or text
///    that parses as JSON. These say what the file is outright.
/// 2. **Signals** — small patterns that are characteristic of a language,
///    scored together. Nothing wins on one signal alone: a language has to
///    reach `threshold` before it's picked, so ordinary prose stays plain text.
enum LanguageDetector {
    /// How much of the text to look at. Enough for the shebang, the imports,
    /// and a good few dozen lines of body — and small enough that a document
    /// can be re-read on every keystroke without the typing feeling it.
    static let windowLength = 2048

    /// The score a language has to reach before it's picked at all. Roughly
    /// "one telling pattern plus corroboration".
    private static let threshold = 4

    /// Below this there's nothing to go on, and guessing would just make the
    /// editor twitch while the first line is being typed.
    private static let minimumCharacters = 12

    /// The language `text` looks like, or `nil` when nothing stands out.
    static func detect(in text: String) -> FileLanguage? {
        // Backing the window with an `NSString` up front matters: every one of
        // the patterns below bridges its input, and doing that once instead of
        // a hundred times is most of the difference between a detection you
        // can run on each keystroke and one you can't.
        let window = String(text.prefix(windowLength)) as NSString as String
        guard window.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumCharacters else {
            return nil
        }

        if let marked = markedLanguage(in: window, whole: text) { return marked }

        var best: (language: FileLanguage, score: Int)?
        for group in signals {
            let score = group.score(in: window)
            // Ties go to whichever comes first in the table, which is what
            // keeps plain JavaScript from being called TypeScript.
            if score > (best?.score ?? 0) {
                best = (group.language, score)
            }
        }

        guard let best, best.score >= threshold else { return nil }
        return best.language
    }

    // MARK: - Markers

    /// The giveaways that need no scoring.
    private static func markedLanguage(in window: String, whole: String) -> FileLanguage? {
        let head = window.trimmingCharacters(in: .whitespacesAndNewlines)

        if head.hasPrefix("#!") {
            let line = head.prefix { !$0.isNewline }.lowercased()
            if line.contains("python") { return .python }
            if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
            if line.contains("ruby") { return .ruby }
            if line.contains("php") { return .php }
            if line.contains("lua") { return .lua }
            if line.contains("swift") { return .swift }
            // sh, bash, zsh, dash, ksh, fish, env, and anything else in
            // /usr/bin is a script the shell highlighting suits.
            return .shell
        }

        if head.hasPrefix("<?php") { return .php }
        if head.hasPrefix("<?xml") { return .xml }

        let opening = head.prefix(512).lowercased()
        if opening.contains("<!doctype html") || opening.contains("<html") { return .html }
        if opening.contains("<!doctype plist") || opening.contains("<svg") { return .xml }

        if isJSON(whole, window: window) { return .json }
        return nil
    }

    /// JSON is the one format worth confirming by actually parsing it — the
    /// braces alone would also match a C file or a CSS rule.
    ///
    /// Parsing costs a pass over the whole document, and this runs while the
    /// user types, so past a certain size the shape of the thing has to do:
    /// brackets that match at both ends, with quoted keys inside.
    private static func isJSON(_ text: String, window: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }),
              let last = text.last(where: { !$0.isWhitespace }),
              (first == "{" && last == "}") || (first == "[" && last == "]")
        else { return false }

        guard text.utf8.count <= 262_144 else {
            return keyedByQuotedNames.matches(window)
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    private static let keyedByQuotedNames = Signal("\"[^\"]+\"\\s*:", 1)

    // MARK: - Signals

    /// One pattern that counts towards a language, worth `weight` however many
    /// times it appears — so a repeated line can't carry a file on its own.
    private struct Signal {
        let expression: NSRegularExpression?
        let weight: Int

        init(_ pattern: String, _ weight: Int, caseInsensitive: Bool = false) {
            expression = try? NSRegularExpression(
                pattern: pattern,
                options: caseInsensitive ? [.caseInsensitive] : []
            )
            self.weight = weight
        }

        func matches(_ text: String) -> Bool {
            guard let expression else { return false }
            return expression.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..., in: text)
            ) != nil
        }
    }

    private struct SignalGroup {
        let language: FileLanguage
        let signals: [Signal]

        func score(in text: String) -> Int {
            signals.reduce(0) { $0 + ($1.matches(text) ? $1.weight : 0) }
        }
    }

    /// Ordered: earlier languages win ties. Compiled once, on first use.
    private static let signals: [SignalGroup] = [
        SignalGroup(language: .markdown, signals: [
            Signal("(?m)^#{1,6} +\\S", 3),
            Signal("(?m)^```", 3),
            Signal("\\A#{1,6} +\\S", 2), // a heading on the very first line
            Signal("\\[[^\\]]+\\]\\([^)\\s]+\\)", 2),
            Signal("(?m)^\\*\\*[^*]+\\*\\*|\\s\\*\\*[^*\\n]+\\*\\*", 2),
            Signal("(?m)^\\|.+\\|$", 2),
            Signal("(?m)^\\s*[-*+] +\\S", 1),
            Signal("(?m)^\\s*\\d+\\. +\\S", 1),
            Signal("(?m)^> +\\S", 1),
        ]),
        SignalGroup(language: .swift, signals: [
            Signal("(?m)^\\s*import (Foundation|SwiftUI|UIKit|AppKit|Combine|XCTest|OSLog)\\b", 4),
            Signal("(?m)^\\s*(public |private |fileprivate |internal |final |open )*(struct|class|enum|protocol|extension|actor) \\w+", 2),
            Signal("\\bfunc \\w+\\s*[(<]", 2),
            Signal("\\b(guard|if) let \\w+", 2),
            Signal("@(State|Published|MainActor|objc|escaping|StateObject|ObservedObject|Environment)\\b", 2),
            Signal("(?m)^\\s*(let|var) \\w+ *[:=]", 1),
        ]),
        SignalGroup(language: .python, signals: [
            Signal("(?m)^\\s*def \\w+\\s*\\([^)]*\\)\\s*(->[^:]+)?:", 4),
            Signal("(?m)^\\s*(from [\\w.]+ )?import [\\w.*]+", 2),
            Signal("(?m)^\\s*class \\w+(\\(.*\\))?\\s*:", 3),
            Signal("if __name__ *== *['\"]__main__['\"]", 4),
            Signal("(?m)^\\s*(elif|except|finally)\\b.*:", 2),
            Signal("\\bself\\.\\w+", 1),
            Signal("\\bprint\\(", 1),
        ]),
        SignalGroup(language: .ruby, signals: [
            Signal("(?m)^\\s*(require|require_relative) ['\"]", 4),
            Signal("(?m)^\\s*def \\w+[?!=]?(\\s*\\([^)]*\\))?\\s*$", 3),
            Signal("\\.each +do +\\|", 3),
            Signal("(?m)^\\s*class \\w+ *<", 2),
            Signal("(?m)^\\s*end\\s*$", 2),
            Signal("\\bputs\\b", 2),
            Signal("(?m)^\\s*@\\w+ *=", 1),
        ]),
        SignalGroup(language: .lua, signals: [
            Signal("(?m)^\\s*local \\w+ *=", 4),
            Signal("(?m)^\\s*(local )?function [\\w.:]+\\(", 3),
            Signal("\\bthen\\b[\\s\\S]{0,400}\\bend\\b", 2),
            Signal("\\bnil\\b", 1),
            Signal("(?m)^\\s*--[^-]", 1),
        ]),
        SignalGroup(language: .shell, signals: [
            Signal("(?m)^\\s*(if \\[|fi$|then$|elif \\[|esac$|done$|do$)", 3),
            Signal("(?m)^\\s*(echo|export|source|cd|mkdir|rm|cp|mv|sudo|grep|sed|awk|chmod|curl|brew|git|npm|open) ", 2),
            Signal("\\$\\{\\w+[}:]|\\$\\(", 2),
            Signal("(?m)^\\s*\\w+\\s*\\(\\)\\s*\\{", 2),
            Signal("(?m)^\\s*\\w+=[^=\\s]", 1),
            Signal("\\s(&&|\\|\\|)\\s", 1),
        ]),
        SignalGroup(language: .javascript, signals: [
            Signal("\\b(const|let) \\w+ *=", 2),
            Signal("\\bfunction\\s*\\w*\\s*\\(", 2),
            Signal("\\bconsole\\.(log|error|warn)\\(", 3),
            Signal("\\bmodule\\.exports\\b|\\brequire\\(['\"]", 3),
            Signal("(?m)^\\s*(export )?(default )?(async )?function\\b", 2),
            Signal("(?m)^\\s*import .* from ['\"]", 2),
            Signal("=>\\s*[{(]", 2),
            Signal("\\bdocument\\.(getElementById|querySelector)|\\bwindow\\.", 2),
            Signal("===|!==", 1),
        ]),
        SignalGroup(language: .typescript, signals: [
            // Everything JavaScript has, plus the parts only TypeScript has —
            // so a file with types beats the JavaScript entry, and one without
            // ties with it and loses on order.
            Signal("\\b(const|let) \\w+ *=", 2),
            Signal("\\bfunction\\s*\\w*\\s*\\(", 2),
            Signal("\\bconsole\\.(log|error|warn)\\(", 3),
            Signal("\\bmodule\\.exports\\b|\\brequire\\(['\"]", 3),
            Signal("(?m)^\\s*(export )?(default )?(async )?function\\b", 2),
            Signal("(?m)^\\s*import .* from ['\"]", 2),
            Signal("=>\\s*[{(]", 2),
            Signal("\\bdocument\\.(getElementById|querySelector)|\\bwindow\\.", 2),
            Signal("===|!==", 1),
            Signal("(?m)^\\s*(export )?interface \\w+\\s*\\{", 4),
            Signal("(?m)^\\s*(export )?type \\w+ *=", 4),
            Signal(": *(string|number|boolean|void|any|unknown|never)\\b", 3),
            Signal("(?m)^\\s*(public|private|protected|readonly) \\w+ *:", 3),
            Signal("\\bas const\\b|\\bimplements \\w+", 2),
        ]),
        SignalGroup(language: .css, signals: [
            Signal("(?m)^\\s*@(media|import|font-face|keyframes|supports)\\b", 4),
            Signal("(?m)^\\s*[.#]?[\\w-]+[^{;\\n]*\\{\\s*$", 2),
            Signal("(?m)^\\s*[a-z-]{3,}\\s*:[^;\\n]+;", 2),
            Signal(":root\\b|!important\\b|\\bvar\\(--", 3),
            Signal("#[0-9a-fA-F]{3,8}\\b|\\b\\d+(px|rem|em|vh|vw)\\b", 1),
        ]),
        SignalGroup(language: .html, signals: [
            Signal("</(div|span|p|body|head|html|section|a|li|ul|table)>", 4),
            Signal("<(div|span|body|head|section|nav|header|footer|button)[ >]", 3),
            Signal("<(script|style|link|meta|img|br|input)[ />]", 2),
            Signal("\\bclass=\"[^\"]*\"|\\bhref=\"[^\"]*\"", 2),
        ]),
        SignalGroup(language: .xml, signals: [
            Signal("</\\w+:\\w+>", 4),
            Signal("(?m)^\\s*<\\w+(\\s+\\w+=\"[^\"]*\")*\\s*/?>", 2),
            Signal("</\\w+>[\\s\\S]{0,400}</\\w+>", 2),
            Signal("<!\\[CDATA\\[", 2),
        ]),
        SignalGroup(language: .cFamily, signals: [
            Signal("(?m)^\\s*#include\\s*[<\"]", 4),
            Signal("\\bint main\\s*\\(", 4),
            Signal("\\bprintf\\s*\\(|std::(cout|string|vector|endl)", 3),
            Signal("(?m)^\\s*(static\\s+)?(void|int|char|float|double|bool|size_t)\\s+\\w+\\s*\\([^)]*\\)\\s*\\{", 3),
            Signal("(?m)^\\s*#(define|pragma|ifndef|endif)\\b", 2),
            Signal("\\btypedef\\b|\\bstruct \\w+\\s*\\{", 1),
        ]),
        SignalGroup(language: .rust, signals: [
            Signal("(?m)^\\s*(pub )?fn \\w+", 4),
            Signal("\\blet mut\\b", 3),
            Signal("(?m)^\\s*use \\w+(::|;)", 3),
            Signal("\\b(println!|format!|vec!|panic!)\\(", 3),
            Signal("(?m)^\\s*impl( <[^>]+>)? \\w+", 3),
            Signal("-> *(Result|Option)<", 2),
            Signal("&(str|mut )\\b|\\bSome\\(|\\bNone\\b", 1),
        ]),
        SignalGroup(language: .go, signals: [
            Signal("(?m)^package \\w+\\s*$", 4),
            Signal("\\bfmt\\.(Println|Printf|Sprintf|Errorf)\\(", 4),
            Signal("\\berr *!= *nil\\b", 4),
            Signal("(?m)^\\s*func (\\([^)]*\\) )?\\w+\\(", 2),
            Signal("(?m)^import \\(", 3),
            Signal("\\w+ *:= *", 2),
        ]),
        SignalGroup(language: .java, signals: [
            Signal("(?m)^\\s*package [\\w.]+;", 4),
            Signal("(?m)^\\s*import (java|javax|kotlin|android)[\\w.]*;?", 4),
            Signal("\\bSystem\\.out\\.print", 4),
            Signal("\\b(public|private|protected)\\s+(static\\s+)?(final\\s+)?(class|void|int|String|boolean)\\b", 3),
            Signal("(?m)^\\s*(public |private |internal )?fun \\w+\\(", 3),
            Signal("\\bnew [A-Z]\\w*\\(", 1),
        ]),
        SignalGroup(language: .sql, signals: [
            Signal("\\bSELECT\\b[\\s\\S]{0,400}\\bFROM\\b", 4, caseInsensitive: true),
            Signal("\\b(CREATE|ALTER|DROP)\\s+(TABLE|VIEW|INDEX|DATABASE|SCHEMA)\\b", 4, caseInsensitive: true),
            Signal("\\bINSERT\\s+INTO\\b|\\bUPDATE\\s+\\w+\\s+SET\\b|\\bDELETE\\s+FROM\\b", 4, caseInsensitive: true),
            Signal("\\b(INNER|LEFT|RIGHT|OUTER)\\s+JOIN\\b|\\bGROUP\\s+BY\\b|\\bORDER\\s+BY\\b", 3, caseInsensitive: true),
            Signal("\\bWHERE\\b", 1, caseInsensitive: true),
        ]),
        SignalGroup(language: .yaml, signals: [
            Signal("(?m)^---\\s*$", 3),
            Signal("(?m)^[A-Za-z_][\\w.-]*:\\s*$", 3),
            Signal("(?m)^\\s+[A-Za-z_][\\w.-]*: +\\S", 3),
            Signal("(?m)^[A-Za-z_][\\w.-]*: +\\S", 2),
            Signal("(?m)^\\s*- +[A-Za-z_\"'{]", 1),
        ]),
        SignalGroup(language: .toml, signals: [
            Signal("(?m)^\\s*\\[\\[?[A-Za-z_][\\w.-]*\\]?\\]\\s*$", 4),
            Signal("(?m)^\\s*[A-Za-z_][\\w.-]* *= *\\S", 3),
            Signal("(?m)^\\s*[A-Za-z_][\\w.-]* *= *[\\[\"']", 2),
        ]),
    ]
}
