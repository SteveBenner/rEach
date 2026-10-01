# Reach runtime kit

The runtime is a per-platform bundle that `reach runtime install` downloads for local qualification: a relocatable Ruby 4.0.7, bundler 4.0.19, and prebuilt gems for each lock profile, plus Chrome for Testing 154.0.8037.92 fetched from Google's storage. The workflow in `.github/workflows/runtime.yml` builds the bundles for macos-arm64, macos-x86_64, linux-x86_64, linux-arm64 and windows-x86_64, checks each one after relocating it, and publishes them with `runtime-manifest.json` as a GitHub release.

## Files

- `locks/<profile>/Gemfile` and `Gemfile.lock`: one directory per lock profile. `capybara-cuprite-1` is the first.
- `package.rb`: stages the Ruby, installs bundler 4.0.19 and the profile gems, writes `runtime/BUILD.json`, and creates `reach-runtime-<runtime_id>-<platform>.tar.gz` and its `.json` (asset, sha256, size, ruby_exe).
- `relocate_check.rb`: extracts a bundle somewhere else, loads the gems under `BUNDLE_FROZEN=true`, and, given a Chrome zip, drives it with Ferrum.
- `manifest.rb`: combines the per-platform `.json` files and the Chrome zips into `runtime-manifest.json` and prints its sha256.
- `RELEASE_NOTES.md`: the release body; the publish job appends the manifest sha256 line.

## Bundle layout

Every path sits under a top directory `runtime/`: `runtime/ruby/` (with `bin/ruby` or `bin/ruby.exe`), `runtime/gems/<lock12>/` (BUNDLE_PATH, Gemfile and Gemfile.lock for one profile, lock12 being the first 12 hex characters of the original lock's sha256), and `runtime/BUILD.json`. When the platform is missing from a lock, `bundle lock --add-platform` runs before install, so the bundled lock can differ from the profile lock; the manifest hashes record the original bytes.

## Ruby sources

rv-ruby release 20260929 supplies the macOS and Linux Rubies. Their tarballs hold the tree under `rv-ruby@4.0.7/4.0.7/`, and the workflow locates `bin/ruby` after extraction instead of assuming that prefix. Windows uses the RubyInstaller 4.0.7-1 7z with MSYS2 (ucrt64) for native gems.

## Add a lock profile

1. Copy the Gemfile and Gemfile.lock into `runtime/locks/<name>/`, byte for byte. Name the profile for its gem stack.
2. Bump the r-number: the release tag `runtime-<ruby>-r<n>` and the matching `RUNTIME_ID` and `RUNTIME_TAG` in `lib/reach/runtime_kit.rb`.
3. Cut a release, then update `MANIFEST_SHA256`.

The bundler version in the lock's BUNDLED WITH must match `BUNDLER_VERSION` in `package.rb` and `manifest.rb`.

## Cut a release

Push a tag named `runtime-<ruby>-r<n>`, for example `runtime-4.0.7-r1`, or run the workflow by hand with that tag as input. The tag's Ruby part must be 4.0.7. When the publish job finishes, its summary and the release notes show the sha256 of `runtime-manifest.json`. Set `MANIFEST_SHA256` in `lib/reach/runtime_kit.rb` to that value and ship a Reach release; installs refuse a manifest that does not match it.

## Pinned actions

Third-party actions are pinned by full commit SHA in the workflow. Versions at pinning time:

| action | version | commit |
| --- | --- | --- |
| actions/checkout | v7.0.1 | 3d3c42e5aac5ba805825da76410c181273ba90b1 |
| actions/upload-artifact | v7.0.1 | 043fb46d1a93c77aae656e7c1c64a875d1fc6a0a |
| actions/download-artifact | v8.0.1 | 3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c |

## Workflow notes

- Each step has `timeout-minutes`, and concurrency per ref does not cancel a running release.
- The Windows package step appends the MSYS2 ucrt64 and usr bin directories to PATH after the runner's own, so System32 `tar.exe` (bsdtar) is used for archives.
- Linux arm64 has no Chrome for Testing build, so its manifest entry has `chrome: null` and its relocation check skips the browser step.
