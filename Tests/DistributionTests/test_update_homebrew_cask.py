import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name("fixtures")
TRANSFORMER = ROOT / "scripts" / "update-homebrew-cask.py"
VERSION = "2.3.4"
SHA256 = "0123456789abcdef" * 4
BINARY_STANZA = '  binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"'


class HomebrewCaskTransformerTests(unittest.TestCase):
    def run_transform(
        self, original, version=VERSION, sha256=SHA256, mode=0o640
    ):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "crisp.rb"
            target.write_bytes(original)
            target.chmod(mode)
            command = [
                "python3",
                str(TRANSFORMER),
                str(target),
                "--version",
                version,
                "--sha256",
                sha256,
            ]
            result = subprocess.run(command, text=True, capture_output=True)
            return result, target.read_bytes(), target.stat().st_mode & 0o7777

    def expected_bytes(self, original):
        newline = b"\r\n" if b"\r\n" in original else b"\n"
        expected = original.replace(
            b'version "1.5.1"', f'version "{VERSION}"'.encode()
        )
        old_sha = b"b" * 64 if b"b" * 64 in original else b"a" * 64
        expected = expected.replace(
            b'sha256 "' + old_sha + b'"', f'sha256 "{SHA256}"'.encode()
        )
        if BINARY_STANZA.encode() not in expected:
            expected = expected.replace(
                b'  app "Crisp.app"' + newline,
                b'  app "Crisp.app"'
                + newline
                + BINARY_STANZA.encode()
                + newline,
            )
        return expected

    def assert_success_bytes_and_idempotence(self, original, expected):
        first_result, first, first_mode = self.run_transform(original)
        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        self.assertEqual(first, expected)
        self.assertEqual(first_mode, 0o640)

        second_result, second, second_mode = self.run_transform(first)
        self.assertEqual(second_result.returncode, 0, second_result.stderr)
        self.assertEqual(second, expected, "transform must be byte-idempotent")
        self.assertEqual(second_mode, 0o640)

    def assert_rejected_unchanged(self, original, error, **arguments):
        result, actual, actual_mode = self.run_transform(
            original, mode=0o751, **arguments
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(error, result.stderr)
        self.assertEqual(actual, original)
        self.assertEqual(actual_mode, 0o751)

    def test_inserts_missing_binary_stanza_once(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes()
        self.assert_success_bytes_and_idempotence(
            original, self.expected_bytes(original)
        )

    def test_existing_binary_stanza_remains_exactly_once(self):
        original = (FIXTURES / "crisp-with-binary.rb").read_bytes()
        self.assert_success_bytes_and_idempotence(
            original, self.expected_bytes(original)
        )

    def test_preserves_crlf_with_complete_expected_bytes(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes().replace(b"\n", b"\r\n")
        self.assert_success_bytes_and_idempotence(
            original, self.expected_bytes(original)
        )

    def test_rejects_app_stanza_without_terminating_newline_unchanged(self):
        fixture = (FIXTURES / "crisp-legacy.rb").read_bytes()
        marker = b'  app "Crisp.app"'
        original = fixture[: fixture.index(marker) + len(marker)]

        self.assert_rejected_unchanged(
            original, "app stanza must end with a newline"
        )

    def test_rejects_mixed_newlines_unchanged(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes().replace(
            b"\n", b"\r\n", 1
        )

        self.assert_rejected_unchanged(
            original, "mixed or ambiguous newline style"
        )

    def test_rejects_wrong_cask_wrapper_unchanged(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes().replace(
            b'cask "crisp" do', b'cask "other" do'
        )

        self.assert_rejected_unchanged(
            original, 'expected top-level cask "crisp" do wrapper'
        )

    def test_rejects_malformed_cask_wrapper_unchanged(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes().removesuffix(b"end\n")
        self.assert_rejected_unchanged(
            original, 'expected top-level cask "crisp" do wrapper'
        )

    def test_rejects_matching_stanzas_nested_in_unexpected_block_unchanged(self):
        original = (
            b'cask "crisp" do\n'
            b'  on_arm do\n'
            b'    version "1.5.1"\n'
            + b'    sha256 "'
            + b"a" * 64
            + b'"\n'
            b'    app "Crisp.app"\n'
            b'  end\n'
            b'end\n'
        )

        self.assert_rejected_unchanged(
            original, "release stanzas must be in the top-level cask block"
        )

    def test_rejects_multiline_ruby_brace_block_unchanged(self):
        original = (
            b'cask "crisp" do\n'
            b'  on_arm {\n'
            b'    version "1.5.1"\n'
            + b'    sha256 "'
            + b"a" * 64
            + b'"\n'
            b'    app "Crisp.app"\n'
            b'  }\n'
            b'end\n'
        )

        self.assert_rejected_unchanged(
            original, "unsupported Ruby brace/block syntax"
        )

    def test_rejects_same_line_ruby_brace_block_unchanged(self):
        fixture = (FIXTURES / "crisp-legacy.rb").read_bytes()
        original = fixture.replace(
            b'  version "1.5.1"\n',
            b'  on_arm { version "nested" }\n  version "1.5.1"\n',
        )

        self.assert_rejected_unchanged(
            original, "unsupported Ruby brace/block syntax"
        )

    def test_escaped_backslash_cannot_hide_unquoted_brace(self):
        fixture = (FIXTURES / "crisp-legacy.rb").read_bytes()
        original = fixture.replace(
            b'  version "1.5.1"\n',
            b'  desc "escaped backslash \\\\" {\n  version "1.5.1"\n',
        )

        self.assert_rejected_unchanged(
            original, "unsupported Ruby brace/block syntax"
        )

    def test_allows_braces_in_quoted_strings_comments_and_binary_interpolation(self):
        fixture = (FIXTURES / "crisp-with-binary.rb").read_bytes()
        original = fixture.replace(
            b'  version "1.5.1"\n',
            b'  # comment braces are harmless: { }\n'
            b'  desc "escaped quote: \\\"{still quoted}\\\""\n'
            b"  homepage 'https://example.test/{literal}'\n"
            b'  version "1.5.1"\n',
        )

        self.assert_success_bytes_and_idempotence(
            original, self.expected_bytes(original)
        )

    def test_rejects_unclosed_quoted_string_unchanged(self):
        fixture = (FIXTURES / "crisp-legacy.rb").read_bytes()
        original = fixture.replace(
            b'  version "1.5.1"\n',
            b'  desc "unterminated {\n  version "1.5.1"\n',
        )

        self.assert_rejected_unchanged(
            original, "unterminated Ruby quoted string"
        )

    def test_rejects_missing_or_duplicate_required_stanzas_unchanged(self):
        fixture = (FIXTURES / "crisp-legacy.rb").read_bytes()
        version = b'  version "1.5.1"\n'
        sha = b'  sha256 "' + b"a" * 64 + b'"\n'
        app = b'  app "Crisp.app"\n'
        cases = {
            "missing version": (fixture.replace(version, b""), "version", 0),
            "duplicate version": (fixture.replace(version, version * 2), "version", 2),
            "missing sha": (fixture.replace(sha, b""), "sha256", 0),
            "duplicate sha": (fixture.replace(sha, sha * 2), "sha256", 2),
            "missing app": (fixture.replace(app, b""), 'app "Crisp.app"', 0),
            "duplicate app": (fixture.replace(app, app * 2), 'app "Crisp.app"', 2),
        }
        for label, (original, stanza, count) in cases.items():
            with self.subTest(label=label):
                self.assert_rejected_unchanged(
                    original, f"expected exactly one {stanza} stanza, found {count}"
                )

    def test_rejects_unrecognized_crispctl_stanza_unchanged(self):
        fixture = (FIXTURES / "crisp-legacy.rb").read_bytes()
        original = fixture.replace(
            b'  app "Crisp.app"\n',
            b'  app "Crisp.app"\n'
            b'  binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl", target: "wrong"\n',
        )
        self.assert_rejected_unchanged(
            original, "found an unrecognized crispctl cask stanza"
        )

    def test_rejects_unsafe_version_and_sha_unchanged(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes()
        cases = (
            ({"version": '2.3.4"; system("bad")'}, "unsafe version value"),
            ({"sha256": "g" * 64}, "sha256 must contain exactly 64 hex characters"),
            ({"sha256": "abc"}, "sha256 must contain exactly 64 hex characters"),
        )
        for arguments, error in cases:
            with self.subTest(arguments=arguments):
                self.assert_rejected_unchanged(original, error, **arguments)

    def test_preserves_file_mode(self):
        original = (FIXTURES / "crisp-legacy.rb").read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "crisp.rb"
            target.write_bytes(original)
            target.chmod(0o751)
            result = subprocess.run(
                [
                    "python3",
                    str(TRANSFORMER),
                    str(target),
                    "--version",
                    VERSION,
                    "--sha256",
                    SHA256,
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.stat().st_mode & 0o7777, 0o751)

    def test_transformed_output_is_valid_ruby_when_available(self):
        ruby = shutil.which("ruby")
        if ruby is None:
            self.skipTest("Ruby is unavailable")
        original = (FIXTURES / "crisp-legacy.rb").read_bytes()
        result, transformed, _ = self.run_transform(original)
        self.assertEqual(result.returncode, 0, result.stderr)

        syntax = subprocess.run(
            [ruby, "-c", "-"], input=transformed, capture_output=True
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode())


if __name__ == "__main__":
    unittest.main()
