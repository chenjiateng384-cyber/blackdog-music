from __future__ import annotations

import re
import sys
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor


INK = "202124"
MUTED = "5F6368"
ACCENT = "87394B"
HEADER = "343A40"
TABLE_ALT = "F4F5F6"
CODE_BG = "F3F4F6"
FONT = "Microsoft YaHei"
MONO = "Consolas"


def set_cell_shading(cell, color: str) -> None:
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), color)


def set_cell_margins(cell, top=90, start=110, bottom=90, end=110) -> None:
    tc = cell._tc
    tc_pr = tc.get_or_add_tcPr()
    tc_mar = tc_pr.first_child_found_in("w:tcMar")
    if tc_mar is None:
        tc_mar = OxmlElement("w:tcMar")
        tc_pr.append(tc_mar)
    for name, value in (("top", top), ("start", start), ("bottom", bottom), ("end", end)):
        node = tc_mar.find(qn(f"w:{name}"))
        if node is None:
            node = OxmlElement(f"w:{name}")
            tc_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def set_repeat_table_header(row) -> None:
    tr_pr = row._tr.get_or_add_trPr()
    tbl_header = OxmlElement("w:tblHeader")
    tbl_header.set(qn("w:val"), "true")
    tr_pr.append(tbl_header)


def set_run_font(run, name=FONT, size=None, bold=None, color=None) -> None:
    run.font.name = name
    run._element.rPr.rFonts.set(qn("w:eastAsia"), name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color is not None:
        run.font.color.rgb = RGBColor.from_string(color)


INLINE_RE = re.compile(r"(`[^`]+`|\*\*[^*]+\*\*)")


def add_inline(paragraph, text: str, *, base_size=10.5, color=INK) -> None:
    for part in INLINE_RE.split(text):
        if not part:
            continue
        if part.startswith("`") and part.endswith("`"):
            run = paragraph.add_run(part[1:-1])
            set_run_font(run, MONO, 9.5, color=ACCENT)
        elif part.startswith("**") and part.endswith("**"):
            run = paragraph.add_run(part[2:-2])
            set_run_font(run, FONT, base_size, bold=True, color=color)
        else:
            run = paragraph.add_run(part)
            set_run_font(run, FONT, base_size, color=color)


def add_page_number(paragraph) -> None:
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = paragraph.add_run()
    fld_char1 = OxmlElement("w:fldChar")
    fld_char1.set(qn("w:fldCharType"), "begin")
    instr_text = OxmlElement("w:instrText")
    instr_text.set(qn("xml:space"), "preserve")
    instr_text.text = " PAGE "
    fld_char2 = OxmlElement("w:fldChar")
    fld_char2.set(qn("w:fldCharType"), "end")
    run._r.extend((fld_char1, instr_text, fld_char2))
    set_run_font(run, FONT, 8.5, color=MUTED)


def configure_document(doc: Document) -> None:
    section = doc.sections[0]
    section.page_width = Inches(8.5)
    section.page_height = Inches(11)
    section.top_margin = Inches(0.72)
    section.bottom_margin = Inches(0.68)
    section.left_margin = Inches(0.78)
    section.right_margin = Inches(0.78)
    section.header_distance = Inches(0.3)
    section.footer_distance = Inches(0.3)

    normal = doc.styles["Normal"]
    normal.font.name = FONT
    normal._element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
    normal.font.size = Pt(10.5)
    normal.font.color.rgb = RGBColor.from_string(INK)
    normal.paragraph_format.space_after = Pt(5)
    normal.paragraph_format.line_spacing = 1.35

    specs = {
        "Title": (27, INK, 18, 10),
        "Heading 1": (18, INK, 18, 8),
        "Heading 2": (14, ACCENT, 14, 6),
        "Heading 3": (11.5, INK, 10, 4),
        "Heading 4": (10.5, MUTED, 8, 3),
    }
    for name, (size, color, before, after) in specs.items():
        style = doc.styles[name]
        style.font.name = FONT
        style._element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
        style.font.size = Pt(size)
        style.font.bold = True
        style.font.color.rgb = RGBColor.from_string(color)
        style.paragraph_format.space_before = Pt(before)
        style.paragraph_format.space_after = Pt(after)
        style.paragraph_format.keep_with_next = True

    if "Code Block" not in [s.name for s in doc.styles]:
        code = doc.styles.add_style("Code Block", WD_STYLE_TYPE.PARAGRAPH)
    else:
        code = doc.styles["Code Block"]
    code.font.name = MONO
    code._element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
    code.font.size = Pt(8.5)
    code.font.color.rgb = RGBColor.from_string(INK)
    code.paragraph_format.left_indent = Inches(0.18)
    code.paragraph_format.right_indent = Inches(0.12)
    code.paragraph_format.space_before = Pt(4)
    code.paragraph_format.space_after = Pt(7)
    code.paragraph_format.line_spacing = 1.12

    header = section.header.paragraphs[0]
    header.text = "黑狗音乐 · 项目与使用说明书"
    header.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    set_run_font(header.runs[0], FONT, 8, color=MUTED)
    add_page_number(section.footer.paragraphs[0])


def add_cover(doc: Document, lines: list[str]) -> int:
    title = lines[0][2:].strip()
    # WPS may add a blue rule to Word's built-in Title style. Use a normal
    # paragraph so the cover remains neutral in both Word and WPS.
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.LEFT
    p.paragraph_format.space_before = Pt(82)
    run = p.add_run(title)
    set_run_font(run, FONT, 27, bold=True, color=INK)

    subtitle = doc.add_paragraph()
    subtitle.paragraph_format.space_before = Pt(10)
    subtitle.paragraph_format.space_after = Pt(26)
    add_inline(subtitle, "从电脑源码、APK 到一加13上的日常使用", base_size=14, color=ACCENT)

    idx = 1
    while idx < len(lines) and idx < 8:
        text = lines[idx].strip()
        if text.startswith("版本：") or text.startswith("更新日期："):
            p = doc.add_paragraph()
            p.paragraph_format.space_after = Pt(2)
            add_inline(p, text.replace("  ", ""), base_size=10.5, color=MUTED)
        elif text.startswith("适合读者："):
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(18)
            p.paragraph_format.space_after = Pt(6)
            add_inline(p, text, base_size=11, color=INK)
        idx += 1

    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(74)
    add_inline(
        p,
        "这不是一份只给程序员看的技术文档，而是一份帮助项目拥有者理解、使用、维护和保护黑狗音乐的说明书。",
        base_size=12,
        color=INK,
    )
    p.paragraph_format.line_spacing = 1.55
    doc.add_page_break()
    return idx


def add_table(doc: Document, rows: list[list[str]]) -> None:
    if not rows:
        return
    width = max(len(row) for row in rows)
    table = doc.add_table(rows=len(rows), cols=width)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.style = "Table Grid"
    table.autofit = True
    for r_idx, row in enumerate(rows):
        for c_idx in range(width):
            cell = table.cell(r_idx, c_idx)
            cell.text = ""
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            set_cell_margins(cell)
            p = cell.paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.15
            value = row[c_idx].strip() if c_idx < len(row) else ""
            add_inline(
                p,
                value,
                base_size=8.5 if r_idx else 8.8,
                color="FFFFFF" if r_idx == 0 else INK,
            )
            if r_idx == 0:
                set_cell_shading(cell, HEADER)
                for run in p.runs:
                    run.bold = True
            elif r_idx % 2 == 0:
                set_cell_shading(cell, TABLE_ALT)
    set_repeat_table_header(table.rows[0])
    doc.add_paragraph().paragraph_format.space_after = Pt(1)


def build(source: Path, output: Path) -> None:
    lines = source.read_text(encoding="utf-8").splitlines()
    doc = Document()
    configure_document(doc)
    idx = add_cover(doc, lines)
    in_code = False
    code_lines: list[str] = []

    while idx < len(lines):
        raw = lines[idx]
        stripped = raw.strip()

        if stripped.startswith("```"):
            if in_code:
                p = doc.add_paragraph(style="Code Block")
                p.paragraph_format.keep_together = True
                p_pr = p._p.get_or_add_pPr()
                shd = OxmlElement("w:shd")
                shd.set(qn("w:fill"), CODE_BG)
                p_pr.append(shd)
                for line_index, line in enumerate(code_lines):
                    if line_index:
                        p.add_run().add_break()
                    run = p.add_run(line)
                    set_run_font(run, MONO, 8.5, color=INK)
                code_lines.clear()
                in_code = False
            else:
                in_code = True
            idx += 1
            continue
        if in_code:
            code_lines.append(raw)
            idx += 1
            continue

        if stripped.startswith("|"):
            table_rows: list[list[str]] = []
            while idx < len(lines) and lines[idx].strip().startswith("|"):
                row = [part.strip() for part in lines[idx].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{3,}:?", cell) for cell in row):
                    table_rows.append(row)
                idx += 1
            add_table(doc, table_rows)
            continue

        heading = re.match(r"^(#{1,4})\s+(.+)$", stripped)
        if heading:
            level = len(heading.group(1))
            if level == 1:
                idx += 1
                continue
            p = doc.add_paragraph(style=f"Heading {level - 1}")
            add_inline(p, heading.group(2), base_size={2: 18, 3: 14, 4: 11.5}.get(level, 10.5))
            idx += 1
            continue

        bullet = re.match(r"^[-*]\s+(.+)$", stripped)
        numbered = re.match(r"^(\d+)\.\s+(.+)$", stripped)
        if bullet:
            p = doc.add_paragraph(style="List Bullet")
            p.paragraph_format.left_indent = Inches(0.25)
            p.paragraph_format.first_line_indent = Inches(-0.16)
            p.paragraph_format.space_after = Pt(2)
            add_inline(p, bullet.group(1))
        elif numbered:
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Inches(0.28)
            p.paragraph_format.first_line_indent = Inches(-0.18)
            p.paragraph_format.space_after = Pt(2)
            prefix = p.add_run(f"{numbered.group(1)}. ")
            set_run_font(prefix, FONT, 10.5, color=INK)
            add_inline(p, numbered.group(2))
        elif stripped:
            p = doc.add_paragraph()
            add_inline(p, stripped)
        idx += 1

    output.parent.mkdir(parents=True, exist_ok=True)
    doc.save(output)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: build_manual_docx.py SOURCE.md OUTPUT.docx")
    build(Path(sys.argv[1]), Path(sys.argv[2]))
