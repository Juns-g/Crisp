import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASE = ROOT / "scripts" / "release.sh"
CRISPCTL_HELPER = ROOT / "scripts" / "build-embed-sign-crispctl.sh"
VERIFIER = ROOT / "scripts" / "verify-release-app.sh"


class ReleaseCrispctlHelperTests(unittest.TestCase):
    def make_fixture(self, archs="arm64 x86_64"):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        repo = root / "repo"
        app = root / "Crisp.app"
        scratch = root / "scratch"
        swift_bin = root / "swift-bin"
        tools = root / "bin"
        for directory in (repo, swift_bin, tools):
            directory.mkdir()

        xcrun = tools / "xcrun"
        xcrun.write_text(
            "#!/bin/sh\n"
            'printf \'%s\\n\' "$*" >> "$XCRUN_LOG"\n'
            'case " $* " in\n'
            '  *" --show-bin-path "*) printf \'%s\\n\' "$SWIFT_BIN" ;;\n'
            '  *) [ "${FAKE_FAIL_STAGE:-}" = build ] && exit 41; '
            '[ "${FAKE_FAIL_STAGE:-}" = copy ] || { '
            'printf \'swiftpm-product\' > "$SWIFT_BIN/crispctl"; '
            'chmod 755 "$SWIFT_BIN/crispctl"; } ;;\n'
            "esac\n"
        )
        xcrun.chmod(0o755)

        lipo = tools / "lipo"
        lipo.write_text(
            "#!/bin/sh\n"
            'printf \'%s\\n\' "$*" >> "$LIPO_LOG"\n'
            '[ "${FAKE_FAIL_STAGE:-}" = verifier ] && { '
            'printf \'%s\\n\' "$FAKE_ARCHS"; exit 43; }\n'
            'printf \'%s\\n\' "$FAKE_ARCHS"\n'
        )
        lipo.chmod(0o755)

        codesign = tools / "codesign"
        codesign.write_text(
            "#!/bin/sh\n"
            'printf \'%s\\n\' "$*" >> "$CODESIGN_LOG"\n'
            '[ "${FAKE_FAIL_STAGE:-}" = sign ] && exit 44\n'
            "exit 0\n"
        )
        codesign.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{tools}:{environment['PATH']}",
                "SWIFT_BIN": str(swift_bin),
                "FAKE_ARCHS": archs,
                "XCRUN_LOG": str(root / "xcrun.log"),
                "LIPO_LOG": str(root / "lipo.log"),
                "CODESIGN_LOG": str(root / "codesign.log"),
            }
        )
        return temporary, root, repo, app, scratch, environment

    def run_helper(self, repo, app, scratch, signing_id, environment):
        return subprocess.run(
            [
                "/bin/bash",
                str(CRISPCTL_HELPER),
                str(repo),
                str(app),
                str(scratch),
                signing_id,
            ],
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_builds_selects_embeds_verifies_and_ad_hoc_signs_swiftpm_product(self):
        temporary, root, repo, app, scratch, environment = self.make_fixture()
        with temporary:
            result = self.run_helper(repo, app, scratch, "", environment)
            destination = app / "Contents" / "MacOS" / "crispctl"

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.read_bytes(), b"swiftpm-product")
            self.assertTrue(os.access(destination, os.X_OK))
            expected_build = (
                "swift build --disable-sandbox -c release --product crispctl "
                f"--package-path {repo} --scratch-path {scratch} "
                "--arch arm64 --arch x86_64"
            )
            xcrun_calls = (root / "xcrun.log").read_text().splitlines()
            self.assertEqual(
                xcrun_calls, [expected_build, expected_build + " --show-bin-path"]
            )
            self.assertEqual(
                (root / "lipo.log").read_text().strip(), f"-archs {destination}"
            )
            self.assertEqual(
                (root / "codesign.log").read_text().strip(),
                f"--force --sign - {destination}",
            )

    def test_developer_id_uses_hardened_runtime_timestamp_and_identity(self):
        temporary, root, repo, app, scratch, environment = self.make_fixture()
        with temporary:
            result = self.run_helper(
                repo, app, scratch, "Developer ID Application: Example", environment
            )
            destination = app / "Contents" / "MacOS" / "crispctl"

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (root / "codesign.log").read_text().strip(),
                "--force --options runtime --timestamp --sign "
                f"Developer ID Application: Example {destination}",
            )

    def test_rejects_any_architecture_set_other_than_exact_universal_pair(self):
        for archs in ("arm64", "arm64 x86_64 i386", "arm64 arm64"):
            with self.subTest(archs=archs):
                temporary, _, repo, app, scratch, environment = self.make_fixture(
                    archs=archs
                )
                with temporary:
                    result = self.run_helper(repo, app, scratch, "", environment)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("exactly arm64 and x86_64", result.stderr)

    def test_build_copy_verifier_and_sign_failures_propagate_nonzero(self):
        for stage in ("build", "copy", "verifier", "sign"):
            with self.subTest(stage=stage):
                temporary, _, repo, app, scratch, environment = self.make_fixture()
                with temporary:
                    environment["FAKE_FAIL_STAGE"] = stage
                    result = self.run_helper(repo, app, scratch, "", environment)
                    self.assertNotEqual(result.returncode, 0)

    def test_cli_sign_completes_before_enclosing_app_sign_can_run(self):
        temporary, root, repo, app, scratch, environment = self.make_fixture()
        with temporary:
            result = self.run_helper(repo, app, scratch, "", environment)
            self.assertEqual(result.returncode, 0, result.stderr)

            enclosing = subprocess.run(
                ["codesign", "--force", "--sign", "-", str(app)],
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(enclosing.returncode, 0, enclosing.stderr)
            self.assertEqual(
                (root / "codesign.log").read_text().splitlines(),
                [
                    f"--force --sign - {app / 'Contents' / 'MacOS' / 'crispctl'}",
                    f"--force --sign - {app}",
                ],
            )


class ReleaseScriptIntegrationTests(unittest.TestCase):
    VERSION = "2.3.4"
    SHA256 = "0123456789abcdef" * 4
    PREFLIGHT_MARKER = (
        "# Preflight the Homebrew cask before any publish-side mutation."
    )
    HELPER_CALL = (
        '"$ROOT/scripts/build-embed-sign-crispctl.sh" "$ROOT" "$APP" '
        '"$CRISPCTL_SCRATCH" "${CRISP_SIGN_ID:-}"'
    )

    def write_executable(self, path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        path.chmod(0o755)

    def make_fixture(self, release_source=None, cask_content=None):
        temporary = tempfile.TemporaryDirectory()
        repo = Path(temporary.name) / "repo"
        scripts = repo / "scripts"
        tools = repo / "fake-bin"
        scripts.mkdir(parents=True)
        tools.mkdir()

        release = scripts / "release.sh"
        shutil.copy2(RELEASE, release)
        if release_source is not None:
            release.write_text(release_source)
            release.chmod(0o755)
        shutil.copy2(ROOT / "scripts" / "update-homebrew-cask.py", scripts)

        marker = repo / "helper.marker"
        event_log = repo / "events.log"
        uploaded_content = repo / "uploaded-cask.base64"
        uploaded_sha = repo / "uploaded-cask.sha"

        self.write_executable(
            scripts / "fetch-sparkle.sh", "#!/bin/sh\nexit 0\n"
        )
        self.write_executable(
            scripts / "build-embed-sign-crispctl.sh",
            "#!/bin/sh\n"
            'if [ "${FAKE_HELPER_FAIL:-}" = 1 ]; then exit 67; fi\n'
            'app="$2"\n'
            'mkdir -p "$app/Contents/MacOS"\n'
            'printf crispctl > "$app/Contents/MacOS/crispctl"\n'
            'chmod 755 "$app/Contents/MacOS/crispctl"\n'
            ': > "$HELPER_MARKER"\n'
            'printf \'helper\\n\' >> "$EVENT_LOG"\n',
        )
        self.write_executable(
            scripts / "verify-release-app.sh",
            "#!/bin/sh\n"
            'cli="$1/Contents/MacOS/crispctl"\n'
            'if [ ! -f "$HELPER_MARKER" ] || [ ! -x "$cli" ]; then\n'
            '  echo "ERROR: crispctl helper output missing" >&2\n'
            "  exit 68\n"
            "fi\n"
            'printf \'verifier\\n\' >> "$EVENT_LOG"\n',
        )
        self.write_executable(
            scripts / "xcstrings-compile.py",
            "#!/usr/bin/env python3\nprint('en')\n",
        )
        self.write_executable(
            scripts / "check-translations.py",
            "#!/usr/bin/env python3\n"
            "import os\n"
            "from pathlib import Path\n"
            "with Path(os.environ['EVENT_LOG']).open('a') as log:\n"
            "    log.write('translations\\n')\n",
        )

        self.write_executable(
            tools / "swiftc",
            "#!/bin/sh\n"
            "output=\n"
            "while [ $# -gt 0 ]; do\n"
            '  if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi\n'
            "done\n"
            'mkdir -p "$(dirname "$output")"\n'
            'printf app-binary > "$output"\n'
            'chmod 755 "$output"\n',
        )
        self.write_executable(
            tools / "lipo",
            "#!/bin/sh\n"
            'if [ "$1" = -create ]; then\n'
            "  output=\n"
            "  while [ $# -gt 0 ]; do\n"
            '    if [ "$1" = -output ]; then output="$2"; shift 2; else shift; fi\n'
            "  done\n"
            '  printf universal > "$output"; chmod 755 "$output"\n'
            "else\n"
            "  printf 'arm64 x86_64\\n'\n"
            "fi\n",
        )
        self.write_executable(
            tools / "iconutil",
            "#!/bin/sh\n"
            "output=\n"
            "while [ $# -gt 0 ]; do\n"
            '  if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi\n'
            "done\n"
            ': > "$output"\n',
        )
        self.write_executable(tools / "xattr", "#!/bin/sh\nexit 0\n")
        self.write_executable(tools / "codesign", "#!/bin/sh\nexit 0\n")
        self.write_executable(
            tools / "hdiutil",
            "#!/bin/sh\n"
            "for argument in \"$@\"; do output=\"$argument\"; done\n"
            'printf dmg-fixture > "$output"\n',
        )
        self.write_executable(
            tools / "shasum",
            f"#!/bin/sh\nprintf '%s  %s\\n' '{self.SHA256}' \"$3\"\n",
        )
        self.write_executable(
            tools / "sed",
            "#!/bin/sh\n"
            'if [ "${REQUIRE_CASK_PREFLIGHT:-}" = 1 ]; then\n'
            '  prepared="$REPO_UNDER_TEST/build/crisp.rb"\n'
            '  grep -F \'version "2.3.4"\' "$prepared" >/dev/null\n'
            '  grep -F \'sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"\' "$prepared" >/dev/null\n'
            "fi\n"
            'printf \'project-mutate\\n\' >> "$EVENT_LOG"\n'
            'exec /usr/bin/sed "$@"\n',
        )
        self.write_executable(
            tools / "gh",
            "#!/bin/bash\n"
            "set -eu\n"
            'if [ "$1" = release ]; then\n'
            '  printf \'release-create\\n\' >> "$EVENT_LOG"\n'
            '  if [ "${REQUIRE_CASK_PREFLIGHT:-}" = 1 ]; then\n'
            '    prepared="$REPO_UNDER_TEST/build/crisp.rb"\n'
            '    grep -F \'version "2.3.4"\' "$prepared" >/dev/null\n'
            '    grep -F \'sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"\' "$prepared" >/dev/null\n'
            '    grep -F \'binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"\' "$prepared" >/dev/null\n'
            "  fi\n"
            "  exit 0\n"
            "fi\n"
            'if [ "$1" != api ]; then exit 70; fi\n'
            "is_put=false\n"
            "for argument in \"$@\"; do\n"
            '  [ "$argument" = PUT ] && is_put=true\n'
            "done\n"
            'if [ "$is_put" = true ]; then\n'
            '  printf \'tap-put\\n\' >> "$EVENT_LOG"\n'
            "  for argument in \"$@\"; do\n"
            '    case "$argument" in\n'
            '      content=*) printf \'%s\' "${argument#content=}" > "$UPLOADED_CONTENT" ;;\n'
            '      sha=*) printf \'%s\' "${argument#sha=}" > "$UPLOADED_SHA" ;;\n'
            "    esac\n"
            "  done\n"
            "  printf 'commit-sha\\n'\n"
            "  exit 0\n"
            "fi\n"
            'printf \'cask-get\\n\' >> "$EVENT_LOG"\n'
            'if [ "${FAKE_CASK_GET_FAIL:-}" = 1 ]; then exit 72; fi\n'
            'case "$*" in\n'
            "  *\"--jq .sha\"*) printf '%s\\n' retained-cask-sha ;;\n"
            "  *\"--jq .content\"*) printf '%s\\n' \"$FAKE_CASK_BASE64\" ;;\n"
            "  *) printf '%s\\n' \"$FAKE_CASK_JSON\" ;;\n"
            "esac\n",
        )

        assets = repo / "Crisp" / "Assets.xcassets" / "AppIcon.appiconset"
        assets.mkdir(parents=True)
        for size in (16, 32, 64, 128, 256, 512, 1024):
            (assets / f"icon_{size}.png").write_bytes(b"icon")
        resources = repo / "Crisp" / "Resources"
        resources.mkdir()
        (resources / "Localizable.xcstrings").write_text("{}")
        (repo / "Crisp" / "Crisp-Bridging-Header.h").write_text("")
        (repo / "Crisp" / "Crisp.entitlements").write_text("")
        (repo / "Crisp" / "Fixture.swift").write_text("")
        core = repo / "Sources" / "CrispControlCore"
        core.mkdir(parents=True)
        (core / "Fixture.swift").write_text("")

        framework = repo / "vendor" / "Sparkle" / "Sparkle.framework"
        (framework / "Versions" / "B" / "Updater.app").mkdir(parents=True)
        (framework / "Versions" / "B" / "Autoupdate").write_text("")
        sparkle_bin = repo / "vendor" / "Sparkle" / "bin"
        self.write_executable(
            sparkle_bin / "generate_appcast",
            "#!/bin/sh\n"
            'printf \'appcast\\n\' >> "$EVENT_LOG"\n'
            "while [ $# -gt 0 ]; do\n"
            '  if [ "$1" = -o ]; then printf appcast > "$2"; exit 0; fi\n'
            "  shift\n"
            "done\n"
            "exit 71\n",
        )

        (repo / "docs").mkdir()
        (repo / "project.yml").write_text('MARKETING_VERSION: "1.0.0"\n')
        (repo / "notes.md").write_text("release notes\n")
        if cask_content is None:
            cask_content = (
                ROOT
                / "Tests"
                / "DistributionTests"
                / "fixtures"
                / "crisp-legacy.rb"
            ).read_bytes()
        encoded_cask = base64.b64encode(cask_content).decode()

        environment = {
            "PATH": f"{tools}:{os.environ.get('PATH', os.defpath)}",
            "LANG": os.environ.get("LANG", "C"),
            "TMPDIR": tempfile.gettempdir(),
            "EVENT_LOG": str(event_log),
            "HELPER_MARKER": str(marker),
            "REPO_UNDER_TEST": str(repo),
            "UPLOADED_CONTENT": str(uploaded_content),
            "UPLOADED_SHA": str(uploaded_sha),
            "FAKE_CASK_BASE64": encoded_cask,
            "FAKE_CASK_JSON": json.dumps(
                {"sha": "retained-cask-sha", "content": encoded_cask}
            ),
        }
        return temporary, repo, environment

    def run_release(self, repo, environment, publish=False):
        command = ["/bin/bash", str(repo / "scripts" / "release.sh"), "v2.3.4"]
        if publish:
            command.extend([str(repo / "notes.md"), "--publish"])
        return subprocess.run(
            command,
            cwd=repo,
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_actual_release_dry_run_executes_helper_and_reaches_no_publish_exit(self):
        temporary, repo, environment = self.make_fixture()
        with temporary:
            result = self.run_release(repo, environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Dry run. Pass --publish", result.stdout)
            self.assertTrue((repo / "helper.marker").is_file())
            events = (repo / "events.log").read_text().splitlines()
            self.assertNotIn("cask-get", events)
            self.assertNotIn("release-create", events)
            self.assertNotIn("appcast", events)
            self.assertNotIn("tap-put", events)
            self.assertTrue(
                os.access(
                    repo / "build" / "Crisp.app" / "Contents" / "MacOS" / "crispctl",
                    os.X_OK,
                )
            )

    def test_helper_invocation_mutant_fails_through_actual_release_verifier(self):
        source = RELEASE.read_text()
        self.assertEqual(source.count(self.HELPER_CALL), 1)
        mutant = source.replace(self.HELPER_CALL, f"# MUTANT {self.HELPER_CALL}")
        temporary, repo, environment = self.make_fixture(release_source=mutant)
        with temporary:
            result = self.run_release(repo, environment)
            self.assertEqual(result.returncode, 68)
            self.assertIn("crispctl helper output missing", result.stderr)
            self.assertNotIn("Dry run. Pass --publish", result.stdout)

    def test_helper_failure_propagates_through_actual_release(self):
        temporary, repo, environment = self.make_fixture()
        with temporary:
            environment["FAKE_HELPER_FAIL"] = "1"
            result = self.run_release(repo, environment)
            self.assertEqual(result.returncode, 67)
            self.assertFalse((repo / "helper.marker").exists())

    def test_publish_rejects_unsupported_cask_before_any_publish_mutation(self):
        fixture = (
            ROOT / "Tests" / "DistributionTests" / "fixtures" / "crisp-legacy.rb"
        ).read_bytes()
        unsupported = fixture.replace(
            b'  version "1.5.1"\n',
            b'  on_arm { version "nested" }\n  version "1.5.1"\n',
        )
        temporary, repo, environment = self.make_fixture(
            cask_content=unsupported
        )
        with temporary:
            original_project = (repo / "project.yml").read_bytes()
            result = self.run_release(repo, environment, publish=True)
            events = (repo / "events.log").read_text().splitlines()

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported Ruby brace/block syntax", result.stderr)
            self.assertNotIn("project-mutate", events)
            self.assertNotIn("release-create", events)
            self.assertNotIn("appcast", events)
            self.assertNotIn("tap-put", events)
            self.assertEqual((repo / "project.yml").read_bytes(), original_project)

    def test_publish_fetch_and_decode_failures_precede_all_mutations(self):
        cases = (
            ("fetch", {"FAKE_CASK_GET_FAIL": "1"}, 72, ""),
            (
                "decode",
                {
                    "FAKE_CASK_JSON": json.dumps(
                        {"sha": "retained-cask-sha", "content": "not base64!"}
                    )
                },
                None,
                "invalid Homebrew cask response",
            ),
        )
        for label, overrides, returncode, error in cases:
            with self.subTest(label=label):
                temporary, repo, environment = self.make_fixture()
                with temporary:
                    environment.update(overrides)
                    original_project = (repo / "project.yml").read_bytes()
                    result = self.run_release(repo, environment, publish=True)
                    events = (repo / "events.log").read_text().splitlines()

                    self.assertNotEqual(result.returncode, 0)
                    if returncode is not None:
                        self.assertEqual(result.returncode, returncode)
                    if error:
                        self.assertIn(error, result.stderr)
                    self.assertNotIn("project-mutate", events)
                    self.assertNotIn("release-create", events)
                    self.assertNotIn("appcast", events)
                    self.assertNotIn("tap-put", events)
                    self.assertEqual(
                        (repo / "project.yml").read_bytes(), original_project
                    )

    def test_publish_prepares_cask_then_uses_retained_sha_and_exact_bytes(self):
        temporary, repo, environment = self.make_fixture()
        with temporary:
            environment["REQUIRE_CASK_PREFLIGHT"] = "1"
            result = self.run_release(repo, environment, publish=True)
            self.assertEqual(result.returncode, 0, result.stderr)

            events = (repo / "events.log").read_text().splitlines()
            ordered = [
                "cask-get",
                "project-mutate",
                "release-create",
                "appcast",
                "tap-put",
            ]
            self.assertEqual(
                [event for event in events if event in ordered], ordered
            )
            prepared = (repo / "build" / "crisp.rb").read_bytes()
            uploaded = base64.b64decode(
                (repo / "uploaded-cask.base64").read_bytes()
            )
            self.assertEqual(uploaded, prepared)
            self.assertEqual(
                (repo / "uploaded-cask.sha").read_text(), "retained-cask-sha"
            )
            self.assertIn(b'version "2.3.4"', prepared)
            self.assertIn(f'sha256 "{self.SHA256}"'.encode(), prepared)
            self.assertIn(
                b'binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"',
                prepared,
            )
            self.assertEqual(
                (repo / "project.yml").read_text(),
                'MARKETING_VERSION: "2.3.4"\n',
            )

    def test_moving_preflight_after_release_is_caught_on_production_path(self):
        source = RELEASE.read_text()
        self.assertIn(self.PREFLIGHT_MARKER, source)
        start = source.index(self.PREFLIGHT_MARKER)
        end = source.index("# Keep project.yml", start)
        preflight = source[start:end]
        without_preflight = source[:start] + source[end:]
        release_call = 'gh release create "$TAG" --title "Crisp ${TAG}" --notes-file "$NOTES" "$DMG"'
        insertion = without_preflight.index(release_call) + len(release_call)
        mutant = (
            without_preflight[:insertion]
            + "\n\n"
            + preflight.rstrip()
            + without_preflight[insertion:]
        )

        fixture = (
            ROOT / "Tests" / "DistributionTests" / "fixtures" / "crisp-legacy.rb"
        ).read_bytes()
        unsupported = fixture.replace(
            b'  version "1.5.1"\n',
            b'  on_arm { version "nested" }\n  version "1.5.1"\n',
        )
        temporary, repo, environment = self.make_fixture(
            release_source=mutant, cask_content=unsupported
        )
        with temporary:
            result = self.run_release(repo, environment, publish=True)
            events = (repo / "events.log").read_text().splitlines()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release-create", events)
            self.assertIn("unsupported Ruby brace/block syntax", result.stderr)


class ReleaseWiringTests(unittest.TestCase):
    def test_release_invokes_behaviorally_tested_helper_before_enclosing_signatures(self):
        source = RELEASE.read_text()
        helper_call = source.index(
            '"$ROOT/scripts/build-embed-sign-crispctl.sh" "$ROOT" "$APP" '
            '"$CRISPCTL_SCRATCH" "${CRISP_SIGN_ID:-}"'
        )
        sparkle_sign = source.index('for item in "${SPARKLE_NESTED[@]}"')
        developer_app_sign = source.index(
            '--entitlements Crisp/Crisp.entitlements --sign "$CRISP_SIGN_ID" "$APP"'
        )
        ad_hoc_app_sign = source.index(
            'codesign --force --sign - --entitlements Crisp/Crisp.entitlements "$APP"'
        )
        verifier = source.index('"$ROOT/scripts/verify-release-app.sh" "$APP"')

        self.assertLess(helper_call, sparkle_sign)
        self.assertLess(helper_call, developer_app_sign)
        self.assertLess(helper_call, ad_hoc_app_sign)
        self.assertGreater(verifier, developer_app_sign)
        self.assertGreater(verifier, ad_hoc_app_sign)
        self.assertNotIn(
            "xcrun swift build --disable-sandbox -c release --product crispctl",
            source,
        )
        self.assertNotIn('codesign --force --sign - "$CRISPCTL_APP_BINARY"', source)

    def test_publish_uses_tested_cask_transformer(self):
        source = RELEASE.read_text()
        helper = source.index('scripts/update-homebrew-cask.py')
        upload = source.index('gh api -X PUT "repos/$TAP_REPO/contents/$TAP_CASK"')
        self.assertLess(helper, upload)
        self.assertNotIn('| sed -e "s/version', source)


class ReleaseArtifactVerifierTests(unittest.TestCase):
    def make_fixture(self, archs="arm64 x86_64", executable=True):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        app = root / "Crisp.app"
        cli = app / "Contents" / "MacOS" / "crispctl"
        cli.parent.mkdir(parents=True)
        cli.write_text("fixture")
        cli.chmod(0o755 if executable else 0o644)

        tools = root / "bin"
        tools.mkdir()
        lipo = tools / "lipo"
        lipo.write_text(f"#!/bin/sh\nprintf '%s\\n' '{archs}'\n")
        lipo.chmod(0o755)
        codesign = tools / "codesign"
        codesign.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CODESIGN_LOG\"\n"
        )
        codesign.chmod(0o755)
        log = root / "codesign.log"
        environment = os.environ.copy()
        environment["PATH"] = f"{tools}:{environment['PATH']}"
        environment["CODESIGN_LOG"] = str(log)
        return temporary, app, log, environment

    def run_verifier(self, app, environment):
        return subprocess.run(
            [str(VERIFIER), str(app)],
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_accepts_executable_two_arch_cli_and_verifies_app_signature(self):
        temporary, app, log, environment = self.make_fixture()
        with temporary:
            result = self.run_verifier(app, environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                log.read_text().strip(), f"--verify --deep --strict {app}"
            )

    def test_rejects_missing_architecture(self):
        temporary, app, _, environment = self.make_fixture(archs="arm64")
        with temporary:
            result = self.run_verifier(app, environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("arm64 and x86_64", result.stderr)

    def test_rejects_non_executable_cli(self):
        temporary, app, _, environment = self.make_fixture(executable=False)
        with temporary:
            result = self.run_verifier(app, environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not executable", result.stderr)

    def test_rejects_missing_cli(self):
        temporary, app, _, environment = self.make_fixture()
        with temporary:
            (app / "Contents" / "MacOS" / "crispctl").unlink()
            result = self.run_verifier(app, environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing or not executable", result.stderr)

    def test_strict_codesign_failure_propagates_nonzero(self):
        temporary, app, _, environment = self.make_fixture()
        with temporary:
            codesign = Path(environment["PATH"].split(":", 1)[0]) / "codesign"
            codesign.write_text("#!/bin/sh\nexit 45\n")
            codesign.chmod(0o755)
            result = self.run_verifier(app, environment)
            self.assertEqual(result.returncode, 45)

    def test_architecture_tool_failure_propagates_even_with_valid_looking_output(self):
        temporary, app, _, environment = self.make_fixture()
        with temporary:
            lipo = Path(environment["PATH"].split(":", 1)[0]) / "lipo"
            lipo.write_text("#!/bin/sh\nprintf '%s\\n' 'arm64 x86_64'\nexit 46\n")
            lipo.chmod(0o755)
            result = self.run_verifier(app, environment)
            self.assertEqual(result.returncode, 46)


if __name__ == "__main__":
    unittest.main()
