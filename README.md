# ppa-sync

Unofficial repackages of upstream `.deb` releases for apps without their own apt
repository, published in `ppa:jokergermany/ppa`.

**Not affiliated with the upstream projects.** The packages contain the unmodified
prebuilt files of the official upstream `.deb`; they are not built from source.
Report bugs in the packaging here, not upstream.

## Install

```bash
sudo add-apt-repository ppa:jokergermany/ppa
sudo apt update && sudo apt install lightcraft
```

## How it works

`.github/workflows/ppa-sync.yml` runs daily. For every line in `apps-ppa.txt` it
checks the newest GitHub release; if it is not in `state/published.txt` yet,
`scripts/make-ppa-source.sh` repacks the `.deb` into a source package (checksum
verified against `SHA256SUMS.txt` where upstream provides one), it is signed with
`debsign` and uploaded with `dput`. Launchpad then builds and publishes it.

## Setup

1. Dedicated upload key (not your personal key), registered in your Launchpad profile:
   `gpg --quick-generate-key "Your Name (ppa-sync) <you@example.org>" rsa4096 sign 2y`
2. GitHub → Settings → Environments → `launchpad` (deployment branches: `main` only):
   - secrets `LP_GPG_PRIVATE_KEY` (`gpg --armor --export-secret-keys <FPR>`), `LP_GPG_PASSPHRASE`
   - variables `LP_SIGN_KEY_FPR`, `DEBFULLNAME`, `DEBEMAIL` (must match the key's UID)
3. Run the workflow manually with `dry_run` = true and check the log.
4. Run it manually with `dry_run` = false and `only` = `lightcraft`, then without filter.

## Cleanup

Each version occupies roughly twice the `.deb` size (orig tarball + built binary);
a PPA has 8 GiB. `scripts/ppa-cleanup.py` deletes older versions (dry run by default).
