# Third-party notices · 第三方声明

This image bundles third-party software under their own licenses. Most are MIT / BSD / Apache-2.0; their license
files ship inside each package (`/usr/local/lib/python3.12/site-packages/*.dist-info/licenses/`).
本镜像带着的第三方软件各按各的许可；大多是 MIT / BSD / Apache-2.0，许可原文在各自包的 `*.dist-info/licenses/` 里。

## LGPL components · LGPL 组件

These are used unmodified, as separate libraries / programs. You may replace them with your own builds.
下面几样原样使用、没有改过，是独立的库或程序，你可以换成自己编译的版本。

| Component | License | Source |
|---|---|---|
| python-soxr (with libsoxr, PFFFT), pulled in by librosa for resampling | LGPL-2.1-or-later (libsoxr); BSD-style (python-soxr wrapper, PFFFT) | https://github.com/dofuuz/python-soxr · https://sourceforge.net/projects/soxr/ — license texts in `soxr-*.dist-info/licenses/` |
| ffmpeg (Debian package, run as an external command) | LGPL-2.1-or-later / GPL-2.0-or-later | `apt-get source ffmpeg` (the Debian release of the `python:3.12-slim` base) · https://ffmpeg.org — copyright in `/usr/share/doc/ffmpeg/copyright` |

## Data · 数据

- Nutrition data © Open Food Facts contributors, Open Database License (ODbL) — https://world.openfoodfacts.org
- Embedding model BAAI/bge-m3 (MIT), downloaded at first start from Hugging Face.
