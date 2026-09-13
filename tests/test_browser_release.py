import json
import re
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from package_browser_release import REQUIRED_FILES, REVISION_MARKER, prepare_bundle


class BrowserReleaseTest(unittest.TestCase):
    revision = "a" * 40

    def test_automatic_start_callback_is_included_in_runtime(self):
        shell = (ROOT / "browser" / "shell.html").read_text(encoding="utf-8")
        cmake = (ROOT / "src" / "CMakeLists.txt").read_text(encoding="utf-8")
        incoming_api = re.search(r"-sINCOMING_MODULE_JS_API=\[([^]]+)\]", cmake)
        self.assertIsNotNone(incoming_api)
        self.assertIn("onRuntimeInitialized", incoming_api.group(1).split(","))
        self.assertIn("onRuntimeInitialized: startGame", shell)
        self.assertIn("-sINVOKE_RUN=0", cmake)

    def make_bundle(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        bundle = Path(temporary.name)
        for name in REQUIRED_FILES:
            (bundle / name).write_text("content", encoding="utf-8")
        (bundle / "otclient.html").write_text(
            f'<meta name="xibat-browser-revision" content="{REVISION_MARKER}">',
            encoding="utf-8",
        )
        return bundle

    def test_prepares_revision_consistent_bundle(self):
        bundle = self.make_bundle()
        prepare_bundle(bundle, self.revision)

        html = (bundle / "otclient.html").read_text(encoding="utf-8")
        release = json.loads((bundle / "revision.json").read_text(encoding="utf-8"))
        self.assertIn(self.revision, html)
        self.assertNotIn(REVISION_MARKER, html)
        self.assertEqual(release, {"revision": self.revision})

    def test_rejects_invalid_revision(self):
        with self.assertRaisesRegex(ValueError, "40-character"):
            prepare_bundle(self.make_bundle(), "latest")

    def test_rejects_missing_or_duplicate_marker(self):
        for marker_count in (0, 2):
            with self.subTest(marker_count=marker_count):
                bundle = self.make_bundle()
                (bundle / "otclient.html").write_text(
                    REVISION_MARKER * marker_count or "no marker", encoding="utf-8"
                )
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    prepare_bundle(bundle, self.revision)

    def test_rejects_missing_required_file(self):
        bundle = self.make_bundle()
        (bundle / "otclient.wasm").unlink()
        with self.assertRaisesRegex(ValueError, "otclient.wasm"):
            prepare_bundle(bundle, self.revision)

    def test_shell_pins_app_files_without_changing_user_storage(self):
        shell = (ROOT / "browser" / "shell.html").read_text(encoding="utf-8")
        self.assertEqual(shell.count(REVISION_MARKER), 1)
        self.assertIn("`/releases/${XIBAT_BROWSER_REVISION}/`", shell)
        self.assertIn("new URL(path, document.baseURI).href", shell)
        self.assertIn('fetch("/revision.json"', shell)
        self.assertIn("window.location.replace(", shell)
        self.assertIn('FS.mount(IDBFS, { autoPersist: true }, "/user")', shell)
        self.assertIn("FS.syncfs(true", shell)
        self.assertIn("if (!persistentStorageReady)", shell)


if __name__ == "__main__":
    unittest.main()
