#!/usr/bin/env python3
"""Insert a release into the Sparkle appcast the app polls for updates.

Sparkle ships `generate_appcast`, which builds a feed from a directory holding every
released archive. gitacre publishes its disk images as GitHub release assets, so their
URLs carry a per-release tag and no single download prefix can describe them, and the
archives are not kept around after a release. This writes one entry at a time instead.
"""

import argparse
import sys
import xml.etree.ElementTree as ElementTree
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ElementTree.register_namespace("sparkle", SPARKLE_NAMESPACE)


def sparkle(name):
    return f"{{{SPARKLE_NAMESPACE}}}{name}"


def empty_feed(title):
    rss = ElementTree.Element("rss", {"version": "2.0"})
    channel = ElementTree.SubElement(rss, "channel")
    ElementTree.SubElement(channel, "title").text = title
    return ElementTree.ElementTree(rss)


def load_feed(path, title):
    if not path.exists():
        return empty_feed(title)
    try:
        return ElementTree.parse(path)
    except ElementTree.ParseError as error:
        sys.exit(f"{path} is not valid XML: {error}")


def build_number(item):
    element = item.find(sparkle("version"))
    if element is None:
        enclosure = item.find("enclosure")
        element = enclosure if enclosure is not None else None
        return element.get(sparkle("version"), "") if element is not None else ""
    return element.text or ""


def as_sortable(version):
    """Orders build numbers made of period-separated integers."""
    try:
        return [int(part) for part in version.split(".")]
    except ValueError:
        return [-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", required=True, help="CFBundleVersion; what Sparkle compares")
    parser.add_argument("--short-version", required=True, help="Release label shown to the user")
    parser.add_argument("--url", required=True, help="Download URL for the disk image")
    parser.add_argument("--length", required=True, help="Size of the disk image in bytes")
    parser.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--release-notes-link", default=None)
    parser.add_argument("--title", default="gitacre")
    parser.add_argument("--keep", type=int, default=10, help="How many releases to retain")
    arguments = parser.parse_args()

    tree = load_feed(arguments.appcast, arguments.title)
    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit(f"{arguments.appcast} has no <channel>")

    # Re-running a release must replace its entry rather than duplicate it.
    for existing in channel.findall("item"):
        if build_number(existing) == arguments.version:
            channel.remove(existing)

    newest = max(
        (as_sortable(build_number(item)) for item in channel.findall("item")),
        default=[0],
    )
    if as_sortable(arguments.version) <= newest:
        sys.exit(
            f"Build number {arguments.version} is not greater than the newest already "
            f"published ({'.'.join(str(part) for part in newest)}). Sparkle compares "
            "CFBundleVersion, so it must increase with every release."
        )

    item = ElementTree.Element("item")
    ElementTree.SubElement(item, "title").text = arguments.short_version
    ElementTree.SubElement(item, sparkle("version")).text = arguments.version
    ElementTree.SubElement(item, sparkle("shortVersionString")).text = arguments.short_version
    ElementTree.SubElement(item, sparkle("minimumSystemVersion")).text = arguments.minimum_system_version
    ElementTree.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )
    if arguments.release_notes_link:
        ElementTree.SubElement(item, sparkle("fullReleaseNotesLink")).text = arguments.release_notes_link
    ElementTree.SubElement(
        item,
        "enclosure",
        {
            "url": arguments.url,
            "length": arguments.length,
            "type": "application/octet-stream",
            sparkle("edSignature"): arguments.signature,
        },
    )

    items = channel.findall("item")
    for existing in items:
        channel.remove(existing)
    ordered = sorted(
        [item] + items,
        key=lambda entry: as_sortable(build_number(entry)),
        reverse=True,
    )[: arguments.keep]
    for entry in ordered:
        channel.append(entry)

    ElementTree.indent(tree, space="    ")
    arguments.appcast.parent.mkdir(parents=True, exist_ok=True)
    tree.write(arguments.appcast, encoding="UTF-8", xml_declaration=True)
    # Without this every release shows up as a "no newline at end of file" diff.
    with arguments.appcast.open("a", encoding="utf-8") as feed:
        feed.write("\n")
    print(f"Wrote {arguments.short_version} (build {arguments.version}) to {arguments.appcast}")


if __name__ == "__main__":
    main()
