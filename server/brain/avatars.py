"""联系人头像：裁中间正方形、缩到 512、存 JPEG（iOS 第二块）。文件在 files_dir/avatars/<联系人>.jpg。"""
from __future__ import annotations

import io
from pathlib import Path
from uuid import UUID

from PIL import Image, UnidentifiedImageError

SIDE = 512
MAX_BYTES = 10 * 1024 * 1024


class AvatarError(ValueError):
    pass


def path(files_dir: Path, companion: UUID) -> Path:
    return files_dir / "avatars" / f"{companion}.jpg"


def save(files_dir: Path, companion: UUID, data: bytes) -> None:
    if len(data) > MAX_BYTES:
        raise AvatarError("图片太大了（最多 10MB）")
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except (UnidentifiedImageError, OSError) as e:
        raise AvatarError("这不是一张能读的图片") from e
    img = img.convert("RGB")
    w, h = img.size
    s = min(w, h)
    img = img.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s)).resize((SIDE, SIDE), Image.LANCZOS)
    p = path(files_dir, companion)
    p.parent.mkdir(parents=True, exist_ok=True)
    img.save(p, "JPEG", quality=88)


def remove(files_dir: Path, companion: UUID) -> None:
    path(files_dir, companion).unlink(missing_ok=True)
