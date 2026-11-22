#!/usr/bin/env python3
"""把 DSH 的原始图标做成 iPad App 需要的 1024x1024 AppIcon.png。

默认源图是桌面端那份 1104x1104 的整幅图（比 web 的 512 更清晰）；
它不存在时退回 web 的 icon-512.png。输出会压到白底、去掉 alpha 通道 ——
iOS 的 AppIcon 不接受透明通道，留着 alpha 会被渲染成黑底。
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

DEFAULT_SOURCES = (
    Path(r"D:\DSH\apps\desktop\resources\icon.png"),
    Path(r"D:\DSH\apps\web\public\icon-512.png"),
)
DEFAULT_OUTPUT = Path(
    r"D:\dsh-ipad\App\Assets.xcassets\AppIcon.appiconset\AppIcon.png"
)
TARGET_SIZE = 1024
BACKGROUND = (255, 255, 255)


def pick_source(explicit: Path | None) -> Path:
    if explicit is not None:
        if not explicit.is_file():
            raise SystemExit(f"source not found: {explicit}")
        return explicit
    for candidate in DEFAULT_SOURCES:
        if candidate.is_file():
            return candidate
    raise SystemExit("no default source found: " + ", ".join(str(p) for p in DEFAULT_SOURCES))


def build_icon(source: Path, output: Path) -> Image.Image:
    image = Image.open(source)
    icon = image.convert("RGBA").resize(
        (TARGET_SIZE, TARGET_SIZE), Image.Resampling.LANCZOS
    )
    if icon.size != (TARGET_SIZE, TARGET_SIZE):
        raise SystemExit(f"resize failed: got {icon.size}, want {(TARGET_SIZE, TARGET_SIZE)}")

    flat = Image.new("RGB", icon.size, BACKGROUND)
    flat.paste(icon, (0, 0), icon)

    output.parent.mkdir(parents=True, exist_ok=True)
    flat.save(output, format="PNG")
    return flat


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=None, help="源图路径（默认按内置顺序挑第一张存在的）")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="输出的 AppIcon.png 路径")
    args = parser.parse_args()

    source = pick_source(args.source)
    icon = build_icon(source, args.output)
    print(f"source: {source}")
    print(f"wrote {args.output} ({icon.width}x{icon.height}, {icon.mode}, {args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
