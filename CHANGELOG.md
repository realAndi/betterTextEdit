# Changelog

Each release gets a section here. The release workflow reads it: the section
matching the version being tagged becomes the GitHub Release notes *and* the
text shown in the app's update dialogue, so this file is the one place release
notes are written.

Headings and bullets carry across; keep entries short and in plain language,
since they're read by someone deciding whether to click Install.

## 1.1.0

### Word documents

- Word documents are now read and written by betterTextEdit itself instead of
  macOS's converter. Numbered lists stay numbered, links keep their
  destinations, and tables keep merged cells. Highlighting, pictures,
  headings, footnotes, tables of contents and headers and footers all survive
  being edited and saved.
- Pages look the way they do in Word. Lines, paragraph spacing, borders and
  justified text land where Word puts them, so a one-page résumé stays one
  page and every line breaks in the same place.
- Calibri and Cambria are shown in Carlito and Caladea, free typefaces drawn
  to the same widths, so lines break exactly where Word breaks them. Other
  typefaces this Mac doesn't have, such as Aptos, are shown in the closest
  match. All are saved under their real names.
- PDF export and printing start new pages where Word does. Headings stay
  with what follows, and a paragraph's first or last line isn't left alone on
  a page. Page breaks in the document now start a new page.
- Opens Word templates and macro-enabled documents, and saves them as a copy.
- Saves OpenDocument files in place, and can export Word 97–2004 files.
- A4 and other paper sizes now keep their height when saved.
- Horizontal lines and paragraph borders show, however Word drew them: the
  `---` kind, Insert ▸ Horizontal Line, drawn lines, boxes and shading.
- Table-of-contents dot leaders, small caps, boxed text, hidden text, and
  Wingdings and Symbol characters show as they do in Word.
- Equations, text boxes, shapes, charts and SmartArt are kept exactly and
  saved back untouched, instead of being lost.
- Bookmarks, content controls, named styles, columns, page borders, line
  numbers and custom document properties all survive a save.
- Before saving over a Word document that has comments, tracked changes or
  other content betterTextEdit can't keep, you're asked first and offered a
  copy instead.

### PDFs

- Highlight, underline and strike through text, add notes, and fill in forms.
- Rotate, reorder, delete, insert and export pages, with a thumbnail sidebar.
- Find text in a PDF, with every match shown.
- Open password-protected PDFs.
- Save it all back into the PDF, with undo throughout.
- Reads scanned PDFs and pictures with on-device text recognition.

### Text files

- Keeps each file's encoding and line endings. Windows files with curly
  quotes open correctly, and UTF-16 and BOM files are saved the way they were
  opened. The status bar shows the encoding and lets you change it.
- Saving keeps a file's Finder tags and permissions.
- New tabs are ready to type into straight away.

### Everywhere

- Print with ⌘P.

### Fixes

- ⌘S on a Word or Rich Text file opened from disk no longer
  replaces it with plain text.
- Opening files from the Finder while betterTextEdit is running no longer
  opens extra windows, and relaunching no longer brings back duplicates.
- PDF export and printing put text the right distance from the top of the
  page when a document's top and bottom margins differ, and no longer add a
  blank page at the end.
- Word documents from Google Docs no longer show a stray "Shape" box at the
  top, and an empty comments section no longer counts as content that can't
  be kept.

## 1.0.1

The first release.

### Editing

- Syntax highlighting for the languages betterTextEdit detects by extension and
  by content.
- Rich text alongside plain text — bold, italic, alignment, fonts and colours,
  with a formatting bar that appears only when it applies.
- Markdown, HTML and SVG preview, side by side with the source or on its own.
- Find within a document, line numbers, soft wrapping and adjustable line
  spacing.

### Files

- Tabs, with ⌃Tab to cycle and ⌘1–⌘9 to jump.
- A file browser for a folder you point it at.
- Opens Word documents, RTF, OpenDocument text, web archives, PDFs and images.
- Extracts text and images out of PDFs; exports to PDF; converts rich text and
  PDFs to Markdown; exports SVG as PNG.

### Appearance

- Built-in light and dark themes, plus import of VS Code themes.
- Three window surfaces: solid, glass and clear.
- Per-file-type presets, so a `.md` file can open in a different theme than a
  `.swift` one.

### Updates

- Checks for new versions automatically and installs them on request.
