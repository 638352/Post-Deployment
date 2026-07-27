from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path

from lxml import etree


NS = {
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
    "dc": "http://purl.org/dc/elements/1.1/",
    "dcterms": "http://purl.org/dc/terms/",
    "ep": "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties",
}
W = f"{{{NS['w']}}}"


def read_xml(archive: zipfile.ZipFile, name: str):
    try:
        return etree.fromstring(archive.read(name))
    except KeyError:
        return None


def style_map(archive: zipfile.ZipFile) -> dict[str, str]:
    root = read_xml(archive, "word/styles.xml")
    if root is None:
        return {}
    result: dict[str, str] = {}
    for style in root.xpath(".//w:style", namespaces=NS):
        style_id = style.get(f"{W}styleId", "")
        name = style.find("w:name", NS)
        result[style_id] = name.get(f"{W}val", style_id) if name is not None else style_id
    return result


def paragraph_text(paragraph) -> str:
    parts: list[str] = []
    for node in paragraph.iter():
        local = etree.QName(node).localname
        if local in {"t", "delText", "instrText"} and node.text:
            parts.append(node.text)
        elif local == "tab":
            parts.append("\t")
        elif local in {"br", "cr"}:
            parts.append("\n")
    return "".join(parts).strip()


def paragraph_record(paragraph, styles: dict[str, str]) -> dict[str, str]:
    style_nodes = paragraph.xpath("./w:pPr/w:pStyle", namespaces=NS)
    style_id = style_nodes[0].get(f"{W}val", "") if style_nodes else ""
    return {
        "type": "paragraph",
        "style_id": style_id,
        "style": styles.get(style_id, style_id or "Normal"),
        "text": paragraph_text(paragraph),
    }


def table_record(table, styles: dict[str, str]) -> dict:
    rows: list[list[str]] = []
    for row in table.xpath("./w:tr", namespaces=NS):
        cells: list[str] = []
        for cell in row.xpath("./w:tc", namespaces=NS):
            paragraphs = []
            for p in cell.xpath(".//w:p", namespaces=NS):
                text = paragraph_text(p)
                if text:
                    paragraphs.append(text)
            cells.append(" | ".join(paragraphs))
        rows.append(cells)
    return {"type": "table", "rows": rows}


def blocks_from_part(root, styles: dict[str, str]) -> list[dict]:
    if root is None:
        return []
    body_nodes = root.xpath("./w:body", namespaces=NS)
    container = body_nodes[0] if body_nodes else root
    blocks: list[dict] = []
    for child in container:
        local = etree.QName(child).localname
        if local == "p":
            record = paragraph_record(child, styles)
            if record["text"]:
                blocks.append(record)
        elif local == "tbl":
            blocks.append(table_record(child, styles))
        elif local == "sdt":
            for nested in child.xpath(".//w:p | .//w:tbl", namespaces=NS):
                if etree.QName(nested).localname == "p":
                    record = paragraph_record(nested, styles)
                    if record["text"]:
                        blocks.append(record)
                else:
                    blocks.append(table_record(nested, styles))
    return blocks


def first_text(root, xpath: str) -> str:
    if root is None:
        return ""
    values = root.xpath(xpath, namespaces=NS)
    if not values:
        return ""
    value = values[0]
    return value if isinstance(value, str) else (value.text or "")


def extract(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        styles = style_map(archive)
        document = read_xml(archive, "word/document.xml")
        core = read_xml(archive, "docProps/core.xml")
        app = read_xml(archive, "docProps/app.xml")

        parts = {"document": blocks_from_part(document, styles)}
        for name in sorted(archive.namelist()):
            if (
                name.startswith("word/header")
                or name.startswith("word/footer")
                or name in {"word/footnotes.xml", "word/endnotes.xml"}
            ) and name.endswith(".xml"):
                parts[name] = blocks_from_part(read_xml(archive, name), styles)

        all_xml = b"\n".join(
            archive.read(name)
            for name in archive.namelist()
            if name.startswith("word/") and name.endswith(".xml")
        )
        all_root = etree.fromstring(b"<root>" + all_xml.replace(b"<?xml version='1.0' encoding='UTF-8' standalone='yes'?>", b"").replace(b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>', b"") + b"</root>")

        return {
            "path": str(path),
            "size": path.stat().st_size,
            "metadata": {
                "title": first_text(core, "string(cp:coreProperties/dc:title)"),
                "subject": first_text(core, "string(cp:coreProperties/dc:subject)"),
                "creator": first_text(core, "string(cp:coreProperties/dc:creator)"),
                "modified_by": first_text(core, "string(cp:coreProperties/cp:lastModifiedBy)"),
                "created": first_text(core, "string(cp:coreProperties/dcterms:created)"),
                "modified": first_text(core, "string(cp:coreProperties/dcterms:modified)"),
                "pages": first_text(app, "string(ep:Properties/ep:Pages)"),
                "words": first_text(app, "string(ep:Properties/ep:Words)"),
            },
            "counts": {
                "paragraphs": len(document.xpath(".//w:p", namespaces=NS)) if document is not None else 0,
                "tables": len(document.xpath(".//w:tbl", namespaces=NS)) if document is not None else 0,
                "sections": len(document.xpath(".//w:sectPr", namespaces=NS)) if document is not None else 0,
                "tracked_insertions": len(all_root.xpath(".//w:ins", namespaces=NS)),
                "tracked_deletions": len(all_root.xpath(".//w:del", namespaces=NS)),
                "comments": len(read_xml(archive, "word/comments.xml").xpath(".//w:comment", namespaces=NS))
                if "word/comments.xml" in archive.namelist()
                else 0,
                "images": len(
                    [
                        name
                        for name in archive.namelist()
                        if name.startswith("word/media/") and not name.endswith("/")
                    ]
                ),
            },
            "parts": parts,
        }


def as_markdown(data: dict) -> str:
    lines = [
        f"# {Path(data['path']).name}",
        "",
        "## Document facts",
        "",
        f"- Path: {data['path']}",
        f"- Metadata: {json.dumps(data['metadata'], ensure_ascii=False)}",
        f"- Counts: {json.dumps(data['counts'], ensure_ascii=False)}",
        "",
    ]
    for part, blocks in data["parts"].items():
        lines.extend([f"## Part: {part}", ""])
        for index, block in enumerate(blocks, 1):
            if block["type"] == "paragraph":
                lines.append(
                    f"P{index:03d} [{block['style'] or 'Normal'}]: {block['text']}"
                )
            else:
                lines.append(f"TABLE {index:03d}:")
                for row in block["rows"]:
                    lines.append(" | ".join(row))
            lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for input_path in args.inputs:
        data = extract(input_path)
        stem = input_path.stem.replace(" ", "_")
        (args.output_dir / f"{stem}.json").write_text(
            json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        (args.output_dir / f"{stem}.md").write_text(
            as_markdown(data), encoding="utf-8"
        )
        print(
            json.dumps(
                {
                    "input": str(input_path),
                    "output_stem": stem,
                    "counts": data["counts"],
                    "metadata": data["metadata"],
                },
                ensure_ascii=False,
            )
        )


if __name__ == "__main__":
    main()
