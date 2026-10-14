"""Импорт локального справочника проекта"""

import argparse
from datetime import datetime
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import tempfile


SENSITIVE_PATTERNS = {
    "private-key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "token-prefix": r"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{15,}|xox[baprs]-[A-Za-z0-9-]{12,})\b",
    "telegram-token": r"\b[0-9]{8,12}:[A-Za-z0-9_-]{25,}\b",
    "password-url": r"https?://[^\s\"<>:]+:[^\s\"<>@]+@",
    "jwt": r"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\b",
}


class ContextHTMLParser(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.source = source
        self.article = False
        self.hidden = 0
        self.snapshot = False
        self.snapshot_parts = []
        self.heading = None
        self.heading_parts = []
        self.heading_anchor = ""
        self.hierarchy = {}
        self.title = ""
        self.current_title = source.name
        self.current_anchor = ""
        self.parts = []
        self.sections = []
        self.pre = False
        self.row_cells = 0
        self.links = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "script" and attributes.get("id") == "atlas-snapshot":
            self.snapshot = True
            return
        if self.snapshot:
            return
        if tag == "article":
            self.article = True
            return
        if not self.article:
            return
        if tag in ("script", "style", "nav"):
            self.hidden += 1
            return
        if self.hidden:
            return
        if tag in ("h1", "h2", "h3", "h4"):
            self.flush()
            self.heading = int(tag[1])
            self.heading_parts = []
            self.heading_anchor = attributes.get("id", "")
        elif tag == "pre":
            self.parts.append("\n```\n")
            self.pre = True
        elif tag == "code" and not self.pre:
            self.parts.append("`")
        elif tag == "tr":
            self.parts.append("\n")
            self.row_cells = 0
        elif tag in ("td", "th"):
            if self.row_cells:
                self.parts.append(" | ")
            self.row_cells += 1
        elif tag == "li":
            self.parts.append("\n- ")
        elif tag in ("p", "div", "blockquote", "br", "hr"):
            self.parts.append("\n")
        elif tag == "a":
            self.links.append(attributes.get("href", ""))

    def handle_endtag(self, tag):
        if tag == "script" and self.snapshot:
            self.snapshot = False
            return
        if not self.article:
            return
        if tag in ("script", "style", "nav") and self.hidden:
            self.hidden -= 1
            return
        if self.hidden:
            return
        if tag == "article":
            self.flush()
            self.article = False
        elif tag in ("h1", "h2", "h3", "h4") and self.heading:
            text = " ".join("".join(self.heading_parts).split())
            level = self.heading
            self.hierarchy = {key: value for key, value in self.hierarchy.items() if key < level}
            self.hierarchy[level] = text
            self.current_title = " / ".join(self.hierarchy[key] for key in sorted(self.hierarchy))
            self.current_anchor = self.heading_anchor
            if not self.title and level == 1:
                self.title = text
            self.heading = None
        elif tag == "pre":
            self.parts.append("\n```\n")
            self.pre = False
        elif tag == "code" and not self.pre:
            self.parts.append("`")
        elif tag in ("p", "li", "div", "blockquote", "tr"):
            self.parts.append("\n")
        elif tag == "a" and self.links:
            target = self.links.pop()
            if target and not target.startswith("#"):
                self.parts.append(" [" + target + "]")

    def handle_data(self, data):
        if self.snapshot:
            self.snapshot_parts.append(data)
        elif self.article and not self.hidden:
            if self.heading:
                self.heading_parts.append(data)
            elif self.pre:
                self.parts.append(data)
            else:
                self.parts.append(re.sub(r"\s+", " ", data))

    def flush(self):
        text = re.sub(r"\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", "".join(self.parts)).strip()
        if text:
            ordinal = len(self.sections) + 1
            anchor = self.current_anchor or "section-" + str(ordinal)
            self.sections.append({"title": self.current_title, "text": text, "source": str(self.source) + "#" + anchor})
        self.parts = []


def reject_credentials(text, source):
    for name, pattern in SENSITIVE_PATTERNS.items():
        if re.search(pattern, text):
            raise ValueError("Потенциальный секрет: " + source.name + " (" + name + ")")


def normalized_date(value):
    for form in ("%d.%m.%Y", "%Y-%m-%d"):
        try:
            return datetime.strptime(value, form).strftime("%Y-%m-%d")
        except ValueError:
            pass
    return value


def remove_duplicate_manifests(value):
    if isinstance(value, dict):
        return {key: remove_duplicate_manifests(item) for key, item in value.items() if key not in ("local_manifest", "origin_manifest")}
    if isinstance(value, list):
        return [remove_duplicate_manifests(item) for item in value]
    return value


def format_facts(value, prefix=""):
    lines = []
    if isinstance(value, dict):
        for key, item in value.items():
            label = prefix + key
            if isinstance(item, (dict, list)):
                lines.append(label + ":")
                lines.extend(format_facts(item, prefix + "  "))
            else:
                lines.append(label + ": " + scalar(item))
    elif isinstance(value, list):
        for index, item in enumerate(value, 1):
            if isinstance(item, (dict, list)):
                lines.append(prefix + "- " + str(index) + ":")
                lines.extend(format_facts(item, prefix + "  "))
            else:
                lines.append(prefix + "- " + scalar(item))
    else:
        lines.append(prefix + scalar(value))
    return lines


def scalar(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def atlas_sections(data, source):
    for key, value in data.items():
        groups = value.items() if key == "server" and isinstance(value, dict) else [(key, value)]
        for group, content in groups:
            records = content if isinstance(content, list) else [content]
            for index, record in enumerate(records, 1):
                if isinstance(record, dict):
                    name = str(record.get("title") or record.get("name") or record.get("id") or record.get("path") or record.get("repository") or index)
                else:
                    name = str(index)
                title = "Atlas / " + key + (" / " + group if group != key else "") + " / " + name
                clean = remove_duplicate_manifests(record)
                text = "\n".join(format_facts(clean))
                yield {"title": title, "text": text, "source": str(source) + "#atlas-snapshot/" + key + "/" + group + "/" + str(index)}
    inventory = data.get("fileInventory", [])
    fingerprints = {(item.get("absolute_path", item.get("path")), item.get("sha256")) for item in inventory if isinstance(item, dict)}
    for repository in data.get("repositories", []):
        for snapshot in ("local_manifest", "origin_manifest"):
            for record in repository.get(snapshot, []):
                fingerprint = (record.get("absolute_path", record.get("path")), record.get("sha256"))
                if fingerprint in fingerprints:
                    continue
                fingerprints.add(fingerprint)
                content = {"repository": repository.get("name"), "snapshot": snapshot, **record}
                yield {
                    "title": "Atlas / manifest evidence / " + str(repository.get("name")) + " / " + str(record.get("path")),
                    "text": "\n".join(format_facts(content)),
                    "source": str(source) + "#atlas-snapshot/repositories/" + snapshot,
                }


def build_corpus(paths):
    sources = [Path(path).expanduser().resolve() for path in paths]
    sections = []
    intro = []
    title = "Рабочий проект"
    date = "не указан"
    for source in sources:
        raw = source.read_text(encoding="utf-8")
        reject_credentials(raw, source)
        parser = ContextHTMLParser(source)
        parser.feed(raw)
        parser.flush()
        if parser.title:
            title = parser.title
        if parser.sections:
            sections.extend(parser.sections)
            intro.extend(section["text"] for section in parser.sections[:2])
        if parser.snapshot_parts:
            data = json.loads("".join(parser.snapshot_parts))
            if not isinstance(data, dict):
                raise ValueError("Неверный atlas snapshot: " + source.name)
            meta = data.get("meta", {})
            date = normalized_date(str(meta.get("date", date)))
            if title == "Рабочий проект":
                title = str(meta.get("title", title))
            sections.extend(atlas_sections(data, source))
            intro.extend(item.get("text", "") for item in data.get("intro", []) if isinstance(item, dict))
            intro.extend(str(item) for item in meta.get("limitations", []))
    if not sections:
        raise ValueError("Не найден article или atlas-snapshot")
    seen = set()
    unique = []
    for section in sections:
        text = section["text"].replace("\x00", "")
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        section = dict(section, text=text, id="section-" + hashlib.sha256((section["source"] + "\n" + section["title"]).encode("utf-8")).hexdigest()[:16])
        unique.append(section)
    return {
        "title": title,
        "snapshotDate": date,
        "sourcePaths": [str(source) for source in sources],
        "overview": "Документированный срез; возможности в коде, configured, running и E2E различаются. Личное авторство участника не устанавливается наличием функции проекта.\n\n" + "\n\n".join(dict.fromkeys(intro)),
        "sections": unique,
    }


def main():
    parser = argparse.ArgumentParser(description="Импорт локального HTML-контекста проекта")
    parser.add_argument("sources", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output in [source.expanduser().resolve() for source in args.sources]:
        parser.error("output не должен заменять исходный HTML")
    try:
        corpus = build_corpus(args.sources)
        payload = (json.dumps(corpus, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".context-", delete=False) as handle:
                temporary = Path(handle.name)
                os.chmod(temporary, 0o600)
                handle.write(payload)
            os.replace(temporary, output)
        finally:
            if temporary and temporary.exists():
                temporary.unlink()
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps({"output": str(output), "sourceCount": len(corpus["sourcePaths"]), "sections": len(corpus["sections"]), "utf8Bytes": len(payload), "snapshotDate": corpus["snapshotDate"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
