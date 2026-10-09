# package-repo

Package repositories for ChaoticTrials software, served from
<https://repo.chaotictrials.de> by GitHub Pages (`public/` is the site root).

| Path                                   | What                                            |
|----------------------------------------|-------------------------------------------------|
| `public/deb/`                          | apt repository (`stable main`, amd64 and arm64) |
| `public/rpm/`                          | rpm repository (`x86_64` and `aarch64`)         |
| `public/apt-keyring.gpg`               | public signing key for apt (binary)             |
| `public/rpm/RPM-GPG-KEY-chaotictrials` | the same key, ASCII-armored, for dnf            |
| `public/dists`, `public/pool`          | frozen legacy copy of the apt repo, see below   |

Projects publish here from their release workflows. Nothing in this repo is
meant to be edited by hand.

## Using the repositories

### Debian, Ubuntu and derivatives

```bash
curl -fsSL https://repo.chaotictrials.de/apt-keyring.gpg \
  | sudo tee /usr/share/keyrings/chaotictrials.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/chaotictrials.gpg] https://repo.chaotictrials.de/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/chaotictrials.list
sudo apt update
```

### Fedora and other dnf-based distributions

```bash
sudo dnf config-manager addrepo --from-repofile=https://repo.chaotictrials.de/rpm/chaotictrials.repo
```

On older dnf (4.x): `sudo dnf config-manager --add-repo https://repo.chaotictrials.de/rpm/chaotictrials.repo`.
Both the packages and the repository metadata are signed.

## How publishing works

### apt (`public/deb/`)

[aptly](https://www.aptly.info) does the work. `.aptly/` holds its database and
package pool and must stay in git: it is how a release knows about the versions
published before it. A release workflow checks this repo out, runs
`aptly repo add` and `aptly publish` with the endpoint prefix `deb`
(`filesystem:apt-repo:deb`), and pushes the result.

### rpm (`public/rpm/`)

`scripts/publish-rpm.sh <directory-of-rpms>` copies the packages into
`public/rpm/<arch>/`, signs them, regenerates and signs `repodata/` with
`createrepo_c`, and then verifies everything against the published key. It needs
`rpm` (for `rpmsign`), `createrepo-c` and `gpg`, plus `GPG_KEY_ID` and
`GPG_PASSPHRASE` in the environment with the key imported. There is no database:
the metadata is built from the files in each directory, so older packages stay
installable only while their `.rpm` files stay here.

### Signing

One key signs everything. `GPG_KEY_ID` must be the key published as
`apt-keyring.gpg` and `RPM-GPG-KEY-chaotictrials`; `publish-rpm.sh` refuses to
run otherwise.

## Legacy root

Before the `/deb` and `/rpm` split the apt repository lived at the site root.
`public/dists` and `public/pool` are a frozen copy of it as of sbk 0.3.0 and
sbk-gui 0.2.0, kept so installs that still point at
`https://repo.chaotictrials.de/ stable main` keep working. They receive no
updates and should be replaced with the new `/deb` variant.
