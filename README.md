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
