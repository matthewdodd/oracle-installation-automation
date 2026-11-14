# Oracle Installation

## Security configuration

The full README is planned for a later step. Until then, these are the secure defaults and how to
configure them. Variable reference: `roles/*/meta/argument_specs.yml`; example settings:
`inventory/example/group_vars/oracle_db_servers/main.yml`.

- **SSH host keys are verified** (`host_key_checking = True` in `ansible.cfg`). Put the targets'
  host keys in the controller's (or the AAP execution environment's) `known_hosts` from a trusted
  source, for example `ssh-keyscan` output whose fingerprint you compared with the host console or
  your provisioning records, or point at a managed file with
  `ansible_ssh_common_args: "-o UserKnownHostsFile=<file>"`. Turn checking off only temporarily and
  knowingly, with the environment variable `ANSIBLE_HOST_KEY_CHECKING=False`.
- **No world-readable module temp files.** `allow_world_readable_tmpfiles` is not set. To become the
  unprivileged `db_owner`, use one of:
  - POSIX ACLs: install the `acl` package (`setfacl`) on RHEL/Linux targets. Nothing else is needed.
  - A shared group: set `ansible_common_remote_group` (for example to `oracle_common_group_name`) on
    AIX, or on Linux without `setfacl`.
  - Connect as root: set `ansible_user: root` (with or without `b_user: root`). Ansible then hands
    its temp files to `db_owner`, and the tasks still become `db_owner` where they must (runInstaller
    and OPatch refuse to run as root). Do not set `ansible_become_user`: it overrides every task's
    `become_user`, so the Oracle home, staging, runInstaller and OPatch would all run as root and fail.

  Only if none of these is possible, set `ansible_shell_allow_world_readable_temp: true` for the
  affected hosts in the inventory.
- **Downloads are verified.** TLS certificates are checked (`oracle_common_artifactory_validate_certs`,
  with `oracle_common_artifactory_ca_path` for an internal CA). Each artifact needs a checksum in
  `oracle_common_artifact_checksums` unless `oracle_common_artifact_checksum_required: false` is set.
- **Secrets come from Ansible Vault** (or an AAP credential): the Teams webhook URL and the repository
  credentials. Tasks that use them run with `no_log`. Use one `--vault-id` per environment and rotate
  with `ansible-vault rekey`. See `inventory/example/group_vars/oracle_db_servers/vault.yml.example`.
- **No world-writable files.** Scripts are 0750 and data files 0640. Staging directories are 0750,
  owned by `db_owner`, under `<mountpoint>/<db_owner>/ansible_staging` (not `/tmp`). Modes that are
  group- or world-writable are rejected. Quote modes (`"0750"`): an unquoted `0777` is read as the
  integer 511, which is normalised back to "0777" and rejected, and the normalised value is the one
  applied. Regression test: `ansible-playbook -i localhost, tests/mode_validation.yml` (controller only).
- **No shell interpolation of inputs and no inline `sudo`.** Scripts run with an argument vector.
  Group membership is checked exactly and changed through `become`
  (`oracle_common_group_membership_become_user`, default root). Set
  `oracle_common_manage_group_membership: false` where groups are managed elsewhere.

## Install correctness

- **Root scripts are verified.** `root.sh` (and `clone/rootpre.sh` on AIX) run by one of two methods,
  set with `oracle_common_root_script_method` (short alias `oracle_root_script_method`):
  - `wrapper` (default, the original flow): `b_user` runs the site root wrapper
    (`oracle_common_root_wrapper_path`), and `roles/oracle_database_install_role/files/root_wrapper.exp`
    answers its menu. Each prompt waits `oracle_common_root_wrapper_timeout` seconds. The run fails on a
    timeout, if the wrapper ends early, on an unexpected prompt or question, or if the wrapper exits
    non-zero. root.sh's own questions (local bin directory, overwrite an existing `dbhome`/`oraenv`) get
    root.sh's default answer (`oracle_common_root_wrapper_accept_default_regex`).
  - `become`: the script runs directly through `become` as `oracle_common_root_script_become_user`
    (default root). Use this on hosts without the wrapper, for example cloud hosts. The wrapper path is
    then not needed.

  Both methods check that the exit status is 0, that the output does not match
  `oracle_common_root_script_failure_regex`, and that it contains `oracle_common_root_sh_success_regex`
  ("Finished running generic part of root script"). If your wrapper hides root.sh's output, set that
  regex to empty.
- **Prerequisite packages are enforced.** The per-OS list is checked before the host is changed.
  - RHEL and Oracle Linux 7, 8 and 9 (and other Red Hat rebuilds): `roles/oracle_common/vars/RedHat-<major>.yml`.
  - AIX filesets via `lslpp -Lc`: `roles/oracle_common/vars/AIX.yml`.

  If a package is missing, the run fails and lists it. A release with no list file is skipped with a
  message. `oracle_ignore_prereqs: true` (long name `oracle_database_install_role_ignore_prereqs`)
  continues knowingly, and it is also the only way `-ignorePrereq` reaches the installer (default
  false). To support a new release, add one vars file.
