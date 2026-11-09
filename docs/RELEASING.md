# Release workflow

The `macOS` workflow publishes stable GitHub releases from pushed `vX.Y.Z` tags.
It packages the direct macOS 27 / Apple Silicon app. It does not submit anything
to the Mac App Store or provision Apple signing credentials.

## Prepare a version

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`, the canonical version metadata.
2. Match `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `AppStore/Base.xcconfig`.
3. Add English notes at `docs/releases/X.Y.Z.md` and update the README and
   validation report as appropriate.
4. Run the checks, commit and push the source:

```sh
python3 scripts/release_metadata.py --tag v1.0.0
python3 -m unittest discover -s scripts/tests -v
swift test
./scripts/build-app.sh
python3 scripts/package_release.py --app 'build/One Clipboard History.app' --tag v1.0.0
```

Replace `v1.0.0` with the intended version. Versions use numeric `X.Y.Z` syntax;
builds are positive integers. A mismatched tag or Store configuration is rejected
before building. Local packages record whether their source checkout was dirty;
publication requires a clean checkout.

After the branch CI is green, publish its exact commit by pushing a tag:

```sh
git tag -a v1.0.0 -m 'One Clipboard History 1.0.0'
git push origin v1.0.0
```

An ordinary push, pull request or manual workflow run validates and retains the
package without publishing. Tag publication rebuilds and validates the exact
tagged source; a later branch push does not change the release.

## What the workflow does

The read-only macOS job checks metadata, runs Python and Swift tests, builds the
direct app and sandboxed Store archive, and prepares:

- `one-clipboard-history-X.Y.Z-macos-arm64.zip`
- `SHA256SUMS.txt`
- `release.json`: version, build, tag, source commit, signing category and digests
- `release-notes.md`: version notes and the actual signing status

The ZIP preserves executable permissions and resources. It is extracted into a
fresh directory and the app signature, resources, architecture and version are
validated again. The Store archive is retained separately as a prototype.

Only the dependent Ubuntu publish job receives `contents: write`. It downloads
the package from that same run, verifies its manifest, checksums, ZIP layout and
remote tag commit, creates or resumes a draft, uploads all four files, downloads
them again and verifies the bytes before publishing the release as Latest.
Checkout credentials are not persisted; the write token is used only for the
publication step. Tag runs are not cancelled by newer runs.

GitHub references: [workflow permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions),
[release creation](https://cli.github.com/manual/gh_release_create).

## Signing and installation

The current CI build is **ad hoc signed and not notarized**. Release notes report
this explicitly. A version number or successful workflow does not establish
Developer ID signing, Gatekeeper acceptance or Mac App Store approval.
Existing Developer ID, notarization and Store scripts remain available; see
[APP_STORE.md](APP_STORE.md) for their prerequisites. Apple credentials must not
be committed or placed in release assets.

Download the app ZIP, compare its SHA-256 with `SHA256SUMS.txt`, quit the previous
version, and move the extracted app into Applications. GitHub also provides
source archives automatically. The Store prototype is not a consumer installer.

## Retry and failure behavior

- A failed check or packaging step never starts publication.
- A failed upload or downloaded-byte check leaves the release unpublished.
- Rerun the failed workflow jobs to resume a draft while its CI artifact exists
  (retained for 14 days), or rerun all jobs to regenerate it. CI artifacts may be
  replaced on a rerun; published release assets are never overwritten.
- A published release is verified against its recorded source and checksums,
  then left unchanged. Different ZIP timestamps on a rebuild do not replace
  the previously published bytes.
- A conflicting published source or unexpected draft asset stops the workflow
  for review. Fix source errors with a new version and tag; do not move a
  published tag.

The workflow supports stable numeric tags. Prerelease suffixes are rejected;
adding a prerelease policy is a separate change.
