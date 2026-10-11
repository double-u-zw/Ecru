#!/usr/bin/env python3
"""Create a synthetic, non-sensitive PDF fixture. Refuses to overwrite the original."""
from __future__ import annotations

import argparse
from io import BytesIO
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from pypdf import PdfReader, PdfWriter
from pypdf.annotations import Highlight, Text
from pypdf.generic import (ArrayObject, DictionaryObject, FloatObject, NameObject,
                          NumberObject, RectangleObject, TextStringObject,
                          DecodedStreamObject)

PAPER = '#FBFAF5'
GREEN = '#315745'
INK = '#253C30'
MUTED = '#6B7A6D'
RULE = '#DCE4D9'
FONT_PATH = str(Path(__file__).resolve().parents[1] / 'Resources/Preview/vendor/katex/fonts/KaTeX_Main-Regular.ttf')


def draw_page(c, w, h, index, title, description, chinese, instruction):
    c.setFillColor(HexColor(PAPER))
    c.rect(0, 0, w, h, stroke=0, fill=1)
    c.setFillColor(HexColor(GREEN))
    c.setFont('Helvetica-Bold', 11)
    c.drawString(40, h - 42, 'ECRU  /  READER TEST')
    c.setFont('Helvetica', 9)
    c.drawRightString(w - 40, h - 42, f'{index:02d} / 04')
    c.setFont('Helvetica-Bold', 22)
    c.drawString(40, h - 85, title)
    c.setFillColor(HexColor(INK))
    c.setFont('Helvetica', 11)
    c.drawString(40, h - 110, description)
    c.setFont('Helvetica', 11)
    c.drawString(40, h - 132, chinese)
    c.setFillColor(HexColor(MUTED))
    c.setFont('Helvetica', 10)
    c.drawString(40, h - 159, instruction)
    c.setStrokeColor(HexColor(RULE))
    c.line(40, h - 176, w - 40, h - 176)
    c.setFillColor(HexColor(MUTED))
    c.setFont('Helvetica', 9)
    c.drawString(40, h - 197, 'HANDWRITING AREA  /  Page coordinates should remain stable after zoom and reopen.')
    c.setStrokeColor(HexColor(RULE))
    for y in range(105, int(h - 219), 34):
        c.line(40, y, w - 40, y)
    c.setFillColor(HexColor(MUTED))
    c.setFont('Helvetica', 8)
    c.drawString(40, 31, 'Synthetic test fixture. No personal or copyrighted source material.')


def annotation_appearance(writer, annotation, width, height, drawing):
    stream = DecodedStreamObject()
    stream.set_data(drawing.encode('ascii'))
    stream.update({NameObject('/Type'): NameObject('/XObject'),
                   NameObject('/Subtype'): NameObject('/Form'),
                   NameObject('/BBox'): ArrayObject([NumberObject(0), NumberObject(0),
                                                     FloatObject(width), FloatObject(height)]),
                   NameObject('/Resources'): DictionaryObject()})
    annotation[NameObject('/AP')] = DictionaryObject({NameObject('/N'): writer._add_object(stream)})


def make_fixture(output):
    if output.exists():
        raise SystemExit(f'Refusing to overwrite immutable fixture: {output}')
    buffer = BytesIO()
    c = canvas.Canvas(buffer, pagesize=(612, 792), pageCompression=1)
    c.setTitle('Ecru Reader Test - Synthetic Original')
    c.setAuthor('Ecru test fixtures')
    c.bookmarkPage('normal')
    draw_page(c, 612, 792, 1, 'Read, select, and annotate',
              'Search phrase: Ecru selectable text. Read before entering annotation mode.',
              'Selectable text: read, select, highlight, save and reopen.',
              'Draw a thin pen stroke, a translucent marker stroke, then undo / redo.')
    c.setFont('Helvetica', 10)
    c.setFillColor(HexColor(GREEN))
    c.drawString(40, 68, 'Internal link: open the mixed-size page')
    c.linkRect('', 'mixed', (40, 63, 260, 81), relative=0, thickness=0)
    c.drawString(333, 68, 'External link: example.com')
    c.linkURL('https://example.com', (331, 63, 480, 81), relative=0, thickness=0)
    c.showPage()

    c.setPageSize((612, 792))
    c.saveState()
    c.translate(588, 36)
    c.rotate(90)
    draw_page(c, 732, 564, 2, 'Rotated crop geometry',
              'This page already has /Rotate 90 and a nonzero crop-box origin.',
              'Rotated crop: annotations stay aligned after zoom.',
              'Write near two distant corners. Save, reopen, zoom, and check alignment.')
    c.restoreState()
    c.showPage()

    c.setPageSize((500, 680))
    c.bookmarkPage('mixed')
    draw_page(c, 500, 680, 3, 'Mixed-size page',
              'Page size is 500 x 680 points. Search phrase: Ecru mixed size.',
              'Mixed page: preserve outline, text and links.',
              'Use page-fit view, draw in the open area, and return using the outline.')
    c.showPage()

    # A deliberately image-only PDF page with visible text rasterized into one image.
    scan = Image.new('RGB', (1224, 1584), PAPER)
    draw = ImageDraw.Draw(scan)
    regular = ImageFont.truetype(FONT_PATH, 22)
    small = ImageFont.truetype(FONT_PATH, 18)
    large = ImageFont.truetype(FONT_PATH, 44)
    draw.text((80, 60), 'ECRU / READER TEST                                         04 / 04', fill=GREEN, font=small)
    draw.text((80, 134), 'Image-only scanned page', fill=GREEN, font=large)
    draw.text((80, 203), 'This visible text is embedded as pixels, with no PDF text layer.', fill=INK, font=regular)
    draw.text((80, 245), 'Image-only page: write, save and reopen.', fill=INK, font=regular)
    draw.text((80, 300), 'Annotation should work even when selection / search has no text.', fill=MUTED, font=regular)
    draw.line((80, 355, 1144, 355), fill=RULE, width=2)
    draw.text((80, 385), 'HANDWRITING AREA / SCANNED PAGE', fill=MUTED, font=small)
    for y in range(480, 1400, 68):
        draw.line((80, y, 1144, y), fill=RULE, width=2)
    draw.text((80, 1510), 'Synthetic raster scan. No OCR layer.', fill=MUTED, font=small)
    c.setPageSize((612, 792))
    c.drawImage(ImageReader(scan), 0, 0, width=612, height=792)
    c.showPage()
    c.save()

    reader = PdfReader(BytesIO(buffer.getvalue()))
    writer = PdfWriter()
    writer.clone_document_from_reader(reader)
    writer.pages[1].cropbox = RectangleObject([24, 36, 588, 768])
    writer.pages[1].rotate(90)
    writer.add_outline_item('01 Read and annotate', 0)
    writer.add_outline_item('02 Rotated crop geometry', 1)
    writer.add_outline_item('03 Mixed-size page', 2)

    # Pre-existing foreign annotations have appearance streams, so they are visible
    # even in renderers that do not synthesize annotation appearances.
    ink = DictionaryObject({NameObject('/Type'): NameObject('/Annot'),
                            NameObject('/Subtype'): NameObject('/Ink'),
                            NameObject('/Rect'): RectangleObject([65, 427, 261, 486]),
                            NameObject('/InkList'): ArrayObject([ArrayObject([FloatObject(v) for v in
                                [71, 453, 93, 470, 122, 439, 155, 462, 184, 447, 250, 460]])]),
                            NameObject('/C'): ArrayObject([FloatObject(v) for v in [.20, .39, .78]]),
                            NameObject('/BS'): DictionaryObject({NameObject('/W'): FloatObject(3)}),
                            NameObject('/F'): NumberObject(4),
                            NameObject('/NM'): TextStringObject('foreign-ink-001'),
                            NameObject('/T'): TextStringObject('Other PDF editor'),
                            NameObject('/Contents'): TextStringObject('Foreign ink must remain intact.')})
    annotation_appearance(writer, ink, 196, 59, '.20 .39 .78 RG 3 w 1 J 1 j 6 26 m 28 43 l 57 12 l 90 35 l 119 20 l 185 33 l S')
    writer.add_annotation(0, ink)
    highlight = Highlight(rect=(39, 678, 552, 696),
                          quad_points=ArrayObject([FloatObject(v) for v in [39, 696, 552, 696, 39, 678, 552, 678]]),
                          highlight_color='E8DAA6', printing=True)
    highlight.update({NameObject('/NM'): TextStringObject('foreign-highlight-001'),
                      NameObject('/T'): TextStringObject('Other PDF editor'),
                      NameObject('/Contents'): TextStringObject('Foreign text highlight must remain intact.')})
    annotation_appearance(writer, highlight, 513, 18, '.91 .85 .65 rg 0 0 513 18 re f')
    writer.add_annotation(0, highlight)
    note = Text(rect=(552, 608, 574, 630), text='Foreign sticky note. Preserve this annotation.', flags=4)
    note.update({NameObject('/NM'): TextStringObject('foreign-text-001'),
                 NameObject('/T'): TextStringObject('Other PDF editor'),
                 NameObject('/Name'): NameObject('/Comment')})
    annotation_appearance(writer, note, 22, 22, '.94 .80 .25 rg 1 1 20 20 re f .44 .39 .20 RG 1 w 1 1 20 20 re S 5 7 m 17 7 l 5 11 m 17 11 l 5 15 m 17 15 l S')
    writer.add_annotation(0, note)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as stream:
        writer.write(stream)
    summary = {
        'fixture': str(output.resolve()), 'pages': 4,
        'text_layers': ['English', 'English', 'English', 'image-only'],
        'geometry': {'page_2': {'rotate': 90, 'crop_box': [24, 36, 588, 768]},
                     'page_3': {'media_box': [0, 0, 500, 680]}},
        'links': {'internal': 1, 'external': 1}, 'outline_entries': 3,
        'foreign_annotations': ['foreign-ink-001', 'foreign-highlight-001', 'foreign-text-001'],
        'fonts': ['Helvetica', FONT_PATH],
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'output/pdf/reader-test-original.pdf')
    make_fixture(parser.parse_args().output)
