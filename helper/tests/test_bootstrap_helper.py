from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = REPOSITORY_ROOT / "scripts" / "bootstrap-helper.sh"


class BootstrapHelperTests(unittest.TestCase):
    def test_bootstrap_resolves_flat_packaged_assets_before_repository_assets(self):
        script = BOOTSTRAP.read_text(encoding="utf-8")

        self.assertIn('ASSET_DIRECTORY="$SCRIPT_DIR"', script)
        self.assertIn('ASSET_DIRECTORY="$REPOSITORY_ROOT/helper"', script)
        self.assertIn('MANIFEST="$ASSET_DIRECTORY/runtime-manifest.json"', script)
        self.assertIn('REQUIREMENTS="$ASSET_DIRECTORY/requirements.lock"', script)

        packaged = script.index('ASSET_DIRECTORY="$SCRIPT_DIR"')
        repository = script.index('ASSET_DIRECTORY="$REPOSITORY_ROOT/helper"')
        manifest = script.index(
            'MANIFEST="$ASSET_DIRECTORY/runtime-manifest.json"'
        )
        requirements = script.index(
            'REQUIREMENTS="$ASSET_DIRECTORY/requirements.lock"'
        )

        self.assertLess(packaged, repository)
        self.assertLess(repository, manifest)
        self.assertLess(manifest, requirements)

    def test_bootstrap_uses_clean_macos_tools_and_builds_venv_at_final_path(self):
        script = BOOTSTRAP.read_text(encoding="utf-8")

        self.assertNotIn("/usr/bin/python3", script)
        self.assertIn("/usr/bin/plutil -extract url raw", script)
        self.assertIn("/usr/bin/plutil -extract sha256 raw", script)
        self.assertIn("/usr/bin/plutil -extract archiveSize raw", script)
        self.assertNotIn('"$STAGING/venv"', script)

        place_runtime = script.index(
            'mv "$STAGING/python" "$RUNTIME_DESTINATION/python"'
        )
        create_venv = script.index(
            '"$RUNTIME_DESTINATION/python/bin/python3" -m venv '
            '"$RUNTIME_DESTINATION/venv"'
        )
        launch_final_interpreter = script.index(
            '"$RUNTIME_DESTINATION/venv/bin/python" -c'
        )
        mark_ready = script.index('mv "$READY_TEMP" "$RUNTIME_READY"')

        self.assertLess(place_runtime, create_venv)
        self.assertLess(create_venv, launch_final_interpreter)
        self.assertLess(launch_final_interpreter, mark_ready)
        self.assertIn('rm -rf -- "$RUNTIME_DESTINATION"', script)


if __name__ == "__main__":
    unittest.main()
