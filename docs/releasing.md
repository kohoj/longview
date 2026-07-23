# Release contract

`LongviewBuildInfo.version` is the single source version. A stable release tag
must equal `v` plus that value.

1. Update `LongviewBuildInfo.version` and `CHANGELOG.md` in a pull request.
2. Pass CI on `macos-15` arm64 and `macos-15-intel` x86_64.
3. Merge to protected `main`.
4. Create a signed annotated `vX.Y.Z` tag.
5. Push the tag and manually run the Release workflow with that exact tag.
6. Inspect the draft release and `SHA256SUMS`, then publish it.

Release history must contain only the reviewed public tree. Do not import
unrelated development artifacts, captured application content, credentials, or
generated binaries. Public proof must be generated exclusively from
`LongviewFixtureApp` and synthetic data.

Developer ID signing and Apple notarization will be added as a separate gated
binary-release job. Source releases must not describe an ad-hoc signature as a
trusted distribution signature.
