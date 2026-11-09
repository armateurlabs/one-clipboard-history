# One Clipboard History 1.0.0 validation — 9 November 2026

Version **1.0.0 (10)**, macOS 27 on Apple Silicon. This release automates
packaging and GitHub publication; clipboard capture and paste behavior are
unchanged from 0.9.0. Previous application checks remain recorded in
[VALIDATION-0.9.md](VALIDATION-0.9.md) and its linked historical reports.

## Executed local checks

- **139 Swift tests passed:** 79 Core and 60 AppKit/settings tests.
- **35 Python tests passed:** 10 metadata, 17 package and 8 publication tests.
- Workflow syntax checked with actionlint 1.7.12. Its configuration recognizes
  the repository's additional `xcode-27` runner label.
- Release app built and validated as version 1.0.0/build 10. Both distribution
  configurations use the same canonical version/build.
- Actual macOS packaging succeeded: direct bundle identity and arm64 checked,
  ZIP created with `ditto`, extracted into a fresh directory, then app signature,
  executable permissions, resources, architecture and metadata checked again.
- Portable manifest, ZIP and checksum verification passed for that real package.
  Local uncommitted work was recorded as dirty; publication rejects that state.

## Release automation coverage

The metadata tests reject invalid or mismatched versions, builds and tags.
Package tests reject altered archives, lost executable permissions, corrupt
sidecars, unsafe paths, preview/Store bundles and mismatched bundle metadata.

Publication tests cover draft creation and retries, byte verification before
publication, dirty/wrong-source rejection, remote-tag mismatches, corrupted
downloads, unexpected draft assets and preservation of published releases.
They use a fake GitHub client and do not mutate remote state.

The [macOS workflow](https://github.com/armateurlabs/one-clipboard-history/actions/workflows/ci.yml)
runs these tests, release compilation, real ZIP verification and sandboxed
archiving. Branch CI does not publish. A matching pushed tag enables the
dependent publish job, which uses that run's verified artifact. GitHub retains
dated run logs; the published `release.json` records the exact source commit
and package digests. See [RELEASING.md](RELEASING.md) for the contract and retries.

## Distribution limits

No valid Apple code-signing identity was available on the development Mac on
9 November 2026. The current CI build is ad hoc signed and not notarized. The
workflow reports signing status in its notes and manifest; it does not claim
Gatekeeper acceptance or App Store approval. The sandbox archive remains a
separate CI prototype, not a release installer or Store submission.

The existing Excel source-context warning and outstanding physical permission,
focus, complex Office, VoiceOver, login, sleep/wake and display qualification
items remain open. A 1.0 version number does not receive those scenarios.
No new CPU limit or opening-time claim is introduced.
