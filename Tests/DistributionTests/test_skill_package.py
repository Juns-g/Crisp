import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "crispctl" / "SKILL.md"
OLD_SKILL = ROOT / "docs" / "skills" / "crispctl" / "SKILL.md"
README = ROOT / "README.md"
CRISPCTL_DOCS = ROOT / "docs" / "crispctl.md"
RELEASING_DOCS = ROOT / "docs" / "RELEASING.md"
SKILL_INSTALL_COMMAND = (
    "npx skills add didriksg/Crisp --skill crispctl -g --agent '*' -y"
)


class CrispctlSkillPackageTests(unittest.TestCase):
    def test_skill_has_one_canonical_location(self):
        self.assertTrue(SKILL.is_file(), "canonical Skill is missing")
        self.assertFalse(OLD_SKILL.exists(), "legacy Skill duplicate still exists")

    def test_frontmatter_is_complete_and_discoverable(self):
        raw = SKILL.read_bytes()
        self.assertTrue(raw.startswith(b"---\n"), "frontmatter must start at byte 0")
        text = raw.decode()
        _, frontmatter, _ = text.split("---", 2)

        self.assertRegex(frontmatter, r"(?m)^name: crispctl$")
        description = re.search(r"(?m)^description: (.+)$", frontmatter)
        self.assertIsNotNone(description)
        description_text = description.group(1).strip('"')
        self.assertLessEqual(len(description_text), 60)
        self.assertTrue(description_text.startswith("Use when "))
        self.assertIn("Crisp", description_text)
        self.assertRegex(description_text.lower(), r"\bdisplays?\b")
        self.assertTrue(description_text.endswith("."))
        self.assertRegex(frontmatter, r"(?m)^version: 0\.1\.0$")
        self.assertRegex(frontmatter, r"(?m)^author: .+$")
        self.assertLess(frontmatter.index("Juns (Juns-g)"), frontmatter.index("Hermes Agent"))
        self.assertRegex(frontmatter, r"(?m)^license: MIT$")
        self.assertRegex(frontmatter, r"(?ms)^platforms:\n  - macos$")
        self.assertRegex(frontmatter, r"(?ms)^metadata:\n  hermes:\n    tags:\n(?:      - .+\n)+    related_skills: \[\]$")

    def test_body_preserves_execution_and_safety_contract(self):
        text = SKILL.read_text()
        for heading in (
            "## When to Use",
            "## Prerequisites",
            "## How to Run",
            "### Preflight",
            "## Pitfalls",
            "## Verification",
        ):
            self.assertIn(heading, text)

        for required in (
            "--json",
            "UUID",
            "capabilities",
            "ambiguous",
            "Tier 2/3",
            "write_outcome_indeterminate",
            "do not retry",
            "fresh user decision",
        ):
            self.assertIn(required, text)

        self.assertIn("command -v crispctl", text)
        self.assertIn("/Applications/Crisp.app/Contents/MacOS/crispctl", text)
        self.assertIn('"${CRISPCTL}" displays list --json', text)
        self.assertNotRegex(text, r"(?m)^crispctl (?:version|status|displays|brightness)")
        self.assertIn("github.com/didriksg/Crisp", text)
        self.assertIn("skills/crispctl", text)
        self.assertRegex(text.lower(), r"fresh agent session")

    def test_skill_uses_conventional_cross_agent_installer(self):
        text = SKILL.read_text()

        self.assertIn(SKILL_INSTALL_COMMAND, text)
        self.assertNotIn("$skill-installer", text)
        self.assertNotIn("CODEX_HOME", text)
        self.assertNotIn(".codex/skills", text)


class DistributionDocumentationTests(unittest.TestCase):
    def test_user_docs_explain_cli_and_skill_distribution_without_overclaiming(self):
        readme = README.read_text()
        crispctl_docs = CRISPCTL_DOCS.read_text()

        self.assertIn("[skills/crispctl/SKILL.md](skills/crispctl/SKILL.md)", readme)
        self.assertIn("/Applications/Crisp.app/Contents/MacOS/crispctl", readme)
        self.assertRegex(readme, r"(?is)homebrew.+?`PATH`")

        self.assertIn(
            "[../skills/crispctl/SKILL.md](../skills/crispctl/SKILL.md)",
            crispctl_docs,
        )
        self.assertIn(
            "/Applications/Crisp.app/Contents/MacOS/crispctl", crispctl_docs
        )
        self.assertRegex(crispctl_docs, r"(?is)homebrew.+?`PATH`")
        self.assertRegex(crispctl_docs, r"(?i)fresh agent session")
        self.assertIn(SKILL_INSTALL_COMMAND, crispctl_docs)

    def test_public_availability_wording_is_durable(self):
        documents = (README, CRISPCTL_DOCS, SKILL)
        transient_wording = (
            r"(?i)PR\s*#\d+",
            r"(?i)open pull request",
            r"(?i)pull request is still open",
            r"(?i)while the pull request",
            r"(?i)(?:once|after) (?:it|the change) is merged",
            r"(?i)not (?:yet )?published",
        )

        for path in documents:
            with self.subTest(path=path):
                text = path.read_text()
                for pattern in transient_wording:
                    self.assertNotRegex(text, pattern)
                self.assertIn("Crisp 1.5.0", text)
                self.assertRegex(
                    text,
                    r"(?is)first Crisp release.+?contains?\s+(?:this|the) distribution change",
                )
                self.assertRegex(text, r"(?is)source\s+checkout.+?build")

    def test_release_docs_record_idempotent_homebrew_path_stanza(self):
        releasing = RELEASING_DOCS.read_text()
        self.assertIn(
            'binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"', releasing
        )
        self.assertIn("scripts/update-homebrew-cask.py", releasing)
        self.assertRegex(releasing, r"(?i)exactly once|idempotent")
        self.assertRegex(releasing, r"(?i)homebrew.+`PATH`")
        self.assertIn("/Applications/Crisp.app/Contents/MacOS/crispctl", releasing)


if __name__ == "__main__":
    unittest.main()
