# betterTextEdit

A native macOS editor with four faces: a code editor for text and source files, a word processor for Word, Rich Text, and OpenDocument files, a PDF viewer and editor, and an image viewer. Built with SwiftUI, AppKit, TextKit, and PDFKit, with no cross-platform shell and no third-party dependencies. The editor itself is TextKit throughout; WebKit appears in exactly one place — rendering the HTML preview.

## Features

- Fast, memory-mapped loading for local text files
- **Keeps a text file's encoding and line endings** — UTF-8 with or without a BOM, UTF-16, Windows 1252, Latin 1, Mac Roman; LF, CRLF, or CR — and shows them in the status bar, where either can be changed
- Syntax highlighting for Swift, JavaScript, TypeScript, Python, HTML, CSS, C/C++, Rust, Go, Java, Shell, YAML, TOML, XML, SQL, JSON, and Markdown
- **Themes** — 21 of them, from Tokyo Midnight to Cherry Sakura, plus a System theme that follows macOS's Light/Dark switch
- **Imports VS Code and Cursor themes** — browse the ones already installed on your Mac, or open a `.json`, `.vsix`, or `.tmTheme` file
- Source, split, and preview modes for Markdown **and HTML** — local pages render with their own stylesheets, scripts, and images
- Tabs, and a file browser for the folder you're working in
- Opens to a blank document, like TextEdit or Notepad
- **Views images** — PNG, JPEG, TIFF, and the awkward ones too: WebP, HEIC, AVIF, and camera RAW; animated GIF, APNG, and animated WebP play, and can be stepped frame by frame. Zoom is continuous: pinch, the buttons under the picture, or double-click to switch between fitting the window and actual size
- **Saves as several formats** — a File Format popup in the Save panel, including PDF export
- **Reads and writes Word documents itself**, rather than through macOS's lossy converter — numbered lists stay numbered, links keep their destinations, tables keep their merged cells, highlighting, pictures, headings, footnotes, fields, headers and footers all survive an edit-and-save round trip. Verified by opening the results in Microsoft Word
- **Opens Rich Text and OpenDocument files with their formatting intact**, and saves them back in place
- **Edits that formatting** — a format bar and a Format menu for typeface, size, style, colour, and alignment, plus the standard macOS Font and Colour panels
- **Edits PDFs** — highlight, underline, and strike through text, add notes, fill in forms, rotate, reorder, delete, insert, and export pages, find text, and open password-protected files; ⌘S writes it all back into the PDF
- **Reads scanned PDFs and pictures** with on-device text recognition, and extracts text *and images* from any PDF into an editable document
- **Prints** anything it opens — ⌘P
- Converts any formatted document to Markdown
- JSON formatting and validation
- Line numbers, find bar, word wrap, text sizing, word count, cursor position
- Drag-and-drop and Finder "Open With" support

## How a file is opened

| Format | Extensions | Opens as | Read via | Save writes |
| --- | --- | --- | --- | --- |
| Text and source code | `.txt`, `.md`, `.json`, `.swift`, `.py`, `.css`, `.yaml`, … | Code editor | Memory-mapped; encoding and line endings detected | The same file, in the same encoding |
| Word | `.docx` | Word processor | `DocxReader` (AppKit as a fallback) | The same file, via `DocxWriter` |
| Word templates, macro-enabled Word | `.dotx`, `.dotm`, `.docm` | Word processor | `DocxReader` | A `.docx` copy |
| Rich Text | `.rtf`, `.rtfd` | Word processor | `NSAttributedString` | The same file |
| OpenDocument | `.odt` | Word processor | `NSAttributedString` | The same file |
| Word 97–2004 | `.doc` | Word processor | `NSAttributedString` | A `.docx` copy (`.doc` on request) |
| Web archive | `.webarchive` | Word processor | `NSAttributedString` | A `.docx` copy |
| PDF | `.pdf` | PDF viewer and editor | PDFKit | The same file |
| Images | `.png`, `.jpg`, `.heic`, `.webp`, `.avif`, `.gif`, `.tiff`, `.dng`, `.cr2`, `.nef`, `.arw`, … | Image viewer | ImageIO | — (read only) |

### Formatted documents

The text view edits the very `NSTextStorage` that came out of the file, so every font, colour, size, indent, tab stop, and paragraph spacing is the same object going back out. The page is laid out at the document's own paper size and margins, so lines break where Word breaks them, and the paper size — width *and* height, so A4 stays A4 — is written back on save.

Rich Text, RTFD, OpenDocument, and the older formats go through macOS's own readers and writers, reachable through `NSAttributedString`. Word documents don't, because macOS's Office Open XML support loses too much — see below.

### Word documents

macOS can read and write `.docx` on its own, and both directions are lossy. Measured on macOS 26, its **reader** turns every list into a bulleted one whatever Word numbered it, drops hyperlinks, pictures, highlighting, and heading levels, and shifts colours. Its **writer** flattens tables into paragraphs, drops link destinations and pictures, types list markers into the text as literal characters, and loses highlighting — and spells some elements in ways Word's schema doesn't recognise.

So betterTextEdit reads and writes the package itself. `.docx` is a ZIP of XML parts; `ZipArchive` and `ZipWriter` handle the container with `libcompression`, whose `COMPRESSION_ZLIB` is exactly the raw DEFLATE stream ZIP stores.

**Reading** (`DocxReader`) resolves formatting the way Word does — document defaults, the paragraph style and everything it's based on, the character style, then direct formatting, with theme fonts and colours looked up — and numbers lists by running Word's own counters over `numbering.xml`, so `1.`, `a.`, `ii.`, and `Article 4` come out as Word shows them, including lists that restart or carry on. Pictures land exactly where their drawing sits, at Word's display size, with their original bytes. Tables keep merged cells, borders, shading, and padding. Fields show their results; tracked changes show accepted; footnotes and endnotes are gathered after the text. Spacing that Word works out between neighbouring paragraphs — contextual spacing, HTML-style automatic spacing — is applied the way Word applies it, so a list's items sit together.

**Writing** (`DocxWriter`) turns it all back into the same structures: real numbering definitions, hyperlinks, `w:tbl` tables, inline pictures, headings Word's navigation pane recognises, highlight versus shading, and the page's size, orientation, and margins. Fields are written back around their results, so a table of contents is still a table of contents; footnotes go back into `footnotes.xml` behind their reference marks. Headers and footers never reach the text view — there's nowhere to put them — so they're copied across from the original package byte for byte.

**Horizontal lines and borders.** Word draws a line across the page in three different ways, and all three are read: a paragraph border (what typing `---` and Return makes), Word's own horizontal line (*Insert ▸ Horizontal Line*, and what HTML's `<hr>` becomes — newer Word versions rewrite it as a thin rectangle named "Horizontal Line"), and a drawn line shape. Paragraph borders and shading become an `NSTextBlock` round the paragraph — shared by consecutive paragraphs with the same borders, as Word groups them, and given an explicit width, because a text block without one collapses to a single letter per line. The other two draw as a rule spanning the line.

**Word formatting the text system doesn't have** is carried as attributes and drawn by `WordLayoutManager`: tab leaders (the dots in a table of contents), small and all capitals (drawn as capitals, saved as typed), boxed text, and hidden text, which stays in the document — and is saved — but takes no space on screen. Character scaling and outline map to AppKit's own expansion and stroke. Symbol characters from Wingdings and Webdings draw in those fonts, which macOS ships; Symbol's are mapped to the Unicode characters they stand for.

**What can't be edited is kept, not dropped.** Equations, text boxes, shapes, charts, SmartArt, and embedded objects arrive as objects in the text — an equation in its linear form, a text box with its text, others as a labelled frame of the right size, or their preview picture — holding the exact XML they came from and every package part it refers to. Saving writes them back byte for byte, with their relationships renumbered for the new package, so a chart stays a live chart. Byte for byte matters: Word keeps a checksum of a VML shape beside the drawing it really uses, and a shape rewritten even in attribute order is drawn from its plain fallback instead.

**Structure survives too:** bookmarks (so internal links and cross-references still land), content controls round text and round whole paragraphs, named paragraph and character styles — written with their original definitions, so Word's style gallery and table of contents still know them — the document theme, custom document properties, custom XML, and the section's columns, page borders, and line numbering.

Office fonts that macOS doesn't ship — Calibri, Cambria, Aptos — are shown in a close stand-in, and written back under their real names, so a document doesn't change typeface by being opened here. The format bar shows the name the document asked for.

The reader leaves AppKit-native structures behind it — `NSTextList`, `NSTextTable`, `NSTextAttachment` — so the text view edits everything natively, and labels anything Word-specific with attributes of its own, which the writer reads. Those labels are kept off text typed next to a labelled run, so new text after a list marker or a footnote never becomes part of it.

Both halves were checked against Microsoft Word itself: documents written in Word, read here, written back, and opened in Word again have the same paragraphs, tables, links, pictures, footnotes, fields, list numbers, and appearance.

### Known limits

These are worth knowing before you rely on a round trip.

- **Some parts of a Word document can't be kept:** comments, tracked changes (they're shown accepted), and layouts with more than one section — a document is saved as one section, with the last section's settings. The status bar says when a document has any, and saving *over the original* asks first and offers a copy instead — a copy leaves the original holding them.
- **Equations, text boxes, shapes, charts, SmartArt, and embedded objects** are kept exactly and saved back as they were, but can't be edited here — they move and delete as a whole, like a picture. Floating objects sit in the line rather than where Word floats them.
- **Columns, page borders, line numbers, and drop caps** are saved back but not shown — the editor is one column. A double or dotted border is drawn as a single line, though it's saved as it was.
- **Pictures linked to a file outside the document**, rather than embedded in it, aren't shown.
- **Macro-enabled documents and templates** open as documents and save as a `.docx` copy: macros can't be written, and writing a template's contents over it would turn it into a document.
- **macOS's Rich Text writer can't hold pictures** — save as RTFD or Word to keep them. Its OpenDocument writer drops pictures too, and its Word 97–2004 writer drops lists, links, and pictures. betterTextEdit says what a format will lose before a save simplifies a document.
- **Pages, Keynote, Numbers, and EPUB** have no public reader. Opening one names the format and suggests an export rather than showing a wall of binary.
- **PDF text isn't edited in place** — PDFs can be marked up, filled in, and rearranged, but rewording one means extracting its text into a document. Text recognised from a scan goes into a new document rather than being embedded in the PDF as a searchable layer.
- `.html` opens as source to edit, not as a formatted document.

### Pictures

Neither of the two frameworks involved hands over the pictures in a document, so betterTextEdit goes and gets them.

**Word.** `DocxReader` places each picture exactly where its drawing sits in the text. Each drawing's `<wp:extent>` gives Word's intended display size in EMUs, so a 3000-pixel photograph scaled to three inches in Word appears three inches wide here too. The attachment carries the file's original bytes rather than a re-encode, so a JPEG stays a JPEG — and `DocxWriter` writes those same bytes back into `word/media/`, converting only formats Word can't read, such as HEIC, to PNG.

When a package is too damaged for `DocxReader` and AppKit's reader takes over, that reader ignores `<w:drawing>` completely, so `DocxImages` puts the pictures back by counting characters through `word/document.xml`. Lists and tables can nudge those offsets, so in that fallback images land near, not always exactly at, their original position.

**PDF.** Images are XObjects in the page's resource dictionary. `CGPDFStreamCopyData` returns either ready-made JPEG/JPEG 2000 bytes, which macOS decodes directly, or raw samples, which are rebuilt into a `CGImage` — the component count is derived from the byte count rather than by parsing the colour-space object, which covers the grey and RGB bitmaps that make up nearly all raw PDF images and declines the rest instead of guessing. Anything under 24 pixels is skipped as a rule or spacer. The walk recurses into form XObjects, because pictures are frequently not at the top of a page — anything drawn through a reusable form, including macOS's own PDF printing, nests them a level or more down, and a scan that only looks at the page's own XObjects comes back empty. Positioning images against the text would mean tracking the graphics state through the whole content stream, so each page's images follow that page's text in draw order.

`.rtfd`, `.html`, and web archives carry their images through AppKit normally. Writing images back needs `.rtfd` — AppKit's `.rtf` and `.docx` writers both drop attachments.

### Zooming pictures and pages

Images and PDFs share one zoom model: `0` means "fit the window" and re-fits as the window resizes, and any other value is a fixed multiple of the content's own size that stays put. Both get the same bar underneath — minus, the live percentage, plus, Fit, 100% — and both pinch.

The two arrive at it differently. The image viewer owns its scale outright, so the pinch is a `MagnifyGesture` whose in-flight value is held apart from the stored setting; committing on every frame of a gesture would mean writing to `UserDefaults` on every frame of a gesture. PDFKit does its own pinch handling — page-aware and properly centred — so rather than fight it with a gesture of our own, `PDFViewer` listens for `PDFViewScaleChanged` and adopts the result. Telling a user's pinch from PDFKit re-fitting after a window resize is what `autoScales` is for: while it's on the scale is only worth reporting for the percentage on the bar, and adopting it there would turn the first window resize into a fixed zoom and quietly break fitting.

### Images

Anything ImageIO decodes opens as a picture, which is most of them: WebP, HEIC, AVIF, and every camera RAW variant arrive for free because the check is a type-conformance test rather than a list of extensions — `public.image` or `public.camera-raw-image`. New formats turn up with the OS. SVG is deliberately excluded: it's a picture, but it's also text, and editing the source is the more useful thing for an editor to offer.

Animation is just a source with more than one frame, so GIF, APNG, and animated WebP all work the same way. Each frame carries the delay its file asked for — floored at 20 ms, the way browsers do it — and the strip under the picture plays, pauses, steps a frame at a time, and scrubs. Transparency sits on a chequerboard so alpha reads as alpha.

Images are read-only. The status bar carries the dimensions, format, colour model, bit depth, and file size.

### Saving as another format

The Save panel carries a **File Format** popup. A plain document can go out as itself, Rich Text, Word, OpenDocument, or PDF; a formatted one as Word, Rich Text, RTFD, OpenDocument, HTML, PDF, Word 97–2004, plain text, or Markdown.

Every save builds the new file beside the original and swaps it in with `replaceItemAt`, so a failed write never leaves half a file, and the original's Finder tags, colour label, permissions, and creation date carry over — an atomic write on its own replaces the file with a new one that has none of them.

PDF export goes through `NSPrintOperation` rather than a Core Text framesetter — the print machinery already paginates an `NSTextView`, and unlike a framesetter it draws text attachments, so a document's pictures make it into the PDF.

Exporting is not the same as saving: writing a PDF or a flattened copy leaves the tab pointing at the original document, so the next ⌘S still goes where you'd expect.

### Text encodings and line endings

A text file is read in whatever encoding it's in and written back the same way: the status bar shows it — `UTF-8 · LF`, `Windows 1252 · CRLF` — and is a menu for changing the encoding, the byte-order mark, or the line endings the next save uses, or for reopening the file in a different encoding when a guess was wrong.

A byte-order mark is believed. Without one, UTF-16 is recognised by its pattern of zero bytes, then UTF-8 is tried — it's strict enough that anything that decodes as UTF-8 almost certainly is — and only then Windows 1252, which decodes anything and so is the last resort for data that already looks like text. Windows 1252 rather than Latin 1, because the two only differ at 0x80–0x9F, where Latin 1 has invisible control codes and Windows 1252 has the curly quotes, dashes, and euro sign such files are actually full of.

The editor only ever sees `\n`; a file's line endings are put back on the way out, using whichever the file mostly used. If text gains a character its encoding can't hold — an emoji typed into a Windows 1252 file — saving offers UTF-8 rather than failing or quietly writing question marks.

### Editing PDFs

PDFs open ready to work on. Highlight, underline, or strike through the selected text, or leave a note — click its icon later to read, change, or delete it. Rotate, reorder, delete, or export pages, or insert pages from other PDFs or pictures. Fill in forms in place. ⌘S writes it all back into the same file, safely: the new version goes to a scratch file first and only replaces the original once it's complete. Every change can be undone, and each PDF keeps its own undo history.

The sidebar shows every page. Click to go to one, ⌘/⇧-click to pick several for the page commands, drag to reorder, or right-click for Rotate, Export, and Delete. If the PDF has a table of contents, it's a click away. The thumbnails are drawn by `PDFPage` rather than `PDFThumbnailView`, because on macOS 26 the latter ignores page rotation.

**Password-protected PDFs** ask for their password instead of refusing to open. Once unlocked, a saved copy stays encrypted with the same password.

**Scanned PDFs and pictures.** *Extract Text from PDF* reads pages that have no text layer using Vision's on-device document recognition, which keeps paragraphs in reading order and turns a title into a heading. It shows progress and can be cancelled. *Convert ▸ Recognise Text in Image* does the same for pictures.

**Find in PDF.** ⌘F jumps to the find field below the page. It shows every match at once with a count; Return and ⇧Return step through them, and Esc clears.

### Printing

⌘P prints whatever is on screen the way the app that made it would: a formatted document at its own paper size and margins, a PDF as its pages, a picture scaled to fit, and text in a monospaced face. The print panel comes down as a sheet on the window.

### HTML preview

HTML opens as source, because that's what a text editor is for, and gains the same Source / Split / Preview switch Markdown has.

Rendering it is less obvious than it looks. `loadHTMLString(_:baseURL:)` pointed at the file's folder doesn't work — WebKit treats a string load as an opaque origin, so the page's stylesheets, scripts, and images never load. Loading the file off disk instead would only ever show the *saved* version, not what you're typing.

So the page is served through a custom URL scheme: the document itself comes from the editor's live text, and relative resources are read from the real folder beside it. Edits appear as you type (debounced, with the scroll position carried across the reload), `<link>`, `<img>`, and `<script>` resolve, and the handler refuses to serve anything outside the document's own directory. Clicking a link to the wider internet hands off to the default browser rather than steering the preview somewhere the editor can't follow. JavaScript runs by default and can be switched off per the View Options menu.

### Markdown conversion

*Convert ▸ Convert to Markdown* flattens a formatted document or a PDF into Markdown in a new tab, leaving the original alone. Headings are recovered by ranking the font sizes used against the document's dominant body size; lists come from the paragraph styles, or from literal `"\t•\t"` markers when a writer baked them into the text; tables are reassembled from their row and column indexes; bold, italic, strikethrough, monospaced runs, and links map to their Markdown spellings.

## Tabs and the file browser

Open files are tabs, with a `+` at the end of the strip for a new one. They can be dragged into any order: the reorder happens as a dragged tab *enters* each neighbour rather than on release, so the strip opens a gap and you can see where it will land. Entering is naturally debounced — it fires once per boundary crossed, not continuously — which is what keeps two tabs of different widths from swapping back and forth under a stationary pointer. The file browser to their left is hidden until asked for — ⌃⌘S, or the button at the left of the toolbar — and follows the folder of the first file you open until you point it somewhere else. Folders load their contents the first time they're opened rather than up front, so aiming it at a large tree costs nothing until you go looking.

## Keyboard shortcuts

| | |
| --- | --- |
| ⌘N / ⌘T | New file · new tab — the same blank document under both chords |
| ⌘O / ⇧⌘O | Open file · open folder |
| ⌘W | Close tab — the window goes only once the last tab has |
| ⌘S / ⇧⌘S | Save · Save As |
| ⌘P | Print |
| ⌘1…⌘9 | Jump to a tab |
| ⇧⌘] / ⇧⌘[ | Next · previous tab |
| ⌃⇥ / ⌃⇧⇥ | Cycle tabs |
| Middle-click | On a tab, closes it · on empty strip, opens a new one |
| Drag a tab | Rearranges the strip |
| ⌃⌘S | Show or hide the file browser |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Source · Split · Preview |
| ⌘+ / ⌘- / ⌘0 | Bigger · smaller · actual size |
| ⌘F | Find |
| ⇧⌘T / ⇧⌘C | Fonts · Colours (formatted documents) |
| ⌘B / ⌘I / ⌘U | Bold · italic · underline (formatted documents) |
| ⌘{ / ⌘\| / ⌘} | Align left · centre · right |
| ⇧⌘E | Extract text from a PDF |
| ⌃⌘H / ⌃⌘U / ⌃⌘N | Highlight · underline · add a note (PDFs) |
| ⌘L / ⌘R | Rotate the page left · right (PDFs) |
| ⌥⇧⌘F | Format JSON |

⌘1…⌘9 belong to the tabs, so the view modes sit on ⌥⌘. Tab cycling is a key monitor rather than a menu item, since a menu shortcut can't carry ⇥ — it watches for that exact chord only, leaving ordinary tabbing in the editor alone.

## Settings

Settings opens as a tab in the window rather than a panel over the top of it — ⌘, or the app menu, closed with ⌘W like any other tab. It's the VS Code arrangement, and the reason for it is that almost everything in there is about how the window looks, which is hard to judge from a floating box covering the thing you're judging.

Inside, a section list runs down the left — General, Themes, Appearance — rather than a row of tabs across the top. A tab bar is for a panel, and this isn't one: it has the whole window's width to work with. The list sits on the same recess and hairline as the file browser, so the two panels in the window are plainly the same kind of thing, and the forms are laid out flat rather than grouped — `.formStyle(.columns)`, because grouped draws each section as a card on an opaque backing, and over glass a column of those reads as a stack of grey slabs dropped on the window.

Every row has the same shape — title, a line of explanation, then the control — all left-aligned to one margin. That's hand-laid rather than a `Form`: the grouped style draws cards, and the columns style right-aligns labels into a gutter, so rows drift away from the left edge by however long the longest label happens to be.

Appearance covers three things: the **Window** (light/dark, surface, tint), the **Editor** (line numbers, current-line highlight, line spacing), and the **Controls** (whether the theme's accent takes over from the one in System Settings, which is disabled under the System theme since it has no accent of its own). Line spacing is labelled Tight / Normal / Relaxed / Airy rather than in points — nobody chooses leading in points, they choose how dense they want the page to feel. Hiding the gutter collapses it to zero width rather than just hiding the numbers, so the code reclaims the space.

### The current-line highlight

The band behind the caret's line is drawn by a view *under* the scroll view, not by the text view and not as an attribute on the storage.

Both of the obvious approaches fail. A `.backgroundColor` attribute is only as wide as the glyphs on that line, so a short line gets a short stripe — and the highlighter rewrites every attribute on the storage on each pass, so the two would fight. The text view's own background can't do it either: it has to stay clear for the window's glass to show through, and anything it did paint would cover the band. So `EditorBackgroundView` is a sibling of the scroll view sitting beneath it — the same trick the gutter uses, reading the TextKit 1 layout without joining the text view's hierarchy — and it paints the canvas *and* the band. The text view now never paints a background at all.

It stops at the gutter rather than running through it, because the gutter paints its own background and would cover it anyway; the gutter marks the active line by brightening its number to the theme's `gutterActiveForeground` instead. A selection replaces the band rather than joining it — two overlapping highlights read as a mistake.

### File type presets

Settings ▸ File Types gives a kind of file its own theme, font, size, line spacing, or wrap setting. Everything defaults to Default, and that's the design: a preset says only what it wants changed, and anything it doesn't mention falls through to General and Appearance. So a preset about fonts keeps working when the theme is changed elsewhere.

Every control is a popup whose first entry is Default, including the numeric ones, because the absence of an override is a real chosen state rather than an empty field — a slider can't say "nothing" without an extra checkbox beside it.

Presets match on `FileLanguage` rather than on file extension, since the language is already what the editor reasons in: it's what the highlighter switches on, what the status bar shows, and what you can override by hand there. Matching extensions would mean a preset for `.js` that missed `.mjs`. One preset per language — languages already spoken for aren't offered in the add menu, so there's never a question of which of two wins.

The theme override reaches the whole window, not just the editor, which is why it lives in `ThemeStore` rather than being resolved at each call site: the store knows which language is on screen, and `current` simply answers differently. Every existing `themes.current` reader — the sidebar, the tab band, the status bar — follows along untouched.

It rides in the tab strip on a fixed id of the same shape as a document's, so tab selection, ⌃Tab, and the glass that slides between tabs all work on one `selectedID` with no second notion of what's on screen. Because that id matches no document, `selectedDocument` is `nil` while Settings is up, which is what keeps Save, the format controls, and the status bar quiet without any of them having to know Settings exists.

## Themes

Settings ▸ Themes is a gallery: every card is the theme itself painting five lines of code, because a name and a swatch don't tell you what a theme is like to read. Twenty-one ship with the app — Tokyo Midnight, Sakura Night, Kanagawa Wave, Nord Aurora, Dracula, Catppuccin Mocha and Latte, Gruvbox Dusk and Dawn, Monokai Neon, One Dark, Rosé Pine and Dawn, Night Owl, Ayu Mirage, Everforest, Synthwave Sunset, Solarized Dark and Light, Cherry Sakura, and Paper White — alongside a System theme that paints with macOS's own semantic colours and so follows the Light/Dark switch on its own. There's a Theme submenu in View for switching without opening Settings.

A theme colours the canvas, the selection, the caret, the gutter, the window's tint, and the accent on every stock control — not just the keywords. Picking one also settles the window's appearance: with Appearance on "System", a dark theme gives you dark chrome. Choosing Light or Dark explicitly overrides that, because that's a decision about your windows rather than about your code.

### Settings

Settings opens as a tab in the window rather than a panel over the top of it — ⌘, or the app menu, closed with ⌘W like any other tab. It's the VS Code arrangement, and the reason for it is that almost everything in there is about how the window looks, which is hard to judge from a floating box covering the thing you're judging.

Inside, a section list runs down the left — General, Themes, Appearance — rather than a row of tabs across the top. A tab bar is for a panel, and this isn't one: it has the whole window's width to work with. The list sits on the same recess and hairline as the file browser, so the two panels in the window are plainly the same kind of thing, and the forms are laid out flat rather than grouped — `.formStyle(.columns)`, because grouped draws each section as a card on an opaque backing, and over glass a column of those reads as a stack of grey slabs dropped on the window.

Every row has the same shape — title, a line of explanation, then the control — all left-aligned to one margin. That's hand-laid rather than a `Form`: the grouped style draws cards, and the columns style right-aligns labels into a gutter, so rows drift away from the left edge by however long the longest label happens to be.

Appearance covers three things: the **Window** (light/dark, surface, tint), the **Editor** (line numbers, current-line highlight, line spacing), and the **Controls** (whether the theme's accent takes over from the one in System Settings, which is disabled under the System theme since it has no accent of its own). Line spacing is labelled Tight / Normal / Relaxed / Airy rather than in points — nobody chooses leading in points, they choose how dense they want the page to feel. Hiding the gutter collapses it to zero width rather than just hiding the numbers, so the code reclaims the space.

### The current-line highlight

The band behind the caret's line is drawn by a view *under* the scroll view, not by the text view and not as an attribute on the storage.

Both of the obvious approaches fail. A `.backgroundColor` attribute is only as wide as the glyphs on that line, so a short line gets a short stripe — and the highlighter rewrites every attribute on the storage on each pass, so the two would fight. The text view's own background can't do it either: it has to stay clear for the window's glass to show through, and anything it did paint would cover the band. So `EditorBackgroundView` is a sibling of the scroll view sitting beneath it — the same trick the gutter uses, reading the TextKit 1 layout without joining the text view's hierarchy — and it paints the canvas *and* the band. The text view now never paints a background at all.

It stops at the gutter rather than running through it, because the gutter paints its own background and would cover it anyway; the gutter marks the active line by brightening its number to the theme's `gutterActiveForeground` instead. A selection replaces the band rather than joining it — two overlapping highlights read as a mistake.

### File type presets

Settings ▸ File Types gives a kind of file its own theme, font, size, line spacing, or wrap setting. Everything defaults to Default, and that's the design: a preset says only what it wants changed, and anything it doesn't mention falls through to General and Appearance. So a preset about fonts keeps working when the theme is changed elsewhere.

Every control is a popup whose first entry is Default, including the numeric ones, because the absence of an override is a real chosen state rather than an empty field — a slider can't say "nothing" without an extra checkbox beside it.

Presets match on `FileLanguage` rather than on file extension, since the language is already what the editor reasons in: it's what the highlighter switches on, what the status bar shows, and what you can override by hand there. Matching extensions would mean a preset for `.js` that missed `.mjs`. One preset per language — languages already spoken for aren't offered in the add menu, so there's never a question of which of two wins.

The theme override reaches the whole window, not just the editor, which is why it lives in `ThemeStore` rather than being resolved at each call site: the store knows which language is on screen, and `current` simply answers differently. Every existing `themes.current` reader — the sidebar, the tab band, the status bar — follows along untouched.

It rides in the tab strip on a fixed id of the same shape as a document's, so tab selection, ⌃Tab, and the glass that slides between tabs all work on one `selectedID` with no second notion of what's on screen. Because that id matches no document, `selectedDocument` is `nil` while Settings is up, which is what keeps Save, the format controls, and the status bar quiet without any of them having to know Settings exists.

## Themes and glass

A theme never turns the glass off. With the window translucent the editor stays clear, exactly as it does without a theme, and the theme's canvas colour becomes what washes over the behind-window blur — so the glass takes on the theme instead of going grey, and the editor and the chrome around it stay one continuous surface rather than a solid slab punched through the middle of one.

The Tint dial still runs that wash, with one difference: a theme puts a floor under it. Its syntax colours were chosen to sit on its own background, and at no tint at all they'd be sitting on whatever happens to be on the desktop. So the dial travels from that floor to the same maximum rather than from zero, which keeps it live across its whole length instead of clamped flat for the first two thirds. Turn translucency off and the theme paints its background solid, as you'd expect.

### The window's surface

macOS offers several genuinely different ways for a window to be see-through, and they aren't points on one scale — so the surface is a picker rather than a slider or a switch.

| | | Tint |
| --- | --- | --- |
| **Solid** | The theme's background, painted. No desktop at all. | — |
| **Glass** | `NSGlassEffectView` at `.regular`. Frosted Liquid Glass. | ✓, with a floor |
| **Clear** | `NSGlassEffectView` at `.clear`. Barely there, still refracting. | ✓, from zero |
| **Blur** | `NSVisualEffectView`'s behind-window material — the blur macOS had before Liquid Glass. Flatter: it smears what's behind the window without bending or catching light on it. | ✓, with a floor |
| **Sheer** | No material at all. Colour over a sharp desktop. | ✓, from zero |

Glass and Blur are kept side by side rather than one replacing the other, because neither is a worse version of the other — glass refracts and catches light across its surface, the material only smears, and the second is calmer to work over for long stretches.

Tint is the one dial, and it means the same thing on all four translucent surfaces: how much of the theme's canvas colour the window carries. The two Liquid Glass surfaces tint themselves through `tintColor`, because that's how the API wants to be told; the other two take the same colour as a flat wash. Switching surface changes the material and nothing else.

A theme keeps a floor under that tint on **Glass** and **Blur** — the surfaces whose job is to *be* a canvas, and a canvas the theme has faded out of isn't one. **Clear** and **Sheer** are both someone asking to see through the window, so they take the dial at its word all the way down: Sheer with the tint at zero is a genuinely transparent window, nothing between the text and the desktop at all.

### Why there's no blur dial

An app cannot set a blur radius. The behind-window blur belongs to the window server, and neither `NSVisualEffectView` nor `NSGlassEffectView` exposes an amount — the first offers named materials, the second two styles. Fading a material's alpha doesn't blur less either: it takes the material away and shows a *sharp* desktop through the gap, which is a second tint control wearing a blur control's label. That state is worth having, so it's a surface of its own (Sheer) rather than the bottom of a dial that lied about being continuous.

`CALayer.backgroundFilters` with a `CIGaussianBlur` looks like the way round this and isn't: measured on macOS 26, a `CIColorInvert` in `backgroundFilters` leaves a red backdrop at exactly red 255 / blue 0, while the same filter in `filters` on the layer's own content inverts it to red 3 / blue 255. Core Image runs fine; backdrop filtering does nothing. The only thing left is private SPI, which isn't worth building a settings dial on.

## Interface

The app uses the system's own furniture: a native title bar with the document proxy icon, a native toolbar, native segmented and pull-down controls, the standard Font and Colour panels, and `ContentUnavailableView` for empty and error states.

Typography follows the macOS type scale — `.body`, `.callout`, `.subheadline`, `.title` and friends — rather than hard-coded point sizes. Monospaced type is reserved for content that is actually code: the code editor, the line-number gutter, and fenced code blocks in the Markdown preview. Chrome uses the system UI font, with `.monospacedDigit()` where numbers would otherwise jitter. Under the System theme the accent colour is whatever the user chose in System Settings; under any other, it's the theme's. Formatted documents are laid out on a white page, because a document carries its own colours and needs paper behind them in either appearance.

## Icon

The icon is a text I-beam on a blue squircle — the one glyph that means "text" to anyone who has used a computer, and the only one of the three designs tried that survives being drawn at 16 points.

Its geometry was measured rather than guessed. Sampling the silhouettes of the system's own Tahoe icons gives a shape covering 83.6% of the canvas, inset 8.2% left and right, sitting slightly high so the baked shadow has room beneath it. The corner is a superellipse, not a circular round-rect: TextEdit's outline has a width profile of 0.728 / 0.830 / 0.922 at 2% / 5% / 10% down from the top, and an exponent of 5 reproduces that to within a hundredth.

`Tools/GenerateAppIcon.swift` draws it, so the icon is source rather than a binary blob:

```sh
swift Tools/GenerateAppIcon.swift /tmp/icon ibeam
iconutil -c icns /tmp/icon/AppIcon.iconset -o betterTextEdit/Resources/AppIcon.icns
```

## Run

Open `betterTextEdit.xcodeproj` in Xcode, select the **betterTextEdit** scheme, and press **Run**. The deployment target is macOS 26 or newer.

From Terminal, you can also build with:

```sh
xcodebuild -project betterTextEdit.xcodeproj -scheme betterTextEdit -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## Releasing

The version number lives in exactly one place — `MARKETING_VERSION` in the project — and even that is overridden at release time by the git tag, so a tag is the only thing that decides what a release is called. `CFBundleVersion` is the commit count, which climbs on its own and is what Sparkle compares to decide one build is newer than another.

Cutting a release is one command:

```sh
git tag v1.0.1 && git push origin v1.0.1
```

`.github/workflows/release.yml` does the rest, in this order:

1. Builds a universal Release archive with the version taken from the tag.
2. Signs the app **inside out** — Sparkle's two XPC services, its helper tool and its nested updater app, then the framework, then the app itself. A bundle's signature covers what's inside it, so anything signed out of order seals a description of code that has already changed. `Tools/sign_app.sh` does this and then verifies it with `--deep --strict`.
3. Notarises the app and staples the ticket to it, *before* the disk image is built around it — so a copy dragged out of the image carries its own notarisation and opens even offline.
4. Builds the `.dmg`, signs it, notarises that too, and checks it with `spctl` the way a user's Mac will.
5. Signs the image with the Sparkle EdDSA key and adds an entry to `appcast.xml`.
6. Publishes the `.dmg` to a GitHub Release and the appcast to GitHub Pages.

Release notes come from `CHANGELOG.md`. The section matching the version being tagged becomes both the GitHub Release body and the text shown inside the app's update dialogue, so notes are written once.

### Releasing from your own Mac instead

`Tools/release_local.sh` does the same thing without CI, running the same scripts in the same order. The Developer ID certificate and the Sparkle key are already in your login Keychain, so the only thing to arrange is notarisation — once, ever:

```sh
xcrun notarytool store-credentials betterTextEdit \
    --apple-id <you@example.com> --team-id UP8MGDBQ7Q --password <app-specific>

Tools/release_local.sh 1.0.1
```

It refuses to start unless the tree is clean, the tag doesn't already name a published release, the certificate and notarisation profile are present, and the version is well formed — all checked up front rather than discovered three minutes into a build. The tag is pushed last, after everything else has succeeded, so a failure partway through leaves no tag claiming a release that doesn't exist.

The two paths can't collide: the workflow's first job checks whether the tag already has a `.dmg` attached and stands down if it does. That matters because the appcast records a signature for one specific file — a second build of the same version would produce a different one, and Sparkle would refuse the download whose signature no longer matched.

### Repository protections

- Only GitHub-authored actions may run, so no third-party action can be introduced into the release pipeline.
- `GITHUB_TOKEN` defaults to read-only; the release workflow asks for `contents: write` explicitly and nothing else does.
- `main` cannot be force-pushed or deleted.
- `v*` tags cannot be deleted, moved, or force-updated — a moved tag would republish different code under a version users have already been offered.
- Secret scanning with push protection is on, so a key can't be committed by accident.

### How updating works

The app embeds [Sparkle](https://sparkle-project.org). On launch it starts a daily background check against the feed named by `SUFeedURL` in `Info.plist`; **Check for Updates…** in the app menu and the button in Settings ▸ General ask immediately.

Every build is signed with an ed25519 key whose public half is `SUPublicEDKey` in `Info.plist`. Sparkle verifies that signature before it will install anything, so a download swapped in transit — or a release published by anyone without the private key — is refused. The private key lives in the login Keychain and in the `SPARKLE_PRIVATE_KEY` Actions secret, and nowhere else. **Losing it means no existing install can ever be updated again**, because they will only accept builds signed by its counterpart; back it up somewhere durable.

### Secrets the release workflow needs

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | The Developer ID Application certificate and key, exported as `.p12` and base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | The password set when exporting that `.p12` |
| `APPLE_ID` | The Apple ID that owns the certificate |
| `APPLE_TEAM_ID` | The ten-character team identifier |
| `APPLE_APP_PASSWORD` | An app-specific password from [appleid.apple.com](https://appleid.apple.com), for notarisation |
| `SPARKLE_PRIVATE_KEY` | The ed25519 private key that signs updates |

`Tools/setup_secrets.sh` sets all of them except the Sparkle key, which is generated once and never changes. Run it again whenever the Developer ID certificate is reissued — Apple's expire yearly, and a release that fails while signing is usually just that:

```sh
Tools/setup_secrets.sh ~/Desktop/DeveloperID.p12
```

`.github/workflows/build.yml` needs none of them — it compiles, checks the release tooling still runs, and signs nothing, so it works on forks and pull requests.
