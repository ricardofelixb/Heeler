# Self-hosted iOS CI (personal fork)

The fork uses one repository-scoped macOS/ARM64 runner, `heeler-mac-mini-arm64`,
labelled `heeler-ios`. Lightweight Linux/Node jobs remain GitHub-hosted. Release
signing/upload jobs are unchanged.

## Trust boundary — read before enabling

**This is a persistent, root-capable runner on Ricardo's development Mac, running
as Ricardo. It can access that account's files and credentials. It is not a sandbox.**
The SSH E2E harness must create temporary users, groups, ownership and root sshd
fixtures. Its approved sudo policy permits those command executables without a
password, not a general shell or `NOPASSWD: ALL`; several still confer root.
Do not use this configuration for untrusted code or a shared production machine.

Repository Actions settings must require approval for **all external contributors**
(`approval_policy: all_external_contributors`), including previously approved fork
contributors. The checked-in workflows route external fork PRs to hosted runners,
but a PR can modify its workflow: the routing condition alone is not a security
boundary. **Never approve an untrusted workflow onto this Mac.** Review workflow
changes and executable code before approving external contributions. No
`pull_request_target` checkout or auto-approval job is involved.

## Machine setup

- macOS/Apple Silicon, Xcode 26.x at `/Applications/Xcode.app`, an available iOS 26
  runtime, Node and Python >= 3.12 on the runner's captured PATH (currently Python
  3.13.12). Workflows provision Node 24; hosted jobs provision Python 3.12. Native
  jobs validate the existing Python instead: GitHub's macOS Python archives assume
  `/Users/runner` and cannot be installed unchanged under Ricardo's account.
- Install the official [GitHub runner](https://github.com/actions/runner/releases)
  for `osx-arm64`, verifying its published SHA256 digest. Register with this
  repository only, name `heeler-mac-mini-arm64`, custom label `heeler-ios` and the
  default `_work` directory. Leave automatic runner updates enabled.
- Current installation: `~/actions-runner-heeler`, mode 0700; credential files are
  private. Use its `./svc.sh install`, `start`, `status`, `stop` as the runner user,
  **not root**. This is a per-user LaunchAgent: it starts on user login, not an
  unattended pre-login boot. Keep the Mac awake and that user logged in for CI.
  It neither replaces nor reconfigures the other repositories' runner services.
- macOS also requires **Full Disk Access** for the runner's responsible process:
  `~/actions-runner-heeler/externals/node24/bin/node`. In System Settings → Privacy
  & Security → Full Disk Access, use `+` and Cmd-Shift-G to select that exact file,
  enable it, then restart this runner's service. This is a separate, broad privacy
  grant, not implied by sudo; approve it explicitly. Runner binary updates may
  require reapproval. Without it, TCC denies Directory Service changes and
  `sysadminctl` can hang after “Assigning UID” even as root. Do not work around this
  by editing TCC databases, disabling SIP, or granting access to unrelated runners.
- Review, then install the fixture policy once in a real Mac Terminal:

  ```sh
  /bin/bash scripts/install-self-hosted-ios-sudoers.sh --print ricardo
  sudo /bin/bash scripts/install-self-hosted-ios-sudoers.sh ricardo
  sudo -n /usr/bin/true
  ```

  Only the second line needs interactive admin authentication. Never send that
  password or a runner registration token in chat/logs. The policy is installed
  at `/private/etc/sudoers.d/heeler-ios-ricardo`; a different existing policy or
  symlink is rejected rather than overwritten.

## Repository setup

Set Actions fork-contributor approval before enabling the runner:

```sh
gh api --method PUT repos/ricardofelixb/Heeler/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
gh variable set HEELER_IOS_SELF_HOSTED --body true --repo ricardofelixb/Heeler
```

The variable is opt-in; upstream/other forks without it retain hosted execution.
Internal PRs/pushes use one serial `App tests (all)` build plus the complete
HeelerSSH package suite, queued on this single worker. Coverage aggregation must
verify the serial evidence; no tests become optional or skipped. Manual dispatch
still supports explicit sharded/serial layout and cold/warm dependency modes.
Diagnostics use the same runner but retain their separate, non-merge-gate evidence.

## Isolation and reuse

`prepare-self-hosted-ios.sh` fails early if non-interactive fixture privileges or
the expected Xcode/runtime are missing. It selects/creates only **Heeler CI iPhone
17**, exports its UDID, and never erases, shuts down or resets an interactive
simulator. The existing test harness owns fixture ports/users, per-run derived
data, evidence, simulator locks and cleanup. Only one Heeler job executes at once;
other repository runners can still consume this Mac's resources.

SwiftPM **sources** persist outside the checkout under
`$RUNNER_TOOL_CACHE/heeler-source-packages`. Compiled products and test evidence
are not reused as proof of a new run. Manual cold mode uses an empty directory in
`$RUNNER_TEMP`; hosted runners keep their existing `actions/cache` behavior.
Native build/preparation overlap is disabled to reduce memory pressure on this
8 GB Mac. No global simulator reset, sleep-policy change, or cleanup of other
runners' workspaces is performed.

## Operate / roll back

```sh
cd ~/actions-runner-heeler
./svc.sh status
# Pause this repository's worker only:
./svc.sh stop
# Resume:
./svc.sh start
```

Set `HEELER_IOS_SELF_HOSTED=false` to route subsequent jobs back to hosted Macs
without changing workflow code. Already queued jobs keep their original labels;
cancel/re-run those separately. Retiring the installation also requires removing
its registration/service and the explicitly approved sudoers policy; don't leave
an unused root-capable policy behind.

Focused checks:

```sh
python3 scripts/test-self-hosted-ios.py
bash scripts/test-ci-ios-diagnostics.sh
bash -n scripts/prepare-self-hosted-ios.sh scripts/install-self-hosted-ios-sudoers.sh
```

The first native PR run is the end-to-end acceptance check: full app/package
coverage must pass on `heeler-mac-mini-arm64` before merging.
