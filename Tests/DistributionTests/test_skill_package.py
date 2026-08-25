import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "crispctl" / "SKILL.md"
OLD_SKILL = ROOT / "docs" / "skills" / "crispctl" / "SKILL.md"
README = ROOT / "README.md"
CRISPCTL_DOCS = ROOT / "docs" / "crispctl.md"
COMPARE_EN = ROOT / "docs" / "crisp-vs-betterdisplay.html"
COMPARE_ZH = ROOT / "docs" / "crisp-vs-betterdisplay-zh.html"
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

    def test_p0_skill_is_fail_closed_for_every_expanded_mutation(self):
        text = SKILL.read_text()
        lower = text.lower()
        for command in (
            "brightness set <uuid>", "extra-brightness set <uuid>",
            "hdr set <uuid>", "brightness set-all",
        ):
            self.assertIn(command, text)
        for phrase in (
            "external displays only",
            "built-in hdr",
            "extra brightness",
            "logicalpercent",
            "hardwarereadbackpercent",
            "non-atomic",
            "partial failure",
            "do not retry the whole batch",
            "retrysafe:false",
            "fresh user decision",
            "stale display uuid",
            "read-back mismatch",
            "capability collapse",
            "item results",
            "warnings",
        ):
            self.assertIn(phrase, lower)
        self.assertRegex(lower, r"only `?retrysafe:true`? members")
        self.assertRegex(lower, r"missing|unsupported")
        self.assertIn("P1/P2", text)

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

    def test_p0_automation_docs_are_complete_scoped_and_bilingual(self):
        readme = README.read_text()
        docs = CRISPCTL_DOCS.read_text()
        skill = SKILL.read_text()
        en = COMPARE_EN.read_text()
        zh = COMPARE_ZH.read_text()

        for command in (
            "extra-brightness get", "extra-brightness set",
            "hdr get", "hdr set", "brightness get-all", "brightness set-all",
        ):
            self.assertIn(command, readme)
            self.assertIn(command, docs)
            self.assertIn(command, skill)

        for schema_term in (
            "logicalPercent", "hardwareReadbackPercent", "hardwareRange", "logicalRange",
            "app_state_verified", "settling", "batch_partial_failure",
            "same_logical_percent_per_display", "appliedFactor", "factorVerification",
        ):
            self.assertIn(schema_term, docs)

        batch_docs = docs[docs.index("`brightness get-all`"):docs.index("## Response contract")]
        for member_field in ("`attempted`", "`outcome`", "`verification`", "`code`", "`retrySafe`"):
            self.assertIn(member_field, batch_docs)

        for headroom_term in ("appliedFactor", "factorVerification", "app_state"):
            self.assertIn(headroom_term, skill)

        for safety_term in (
            "UUID", "explicit user authorization", "capabilities", "no automatic retry",
            "write_outcome_indeterminate", "batch_partial_failure", "fresh user decision",
        ):
            self.assertIn(safety_term, skill)
        self.assertNotRegex(skill, r"(?i)HDR[^\n]{0,40}(?:not supported|unsupported)")

        for page, section, p1p2 in (
            (en, "GUI to crispctl automation", "P1/P2"),
            (zh, "GUI 到 crispctl 自动化", "P1/P2"),
        ):
            self.assertIn(section, page)
            self.assertIn("extra-brightness", page)
            self.assertIn("brightness set-all", page)
            self.assertIn(p1p2, page)

    def test_extra_brightness_cleanup_only_off_exception_is_fail_closed(self):
        for path in (SKILL, CRISPCTL_DOCS):
            with self.subTest(path=path):
                text = path.read_text()
                normalized = " ".join(text.split()).lower()
                for required in (
                    "fresh discovery",
                    "exact same UUID",
                    "`state: writable`",
                    "`extra-brightness set <same-uuid> off`",
                    "`state: unsupported`",
                    "`persistedEnabled: true`",
                    "`enabled: true`",
                    "`maxBrightness > 100`",
                    "never permits `on`",
                    "never permits unsupported HDR or brightness writes",
                    "unsupported `off` without a cleanup indicator",
                    "explicit user authorization",
                    "stop and re-discover",
                    "write_outcome_indeterminate",
                    "`retrySafe: false`",
                    "no automatic retry",
                    "fresh user decision",
                ):
                    self.assertIn(required.lower(), normalized)

    def test_extra_brightness_disable_documents_settling_and_indeterminate_outcomes(self):
        for path in (SKILL, CRISPCTL_DOCS):
            with self.subTest(path=path):
                text = " ".join(path.read_text().split()).lower()
                for required in (
                    "accepted and persisted off",
                    "verification: settling",
                    "terminal cleanup",
                    "read back",
                    "write_outcome_indeterminate",
                    "no automatic retry",
                ):
                    self.assertIn(required, text)

    def test_comparison_pages_distinguish_source_p0_from_public_availability(self):
        en = COMPARE_EN.read_text()
        zh = COMPARE_ZH.read_text()

        for page in (en, zh):
            self.assertIn("Crisp 1.5.0", page)
            self.assertIn("Homebrew cask", page)
            self.assertIn("P0", page)
        self.assertRegex(en, r"(?is)source-build.+?future release")
        self.assertRegex(zh, r"(?is)源码构建.+?未来版本")
        self.assertNotIn("Crisp now has <strong>crispctl</strong>", en)
        self.assertNotIn("Crisp 现在已有 <strong>crispctl</strong>", zh)


if __name__ == "__main__":
    unittest.main()
