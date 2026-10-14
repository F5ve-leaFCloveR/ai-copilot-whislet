import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("project_context_import", Path(__file__).parents[1] / "scripts/import-project-context.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ImportProjectContextTests(unittest.TestCase):
    def test_narrative_and_embedded_catalog_preserve_tables_code_and_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            guide = Path(directory) / "guide.html"
            atlas = Path(directory) / "index.html"
            guide.write_text('<nav>Навигация</nav><article><h1>Example meeting service</h1><p>Вымышленный срез 12 апреля 2024 года</p><h2 id="state">Хранение</h2><table><tr><th>База</th><th>Роль</th></tr><tr><td>PostgreSQL</td><td>История</td></tr></table><pre><code>if x:\n    return x</code></pre><script>hiddenUI()</script></article>', encoding="utf-8")
            data = {"meta": {"date": "12.04.2024", "limitations": ["Не E2E"]}, "connectors": [{"id": "calendar", "purpose": "Встречи", "status": "code", "runtime_verified": False, "tools": [{"name": "query_calendar", "signature": "query_calendar(date: str)", "sources": [{"revision": "abcd", "line_start": 10}]}]}]}
            atlas.write_text('<style>hiddenCSS</style><script id="atlas-snapshot" type="application/json">' + json.dumps(data, ensure_ascii=False) + '</script><script>hiddenUI()</script>', encoding="utf-8")
            corpus = module.build_corpus([guide, atlas])
            text = "\n".join(section["text"] for section in corpus["sections"])
            self.assertIn("База | Роль", text)
            self.assertIn("PostgreSQL | История", text)
            self.assertIn("if x:\n    return x", text)
            self.assertIn("query_calendar(date: str)", text)
            self.assertIn("runtime_verified: false", text)
            self.assertIn("revision: abcd", text)
            self.assertIn("line_start: 10", text)
            self.assertNotIn("hiddenUI", text)
            self.assertNotIn("hiddenCSS", text)
            self.assertNotIn("Навигация", text)
            self.assertEqual(corpus["snapshotDate"], "2024-04-12")
            self.assertEqual(len(corpus["sourcePaths"]), 2)

    def test_duplicate_manifest_blob_is_removed_but_central_inventory_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            atlas = Path(directory) / "index.html"
            data = {"meta": {"date": "2024-04-12"}, "repositories": [{"name": "source", "local_manifest": [{"path": "a.py", "sha256": "hash"}]}], "fileInventory": [{"path": "a.py", "sha256": "hash", "bytes": 23}]}
            atlas.write_text('<script id="atlas-snapshot" type="application/json">' + json.dumps(data) + '</script>', encoding="utf-8")
            text = "\n".join(section["text"] for section in module.build_corpus([atlas])["sections"])
            self.assertEqual(text.count("path: a.py"), 1)
            self.assertIn("sha256: hash", text)
            self.assertIn("bytes: 23", text)

    def test_secret_detection_does_not_echo_sensitive_values(self):
        with tempfile.TemporaryDirectory() as directory:
            guide = Path(directory) / "guide.html"
            value = "sk-" + "z" * 40
            guide.write_text("<article><h1>Context</h1><p>" + value + "</p></article>", encoding="utf-8")
            with self.assertRaises(ValueError) as caught:
                module.build_corpus([guide])
            self.assertNotIn(value, str(caught.exception))
            self.assertIn("guide.html", str(caught.exception))

    def test_unique_local_manifest_revision_is_not_lost(self):
        with tempfile.TemporaryDirectory() as directory:
            atlas = Path(directory) / "index.html"
            data = {"repositories": [{"name": "source", "local_manifest": [{"path": "a.py", "sha256": "old"}]}], "fileInventory": [{"repository": "source", "path": "a.py", "sha256": "new"}]}
            atlas.write_text('<script id="atlas-snapshot" type="application/json">' + json.dumps(data) + '</script>', encoding="utf-8")
            text = "\n".join(section["text"] for section in module.build_corpus([atlas])["sections"])
            self.assertIn("sha256: old", text)
            self.assertIn("sha256: new", text)


if __name__ == "__main__":
    unittest.main()
