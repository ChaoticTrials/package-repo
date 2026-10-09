#!/usr/bin/env bash
# Adds .rpm packages to the rpm repository under public/rpm/ and regenerates
# its signed metadata.
#
#   usage: scripts/publish-rpm.sh <directory-of-rpms>
#
# Environment:
#   GPG_KEY_ID      the signing key, already imported into the gpg keyring
#   GPG_PASSPHRASE  its passphrase (may be empty for an unprotected key)
#
# Needs: rpm (rpmsign), createrepo_c, gpg.
#
# Each package is copied to public/rpm/<arch>/, signed there, and the
# directory's repodata is updated and signed. The files in the source
# directory are never modified, so what a release page offers stays untouched.
# A package that is already in the repository is left alone, which makes a
# re-run of the same release a no-op. Packages are never removed: the metadata
# is built from the directory, so older versions stay installable for as long
# as their files stay here.
#
# It works in place and does not clean up after a failure: a run that dies
# part-way leaves unsigned packages behind, so discard the checkout rather than
# committing it.
set -euo pipefail

fail() {
    printf 'publish-rpm: %s\n' "$*" >&2
    exit 1
}

note() { printf '==> %s\n' "$*"; }

[[ $# -eq 1 ]] || fail "usage: $0 <directory-of-rpms>"
SOURCE_DIR=$1
[[ -d ${SOURCE_DIR} ]] || fail "${SOURCE_DIR} is not a directory."
: "${GPG_KEY_ID:?GPG_KEY_ID must name the signing key}"
: "${GPG_PASSPHRASE-}"

for tool in rpm rpmsign createrepo_c gpg; do
    command -v "${tool}" >/dev/null || fail "${tool} is not installed."
done

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RPM_ROOT="${REPO_ROOT}/public/rpm"
KEY_FILE="${RPM_ROOT}/RPM-GPG-KEY-chaotictrials"
[[ -f ${KEY_FILE} ]] || fail "${KEY_FILE} is missing."

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"
PASSFILE="${WORK}/passphrase"
(umask 077 && printf '%s' "${GPG_PASSPHRASE-}" > "${PASSFILE}")

# Users verify with the key published in this repository. Signing with any
# other key would produce a repository nobody can install from.
fingerprint() { awk -F: '/^fpr/ { print $10; exit }'; }
SIGNING_FPR=$(gpg --batch --with-colons --fingerprint "${GPG_KEY_ID}" | fingerprint)
PUBLISHED_FPR=$(gpg --batch --show-keys --with-colons "${KEY_FILE}" | fingerprint)
[[ -n ${SIGNING_FPR} ]] || fail "key ${GPG_KEY_ID} is not in the gpg keyring."
[[ ${SIGNING_FPR} == "${PUBLISHED_FPR}" ]] || fail \
    "key ${GPG_KEY_ID} is not the key published as ${KEY_FILE##*/}."

shopt -s nullglob
sources=("${SOURCE_DIR}"/*.rpm)
(( ${#sources[@]} > 0 )) || fail "no .rpm files in ${SOURCE_DIR}."

# --- copy what is new --------------------------------------------------------
declare -A touched=()
added=()
for src in "${sources[@]}"; do
    name=$(basename "${src}")
    arch=$(rpm -qp --qf '%{ARCH}' "${src}" 2>/dev/null) \
        || fail "${name} is not a readable rpm."
    case ${arch} in
        x86_64 | aarch64) ;;
        *) fail "${name} is built for '${arch}'; only x86_64 and aarch64 are published." ;;
    esac
    dest="${RPM_ROOT}/${arch}/${name}"
    if [[ -e ${dest} ]]; then
        note "${arch}/${name} is already in the repository, leaving it."
        continue
    fi
    mkdir -p "${RPM_ROOT}/${arch}"
    cp "${src}" "${dest}"
    added+=("${dest}")
    touched[${arch}]=1
done

if (( ${#added[@]} == 0 )); then
    note "nothing new to publish."
    exit 0
fi

# --- sign the packages -------------------------------------------------------
# dnf checks each package against the key (gpgcheck=1), which needs the
# signature inside the .rpm itself. Loopback pinentry because there is no
# terminal to ask on.
note "signing ${#added[@]} package(s)"
rpmsign --addsign \
    --define "__gpg $(command -v gpg)" \
    --define "_gpg_name ${GPG_KEY_ID}" \
    --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${PASSFILE}" \
    "${added[@]}"

# --- regenerate and sign the metadata ----------------------------------------
# repo_gpgcheck=1 makes dnf check repodata/repomd.xml against this detached
# signature, which is what covers the package list itself.
for arch in "${!touched[@]}"; do
    dir="${RPM_ROOT}/${arch}"
    note "updating ${arch} metadata"
    createrepo_c --quiet --update --no-database "${dir}"
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "${PASSFILE}" \
        --local-user "${GPG_KEY_ID}" --detach-sign --armor \
        --output "${dir}/repodata/repomd.xml.asc" "${dir}/repodata/repomd.xml"
done

# --- check the result the way a user's machine would -------------------------
# A clean keyring and a clean rpm database that know only the published key,
# so a signature made with the wrong key, or none, fails here rather than on
# someone's `dnf install`.
note "verifying against the published key"
mkdir -m 700 "${WORK}/gnupg" "${WORK}/rpmdb"
GNUPGHOME="${WORK}/gnupg" gpg --batch --quiet --import "${KEY_FILE}"
rpm --dbpath "${WORK}/rpmdb" --import "${KEY_FILE}"
for pkg in "${added[@]}"; do
    rpm --dbpath "${WORK}/rpmdb" --checksig "${pkg}" >/dev/null \
        || fail "${pkg##*/} does not verify against the published key."
done
for arch in "${!touched[@]}"; do
    dir="${RPM_ROOT}/${arch}/repodata"
    GNUPGHOME="${WORK}/gnupg" gpg --batch --quiet --verify \
        "${dir}/repomd.xml.asc" "${dir}/repomd.xml" \
        || fail "${arch} metadata does not verify against the published key."
done

note "published ${#added[@]} package(s)"
