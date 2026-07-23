# Source installation

Longview's source distribution keeps the runtime offline and makes the local
build auditable. The default prefix is `~/.local`.

```bash
git clone https://github.com/kohoj/longview.git
cd longview
./scripts/install.sh
longview doctor --pretty
```

The installer validates macOS, Swift, and the release build, applies and verifies
a local ad-hoc signature, then checks the CLI version protocol and SHA-256 before
atomically replacing a managed binary. The ad-hoc signature provides local code
integrity; it is not a Developer ID identity or notarization claim.
It creates:

```text
~/.local/bin/longview
~/.local/share/longview/install-receipt.json
~/.local/share/longview/uninstall.sh
~/.local/share/doc/longview/LICENSE
```

It never invokes `sudo`, modifies `PATH`, requests privacy permission, or clears
quarantine. An unmanaged existing binary requires `--force`; a symlink is always
refused.

## Update

```bash
./scripts/update.sh --check
./scripts/update.sh --to v0.3.1
```

Update resolves only stable `vX.Y.Z` tags from `origin`, clones the selected tag
into a private temporary directory, verifies tag/version agreement, and reuses
the installer. It never installs a moving branch or mutates the current checkout.

## Uninstall

```bash
~/.local/share/longview/uninstall.sh
```

Uninstall reads the receipt, verifies the binary hash, and removes only managed
files. A modified binary is preserved unless `--force` is explicit. Screenshots,
caches, shell files, sibling files, and macOS permissions remain untouched.
