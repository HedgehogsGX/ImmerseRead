# ImmersiveReader

A local-first ebook reader for iPhone and iPad.

Documents are imported through the system file picker and copied into the app's
sandbox. Reading, conversion and text extraction all happen on the device —
nothing is uploaded, and the original file is never modified.

## Formats

| Format | What you get |
| --- | --- |
| EPUB | Reflowable, DRM-free books, via Readium |
| PDF | The existing text layer, reflowed at any font size and keeping emphasis colours; the original page layout is one tap away |
| TXT / Markdown | UTF-8, and UTF-16 with a BOM; common Markdown blocks and inline formatting |
| DOCX | Converted on device with a bundled copy of Mammoth, then sanitised into reflowable text |
| DOC (legacy) | Quick Look preview only |

Not in scope: OCR for scanned pages, accounts, cloud sync, AI, annotations, DRM.

## Library

Covers are read from the files themselves — an EPUB's declared cover, a PDF's
first page, a DOCX's thumbnail or first picture. When a file has none, the shelf
draws a lettering cover from the title. Any cover can be replaced with a picture
from Photos or Files, re-detected, or removed, and the title, author and palette
can be edited.

The shelf supports search, sorting, a cover grid or a list, and keeps the book
you are part-way through at the top.

## Reading

Pages turn or scroll, at 14–40 pt, with adjustable line height and margins and a
light, sepia or dark theme. The bottom bar carries the two choices you make while
reading — page turning and font size — and everything else lives in the reading
settings sheet.

Reading positions are stored per book as a position in the text, not as a scroll
offset, so changing the font size reopens the book where you left off. PDFs keep
separate positions for reflowed text and original pages.

## Limits

Import caps: 32 MiB for TXT, Markdown and DOCX, 128 MiB for legacy DOC, 256 MiB
for PDF, 512 MiB for EPUB. EPUB and DOCX archives are checked for unsafe paths,
symlinks and decompression bombs before they are opened.

PDF text extraction handles up to 5,000 pages and 500,000 paragraphs. A long
document takes a while the first time; the result is cached beside the book, so
reopening is immediate. Anything past those limits can still be read as original
pages.

## Building

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

Open `ImmersiveReader.xcodeproj` and build the `ImmersiveReader` scheme.
Dependencies are pinned through Swift Package Manager: Readium 3.11.0,
SwiftSoup 2.13.9, Readium ZIPFoundation 3.0.1. The bundled Mammoth build and its
licence are in `ImmersiveReader/Resources/Vendor/Mammoth/`.

Requires iOS 17 or later.
