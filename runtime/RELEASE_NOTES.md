Portable runtime for Reach local qualification.

Each bundle holds a relocatable Ruby 4.0.7, bundler 4.0.19, and the prebuilt gems for every lock profile under runtime/locks. runtime-manifest.json lists the bundles for five platforms, the profiles, and the Chrome for Testing 154.0.8037.92 download (url, sha256, size) for each platform Google publishes. Chrome is fetched from Google's storage, not re-hosted here.

Install with `reach runtime install`. Reach verifies the manifest against the sha256 pinned in its own source before trusting anything in it.

The Linux bundles are built on glibc 2.28 and need glibc 2.28 or newer: Debian 10 and later, Ubuntu 20.04 and later, RHEL and Alma 8 and later.
