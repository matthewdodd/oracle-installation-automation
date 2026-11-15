# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project intends to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) from its first tagged release.

## [Unreleased]

This is the production-readiness rework of the original playbook. The playbook can now run on a
supported ansible-core. It is safe on hosts that already run Oracle, has no environment-specific values
in code, and is secure by default. The job inputs used by existing AAP job templates are unchanged.

### Breaking changes and upgrade notes

- **ansible-core 2.22 is required** on the controller (Python 3.13 or later). The original playbook used
  `include:`, which current ansible-core no longer accepts. Target hosts need Python 3.9 or later.
- **EL7 is no longer supported.** RHEL 7, Oracle Linux 7 and other Red Hat family releases before 8 are
  refused before anything changes on the host, because they have no vendor Python 3.9+. See Removed.
- **New required environment inputs.** They used to be placeholders hard-coded in the code, and now
  have no default:
  - `oracle_common_artifactory_url` (was a placeholder repository URL in the code).
  - `oracle_common_site_prefix` (was `/local`).
  - `oracle_common_root_wrapper_path` (was `/usr/local/bin/root-wrapper`). Required only with
    `oracle_common_root_script_method: wrapper`, which is the default.
  - `oracle_common_group_name`, or the original `GROUP_NAME` (was a placeholder group name). Required only
    while `oracle_common_manage_group_membership: true`, which is the default.
  - `oracle_common_artifact_checksums`: one checksum per downloaded artifact, unless
    `oracle_common_artifact_checksum_required: false`.
- **`b_user` now defaults to `root`** (was a placeholder user name). It is still overridable as
  `b_user` or `oracle_common_privileged_user`.
- **No default inventory**: `ansible.cfg` no longer points at `./inventory`, so pass `-i`. An example is
  in `inventory/example/`.
- **SSH host key checking is on.** The targets' keys must be in `known_hosts`.
- **`allow_world_readable_tmpfiles` was removed.** Becoming `db_owner` now needs POSIX ACLs,
  `ansible_common_remote_group`, or a root connection. There is a per-host opt-in as a last resort.
- **Missing prerequisite packages now fail the run**, and `-ignorePrereq` is no longer passed by default.
  Set `oracle_ignore_prereqs: true` to restore both.
- **Staging moved** from `/tmp` to `<mountpoint>/<db_owner>/ansible_staging`. Set
  `oracle_common_staging_base: /tmp` to move it back.
- **The software download directory is per database**: `<prefix>/software/<DB>_<version>` instead of
  `<prefix>/software/<version>`.
- **Existing Oracle software is protected.**
  - A non-empty `ORACLE_HOME` is refused (set `oracle_force_reinstall: true` to override).
  - An existing `/etc/oraInst.loc` is reused and not rewritten (set
    `oracle_database_install_role_force_inventory_pointer: true` for the original rewrite, with a backup
    that rollback restores).
  - A different existing `<DB>.env` is refused (set `oracle_database_install_role_force_env_file`).
  - A second run for a database that is already installed is therefore refused.
- **`database_version` has an allow-list** (`19.0.0.0`, `12.2.0.1`, `12.1.0.2`). Unknown values no longer
  fall back silently to 12.1.0.2. The 12.x releases print a desupport warning.
- **The env file PATH no longer ends with `.`.** An env file written by an earlier run therefore differs,
  and a rerun is refused unless forced or `oracle_database_install_role_env_path_include_cwd: true` is set.
- **Teams notifications use a Teams Workflows webhook** (Adaptive Card) instead of an Office 365 connector
  card. Supply a new webhook URL from Vault. The card's "URL" fact is now called "Job URL".
- **Failures of root.sh / rootpre.sh, a hung root wrapper, or an unexpected wrapper prompt now fail the
  install** and trigger a rollback. The original always reported success.
- File modes must be quoted strings. Group- or world-writable modes, including `0777`, are rejected.
- `community.general` is no longer needed.

### Added

- `roles/oracle_common`, a shared role:
  - per-OS variable loading (`vars/<system>.yml`, `<os_family>.yml`, `<distribution>.yml`,
    `<os_family>-<major>.yml`, `<distribution>-<major>.yml`), so adding a distribution or release
    means adding one file. It ships `Linux.yml`, `AIX.yml`, `RedHat.yml`, and `RedHat-8/9.yml`;
  - validation of every input before the host is changed, reporting all problems at once;
  - the Teams notification, failure recording and reporting, and best-effort staging removal.
- `meta/argument_specs.yml` for every role (all inputs, types, defaults, aliases) and `meta/main.yml`
  (platforms EL 8/9 and AIX, `min_ansible_version` 2.22).
- `oracle_database_install_role_env_tns_admin`, `_env_path_dirs`, `_env_nls_lang`,
  `_env_nls_timestamp_format` and `_env_nls_date_format`: the site conventions in `<DB>.env`, validated
  for safe characters. The defaults are the original values, so the file content is unchanged.
- `oracle_database_install_role_force_inventory_pointer` (default false): opt-in rewrite of an existing
  `oraInst.loc`, with a backup that rollback restores.
- `oracle_database_install_role_env_file_backup` (default true): a forced replacement of a different
  existing `<DB>.env` first keeps a timestamped backup next to it (`<DB>.env.<pid>.<date>~`, owner, group
  and mode preserved). Rollback never removes it.
- `oracle_database_install_role_patch_inner_archive_patterns`: the archives inside the patch bundle that
  are extracted (default `*.zip`, `*.tar.gz`, as before).
- Clean-target and side-by-side support:
  - read-only host preflight (`tasks/preflight.yml`);
  - central inventory reuse or creation (`tasks/inventory.yml`), with
    `oracle_database_install_role_inventory_location`, `_new_inventory_location` and `_inventory_group`;
  - templated env file (`templates/db_install.env.j2`);
  - new inputs `oracle_database_install_role_oracle_base` and `oracle_home` (alias), plus the force flags
    `oracle_database_install_role_force_reinstall` (alias `oracle_force_reinstall`) and
    `oracle_database_install_role_force_env_file`.
- Automatic rollback after a failed install (`tasks/rollback.yml`,
  `oracle_database_install_role_rollback_on_failure`). It removes only what the run created, and first
  detaches a home that is registered in a pre-existing inventory.
- Root script methods (`oracle_common_root_script_method`, alias `oracle_root_script_method`):
  - `wrapper`: the original flow, now verified through a static `files/root_wrapper.exp`;
  - `become`: runs the script directly as `oracle_common_root_script_become_user`.

  Both have configurable success and failure patterns, timeout, wrapper exit check, default-answer regex,
  arguments and stdin.
- Enforced prerequisite checks per OS (RHEL/OL 8, 9 package lists; AIX filesets through `lslpp -Lc`)
  in `tasks/prereqs.yml`. The flag is `oracle_database_install_role_ignore_prereqs` (alias
  `oracle_ignore_prereqs`).
- Installer settings: `oracle_database_install_role_install_edition`, `_install_option`, `_os_group`,
  `_response_file` and `_response_extra_file`.
- Download security: `oracle_common_artifact_checksums`, `oracle_common_artifact_checksum_required`,
  `oracle_common_artifactory_validate_certs`, `oracle_common_artifactory_ca_path`, optional Vault-backed
  `oracle_common_artifactory_username`/`_password`, and `oracle_common_artifactory_use_proxy`.
- Notification settings:
  - `oracle_common_notification_webhook_url` (alias `notification_webhook_url`);
  - `oracle_common_job_url_base`, `oracle_common_https_proxy`;
  - `oracle_common_notification_delegate_to`, `_validate_certs`, `_ca_path`, `_timeout`,
    `_error_max_length`, `_colours`.

  Failure cards include the failed stage, task and error. The `awx_*` variables are a fallback for
  `tower_*`.
- Pinned patch selection with `oracle_common_patch_file_name`. The original date-derived name remains as
  `oracle_common_patch_file_name_fallback`, with a warning.
- Timeouts: `oracle_database_install_role_install_timeout`, `_patch_timeout` and `_poll_interval`.
- Configurable modes for every file and directory the playbook creates, validated and normalised.
- OS group membership is optional (`oracle_common_manage_group_membership`) and runs as
  `oracle_common_group_membership_become_user`. The lookup and add commands are per OS.
- Toolchain and CI:
  - `requirements.txt` (pinned ansible-core, ansible-lint, yamllint, shellcheck-py) and
    `collections/requirements.yml`;
  - `.yamllint`, `.ansible-lint` (production profile, no skips), `.gitignore`;
  - GitHub Actions CI (yamllint, shellcheck, syntax-check, ansible-lint, mode regression test).
  - GitHub Actions Molecule workflow (`.github/workflows/molecule.yml`). It runs on every pull request,
    with no paths filter, so the required `molecule` check reports even on docs-only PRs. It also runs on
    push to `main` and on demand.
- `inventory/example/` with documented group_vars and a `vault.yml.example`. It covers per-environment
  vault ids and rekey rotation.
- `tests/mode_validation.yml`, a controller-only permission-mode regression test.
- README with full documentation, and this changelog.
- Licensing: the repository is now licensed under `GPL-3.0-or-later` (`LICENSE`, the unmodified GNU GPL v3
  text). `NOTICE` states that Oracle software, patches and installer formats, and Red Hat/IBM operating
  systems and packages, are not covered and stay under their owners' terms. It also lists the file that
  is covered only in part. The roles' `galaxy_info.license` changes from `NOASSERTION` to
  `GPL-3.0-or-later`.

### Changed

- Role-prefixed variable names. The original names still work as aliases: `b_user`, `GROUP_NAME`,
  `remote_script_directory`, `remote_output_directory`, `script_permission`, `oracle_home`,
  `patch_folder_prefix`, `install_folder_name`, `artf_ver`, `artifactory_repo`, `install_file_name`,
  `patch_file_name`.
- Play 1 runs only on `localhost` and fails with a clear message when `target` is missing.
- Each role is self-contained (role defaults instead of facts set by another role) and copies its scripts
  from `role_path`.
- Every stage, including Pre-Cleanup, is in a block. A failure sends a notification and fails with the
  failed task and its error, instead of `Fail`.
- The scripts run with an argument vector. The env file path is passed as a 6th argument, so
  `/local/$SID.env` is no longer hard-coded.
- The binaries archive is extracted straight from staging, instead of being copied into ORACLE_HOME first.
- Async polling covers the whole timeout. Install and patch use separate registers, and their output is
  always shown before the result is checked.
- `database_install.bash` rewrites the response file on every run (no duplicate keys). `INVENTORY_LOCATION`
  is the real inventory directory. 12.1.0.2 gets its schema key.
- `database_patch.bash` writes one status file per patch (`opatch_status.txt`, `opatch_jvm_status.txt`).
- Group membership is matched exactly, using `getent group` or `lsgroup`.
- `interpreter_python = auto_silent`. The YAML output now uses the builtin callback.
- FQCN everywhere. Task `vars:` are dicts. `include:` was replaced.
- The install role preflight uses the shared `..` path rule (`__oracle_common_re_dotdot`) for every path it
  checks, instead of its own copies. A leading or bare `..` is now also reported as a `..` component (such
  paths were already rejected as not absolute). `tests/mode_validation.yml` covers these checks.
- `yamllint` and `ansible-lint` now also check `.github/` (the CI workflows and `.github/dependabot.yml`).
  The yamllint rules are unchanged; the workflows gained the `---` document start marker.

### Removed

- Hard-coded environment values: the placeholder webhook, AAP, repository and proxy URLs, and the
  placeholder privileged user and group names.
- The `community.general.office_365_connector_card` notification.
- `roles/initialization_role/vars/main.yml`, with its conflicting `remote_output_directory`.
- The empty `roles/oracle_database_install_role/vars/main.yml`.
- `files/db_install.rsp` (it only had a header and was never used) and `files/db_install.env` (now a
  template).
- The duplicate script copy, and the unused `ORACLE_SID`/`server_name`/`action` facts.
- Every `ignore_errors`.
- All `0777` modes. This has no toggle.
- **EL7 support (breaking change).** RHEL 7, Oracle Linux 7 and other Red Hat family releases before 8
  are no longer supported, and `roles/oracle_common/vars/RedHat-7.yml` is gone. ansible-core 2.22 needs
  Python 3.9 or later on the targets and EL7 has no vendor Python 3.9+. Such hosts are now refused early
  by `roles/oracle_common/tasks/os_vars.yml` with a clear message (without the check they would have run
  with an empty prerequisite list and skipped the package check); `tests/mode_validation.yml` covers it.

### Fixed

- The OJVM patch is optional, as intended. Previously a missing OJVM folder ran `opatch apply` with an
  empty path and failed.
- Cleanup no longer deletes a software directory shared by other databases of the same release.
- A failed install no longer leaves a half-built ORACLE_HOME behind.
- The prerequisite package check now has an effect, and it also covers Oracle Linux and other RHEL
  rebuilds.
- Polling no longer gives up (after 3600 s) before the async limit (4000 s).
- `remote_output_directory` has one consistent definition.
- The play no longer aborts on an undefined `target`, or on missing `tower_*` variables outside AAP.
- A missing `mountpoint` or `db_owner` is reported in the list of missing required arguments, instead of
  as `'mountpoint' is undefined`.
- The `..` path guard (`__oracle_common_re_dotdot`) now finds a `..` component at the start, in the middle
  or at the end of a path on its own (`..`, `../x`, `/u01/..`), instead of only `/../`. Names that merely
  contain dots (`/u01/app..x`, `/u01/.hidden`, `19.0.0.0`) are still accepted. `tests/mode_validation.yml`
  covers both.
- The environment-file backup message is accurate in every case. It shows the backup path when one was
  made, and otherwise says why none was made: check mode, `oracle_database_install_role_env_file_backup`
  is false, or no backup was needed because the content was unchanged (only attributes such as the mode
  were corrected). Previously that last case wrongly said the backup setting was false.

### Security

- Host key checking is on. TLS certificates of the repository and the webhook are verified, with an
  optional CA bundle.
- Every downloaded artifact must match a checksum (configurable).
- Artifact checksums are validated strictly before anything changes on the host: a hex digest (either case)
  must have exactly its algorithm's length (md5 32 ... sha512 128), a checksum-file URL must be http(s), and
  an all-zero placeholder digest is rejected as such. The example inventory now ships `<CHANGE_ME>`
  instead of an all-zero digest, which used to pass validation and fail only at download.
- Credentials are refused over plain http.
- Secrets come from Ansible Vault or AAP credentials. Every task that handles them runs with `no_log`,
  and error messages are redacted.
- Inputs are no longer interpolated into shell commands. The root-wrapper dialogue is a static expect
  script that reads its values from its environment.
- All inputs are validated with anchored patterns. Paths reject metacharacters, `..` and trailing
  newlines.
- There is no inline `sudo`. Privilege changes use `become`.
- There are no world-writable files. Staging is private to `db_owner`, is created without following
  symlinks, and is verified.
- World-readable module temp files are no longer enabled globally.
- The env file PATH no longer includes the current directory by default.
- CI actions (`actions/checkout`, `actions/setup-python`) are pinned by full commit SHA, with the
  release version in a trailing comment. `.github/dependabot.yml` checks the pins weekly.
