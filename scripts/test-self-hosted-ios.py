#!/usr/bin/env python3
"""Runner routing and root-policy regressions. No Xcode, admin access, or PyYAML."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
CI = (ROOT / ".github/workflows/ci.yml").read_text()
DIAGNOSTICS = (ROOT / ".github/workflows/ci-diagnostics.yml").read_text()


def expression(line):
    return re.search(r"\$\{\{ (.*) \}\}", line).group(1)


def evaluate(source, *, enabled=True, fork=False, event="pull_request", layout=""):
    values = {"vars.HEELER_IOS_SELF_HOSTED": "true" if enabled else "",
              "github.event_name": event, "github.repository": "owner/repo",
              "github.event.pull_request.head.repo.full_name": "external/repo" if fork else "owner/repo",
              "inputs.layout": layout}
    source = re.sub(r"\b(?:vars|github|inputs)\.[\w.]+",
                    lambda match: repr(values[match.group()]), source)
    source = source.replace("&&", " and ").replace("||", " or ")
    # Only the checked-in workflow expressions, with no builtins or user-provided expressions.
    return eval(source, {"__builtins__": {}, "fromJSON": json.loads})


class SelfHostedIOSTests(unittest.TestCase):
    def test_all_native_jobs_use_the_same_opt_in_and_external_fork_boundary(self):
        routes = [expression(line) for text in (CI, DIAGNOSTICS) for line in text.splitlines()
                  if "runs-on: ${{" in line]
        self.assertEqual(len(routes), 3)
        self.assertEqual(len(set(routes)), 1)
        for route in routes:
            self.assertEqual(evaluate(route), ["self-hosted", "macOS", "ARM64", "heeler-ios"])
            for settings in ({"enabled": False}, {"fork": True}):
                self.assertEqual(evaluate(route, **settings), ["macos-26"])
            for event in ("push", "workflow_dispatch"):
                self.assertEqual(evaluate(route, event=event)[-1], "heeler-ios")

    def test_default_layout_and_coverage_aggregator_always_agree(self):
        shard = expression(next(line for line in CI.splitlines() if "shard: ${{ fromJSON" in line))
        coverage = expression(next(line for line in CI.splitlines() if "LAYOUT: ${{" in line))
        for enabled in (False, True):
            for fork in (False, True):
                for layout in ("", "serial", "sharded"):
                    settings = dict(enabled=enabled, fork=fork, layout=layout)
                    shards = evaluate(shard, **settings)
                    expected = "serial" if shards == ["all"] else "sharded"
                    self.assertEqual(evaluate(coverage, **settings), expected, settings)
        self.assertEqual(evaluate(shard), ["all"])
        self.assertEqual(len(evaluate(shard, fork=True)), 3)

    def test_only_self_hosted_steps_prepare_resources_and_skip_cloud_source_cache(self):
        self.assertEqual(CI.count("if: runner.environment == 'self-hosted'"), 2)
        self.assertEqual(DIAGNOSTICS.count("if: runner.environment == 'self-hosted'"), 1)
        self.assertIn("runner.environment != 'self-hosted' &&", CI)
        helper = (ROOT / "scripts/prepare-self-hosted-ios.sh").read_text()
        self.assertIn('name = "Heeler CI iPhone 17"', helper)
        self.assertIn("HEELER_CI_OVERLAP_BUILD=0", helper)
        self.assertIn('sudo -n /usr/bin/true', helper)
        for forbidden in ("simctl erase", "simctl shutdown", "simctl delete", "killall"):
            self.assertNotIn(forbidden, helper)

    def test_native_jobs_do_not_run_the_hosted_python_installer(self):
        for source, expected in ((CI, 2), (DIAGNOSTICS, 1)):
            native_preparations = source.split("      - name: Prepare isolated self-hosted resources")[:-1]
            self.assertEqual(len(native_preparations), expected)
            for before in native_preparations:
                python_step = before.rsplit("      - uses: actions/setup-python@v6", 1)[1]
                self.assertIn("if: runner.environment != 'self-hosted'", python_step)
        helper = (ROOT / "scripts/prepare-self-hosted-ios.sh").read_text()
        self.assertIn("sys.version_info >= (3, 12)", helper)

    def policy(self, *arguments):
        return subprocess.run(["/bin/bash", str(ROOT / "scripts/install-self-hosted-ios-sudoers.sh"),
                               "--print", *arguments], text=True, capture_output=True)

    def test_policy_can_be_reviewed_without_root_and_does_not_grant_general_shell(self):
        user = subprocess.check_output(["id", "-un"], text=True).strip()
        if user == "root":
            # GitHub Ubuntu uses runner; local root-only environments can still check rejection below.
            self.skipTest("Policy deliberately rejects root as the runner user")
        result = self.policy(user)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{user} ALL=(root) NOPASSWD: HEELER_IOS_FIXTURES", result.stdout)
        self.assertIn("/usr/sbin/sshd", result.stdout)
        self.assertIn("/usr/sbin/sysadminctl", result.stdout)
        self.assertNotIn("NOPASSWD: ALL\n", result.stdout)
        self.assertNotIn("/bin/bash", result.stdout)
        self.assertIn("Root-capable", result.stdout)

    def test_policy_rejects_root_and_sudoers_injection(self):
        for value in ("root", "bad\nALL ALL=(ALL) ALL", "user:group", "../root", "-user", "user name"):
            self.assertEqual(self.policy(value).returncode, 2, value)
        self.assertEqual(self.policy().returncode, 2)


if __name__ == "__main__":
    unittest.main()
