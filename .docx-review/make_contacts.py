from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


def build_contacts(source_dir: Path, prefix: str, pages_per_sheet: int = 9) -> None:
    page_paths = sorted(
        source_dir.glob(f"{prefix}-*.png"),
        key=lambda path: int(path.stem.rsplit("-", 1)[1]),
    )
    thumb_width = 700
    label_height = 42
    columns = 3
    rows = 3
    background = "white"
    font = ImageFont.load_default(size=28)

    for sheet_index in range(0, len(page_paths), pages_per_sheet):
        group = page_paths[sheet_index : sheet_index + pages_per_sheet]
        opened = [Image.open(path).convert("RGB") for path in group]
        thumb_height = int(opened[0].height * thumb_width / opened[0].width)
        canvas = Image.new(
            "RGB",
            (columns * thumb_width, rows * (thumb_height + label_height)),
            background,
        )
        draw = ImageDraw.Draw(canvas)

        for item_index, (path, page) in enumerate(zip(group, opened)):
            x = (item_index % columns) * thumb_width
            y = (item_index // columns) * (thumb_height + label_height)
            page.thumbnail((thumb_width, thumb_height), Image.Resampling.LANCZOS)
            canvas.paste(page, (x, y + label_height))
            page_number = int(path.stem.rsplit("-", 1)[1])
            draw.text((x + 12, y + 6), f"Page {page_number}", fill="black", font=font)

        first_page = int(group[0].stem.rsplit("-", 1)[1])
        last_page = int(group[-1].stem.rsplit("-", 1)[1])
        output = source_dir / f"contact-{first_page:02d}-{last_page:02d}.png"
        canvas.save(output, optimize=True)
        print(output)


if __name__ == "__main__":
    build_contacts(Path(__file__).resolve().parent / "baseline", "page")
