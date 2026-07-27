from __future__ import annotations

import argparse
import importlib.util
import json
import zipfile
from pathlib import Path

from lxml import etree


HELPER_PATH = Path(__file__).parent / ".codex-doc-work" / "extract_docx.py"
SPEC = importlib.util.spec_from_file_location("docx_extract_helper", HELPER_PATH)
HELPER = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(HELPER)


def extract(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        styles = HELPER.style_map(archive)
        document = HELPER.read_xml(archive, "word/document.xml")
        core = HELPER.read_xml(archive, "docProps/core.xml")
        app = HELPER.read_xml(archive, "docProps/app.xml")
        parts = {"document": HELPER.blocks_from_part(document, styles)}

        for name in sorted(archive.namelist()):
            if (
                name.startswith("word/header")
                or name.startswith("word/footer")
                or name in {"word/footnotes.xml", "word/endnotes.xml"}
            ) and name.endswith(".xml"):
                parts[name] = HELPER.blocks_from_part(
                    HELPER.read_xml(archive, name), styles
                )

        word_roots = [
            HELPER.read_xml(archive, name)
            for name in archive.namelist()
            if name.startswith("word/") and name.endswith(".xml")
        ]
        comments = HELPER.read_xml(archive, "word/comments.xml")
        return {
            "path": str(path),
            "size": path.stat().st_size,
            "metadata": {
                "title": HELPER.first_text(core, "string(cp:coreProperties/dc:title)"),
                "subject": HELPER.first_text(
                    core, "string(cp:coreProperties/dc:subject)"
                ),
                "creator": HELPER.first_text(
                    core, "string(cp:coreProperties/dc:creator)"
                ),
                "modified_by": HELPER.first_text(
                    core, "string(cp:coreProperties/cp:lastModifiedBy)"
                ),
                "created": HELPER.first_text(
                    core, "string(cp:coreProperties/dcterms:created)"
                ),
                "modified": HELPER.first_text(
                    core, "string(cp:coreProperties/dcterms:modified)"
                ),
                "pages": HELPER.first_text(app, "string(ep:Properties/ep:Pages)"),
                "words": HELPER.first_text(app, "string(ep:Properties/ep:Words)"),
            },
            "counts": {
                "paragraphs": len(
                    document.xpath(".//w:p", namespaces=HELPER.NS)
                )
                if document is not None
                else 0,
                "tables": len(document.xpath(".//w:tbl", namespaces=HELPER.NS))
                if document is not None
                else 0,
                "sections": len(
                    document.xpath(".//w:sectPr", namespaces=HELPER.NS)
                )
                if document is not None
                else 0,
                "tracked_insertions": sum(
                    len(root.xpath(".//w:ins", namespaces=HELPER.NS))
                    for root in word_roots
                    if root is not None
                ),
                "tracked_deletions": sum(
                    len(root.xpath(".//w:del", namespaces=HELPER.NS))
                    for root in word_roots
                    if root is not None
                ),
                "comments": len(
                    comments.xpath(".//w:comment", namespaces=HELPER.NS)
                )
                if comments is not None
                else 0,
                "images": sum(
                    1
                    for name in archive.namelist()
                    if name.startswith("word/media/") and not name.endswith("/")
                ),
            },
            "parts": parts,
        }


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
            HELPER.as_markdown(data), encoding="utf-8"
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
