#!/usr/bin/env python3
"""Add one release to appcast.xml — the feed Sparkle reads to find updates.

Sparkle ships a `generate_appcast` tool that scans a folder of builds and writes
the whole feed from scratch. That needs every past .dmg on disk, which a CI job
starting from an empty checkout doesn't have. This instead treats the existing
appcast as the record it already is: read it, put the new release at the top,
write it back. Old entries survive untouched because they're never regenerated,
and the workflow only has to hold the one build it just made.

Re-running for a version already in the feed replaces that entry rather than
adding a second one, so a re-run of a failed release job is harmless.

Usage:
    update_appcast.py --appcast appcast.xml \\
        --short-version 1.0.1 --build 42 \\
        --url https://github.com/.../betterTextEdit-1.0.1.dmg \\
        --length 8123456 --signature <ed25519-sig> \\
        --min-system 26.0 --notes CHANGELOG.md
"""

from __future__ import annotations

import argparse
import html
import os
import re
import sys
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>betterTextEdit</title>
    <link>https://realandi.github.io/betterTextEdit/appcast.xml</link>
    <description>Updates for betterTextEdit.</description>
    <language>en</language>
  </channel>
</rss>
"""


# --- Release notes ------------------------------------------------------------

def extract_section(changelog: str, version: str) -> str:
    """Pull one version's section out of a Keep-a-Changelog style file.

    Matches a heading containing the version number, and takes everything up to
    the next heading of the same level. A version with no section yields an
    empty string, which is not an error — a release simply goes out without
    notes rather than failing the build over prose.
    """
    pattern = re.compile(
        rf"^(#{{1,3}})\s*\[?v?{re.escape(version)}\]?.*?$", re.MULTILINE
    )
    match = pattern.search(changelog)
    if not match:
        return ""

    level = len(match.group(1))
    rest = changelog[match.end():]
    following = re.search(rf"^#{{1,{level}}}\s", rest, re.MULTILINE)
    return (rest[: following.start()] if following else rest).strip()


def markdown_to_html(text: str) -> str:
    """Convert the small slice of Markdown a changelog actually uses.

    Deliberately not a full Markdown implementation. Sparkle renders this in a
    web view, and a changelog is headings, bullets, links and the odd bit of
    emphasis — so that is exactly what's supported, and anything else passes
    through as escaped text rather than being silently mangled.
    """
    out: list[str] = []
    paragraph: list[str] = []
    items: list[list[str]] = []

    def inline(s: str) -> str:
        s = html.escape(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<![*\w])\*([^*]+)\*(?!\w)", r"<em>\1</em>", s)
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
        return s

    # Blocks are buffered line by line and only emitted once something ends
    # them, because a wrapped line is a continuation of the block above it, not
    # a block of its own. Emitting per line would turn the second half of every
    # wrapped bullet into a stray paragraph sitting outside the list.
    def flush_paragraph() -> None:
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def flush_list() -> None:
        if items:
            out.append("<ul>")
            out.extend(f"<li>{inline(' '.join(item))}</li>" for item in items)
            out.append("</ul>")
            items.clear()

    for line in text.splitlines():
        stripped = line.strip()

        if not stripped:
            flush_paragraph()
            flush_list()
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush_paragraph()
            flush_list()
            # Shifted down two levels: an <h1> inside Sparkle's small update
            # window is comically large, and these are subheadings of the
            # release title Sparkle already shows above them.
            level = min(len(heading.group(1)) + 2, 6)
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            continue

        bullet = re.match(r"^[-*+]\s+(.*)$", stripped)
        if bullet:
            flush_paragraph()
            items.append([bullet.group(1)])
            continue

        # An indented line under a bullet belongs to that bullet.
        if items and line[:1].isspace():
            items[-1].append(stripped)
            continue

        flush_list()
        paragraph.append(stripped)

    flush_paragraph()
    flush_list()
    return "\n".join(out)


# --- The feed -----------------------------------------------------------------

def load_channel(path: str) -> tuple[ET.ElementTree, ET.Element]:
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, encoding="utf-8") as handle:
            existing = handle.read()
        # A valid appcast has no DOCTYPE, and ElementTree will happily expand
        # nested entities until it runs out of memory. Refusing the declaration
        # outright is cheaper than a defusedxml dependency on the runner, and
        # says plainly that this file is a record we wrote, not input we parse.
        if re.search(r"<!DOCTYPE", existing, re.IGNORECASE):
            raise SystemExit(f"error: {path} contains a DOCTYPE; refusing to parse")
        tree = ET.ElementTree(ET.fromstring(existing))
    else:
        tree = ET.ElementTree(ET.fromstring(EMPTY_FEED))

    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit(f"error: {path} has no <channel>")
    return tree, channel


def drop_existing(channel: ET.Element, build: str) -> None:
    for item in channel.findall("item"):
        version = item.find(sparkle("version"))
        if version is not None and (version.text or "").strip() == build:
            channel.remove(item)


def build_item(args: argparse.Namespace, notes_html: str) -> ET.Element:
    item = ET.Element("item")

    ET.SubElement(item, "title").text = args.short_version
    ET.SubElement(item, "pubDate").text = format_datetime(
        datetime.now(timezone.utc)
    )
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.short_version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.min_system

    if notes_html:
        # ElementTree escapes this on write; the XML parser at the other end
        # unescapes it again, so Sparkle's web view receives real HTML.
        ET.SubElement(item, "description").text = notes_html

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", str(args.length))
    enclosure.set("type", "application/octet-stream")
    # The signature is the point of the whole exercise: Sparkle checks it
    # against SUPublicEDKey in the app's Info.plist and refuses anything that
    # doesn't match, so a swapped download can't install itself.
    enclosure.set(sparkle("edSignature"), args.signature)

    return item


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--min-system", default="26.0")
    parser.add_argument("--notes", help="path to CHANGELOG.md")
    args = parser.parse_args()

    notes_html = ""
    if args.notes and os.path.exists(args.notes):
        with open(args.notes, encoding="utf-8") as handle:
            section = extract_section(handle.read(), args.short_version)
        notes_html = markdown_to_html(section)
        if not section:
            print(
                f"note: no changelog section for {args.short_version}; "
                "publishing without release notes",
                file=sys.stderr,
            )

    tree, channel = load_channel(args.appcast)
    drop_existing(channel, args.build)

    # Newest first, which is the order Sparkle and anyone reading the file
    # both expect.
    first_item = next(iter(channel.findall("item")), None)
    index = list(channel).index(first_item) if first_item is not None else len(channel)
    channel.insert(index, build_item(args, notes_html))

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"wrote {args.appcast}: {args.short_version} (build {args.build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
