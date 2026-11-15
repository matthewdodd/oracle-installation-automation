#!/bin/bash
#
# TEST FIXTURE. Builds the fake artifact repository the Molecule scenario serves over HTTP (prepare.yml).
# Nothing in it is Oracle software: the binaries and patches are the stubs in files/stubs/.
#
# Usage:
#   build_artifacts.bash <stub_dir> <repository_dir> <release_folder> <platform> <patch_file> \
#                        <db_ru_id> <ojvm_id> <old_opatch_version> <new_opatch_version>
#
# Result (the layout oracle_common_artifactory_url/<release_folder>/<file> expects):
#   <repository_dir>/<release_folder>/<platform>_binaries.tar.gz          extracted into ORACLE_HOME:
#       runInstaller, oui/bin/runInstaller, root.sh, OPatch/opatch (+ version.txt = old version)
#   <repository_dir>/<release_folder>/<patch_file>                        patch bundle, extracted into
#       the software staging directory: OPatch/ (new version) and two inner archives,
#       p<db_ru_id>_*.tar.gz  -> <db_ru_id>/README.html  ("Database Release Update", mandatory)
#       p<ojvm_id>_*.tar.gz   -> <ojvm_id>/README.html   ("- Oracle JavaVM Component" twice, optional)
#   <file>.sha256 next to each archive ("<digest>  <file>"), referenced from oracle_common_artifact_checksums
#   as sha256:<URL>, so the secure default (a checksum for every download) stays on.
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: $0 <stub_dir> <repository_dir> <release_folder> <platform> <patch_file> <db_ru_id> <ojvm_id> <old_opatch_version> <new_opatch_version>"
  exit 1
fi

stub_dir=$1
repository_dir=$2
release_folder=$3
platform=$4
patch_file=$5
db_ru_id=$6
ojvm_id=$7
old_opatch_version=$8
new_opatch_version=$9

out_dir=$repository_dir/$release_folder
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$out_dir"

# --- Binaries ---------------------------------------------------------------------------------
home=$work_dir/home
mkdir -p "$home/oui/bin" "$home/OPatch" "$home/install"
install -m 0755 "$stub_dir/runInstaller" "$home/runInstaller"
install -m 0755 "$stub_dir/runInstaller" "$home/oui/bin/runInstaller"
install -m 0755 "$stub_dir/root.sh" "$home/root.sh"
install -m 0755 "$stub_dir/opatch" "$home/OPatch/opatch"
printf 'OPATCH_VERSION:%s\n' "$old_opatch_version" > "$home/OPatch/version.txt"
printf 'TEST STUB home built by molecule/default/files/build_artifacts.bash - not Oracle software.\n' > "$home/README.molecule"
tar -C "$home" -czf "$out_dir/${platform}_binaries.tar.gz" .

# --- Patch bundle -----------------------------------------------------------------------------
bundle=$work_dir/bundle
mkdir -p "$bundle/OPatch" "$work_dir/ru/$db_ru_id" "$work_dir/ojvm/$ojvm_id"
install -m 0755 "$stub_dir/opatch" "$bundle/OPatch/opatch"
printf 'OPATCH_VERSION:%s\n' "$new_opatch_version" > "$bundle/OPatch/version.txt"

cat > "$work_dir/ru/$db_ru_id/README.html" <<EOF
<html><head><title>Database Release Update $db_ru_id (test stub)</title></head>
<body><h1>Oracle Database Release Update $db_ru_id - test stub</h1></body></html>
EOF
cat > "$work_dir/ojvm/$ojvm_id/README.html" <<EOF
<html><head><title>OJVM Release Update $ojvm_id (test stub)</title></head>
<body>
<p>Patch $ojvm_id - Oracle JavaVM Component Release Update (test stub)</p>
<p>Applies to - Oracle JavaVM Component of Oracle Database</p>
</body></html>
EOF
tar -C "$work_dir/ru" -czf "$bundle/p${db_ru_id}_190000_Linux-x86-64.tar.gz" "$db_ru_id"
tar -C "$work_dir/ojvm" -czf "$bundle/p${ojvm_id}_190000_Linux-x86-64.tar.gz" "$ojvm_id"
tar -C "$bundle" -czf "$out_dir/$patch_file" .

# --- Checksums --------------------------------------------------------------------------------
cd "$out_dir"
for file in "${platform}_binaries.tar.gz" "$patch_file"; do
  sha256sum "$file" > "$file.sha256"
done
ls -l "$out_dir"
