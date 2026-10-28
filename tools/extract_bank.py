"""Extract and strictly validate the supplied Huadian 2026 question bank."""
import argparse
import json
import re
import shutil
from collections import Counter
from pathlib import Path
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "source" / "题库原文.pdf"


def join_lines(lines):
    text = ""
    for line in lines:
        line = line.strip()
        if text and re.search(r"[A-Za-z0-9]$", text) and re.match(r"[A-Za-z0-9]", line):
            text += " "
        text += line
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    source = parser.parse_args().source.resolve()
    reader = PdfReader(source)
    lines = []
    for index in range(39, len(reader.pages)):
        page_lines = reader.pages[index].extract_text().splitlines()
        page_lines = [s.strip() for s in page_lines if s.strip()]
        assert page_lines[-1] == str(index), (index + 1, page_lines[-1])
        lines.extend((s, index + 1) for s in page_lines[:-1])
    audit = ROOT / "tools" / "extraction"
    audit.mkdir(parents=True, exist_ok=True)
    (audit / "source-text.txt").write_text("\n".join(f"[PDF {p}] {s}" for s, p in lines), encoding="utf-8")
    types = {"一、单选题": "single", "二、多选题": "multiple", "三、判断题": "judge"}
    questions, current, kind, group, groups = [], None, None, None, []
    subsection = None

    def finish():
        nonlocal current
        if not current:
            return
        assert current.get("answer"), ("missing answer", current)
        assert len(current["options"]) >= 2, current
        current["text"] = join_lines(current.pop("stemLines"))
        for option in current["options"]:
            option["text"] = join_lines(option.pop("lines"))
        keys = [o["key"] for o in current["options"]]
        assert keys == list("ABCDEFGH"[:len(keys)]), ("option sequence", current)
        assert set(current["answer"]).issubset(keys), current
        assert len(current["answer"]) == len(set(current["answer"])), current
        assert len(current["answer"]) == 1 if current["type"] != "multiple" else len(current["answer"]) >= 2, current
        assert not re.search(r"答案\s*[：:]", current["text"]), current
        questions.append(current)
        current = None

    for line, page in lines:
        if line in types:
            finish()
            kind = types[line]
            continue
        match = re.fullmatch(r"(第[一二三四五六七八九十]+部分)\s*(.+)", line)
        if match:
            finish()
            subsection = None
            group = f"{kind}-{len([g for g in groups if g['type'] == kind]) + 1}"
            groups.append({"id": group, "type": kind, "part": match[1], "title": match[2]})
            continue
        if re.fullmatch(r"（\d+）.+", line):
            finish()
            subsection = line
            continue
        match = re.match(r"^(\d+)\s*[.．]\s*(.*)$", line)
        if match:
            finish()
            number = int(match[1])
            current = {"id": str(number), "number": number, "type": kind, "group": group, "subsection": subsection,
                       "stemLines": [match[2]], "options": [], "pdfPage": page, "printedPage": page - 1, "pdfEndPage": page}
            continue
        if current is None:
            assert not kind, ("orphan line", line, page)
            continue
        current["pdfEndPage"] = page
        match = re.fullmatch(r"答案\s*[：:]\s*([A-HＡ-Ｈ、，,\s]+)", line)
        if match:
            assert not current.get("answer"), current
            current["answer"] = sorted(re.findall(r"[A-H]", match[1]))
            continue
        match = re.match(r"^([A-H])\s*[.．]\s*(.*)$", line)
        if match:
            current["options"].append({"key": match[1], "lines": [match[2]]})
        elif current.get("answer"):
            raise ValueError(("line after answer", line, page, current["id"]))
        elif current["options"]:
            current["options"][-1]["lines"].append(line)
        else:
            current["stemLines"].append(line)
    finish()
    assert [q["number"] for q in questions] == list(range(1, 564)), "Question numbering must be continuous 1–563"
    assert len(groups) == 18
    for g in groups:
        g["count"] = sum(q["group"] == g["id"] for q in questions)
    bank = {"id": "huadian-2026-public-industry-v1", "title": "中国华电集团有限公司高校毕业生招聘考试公共与行业知识题库",
            "edition": "2026 版", "total": len(questions), "groups": groups, "questions": questions,
            "source": {"file": "附件2_20260914225451.pdf", "pdfStartPage": 40, "printedStartPage": 39, "pages": len(reader.pages)}}
    (ROOT / "bank.json").write_text(json.dumps(bank, ensure_ascii=False, indent=2), encoding="utf-8")
    (ROOT / "source").mkdir(exist_ok=True)
    destination = ROOT / "source" / "题库原文.pdf"
    if source != destination.resolve():
        shutil.copy2(source, destination)
    report = {"total": len(questions), "byType": dict(Counter(q["type"] for q in questions)), "groups": groups,
              "checks": ["563 道题连续编号，无重复和遗漏", "18 个分组", "全部题目具有题干、连续选项和有效答案", "单选及判断答案为 1 项，多选答案至少 2 项", "PDF 跨页题目合并并保留起止页码"]}
    (audit / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
