# S01 platform and stage tools

Run these commands from the repository root. Install the pinned Python dependency
with `python3 -m pip install -r requirements-dev.txt` if PyYAML is unavailable.

```sh
./tools/platform validate --profile linux-x86_64
./tools/platform describe --profile android-arm64
./tools/platform generate --profile linux-x86_64
PHOTO_FLUTTER_ROOT=/path/to/flutter ./tools/platform build --profile linux-x86_64 --mode release
PHOTO_FLUTTER_ROOT=/path/to/flutter ./tools/platform run --profile linux-x86_64 --mode debug -- --example-application-argument
python3 -B -m unittest discover -s tests/platform -p 'test_*.py' -v
./tools/acceptance run --stage S01 --evidence-dir /path/to/fresh-evidence-directory
```

`--mode` defaults to `debug`; both `debug` and `release` are accepted. `run`
performs a build, then locates the single executable at the bundle root and
forwards arguments following `--` literally. Application arguments must be
supported by the application itself.

`--profile-file /path/to/profile.yaml` replaces the named configuration and is
useful for negative tests. All fields and nested keys are mandatory and strict;
unknown fields, duplicate keys, aliases, unsafe YAML tags, scalar type mismatches,
and incoherent target/adapter/resource combinations fail before application data
is opened. All numeric limits must be positive u32 integers (at most
4,294,967,295), and `gallery_rows_limit` must be at most 2,000. Active Linux
profiles require a Linux x86_64 host. Planned profiles
can be inspected/generated but cannot be built or run; changing Android/Windows
to `active` is rejected until the corresponding implementation is integrated.

Generation writes `.build/<profile>/profile.json` as compact, recursively sorted
UTF-8 JSON with no trailing newline. SHA-256 is calculated over exactly those
bytes. `dart-defines.json` contains three string values:

- `PHOTO_PROFILE_JSON`: the canonical JSON string.
- `PHOTO_PROFILE_DIGEST`: its lowercase SHA-256 hex digest.
- `PHOTO_BRIDGE_PROTOCOL_VERSION`: `1`.

Build exports these same three values for the Rust build script and Flutter
process. Flutter receives the generated defines with `--dart-define-from-file`.
The fixed sequence is `cargo build --locked -p photo-bridge [--release]`, then
`flutter --no-version-check build linux --debug|--release`.
The global SDK update check is disabled to keep builds independent of the
GitHub version-check request. Cargo's target directory is fixed to
`<repository>/target`, yielding `target/<mode>/libphoto_bridge.so`.
`PHOTO_NATIVE_LIB_DIR` is exported as `<repository>/target/<mode>` for the native
bundle installation step. Flutter is
resolved from `PHOTO_FLUTTER_ROOT/bin/flutter` if configured; otherwise PATH is
used. An invalid explicit Flutter root fails rather than silently using another
SDK. Cargo and other native build dependencies must be available on PATH.

The runner/CMake integration owns installing the native library into Flutter's
bundle. A successful build command describes produced paths and does not certify
installation dependencies, packaging, GUI behavior, or visual performance.

S01 acceptance defaults to collecting profile generation, the focused Python
test result, raw logs, the profile digest and available lock-file fingerprints.
It marks full build/window/FFI/repeat-build checks `NOT RUN` and exits 1 with an
`INCOMPLETE` gate when the automated portion succeeds.

Once the runner, native library and generated bindings are ready, opt into
actual integration with a fresh evidence directory:

```sh
PHOTO_FLUTTER_ROOT=/path/to/flutter ./tools/acceptance run --stage S01 --integration --mode release --evidence-dir /path/to/fresh-integration-evidence
```

Integration defaults to `release`; `--mode debug` is also supported. It invokes
`tools/platform build` twice, then runs the resulting bundle executable with
`--self-test`, `--self-test --expect-profile-mismatch`, and
`--self-test --expect-bridge-mismatch`. An existing `DISPLAY` is used directly;
otherwise `xvfb-run` is required. A missing display leaves window/rejection
checks unrun and the gate incomplete.

Each smoke must exit 0 and emit exactly one `PHOTO_CLIENT_SMOKE ` JSON record
with `result: "PASS"`. A successful window check also requires `real_window`,
`round_trip` and `shutdown` exactly true, exactly three strictly increasing
integer event sequence values, and the selected profile digest. Rejection checks
require the exact `BuildProfileMismatch` or `BridgeMismatch` reason and
`initialized: false`. Missing/malformed/duplicate JSON, incorrect semantics,
nonzero exits and timeouts cannot pass.

`report.json` records actual command arrays, working directories, exit codes,
timeouts and separate logs. Snapshots after the first build and after the repeat
build record SHA-256 for the native library, every bundle file, lockfiles,
generated Rust/Dart bindings, and source/generated profile files. The installed
bridge must match the built library. Missing required artifacts or changed
bindings, profiles or lockfiles fail the gate; binary hashes are recorded without
promising bit reproducibility or full S14 packaging acceptance.

Commands use argument arrays with no shell. Tests have a 180-second timeout,
each build 900 seconds, and each smoke 60 seconds. On timeout the process group
is killed (including child cargo/Flutter/Xvfb processes) and reaping is bounded
to five seconds. No environment values are dumped into the report.

S01-C01–C03 can become `PASS` only with the corresponding integration evidence
and passing platform tests. Failed checks produce `FAIL`; unrun requirements
produce `INCOMPLETE`; both exit nonzero. Even when S01 passes, user review remains
`NOT RECORDED`, GPU visual validation remains `NOT RUN`, and installation/
packaging validation remains `NOT RUN`. Mocked integration tests prove the
validator's behavior and are not application execution evidence.

Existing reports/logs are preserved: use a fresh empty evidence directory for
each run. S02–S14 and unknown stages exit 2 with `NOT IMPLEMENTED` and create no
evidence directory, including when `--integration` is supplied.
