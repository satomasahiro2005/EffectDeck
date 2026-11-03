# Contributing

An issue on its own is plenty. You do not have to send code.

## Written with an AI is fine

Issues, pull requests, either one. I am not asking you to declare it, and it counts
the same as anything else.

The one thing I do ask: **run it on a device first.** The extension needs iOS 27 and
no audio flows in the simulator, so a change can look right in the diff and still pass
silence through. Say which device and which iOS version you tried it on.

Running it on a device means you need a paid Apple Developer Program membership.
A free Apple ID (Personal Team) is not enough: the extension needs the
`com.apple.developer.media-device-extension` entitlement (see
`Sources/Extension/Extension.entitlements`), and Apple gates that behind a paid
account. `Scripts/build.sh` will not get past code signing without one.

The tests below need neither a device nor a paid account. Running them is a real way to
help even without the membership.

## Issues

Say what you were playing from (Spotify, Safari, a podcast app), what was in the chain,
and what you heard. If picking EffectDeck shows Unable to Connect or the output switches
back, read **If it says Unable to Connect** in the README first — it is usually Spotify's
Canvas.

## Pull requests

`bash Scripts/build.sh` builds and installs on the attached device. `bash Scripts/setup.sh`
generates the Xcode project. Both are in the README under **Building**.

Run the tests that cover what you changed. If you change a generator in `Tools/`, or
anything a generator reads, run `bash Scripts/setup.sh` and commit what it regenerates
(`Sources/EffeTuneLive/Generated/`, `chain/`); CI fails when the committed files differ
from a fresh run. The same goes for the golden files under `Tests/Fixtures` (see
**Golden files** below).

`site/` is the official website (a Cloudflare Worker). You do not need it to build the app.

## Running the tests

| Suite | Needs | Covers |
|---|---|---|
| Logic tests | Mac, Xcode 27, xcodegen | Everything in `Tests/Unit`, the JSFX host included |
| Linux harness | Swift 6 on Linux or WSL | The Foundation-only part of the same tests |
| Native tests | CMake 3.24, gcc or clang | The plain C code under `Sources/` |
| Website | Node 22 | `site/` |
| Tool and script tests | Python 3.10+, Node 22, bash | The generators and checks in `Tools/`, and the simulator helpers in `Scripts/` |
| UI tests | Mac, Xcode 27, xcodegen | The app on a simulator, without the extension |

### Logic tests (Mac)

```bash
bash Scripts/test.sh                          # everything in Tests/Unit
bash Scripts/test.sh PipelineRulesTests       # one class (several may follow)
bash Scripts/test.sh ChainTextTests/testWholeReplyWithFence   # one test
SIM="iPhone 17 Pro" bash Scripts/test.sh      # another simulator, by exact name
```

This runs the `Logic` scheme (`EffeTuneLiveUnitTests`) on one simulator. It runs
`Scripts/setup.sh` first (patches, generated files, xcodegen); `SKIP_SETUP=1` skips all of
that except xcodegen. `SAN=address`, `SAN=thread` or `SAN=undefined` turns on a sanitizer;
`SAN=address,undefined` combines two, but address and thread cannot run together.
`DRY_RUN=1` prints what would run and changes nothing.

The default simulator is `iPad Pro 13-inch (M5)`, the one CI uses. `SIM` takes a name,
which must match exactly, or a UDID; when nothing matches, the script stops and lists the
simulators it found. `SIM_OS=27.0` picks between two simulators with the same name.
Other simulators that are running are shut down, so that Xcode never starts a second one.

From Xcode: run `bash Scripts/setup.sh`, open `EffeTuneLive.xcodeproj`, pick the **Logic**
scheme and an iOS 27 simulator, and press ⌘U. The scheme builds only the test bundle, not
the app or the extension. Run `setup.sh` again after pulling: the JSFX sandbox tests
exercise the ysfx patch it applies, and a tree without it runs different code.

The whole log is `test.log` and the result bundle is `build/Logic.xcresult`. The run
passed when the script exits 0 and `test.log` says `** TEST SUCCEEDED **`.

A simulator build needs no paid account. If Xcode still asks for the team in
`DEVELOPMENT_TEAM`, pass `XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO"`, as CI does.

### Linux harness (Linux, WSL)

```bash
bash Tests/Linux/run.sh --name local                           # all of it
bash Tests/Linux/run.sh --name local --filter PipelineStoreTests
bash Tests/Linux/run.sh --name local --sanitize=address
```

From Windows, run it inside WSL: `wsl -e bash /mnt/c/<path to the clone>/Tests/Linux/run.sh
--name local`. In Git Bash, prefix `MSYS_NO_PATHCONV=1` so the `/mnt/c` path is not
rewritten. `-e` keeps a `--filter` regex such as `A|B` away from the shell.

It copies the Logic bundle into a SwiftPM package and runs `swift test` in Swift 5 mode.
The file list comes from the `EffeTuneLiveUnitTests` target in `project.yml`, minus the
C and C++ files and `JSFX*Tests`, which need ysfx and the Mac. `os`, `Accelerate`,
`CryptoKit` and `Compression` are replaced by small stand-ins in `Tests/Linux/Shims`.

- Needs Swift 6 (swiftly works), python3 and the zlib headers.
- The log is `build/linux-unit-<name>.log`. Each `--name` builds in its own
  `~/.cache/effectdeck-linux/<name>/`, so two runs with different names do not collide.
- New test files in `Tests/Unit` are picked up on their own. A new source file or
  fixture that `project.yml` does not list yet is passed with `--add <path>`.
- `Tests/Linux/skip.txt` lists, with a reason, the tests that fail only because Linux's
  Foundation differs from Apple's. Nothing else goes there, and app code is never changed
  to make Linux pass.
- The vDSP stand-in is a substitute. For `FIRDesign`, only the Mac result counts.

### Native tests

```bash
cd Tests/Native
cmake --preset asan && cmake --build --preset asan && ctest --preset asan        # ASan + UBSan
cmake --preset tsan && cmake --build --preset tsan && ctest --preset tsan        # TSan, threaded tests only
cmake --preset engine && cmake --build --preset engine --parallel 4 && ctest --preset engine  # also the real engine
```

These build the plain C files under `Sources/` with gcc or clang, without Xcode. The presets
are in `Tests/Native/CMakePresets.json`; `plain` has no sanitizer and also builds with
MSVC. Build directories are `build/native-<preset>` at the top of the repository.

- The tests that use a stand-in engine read `effetune/abi.h`, so the `Vendor/effetune`
  submodule must be checked out.
- `engine` also builds the pinned EffeTune engine with the patches from `Patches/` applied
  to a copy under the build directory; `Vendor/effetune` itself is not touched. It needs a
  POSIX system. It unpacks the pinned revision with `Tools/golden/extract_pin.sh`, which
  reads the submodule's git objects, so it runs in a clone; elsewhere, pass an unpacked
  copy with `-DET_NATIVE_EFFETUNE_ROOT=<dir>` (the directory that contains `dsp/`). It
  compiles all of upstream's DSP under ASan, up to about 300 MB per file, so give
  `--parallel` a number. The preset uses Make on Linux, and a bare `--parallel` becomes
  `make -j`, which starts every file at once and can run out of memory.
- If a sanitizer dies at startup on a kernel with 32 bits of mmap randomization (Ubuntu
  24.04 does this), run `sudo sysctl -w vm.mmap_rnd_bits=28` first; CI does the same.

### Website

```bash
cd site
npm ci
npm test
```

wrangler and miniflare need Node 22 or later.

### Tool and script tests

```bash
python3 -m unittest discover -s Tests/Tools   # the generators and checks in Tools/
node --test Tools/*.test.mjs                  # the Node tools in Tools/
python3 Tools/check_repo.py                   # facts that must agree across the repository
bash Tests/Scripts/sim_test.sh                # the shell scripts in Scripts/, against fakes
```

None of them need a Mac or a network, and all of them run on Windows too (the last one in
Git Bash or WSL). Run them in a clone: `check_repo.py` asks git which paths are ignored.
They also run without the submodules, but then a few checks skip (see below).

- `Tests/Tools` runs the generators and checks in `Tools/` on small inputs in a temporary
  directory. Nothing tracked is written. A test that cannot run here is reported as
  skipped, not failed, so read the skip count:
  - Without the submodules, the three that compare committed files with `Vendor/`: the
    presets written by `gen_presets.py` and `gen_effect_presets.py`, and the `Base64.hpp`
    copy in `gen_licenses.py`. If you change one of those generators, run the suite with
    the submodules checked out.
  - Without `cc` and `nm`, as on Windows, the privacy-manifest tests that compile a small
    binary.
  - On Windows, the `check_release_binary.py` tests that run a fake `nm` and `codesign`,
    or its bash wrapper. Its tests on real linker output need `clang`, `ld64.lld` and
    `llvm-nm` (one of them also `llvm-strip`) on any system.
  - Without `node`, `git` or PyYAML, the tests that call them.
- `check_repo.py` compares facts that are written in more than one place: the EffeTune
  version in the README badge, `CHAIN.md` and `chain/`; the URLs in the app against what
  `site/` serves; the bundled components against `NOTICE.md`; the repository paths that
  documents and comments cite. The top of the file lists every check, and
  `--only chain,urls` runs just the named ones. `--version-guard` also compares with the
  `dsp-v*` tag of the pinned `Vendor/effetune`, so it needs that submodule. `--base <rev>`
  checks that every `chain/v*` of that revision is still there with the same `dspParams`.
- `sim_test.sh` replaces `xcrun`, `xcodebuild`, `xcodegen`, `setup.sh`, `security`,
  `curl` and the other Mac tools with fakes, and runs the scripts in `Scripts/` against
  them: `Scripts/lib/sim.sh`, the test, build and screenshot scripts, and the archive and
  release scripts. `Tools/asc.py` runs for real against a fake App Store Connect
  (`Tests/Scripts/asc_fake_api.py`). So the way the scripts pick a simulator, call Xcode
  and stop on failure is checked without a Mac.

### Golden files

Some Logic tests compare the Swift code with what upstream's JavaScript computes for the
same input. The expected values are JSON files under `Tests/Fixtures`, made by the
generators in `Tools/golden/` and `Tools/ir_prepare_golden.mjs`. To make them again:

```bash
root=$(bash Tools/golden/extract_pin.sh)
for f in Tools/golden/*_golden.mjs Tools/ir_prepare_golden.mjs; do
  EFFETUNE_ROOT="$root" node "$f"
done
```

`extract_pin.sh` unpacks upstream at the revision the repository pins (`git archive`), not
the working tree of `Vendor/effetune`, which `setup.sh` has patched. The generators write
sorted, deterministic JSON, so running them again on the same pin changes nothing. The
`generated` job in CI does exactly this and fails on any difference.

### UI tests (Mac)

```bash
bash Scripts/uitest.sh MenuProbe                          # one class (several may follow)
bash Scripts/uitest.sh DynamicProbe/test03ExpandCollapse  # one test
bash Scripts/uitest.sh                                    # SmokeTests
```

With no argument the script runs `SmokeTests`, which is not in `Tests/UI` yet, so that run
tests nothing. Name a class until it is.

The simulator SDK has no `MediaDevice.framework`, so the app is built from a simulator
project without the extension: `Tools/gen_sim_spec.py` writes `project-sim.yml`, and
xcodegen makes `EffeTuneLiveSim.xcodeproj` from it. Open that project, not
`EffeTuneLive.xcodeproj`, to run the UI tests from Xcode. The same `SIM`, `SIM_OS`,
`SKIP_SETUP`, `XCODEBUILD_EXTRA` and `DRY_RUN` variables as `Scripts/test.sh` apply. The app
is reinstalled before the run. The log is `uitest.log`, the result bundle is
`build/UITest.xcresult` and the build goes to `DerivedData/`.

## CI

GitHub Actions, on every push to `main` and every pull request. No secrets; nothing is
signed. (Releases are a separate workflow, `release.yml`; see [Releasing](#releasing).)

`.github/workflows/ci.yml`:

| Job | What it checks |
|---|---|
| `site` | `npm ci` and `npm test` on Node 22 |
| `checks` | Python and shell syntax, shellcheck, actionlint, the unit tests in `.github/scripts`, the script tests in `Tests/Scripts`, `Tools/check_repo.py` (plus `--base` against the previous commit), `Tests/Tools` and `Tools/*.test.mjs` |
| `native` | The native tests with gcc and clang, each under ASan+UBSan and TSan |
| `linux-swift` | The Linux harness in the `swift:6.4.0-noble` image, plain and with ASan |
| `generated` | Runs `Scripts/setup.sh` (without xcodegen) and the golden generators with both submodules at the pin, then fails if any committed file changed. Also `check_repo.py --version-guard` |
| `macos (logic)` | The Logic tests on an iOS 27 simulator |
| `macos (sim-build)` | Builds the app for the simulator without the extension |

The macOS jobs run on GitHub's `xcode-27` image, the only one with the iOS 27 SDK (the
deployment target is 27.0). It is a preview image, so the workflow pins the Xcode with
`xcode-select` and stops if the iOS 27 SDK is missing. The label is in one place, the
`runs-on` of the `macos` job; the comment at the top of `ci.yml` says what to change
with it.

`macos (logic)` runs the same scheme on the same simulator as `Scripts/test.sh`, so
`XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO" bash Scripts/test.sh` is the local equivalent.
CI retries a failed test once (`-retry-tests-on-failure`); the script does not.

The UI tests are not run in CI. Run them yourself when you change what they cover.

### Releasing

`.github/workflows/release.yml` builds, signs and uploads to App Store Connect. It is the
normal path; `Scripts/ship.sh` on the Mac is the local fallback. Nothing in it adds a build
to the external "EffectDeck Public Beta" group or submits anything for review.

TestFlight (purple, `Beta` configuration):

1. If the version is already closed in App Store Connect, run `python3 Tools/gen_version.py --today`,
   commit and push to `main`. The version is the day, and a closed version cannot take another build.
2. Wait for CI to go green on that `main` commit.
3. `git tag tf-YYYY.MM.DD-NN <sha> && git push origin tf-YYYY.MM.DD-NN`. The date in the tag must
   equal `MARKETING_VERSION`.
4. Approve the run in GitHub (the `release` environment has a required reviewer). Until then
   nothing is signed or uploaded.
5. The workflow archives (ad-hoc signed), exports with manual signing (see below), runs
   `Tools/check_release_binary.py`, uploads, waits for processing and adds the build to the
   internal group "Internal". The build number is the highest in App Store Connect plus one; it
   is not committed.

App Store build (blue, `Release`): Actions, Release, Run workflow on `main` with `flavor=store`.
`dry_run` is on by default; it archives, exports and checks the build and runs `altool --validate-app`
but uploads nothing. Untick it to upload.

Adding a build to Public Beta, attaching it to a version and submitting for review stay manual
(`python3 Tools/asc.py attach …`). The ipa and the archive are never uploaded as artifacts,
because the repository is public.

Signing is manual, with the same options as `~/signing/export.plist` used by `Scripts/ship.sh`
(`Scripts/ExportOptions-ci.plist`). The archive is ad-hoc signed, so no "Apple Development: Created
via API" certificate is made. The export is signed with the Apple Distribution certificate, which lives
as a p12 in the `release` environment secrets (`DIST_P12_BASE64`, `DIST_P12_PASSWORD`) and goes
into a throwaway keychain for the run. The three App Store profiles are fetched at run time with
`python3 Tools/asc.py profile <name> <bundle-id> <dir>` (it requires exactly one ACTIVE profile that
includes that certificate), so they are not stored. The export gets no API key and the run fails if
its log says "Cloud signing". The API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) is also
only in the `release` environment. At the end of every run the keychain (with the search list and
default restored), the installed profiles and the key are removed. The certificate lists before and
after the run are compared and a change is a warning.

When the Apple Distribution certificate is renewed (it is valid to 2027-09-15), update `DIST_P12_*`
and `DIST_CERT_ID` in `Tools/asc.py`, and regenerate the profiles in the developer portal.

`.github/workflows/dsp.yml` runs upstream's own DSP test suite on `Vendor/effetune` with
our patches applied, in Debug and with ASan+UBSan. It runs nightly and when `Patches/`,
`Vendor/`, `Sources/Shared/`, `Tests/Native/` or `Scripts/setup.sh` change.

## About the DSP under `Vendor/effetune`

That code is EffeTune's, not this project's. If something looks wrong in there, raise it
here first. This host uses that code in ways upstream never intended, so most of what
looks like a DSP bug turns out to be ours.

**Do not report it upstream until you have reproduced it in EffeTune itself** — the
desktop or web build, without this app in the picture. Upstream is not responsible for
EffectDeck and must not be made to carry its bugs.
