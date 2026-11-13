#!/usr/bin/env python3
"""Gera os ícones PNG do aplicativo a partir de um desenho vetorial simples."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

BASE = 1024
OUTPUT = Path(__file__).resolve().parent.parent / "data" / "icons"
SIZES = [16, 24, 32, 48, 64, 128, 256, 512]

TOP = (255, 77, 94)
BOTTOM = (196, 18, 47)


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def build() -> Image.Image:
    # Gradiente vertical
    gradient = Image.new("RGBA", (BASE, BASE))
    pixels = gradient.load()
    for y in range(BASE):
        ratio = y / (BASE - 1)
        color = tuple(
            int(TOP[index] + (BOTTOM[index] - TOP[index]) * ratio) for index in range(3)
        )
        for x in range(BASE):
            pixels[x, y] = (*color, 255)

    # Brilho suave no topo
    highlight = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    hdraw = ImageDraw.Draw(highlight)
    hdraw.ellipse((-220, -520, BASE + 220, 520), fill=(255, 255, 255, 38))
    gradient = Image.alpha_composite(gradient, highlight)

    # Máscara arredondada
    mask = rounded_mask(BASE, 224)
    icon = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    icon.paste(gradient, (0, 0), mask)

    white = (255, 255, 255, 255)

    # Sombra da seta
    shadow = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    sdraw.polygon(
        [(462, 280), (582, 280), (582, 540), (712, 540), (522, 748), (332, 540), (462, 540)],
        fill=(90, 0, 12, 90),
    )
    sdraw.line(
        [(320, 710), (320, 820), (724, 820), (724, 710)],
        fill=(90, 0, 12, 90),
        width=54,
        joint="curve",
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    icon = Image.alpha_composite(icon, shadow)
    draw = ImageDraw.Draw(icon)

    # Seta para baixo
    draw.polygon(
        [(452, 260), (572, 260), (572, 520), (702, 520), (512, 728), (322, 520), (452, 520)],
        fill=white,
    )

    # Bandeja
    draw.line(
        [(300, 690), (300, 800), (724, 800), (724, 690)],
        fill=white,
        width=52,
        joint="curve",
    )
    for point in [(300, 690), (724, 690)]:
        draw.ellipse(
            (
                point[0] - 26,
                point[1] - 26,
                point[0] + 26,
                point[1] + 26,
            ),
            fill=white,
        )

    return icon


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    icon = build()
    icon.save(OUTPUT / "fastsearchx-1024.png")
    for size in SIZES:
        resized = icon.resize((size, size), Image.LANCZOS)
        resized.save(OUTPUT / f"fastsearchx-{size}.png")
    print(f"Ícones gerados em {OUTPUT}")


if __name__ == "__main__":
    main()
