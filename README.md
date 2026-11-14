# Oracle Installation

Ansible automation that installs Oracle Database **binaries** (a software-only install, no database is
created) and applies the Release Update patch bundle, on RHEL-family Linux and IBM AIX hosts. It is safe
to run on a clean host and on a host that already runs Oracle: it never overwrites an existing
`ORACLE_HOME`, central inventory (`/etc/oraInst.loc`) or another database's environment file unless you
explicitly force it.

It is built for Ansible Automation Platform (AAP, formerly Tower/AWX) job templates and also runs from the
command line. It works the same way on premises and in the cloud.

Contents

- [What it does](#what-it-does)
- [Supported platforms and Oracle versions](#supported-platforms-and-oracle-versions)
- [Controller requirements](#controller-requirements)
- [Repository layout](#repository-layout)
- [Quick start (CLI)](#quick-start-cli)
- [Inventory layout](#inventory-layout)
- [Variable reference](#variable-reference)
- [Secrets with Ansible Vault](#secrets-with-ansible-vault)
- [Teams notifications (Teams Workflows webhook)](#teams-notifications-teams-workflows-webhook)
- [Clean target and side-by-side installs](#clean-target-and-side-by-side-installs)
- [Running root.sh: wrapper or become](#running-rootsh-wrapper-or-become)
- [Security defaults](#security-defaults)
- [What the playbook changes on a host](#what-the-playbook-changes-on-a-host)
- [Rollback](#rollback)
- [AAP / Tower usage](#aap--tower-usage)
- [Migrating existing job templates](#migrating-existing-job-templates)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## What it does

`oracle_database_install.yml` has two plays.

1. **Add server names** (on `localhost`): checks that `target` was given, then adds every host in the
   comma-separated `target` list to the in-memory inventory (into `ansible_inventory_groups`, if set).
   The hosts do not have to be in the inventory file.
2. **Database Binary installation** (on the `target` hosts, in parallel). Each stage is a block. If a
   stage fails, a failure notification is sent and the host fails with a message that names the stage,
   the failed task and its error.
   1. Start notification (Teams; skipped when no webhook is configured).
   2. **Initialize**:
      - `oracle_common` loads the per-OS variables and validates every input. It reports all problems
        at once.
      - The read-only host checks (`oracle_database_install_role` `preflight`) refuse an existing
        non-empty `ORACLE_HOME`, or a different existing `<DB>.env`, unless forced. They decide whether
        to reuse the central inventory (side-by-side) or create one (clean target), and they check the
        prerequisite packages. **Nothing on the host has changed up to this point.**
      - `initialization_role` recreates the private staging directories and, optionally, adds
        `db_owner` and the privileged user to an OS group.
   3. **Pre-Cleanup**: removes leftover staging from an earlier run.
   4. **Install**:
      - Downloads the binaries archive and verifies its checksum, then extracts it into `ORACLE_HOME`.
      - Sets up the central inventory and writes `<site prefix>/<DB>.env`.
      - On AIX, runs `rootpre.sh`.
      - Runs `runInstaller` in silent mode, then runs and verifies `root.sh`.
      - Downloads and extracts the patch bundle, upgrades OPatch if the bundle has a newer one, then
        applies the Database RU and, if the bundle has one, the OJVM patch.

      If this stage fails, everything this run created is rolled back (see [Rollback](#rollback)) and
      the staging is cleaned up.
   5. **Cleanup**: removes the downloaded software and the staged scripts. The installer logs are kept.
   6. Success notification.

## Supported platforms and Oracle versions

| Platform | Selected by | Notes |
|---|---|---|
| RHEL 7, 8, 9 | `vars/Linux.yml` + `RedHat.yml` + `RedHat-<major>.yml` | Package list per release. |
| Oracle Linux, Rocky, AlmaLinux 7/8/9 | same files (`os_family` RedHat) | Use the RHEL release file. |
| IBM AIX 7.2 / 7.3 | `vars/AIX.yml` | `lslpp` fileset check, `chgrpmem`, `rootpre.sh`. |
| Other Linux | `vars/Linux.yml` only | Runs, but the package check is skipped until a vars file is added. |

Platform specifics live only in `roles/oracle_common/vars/`. `tasks/os_vars.yml` loads every file that
exists, generic first and most specific last: `<system>.yml`, `<os_family>.yml`, `<distribution>.yml`,
`<os_family>-<major>.yml`, then `<distribution>-<major>.yml`. **To support a new distribution or release,
add one file.** Kernels other than Linux and AIX are refused (`oracle_common_supported_systems`).

**Target Python.** ansible-core 2.22 needs **Python 3.9 or later on the target hosts**.

- RHEL 9: the system Python works.
- RHEL 8: install a newer Python from AppStream (for example `python3.11`) and set
  `ansible_python_interpreter` for those hosts. `package_facts` still reads the rpm database.
- RHEL 7: there is no Red Hat Python 3.9+. These hosts need a site-provided Python 3.9+, or a controller
  with an older ansible-core (which is not tested here).
- AIX: install Python 3.9+ (for example from the AIX Toolbox) and set `ansible_python_interpreter`.

The targets also need `bash` and `expect` (the `expect` paths are in the per-OS vars), plus `tar`/`unzip`
for extraction.

| `database_version` | Repository folder | Response file | Support |
|---|---|---|---|
| `19.0.0.0` | `19.0.0` | schema v19.0.0, `executeRootScript=false` | Supported (recommended) |
| `12.2.0.1` | `12.2.0.1` | schema v12.2.0 | Accepted with a desupport WARNING |
| `12.1.0.2` | `12.1.0.2` | schema v12.1.0 plus the security-updates keys | Accepted with a desupport WARNING |

Any other value is rejected. To add a release, extend `oracle_common_artifactory_version_map`.

## Controller requirements

- **Python 3.13 or later** (ansible-core 2.22 requires it; developed and tested on 3.15).
- The pinned tools in `requirements.txt`: ansible-core 2.22.0, ansible-lint, yamllint, shellcheck-py.
- Collections: `collections/requirements.yml` is currently empty, because the playbook uses only
  `ansible.builtin`. Run the install anyway, so that collections added later are picked up.
- SSH access to the targets, with their host keys in `known_hosts` (see [Security defaults](#security-defaults)).

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r collections/requirements.yml
```

## Repository layout

```
oracle_database_install.yml     playbook (entry point)
notification.yml                playbook-level notification entry point -> roles/oracle_common/tasks/notify.yml
ansible.cfg                     host key checking on, no default inventory, YAML output, pipelining
inventory/example/              example inventory, group_vars and vault example (copy per environment)
roles/oracle_common/            per-OS variables, input validation, notifications, failure reporting
  vars/<os>.yml                 platform specifics (Linux, AIX, RedHat, RedHat-7/8/9)
roles/initialization_role/      staging directories, OS group membership
roles/oracle_database_install_role/
  tasks/preflight.yml           read-only host safety checks (home, inventory, env file, packages)
  tasks/inventory.yml           central inventory: reuse or create
  tasks/env_file.yml            <DB>.env from templates/db_install.env.j2
  tasks/root_script.yml         root.sh / rootpre.sh, wrapper or become, verified
  tasks/rollback.yml            undo what a failed run created
  files/*.bash, root_wrapper.exp  installer, patch and root-wrapper scripts (interfaces documented in their headers)
tests/mode_validation.yml       controller-only regression test for permission modes
requirements.txt, collections/requirements.yml   pinned controller tooling
LICENSE, NOTICE                 GPL-3.0-or-later licence text; scope and Oracle, Red Hat/IBM carve-outs
```

Every role documents its inputs in `meta/argument_specs.yml`. Ansible checks them when the role runs.

## Quick start (CLI)

```bash
# 1. Create the environment's inventory from the example.
cp -R inventory/example inventory/dev
$EDITOR inventory/dev/hosts.yml inventory/dev/group_vars/oracle_db_servers/main.yml

# 2. Secrets (optional: webhook URL, repository credentials). See "Secrets with Ansible Vault".
cp inventory/dev/group_vars/oracle_db_servers/vault.yml.example inventory/dev/group_vars/oracle_db_servers/vault.yml
$EDITOR inventory/dev/group_vars/oracle_db_servers/vault.yml
ansible-vault encrypt --vault-id dev@prompt inventory/dev/group_vars/oracle_db_servers/vault.yml
#    then uncomment the vault_* mappings at the end of main.yml

# 3. Dry run: validates inputs, checks the host safety, packages and staging. Downloads nothing, installs nothing.
ansible-playbook -i inventory/dev/hosts.yml --vault-id dev@prompt oracle_database_install.yml --check \
  -e target=dbhost01.example.com -e DATABASE_NAME=ORCL1 -e db_owner=oracle \
  -e database_version=19.0.0.0 -e mountpoint=/u01

# 4. Real run: the same command without --check.
```

`target` may list several hosts (`-e target=db1.example.com,db2.example.com`). Each host is installed in
parallel and sends its own notifications.

## Inventory layout

```
inventory/<env>/
  hosts.yml                               hosts, in group oracle_db_servers
  group_vars/oracle_db_servers/main.yml   environment configuration (non-secret)
  group_vars/oracle_db_servers/vault.yml  secrets, encrypted with --vault-id <env>
  host_vars/<host>.yml                    per-host overrides (optional), e.g. ansible_python_interpreter
```

- `ansible.cfg` names no default inventory, so always pass `-i inventory/<env>/hosts.yml`.
- Hosts given in `target` that are not in the inventory are added at run time. They only get
  `group_vars/oracle_db_servers/` if you set `-e ansible_inventory_groups=oracle_db_servers`. Without
  it, they have no environment configuration and the input validation fails. Either list the hosts in
  `hosts.yml`, or always pass `ansible_inventory_groups`.
- Use one inventory directory, and one vault id, per environment (dev, test, prod).

## Variable reference

Every input is declared in `roles/*/meta/argument_specs.yml`, and Ansible checks the types when the role
runs. Format rules that argument specs cannot express (patterns, absolute paths, URL schemes, modes,
paired credentials) are checked by `roles/oracle_common/tasks/preflight.yml` and
`roles/oracle_database_install_role/tasks/preflight.yml` **before anything changes on the host**. They
report every problem at once. Defaults are in each role's `defaults/main.yml`.

Variables whose names start with `__` are internal and not meant to be set.

### Job inputs (AAP survey / extra vars; names unchanged from the original playbook)

| Variable | Required | Default | Description |
|---|---|---|---|
| `target` | **yes** | - | Comma-separated host list. It is the host pattern of play 2 and the "Host" fact on the card. |
| `DATABASE_NAME` | **yes** | - | ORACLE_SID. Must fully match `[A-Za-z][A-Za-z0-9_]{0,7}`. Used in the staging names and `<DB>.env`. |
| `db_owner` | **yes** | - | OS user that owns the Oracle software (POSIX name). Its primary group is the default OS/inventory group. |
| `database_version` | **yes** | - | `19.0.0.0`, `12.2.0.1` or `12.1.0.2` (the keys of `oracle_common_artifactory_version_map`). |
| `mountpoint` | **yes** | - | Absolute base filesystem. `ORACLE_BASE` is `<mountpoint>/<db_owner>`. |
| `ansible_inventory_groups` | no | omitted | Group(s) the `target` hosts are added to at run time, e.g. `oracle_db_servers`. |
| `oracle_force_reinstall` | no | `false` | Short alias of `oracle_database_install_role_force_reinstall`. |
| `oracle_ignore_prereqs` | no | `false` | Short alias of `oracle_database_install_role_ignore_prereqs`. |
| `oracle_root_script_method` | no | `wrapper` | Short alias of `oracle_common_root_script_method` (`wrapper` or `become`). |

AAP sets these automatically. They are only used on the notification card. Outside AAP the defaults apply.

| Variable | Fallback | Default |
|---|---|---|
| `tower_job_id` | `awx_job_id` | `n/a` |
| `tower_job_template_name` | `awx_job_template_name` | `manual run` |
| `tower_user_name` | `awx_user_name` | `scheduler` |
| `tower_schedule_name` | `awx_schedule_name` | `manual job` |

### Required environment inputs (set once per environment in group_vars)

There is no safe generic default for these, so none is shipped.

| Variable | Required when | Description |
|---|---|---|
| `oracle_common_artifactory_url` | always | http(s) URL of the repository folder that holds one sub-folder per release. Files are fetched from `<url>/<version folder>/<file>`. Do not embed credentials in it. |
| `oracle_common_site_prefix` | always | Absolute site directory (the original `/local`). It holds `<DB>.env` and `software/<DB>_<version>/`. |
| `oracle_common_root_wrapper_path` | `oracle_common_root_script_method: wrapper` (default) | Absolute path of the site root wrapper (the original `/usr/local/bin/root-wrapper`). |
| `oracle_common_group_name` (alias `GROUP_NAME`) | `oracle_common_manage_group_membership: true` (default) | OS group that `db_owner` and the privileged user join; it was a placeholder name in the original code. |
| `oracle_common_artifact_checksums` | `oracle_common_artifact_checksum_required: true` (default) | Dict of artifact file name to `<algorithm>:<digest>`, e.g. `LINUX_binaries.tar.gz: "sha256:<64 hex>"`. Needs one entry for the binaries and one for the patch bundle. |

### oracle_common: accounts, staging and site layout

| Variable | Default | Description |
|---|---|---|
| `oracle_common_privileged_user` (alias `b_user`) | `root` | Account used through `become` for root-level work: `/etc/oraInst.loc`, the site prefix, downloads, running the root wrapper. |
| `oracle_common_manage_group_membership` | `true` | Add `db_owner` and the privileged user to `oracle_common_group_name`. Set `false` where groups are managed elsewhere (LDAP/IdM, images). |
| `oracle_common_group_membership_become_user` | `root` | Account that runs the group change command through `become`. |
| `oracle_common_staging_base` | `<mountpoint>/<db_owner>/ansible_staging` | Base of the per-database staging directories, created as `db_owner`. `/tmp` (the original location) is allowed, but is not recommended. |
| `oracle_common_remote_script_directory` (alias `remote_script_directory`) | `<staging base>/ora_ansible_scripts_<DB>` | Staged scripts. Removed after the run. |
| `oracle_common_remote_output_directory` (alias `remote_output_directory`) | `<staging base>/oracle_database_install_<DB>` | Installer and OPatch logs. Kept after the run. |
| `oracle_common_script_permission` (alias `script_permission`) | `"0750"` | Mode of the staged scripts. |
| `oracle_common_staging_dir_mode` | `"0750"` | Mode of the staging base and the staging directories. |
| `oracle_common_staging_parent_mode` | `"0755"` | Mode of the staging base's parent, only when this run creates it. |
| `oracle_common_env_dir` | `<oracle_common_site_prefix>` | Directory of the environment files. |
| `oracle_common_env_file` | `<env dir>/<DB>.env` | Environment file that the scripts source. |
| `oracle_common_supported_systems` | `[Linux, AIX]` | Allowed kernel names. Each needs a `vars/<system>.yml`. |

### oracle_common: artifact repository and patch selection

| Variable | Default | Description |
|---|---|---|
| `oracle_common_artifactory_version_map` | `{"19.0.0.0": "19.0.0", "12.2.0.1": "12.2.0.1", "12.1.0.2": "12.1.0.2"}` | Maps `database_version` to the repository folder. It is also the version allow-list. |
| `oracle_common_desupported_versions` | `["12.2.0.1", "12.1.0.2"]` | Versions that are accepted with a WARNING. |
| `oracle_common_artifactory_username` | `""` | Repository user (secret: Vault or AAP credential). Basic auth is forced only when this is set. |
| `oracle_common_artifactory_password` | `""` | Repository password or token (secret, `no_log`). Must be set together with the username. |
| `oracle_common_artifactory_validate_certs` | `true` | Verify the repository TLS certificate. `false` restores the original behaviour (preflight warns). |
| `oracle_common_artifactory_ca_path` | `""` | PEM CA bundle on the target, for an internal CA. It is exported to the download as `SSL_CERT_FILE`. |
| `oracle_common_artifactory_use_proxy` | `false` | Download through `oracle_common_https_proxy`. The original ignored proxies. |
| `oracle_common_artifact_checksum_required` | `true` | Require a checksum for every downloaded artifact. `false` downloads unverified files, with a WARNING per file. |
| `oracle_common_patch_file_name` | `""` | Pinned patch bundle, e.g. `LINUX_jan26.tar.gz`. Empty means the fallback below, with a WARNING. |
| `oracle_common_patch_file_name_fallback` | `<AIX\|LINUX>_jan<YY>.tar.gz` | The original date-derived name, where YY is the current year on the target. |
| `oracle_common_https_proxy` | `""` | HTTPS proxy, e.g. `http://proxy.example.com:8080`. Used by the notification, and by downloads when enabled. |

### oracle_common: root scripts

| Variable | Default | Description |
|---|---|---|
| `oracle_common_root_script_method` (alias `oracle_root_script_method`) | `wrapper` | `wrapper` drives the site root wrapper with expect. `become` runs the script directly through `become`. |
| `oracle_common_root_wrapper_timeout` | `300` | Seconds to wait for each wrapper prompt, including while root.sh runs. |
| `oracle_common_root_wrapper_check_exit_status` | `true` | Fail if the wrapper exits non-zero after the dialogue. `false` turns it into a WARNING. |
| `oracle_common_root_wrapper_accept_default_regex` | local bin directory / `Overwrite it? (y/n)` | Tcl regex of the root.sh questions that get ENTER (root.sh's default). Any other y/n question fails the run. |
| `oracle_common_root_script_become_user` | `root` | Account that runs the root scripts with the `become` method. |
| `oracle_common_root_script_args` | `[]` | Extra arguments for the root scripts (`become` method). |
| `oracle_common_root_script_stdin` | four newlines | Standard input for the root scripts (`become` method). Each newline accepts a default. |
| `oracle_common_root_script_failure_regex` | `(?i)\b(error\|failed\|failure)\b\|permission denied` | Must not match the output. Empty disables the check. |
| `oracle_common_root_sh_success_regex` | `Finished running generic part of root script` | Must match the root.sh output. Set it empty if your wrapper hides that output. |
| `oracle_common_rootpre_success_regex` | `""` | Must match the AIX rootpre.sh output. Empty means not checked. |

### oracle_common: Teams notification

| Variable | Default | Description |
|---|---|---|
| `oracle_common_notification_webhook_url` (alias `notification_webhook_url`) | `""` | Teams Workflows webhook URL (secret, https only). Empty means notifications are skipped. |
| `oracle_common_job_url_base` | `""` | Base of the AAP job link, e.g. `https://aap.example.com/#/jobs/playbook/`. The job id is appended. Empty shows `n/a`. |
| `oracle_common_notification_delegate_to` | `""` | Host that sends the card. Empty means each target sends its own card (the original behaviour). Set `localhost` to send from the controller or execution environment. |
| `oracle_common_notification_validate_certs` | `true` | Verify the webhook TLS certificate. |
| `oracle_common_notification_ca_path` | `""` | PEM CA bundle for the webhook endpoint, e.g. a TLS-inspection CA. |
| `oracle_common_notification_timeout` | `30` | Request timeout in seconds. |
| `oracle_common_notification_error_max_length` | `500` | Failure cards show the stage, task and error, cut to this length. |
| `oracle_common_notification_colours` | `{start: Good, success: Accent, fail: Attention}` | Adaptive Card colour per state. |

### oracle_common: per-OS values (from `vars/<os>.yml`, overridable per host or group)

| Variable | Linux | AIX |
|---|---|---|
| `oracle_common_artifact_platform` | `LINUX` | `AIX` |
| `oracle_common_bash_path` | `/usr/bin/bash` | `/usr/bin/bash` |
| `oracle_common_expect_path` | `/usr/bin/expect` | `/usr/bin/expect` |
| `oracle_common_group_add_command` | `[/bin/gpasswd, --add]` | `[/usr/bin/chgrpmem, -m, +]` |
| `oracle_common_group_members_command` / `oracle_common_group_members_regex` | `getent group` | `lsgroup -a users` |
| `oracle_common_run_rootpre` | `false` | `true` |
| `oracle_common_package_manager` | `rpm` (RedHat family), else `""` | `""` |
| `oracle_common_package_query_command` / `oracle_common_package_query_regex` | `[]` (package_facts is used) | `lslpp -Lc` |
| `oracle_common_prereq_packages` | `RedHat-7/8/9.yml`, else `[]` (skipped) | 19c filesets for AIX 7.2/7.3 |
| `oracle_common_inventory_pointer_file` | `/etc/oraInst.loc` | `/etc/oraInst.loc` |

### oracle_database_install_role: layout and artifacts

| Variable | Default | Description |
|---|---|---|
| `oracle_database_install_role_oracle_base` | `<mountpoint>/<db_owner>` | ORACLE_BASE, written to the env file. |
| `oracle_database_install_role_oracle_home` (alias `oracle_home`) | `<oracle_base>/product/<database_version>` | ORACLE_HOME. Set a new path for a side-by-side install of a release that is already installed. |
| `oracle_database_install_role_patch_folder_prefix` (alias `patch_folder_prefix`) | `<oracle_common_site_prefix>` | Base of the software staging directory. |
| `oracle_database_install_role_install_folder_name` (alias `install_folder_name`) | `<prefix>/software/<DB>_<database_version>` | Per-database download directory. Cleanup removes only this one. |
| `oracle_database_install_role_artf_ver` (alias `artf_ver`) | `oracle_common_artifactory_version_map[database_version]` | Repository folder name. |
| `oracle_database_install_role_artifactory_repo` (alias `artifactory_repo`) | `<oracle_common_artifactory_url>/<artf_ver>` | Full repository folder URL. |
| `oracle_database_install_role_install_file_name` (alias `install_file_name`) | `<AIX\|LINUX>_binaries.tar.gz` | Binaries archive. |
| `oracle_database_install_role_patch_file_name` (alias `patch_file_name`) | `oracle_common_patch_file_name` or its fallback | Patch bundle. |

### oracle_database_install_role: production-host safety

| Variable | Default | Description |
|---|---|---|
| `oracle_database_install_role_force_reinstall` (alias `oracle_force_reinstall`) | `false` | Extract over an existing non-empty ORACLE_HOME (with a WARNING). |
| `oracle_database_install_role_force_env_file` | follows `force_reinstall` | Replace an existing `<DB>.env` whose content differs (backup kept, see below). |
| `oracle_database_install_role_env_file_backup` | `true` | Before a forced replacement overwrites an existing `<DB>.env`, keep its previous content as `<DB>.env.<pid>.<date>~` next to it (owner, group and mode preserved). Rollback never removes it. Set `false` to overwrite without a backup. |
| `oracle_database_install_role_force_inventory_pointer` | `false` | Rewrite an existing `oraInst.loc` that names another inventory or group (backup kept, restored on rollback). Does not follow `force_reinstall`. |
| `oracle_database_install_role_inventory_location` | `""` | Central inventory that must be used. Empty reuses the existing one or creates the one below. When set, a pointer that names a different inventory fails the run. |
| `oracle_database_install_role_new_inventory_location` | `<oracle_base>/oraInventory` | Inventory created on a clean target. |
| `oracle_database_install_role_inventory_group` | `""` (primary group of `db_owner`) | `inst_group` for a new pointer. With an existing pointer, a different value fails the run. |
| `oracle_database_install_role_rollback_on_failure` | `true` | Remove what a failed run created. Set `false` to keep it for troubleshooting. |

### oracle_database_install_role: installer and patching

| Variable | Default | Description |
|---|---|---|
| `oracle_database_install_role_ignore_prereqs` (alias `oracle_ignore_prereqs`) | `false` | Continue despite missing packages, and pass `-ignorePrereq` to runInstaller. |
| `oracle_database_install_role_install_edition` | `EE` | `oracle.install.db.InstallEdition`. |
| `oracle_database_install_role_install_option` | `INSTALL_DB_SWONLY` | `oracle.install.option`. |
| `oracle_database_install_role_os_group` | `""` (primary group of `db_owner`) | `UNIX_GROUP_NAME` and every `OS*_GROUP` key. |
| `oracle_database_install_role_response_file` | `""` (`<ORACLE_HOME>/responseFile.rsp`) | Response file path on the target. |
| `oracle_database_install_role_response_extra_file` | `""` | File on the target with extra `key=value` lines, appended to the response file. |
| `oracle_database_install_role_install_timeout` | `4000` | Seconds runInstaller may run before it is stopped and fails. |
| `oracle_database_install_role_patch_timeout` | `4000` | Seconds OPatch may run before it is stopped and fails. |
| `oracle_database_install_role_poll_interval` | `30` | Seconds between status checks. Polling always covers the whole timeout. |
| `oracle_database_install_role_patch_inner_archive_patterns` | `["*.zip", "*.tar.gz"]` | Globs of the archives inside the patch bundle that are extracted and removed. An empty list skips this step. |

### oracle_database_install_role: environment file and permissions

Modes must be quoted strings (`"0750"`). Group- or world-writable modes are rejected (the only exception
is the inventory directory, which may be group-writable). An unquoted `0777` is read as the integer 511,
normalised to `"0777"`, and rejected.

| Variable | Default | Description |
|---|---|---|
| `oracle_database_install_role_env_path_include_cwd` | `false` | End PATH in `<DB>.env` with `.` as the original did. This is a security risk. |
| `oracle_database_install_role_env_file_mode` | `"0755"` | `<DB>.env`. |
| `oracle_database_install_role_env_tns_admin` | `$ORACLE_BASE/admin/network/admin` | `TNS_ADMIN` in `<DB>.env`. An absolute path, or one starting with `$ORACLE_BASE/` or `$ORACLE_HOME/`. |
| `oracle_database_install_role_env_path_dirs` | `[/usr/bin, /usr/ccs/bin, /bin, /etc, /usr/openwin/bin, /usr/local/bin, /usr/bin, /usr/ucb]` | System directories at the start of PATH in `<DB>.env`, before `$ORACLE_HOME/bin` and `$ORACLE_HOME/OPatch`. Absolute paths only. |
| `oracle_database_install_role_env_nls_lang` | `american_america.AL32UTF8` | `NLS_LANG` in `<DB>.env` (written unquoted, so no spaces). |
| `oracle_database_install_role_env_nls_timestamp_format` | `YYYY-MM-DD-HH24.MI.SS.FF6` | `NLS_TIMESTAMP_FORMAT` in `<DB>.env`. |
| `oracle_database_install_role_env_nls_date_format` | `YYYY-MM-DD-HH24.MI.SS` | `NLS_DATE_FORMAT` in `<DB>.env`. |
| `oracle_database_install_role_inventory_pointer_mode` | `"0644"` | A newly created `oraInst.loc`. |
| `oracle_database_install_role_inventory_dir_mode` | `"0770"` | A newly created inventory directory. |
| `oracle_database_install_role_home_mode` | `"0755"` | ORACLE_HOME directory. |
| `oracle_database_install_role_download_dir_mode` | `"0750"` | Download directory, owned by `db_owner`. |
| `oracle_database_install_role_download_file_mode` | `"0640"` | Downloaded artifacts. |
| `oracle_database_install_role_download_parent_mode` | `"0755"` | `<prefix>/software`, only when this run creates it (never re-moded). |
| `oracle_database_install_role_extracted_mode` | `"u+rwX,g+rX,g-w,o-rwx"` | Applied recursively to the extracted patch tree. Symbolic, so executable bits are kept. |
| `oracle_database_install_role_root_script_mode` | `"0755"` | AIX `<OH>/clone/root.sh` (the copy of rootpre.sh the wrapper runs). |

### Role entry points

| Role / `tasks_from` | Purpose |
|---|---|
| `oracle_common` (`main`) | Load the per-OS vars and validate the inputs. Run it once, before the other roles. |
| `oracle_common` `notify` | Send the Teams card for `call` = `start`, `success` or `fail` (a failure card uses `oracle_common_failure`). |
| `oracle_common` `failure_record` / `failure_report` | Record a stage failure (`oracle_common_failure_stage`, sets `oracle_common_failure`), then notify and fail with the real error. |
| `oracle_common` `remove_staging` | Remove one staging path (`oracle_common_remove_path`) as the connection user, else as `db_owner` (best effort). |
| `initialization_role` (`main`) | Staging directories and group membership. |
| `oracle_database_install_role` (`main`) | Download, install, root.sh, patch. |
| `oracle_database_install_role` `preflight` | Read-only host safety checks and prerequisites. |
| `oracle_database_install_role` `rollback` | Undo what a failed run created. |
| `oracle_database_install_role` `clean_files_from_server` | Remove this database's download directory and staged scripts. |

## Secrets with Ansible Vault

The secrets are the Teams webhook URL (a bearer URL) and the repository credentials. They are never
committed in plain text. The tasks that use them run with `no_log: true`, and error messages redact them.

**One vault id per environment.** Each environment gets its own vault password, so a dev password can
never decrypt prod secrets.

```bash
cp inventory/example/group_vars/oracle_db_servers/vault.yml.example inventory/prod/group_vars/oracle_db_servers/vault.yml
$EDITOR inventory/prod/group_vars/oracle_db_servers/vault.yml          # real values
ansible-vault encrypt --vault-id prod@prompt inventory/prod/group_vars/oracle_db_servers/vault.yml
ansible-vault edit    --vault-id prod@prompt inventory/prod/group_vars/oracle_db_servers/vault.yml
ansible-playbook -i inventory/prod/hosts.yml --vault-id prod@prompt oracle_database_install.yml -e target=...
```

Then map the secrets in `group_vars/oracle_db_servers/main.yml` (the example has these lines commented out):

```yaml
oracle_common_notification_webhook_url: "{{ vault_oracle_notification_webhook_url }}"
oracle_common_artifactory_username: "{{ vault_oracle_artifactory_username }}"
oracle_common_artifactory_password: "{{ vault_oracle_artifactory_password }}"
```

- In automation, `--vault-id prod@/path/outside/the/repo/prod.pass` (a file with mode 0600) or a
  client script can replace `@prompt`. `.gitignore` excludes `.vault_pass*` and `vault_pass*`. Never
  commit a password file or an unencrypted `vault.yml`.
- A single value can also be encrypted inline:
  `ansible-vault encrypt_string --vault-id prod@prompt --name vault_oracle_artifactory_password`.
- **Rotation:** change the vault password regularly, and whenever someone who knew it leaves:
  ```bash
  ansible-vault rekey --vault-id prod@prompt --new-vault-id prod@prompt inventory/prod/group_vars/oracle_db_servers/vault.yml
  ```
  Then update the AAP Vault credential. Rotating the secrets themselves (regenerating the webhook,
  changing the repository token) is a separate step: edit `vault.yml` with the new values.
- In AAP, attach a **Vault credential** with the same vault id (`prod`) to the job template. Or inject
  the three variables with a custom credential type, which needs no vault file.

## Teams notifications (Teams Workflows webhook)

Notifications use a **Teams Workflows** webhook. Office 365 connectors are being retired by Microsoft, and
the playbook no longer uses them. The card is an Adaptive Card 1.4 posted with `ansible.builtin.uri`.

1. In Microsoft Teams, open the channel, then **Workflows**. Pick the template "Post to a channel when a
   webhook request is received" (or "Send webhook alerts to a channel"), choose the team and channel, and
   create it.
2. Copy the generated HTTP POST URL. Treat it as a secret: anyone with it can post to the channel.
3. Store it in the environment's `vault.yml` as `vault_oracle_notification_webhook_url`, and map it to
   `oracle_common_notification_webhook_url` (see above).
4. Optional settings:
   - `oracle_common_job_url_base`, for a "View job" link to AAP.
   - `oracle_common_https_proxy`, if the sender needs a proxy.
   - `oracle_common_notification_ca_path`, for a TLS-inspection CA.
   - `oracle_common_notification_delegate_to: localhost`, to send from the controller or execution
     environment instead of from each target host.

Each card has a title (`Job #<id> '<template>'`), a summary line, and the state ("has
started/completed/failed") in the configured colour. Its facts are Database, Host, Job URL, Running User
and Scheduled Job Name; a failure card adds "Failed step" and "Error". Notifications are best effort: if
the webhook is not set, they are skipped, and if sending fails, a WARNING is shown. A notification never
fails the run.

## Clean target and side-by-side installs

Preflight decides how to proceed before anything is changed on the host.

| Item | Clean target | Existing Oracle on the host (side-by-side) |
|---|---|---|
| ORACLE_HOME | Created. | Absent or empty: used. **Non-empty: refused**, unless `oracle_force_reinstall: true`. For the same release as an installed home, set a new `oracle_home`, e.g. `/u01/oracle/product/19.0.0.0_2`. |
| `/etc/oraInst.loc` | Created, with `inventory_loc=<new inventory>` and `inst_group=<group>`. | **Read and reused, never written** (unless `oracle_database_install_role_force_inventory_pointer` is set). The run fails if it has no valid `inventory_loc`, if an explicitly set inventory or group differs, or if `db_owner` is not in the inventory group. |
| Central inventory | `oracle_database_install_role_new_inventory_location` is created (0770). | The existing one is used. The installer registers the new home in it. |
| `<site prefix>/<DB>.env` | Created. | Other databases' files are never touched. The same name with different content is **refused**, unless `oracle_database_install_role_force_env_file` (or the reinstall flag) is set. Identical content is accepted. |
| Downloads | `<prefix>/software/<DB>_<version>`. | Per database, so concurrent runs for other databases are not affected. |

**Force flags** (prefer per-job extra vars over group_vars):

- `oracle_force_reinstall` (`oracle_database_install_role_force_reinstall`): extract over a non-empty
  home, with a WARNING. A forced home is never removed by rollback.
- `oracle_database_install_role_force_env_file`: replace a different `<DB>.env`. The previous file is
  kept as a timestamped backup next to it (`<DB>.env.<pid>.<date>~`, owner, group and mode preserved)
  unless `oracle_database_install_role_env_file_backup: false`. Rollback leaves the replaced file and the
  backup in place; restore the backup manually if needed.

- `oracle_database_install_role_force_inventory_pointer`: rewrite an existing `/etc/oraInst.loc` that
  names another `inventory_loc` / `inst_group` than requested (the original behaviour). The requested
  inventory is `oracle_database_install_role_inventory_location`, else
  `oracle_database_install_role_new_inventory_location`, and is created if missing. The previous file is
  kept as a timestamped backup next to it (`oraInst.loc.<pid>.<date>~`) and restored by rollback if the
  install fails. This can hide the homes registered in the old inventory from Oracle tools, so it does
  **not** follow `oracle_force_reinstall`; set it only when you mean to move the host to a new inventory.

Without that flag an existing pointer is always respected.

A rerun for a database that already installed successfully is refused at the home check (changed=0). Use
the force flag only if you really mean to reinstall.

## Running root.sh: wrapper or become

`root.sh` (and `clone/rootpre.sh` on AIX, before the installer) runs by one of two methods. Choose with
`oracle_common_root_script_method` (alias `oracle_root_script_method`).

- **`wrapper`** (default, the original flow): the privileged user (`b_user`) runs the site root wrapper
  (`oracle_common_root_wrapper_path`), and `files/root_wrapper.exp` answers its menu: `1`, `1`, the
  path, ENTER, `x`. All values reach the script through its environment. The run fails on:
  - a prompt timeout (`oracle_common_root_wrapper_timeout`);
  - the wrapper ending early;
  - an unexpected prompt or question;
  - a non-zero exit status of the wrapper.

  root.sh's own questions (the local bin directory, and overwriting an existing
  `dbhome`/`oraenv`/`coraenv`) get root.sh's default answer, so another home's copies are kept. On AIX,
  `rootpre.sh` is copied to `clone/root.sh` for the wrapper, and `ROOTPRE_DIR` is exported.
- **`become`**: the script runs directly through `become` as `oracle_common_root_script_become_user`
  (default root). Its standard input is `oracle_common_root_script_stdin`. Use this on hosts without the
  wrapper, such as cloud images where the connection user can become root. The wrapper path is then not
  required.

Both methods require exit status 0, an output that does not match
`oracle_common_root_script_failure_regex`, and an output that matches
`oracle_common_root_sh_success_regex`. A failure triggers the rollback.

## Security defaults

All of these are secure by default. Each one can be changed where there is a legitimate need, except that
world-writable modes are never accepted.

- **SSH host keys are verified** (`host_key_checking = True`). Put the targets' keys in the controller's
  (or the execution environment's) `known_hosts` from a trusted source. For example, use `ssh-keyscan`
  output whose fingerprint you compared with the host console or your provisioning records. Or point at a
  managed file with `ansible_ssh_common_args: "-o UserKnownHostsFile=<file>"`. Disable checking only
  temporarily and knowingly, with `ANSIBLE_HOST_KEY_CHECKING=False`.
- **No world-readable module temp files.** `allow_world_readable_tmpfiles` is not set. To become the
  unprivileged `db_owner`, use one of:
  - POSIX ACLs: install the `acl` package (`setfacl`) on RHEL/Linux targets. Nothing else is needed.
  - A shared group: set `ansible_common_remote_group` (for example to `oracle_common_group_name`) on
    AIX, or on Linux without `setfacl`.
  - Connect as root: set `ansible_user: root` (with or without `b_user: root`). Tasks still become
    `db_owner` where they must, because runInstaller and OPatch refuse to run as root. **Do not set
    `ansible_become_user`.** It overrides every task's `become_user`, so the Oracle home, staging,
    runInstaller and OPatch would all run as root and fail.

  Only if none of these is possible, set `ansible_shell_allow_world_readable_temp: true` for the affected
  hosts in the inventory.
- **Downloads are verified**:
  - The TLS certificate is checked (`oracle_common_artifactory_validate_certs`, with
    `oracle_common_artifactory_ca_path` for an internal CA).
  - Each artifact's checksum is checked (`oracle_common_artifact_checksums`).
  - Credentials are never sent over plain `http://`.
- **Secrets** come from Ansible Vault or AAP credentials, and their tasks run with `no_log`.
- **No world-writable files.** Scripts are 0750, data files 0640, and staging 0750. Everything is owned by
  `db_owner` under `<mountpoint>/<db_owner>/ansible_staging` (not `/tmp`). Staging directories are
  created without following symlinks, then verified.
- **No shell interpolation of inputs.** Scripts run with an argument vector, and the expect script reads
  its values from its environment. There is **no inline `sudo`**: group membership is checked exactly and
  changed through `become`.
- **Input validation**: every input is pattern-checked before use, and `DATABASE_NAME`, user names and
  paths reject shell metacharacters, `..` and trailing newlines.
- **Prerequisites are enforced.** `-ignorePrereq` is passed only with `oracle_ignore_prereqs: true`.
- The env file's PATH no longer ends with `.`. See `oracle_database_install_role_env_path_include_cwd`.

## What the playbook changes on a host

Persistent changes after a **successful** run:

| Change | Owner / mode | Undone by rollback? |
|---|---|---|
| `db_owner` and the privileged user added to `oracle_common_group_name` (if enabled) | OS group | No (shared OS state) |
| `<mountpoint>/<db_owner>` (only if missing) and `<...>/ansible_staging` | `db_owner`, 0755 / 0750 | No |
| Log directory `<staging>/oracle_database_install_<DB>` with `install_status.txt`, `opatch_status.txt`, `opatch_jvm_status.txt` | `db_owner`, 0750 | No (kept for troubleshooting) |
| `<site prefix>/software` (only if missing) | privileged user, 0755 | No |
| ORACLE_HOME with the extracted binaries, `responseFile.rsp`, the RU/OJVM patches and maybe a newer OPatch (`OPatch.old` is kept) | `db_owner`, 0755 | Yes, if this run created it |
| Central inventory directory and `/etc/oraInst.loc` (**clean target only**) | `db_owner`:inst_group 0770 / 0644 | Yes, if this run created them |
| Existing `/etc/oraInst.loc` rewritten, plus a backup `oraInst.loc.<pid>.<date>~` (**only with** `oracle_database_install_role_force_inventory_pointer`) | inst_group 0644 | Yes: the previous content, owner, group and mode are restored (the backup file is kept) |
| The new home's entry in the central inventory (`ContentsXML/inventory.xml`, written by runInstaller) | Oracle installer | Yes (detached) |
| `<site prefix>/<DB>.env` | 0755 | Yes, if this run created it |
| Existing `<DB>.env` replaced, plus a backup `<DB>.env.<pid>.<date>~` (**only with** `oracle_database_install_role_force_env_file` and different content; no backup with `oracle_database_install_role_env_file_backup: false`) | 0755 (backup: previous owner, group and mode) | No: the replaced file and the backup are kept |
| Files written by root.sh as root: `/etc/oratab`, `/usr/local/bin/dbhome`, `oraenv`, `coraenv` (existing copies are not overwritten) | root | No (shared files) |
| AIX: `rootpre.sh` run as root, `<OH>/clone/root.sh` | root / 0755 | With the home |

Removed again by the run itself: the staged scripts (`<staging>/ora_ansible_scripts_<DB>`) and the
download directory (`<site prefix>/software/<DB>_<version>`).

**Never changed**: other Oracle homes, an existing `/etc/oraInst.loc` (unless forced), other databases' env files, and
installed packages. The playbook only checks packages; it does not install any. No database is created,
so `datapatch` is not run.

## Rollback

**Automatic, after a failed install.** If the Install stage fails, `tasks/rollback.yml` removes only what
this run created, as recorded in `oracle_database_install_role_created`:

- a home this run created is removed. A home that was an empty directory before is emptied and kept. A
  non-empty or forced-over home is **never** removed;
- if the failed home is registered in an inventory this run did not create, it is first detached with
  `<home>/oui/bin/runInstaller -silent -waitforcompletion -detachHome`. If that fails, the home is kept
  and a WARNING is shown, so that the shared inventory never ends up with a dangling entry;
- the env file, `oraInst.loc` and the inventory directory are removed if this run created them;
- an `oraInst.loc` rewritten with `oracle_database_install_role_force_inventory_pointer` gets its previous
  content, owner, group and mode back.

The rollback is best effort. A rollback problem is a WARNING and never hides the original error. Set
`oracle_database_install_role_rollback_on_failure: false` to keep everything for troubleshooting.

**Manual, after a successful install.** No playbook removes a working home. If you need to:

1. Make sure no database or listener runs from the home.
2. Detach it from the central inventory as `db_owner`:
   `$ORACLE_HOME/oui/bin/runInstaller -silent -waitforcompletion -detachHome ORACLE_HOME=<home>`.
   Or use Oracle's `$ORACLE_HOME/deinstall/deinstall` tool.
3. Remove the home directory and `<site prefix>/<DB>.env`.
4. Remove `/etc/oraInst.loc` and the inventory directory **only** if this was the only home registered
   in them.

To back out only a patch, use `opatch rollback -id <patch id>` in the home, as described in the patch
README. If OPatch was upgraded, the previous version is in `$ORACLE_HOME/OPatch.old`.

## AAP / Tower usage

1. **Project**: this repository (branch or tag).
2. **Execution environment**: one with ansible-core 2.22 and Python 3.13 or later, and with the targets'
   host keys in `known_hosts` (baked into the image or mounted).
3. **Inventory**: one per environment, sourced from `inventory/<env>/` in the project, or an AAP inventory
   whose `oracle_db_servers` group has the same variables.
4. **Credentials**:
   - a Machine credential (SSH user and key; privilege escalation as needed);
   - a Vault credential with the environment's vault id;
   - optionally, a custom credential type that injects `oracle_common_notification_webhook_url`,
     `oracle_common_artifactory_username` and `oracle_common_artifactory_password` as extra vars,
     instead of a vault file.
5. **Survey / extra vars**: `target`, `DATABASE_NAME`, `db_owner`, `database_version`, `mountpoint`.
   Optional: `ansible_inventory_groups` (set `oracle_db_servers` if the hosts are not in the inventory),
   `oracle_force_reinstall`, `oracle_ignore_prereqs`, `oracle_root_script_method`. Keep the force and
   ignore flags as per-job choices that default to false.
6. Set `oracle_common_job_url_base` (e.g. `https://aap.example.com/#/jobs/playbook/`) so the card links to
   the job.

AAP injects the `tower_*` / `awx_*` variables, and the card uses them.

## Migrating existing job templates

The job inputs `target`, `DATABASE_NAME`, `db_owner`, `database_version`, `mountpoint`,
`ansible_inventory_groups` and `tower_*` are unchanged. Inputs that existing inventories may set keep
working as aliases: `b_user`, `GROUP_NAME`, `remote_script_directory`, `remote_output_directory`,
`script_permission`, `oracle_home`, `patch_folder_prefix`, `install_folder_name`, `artf_ver`,
`artifactory_repo`, `install_file_name`, `patch_file_name` and `notification_webhook_url`.

Before the first run of an existing template:

1. **Use an execution environment with ansible-core 2.22.** The original used `include:`, which no
   current ansible-core accepts. `community.general` is no longer needed.
2. **Add the newly required environment inputs** (inventory group_vars): `oracle_common_artifactory_url`,
   `oracle_common_site_prefix`, and `oracle_common_root_wrapper_path` (or
   `oracle_common_root_script_method: become`), and `oracle_common_group_name`/`GROUP_NAME` (or
   `oracle_common_manage_group_membership: false`). The previous values were placeholders in the code.
3. **Add checksums** for the binaries and patch bundle in `oracle_common_artifact_checksums`, or set
   `oracle_common_artifact_checksum_required: false` knowingly.
4. **Pin the patch bundle** with `oracle_common_patch_file_name`. Otherwise the current-year January
   bundle is used, with a WARNING.
5. **Notifications**: create a Teams Workflows webhook and supply it through Vault or a credential.
   Without it, notifications are skipped.
6. **Host keys**: put the targets' keys in the execution environment's `known_hosts`.
7. **Becoming db_owner**: the targets need ACLs, `ansible_common_remote_group`, or a root connection
   (see [Security defaults](#security-defaults)).
8. **Behaviour that changed on purpose** (each one can be configured back, except 0777):
   - `-ignorePrereq` is off and missing packages fail the run. To get the old behaviour, set
     `oracle_ignore_prereqs: true`.
   - Staging moved from `/tmp` to `<mountpoint>/<db_owner>/ansible_staging`. Set
     `oracle_common_staging_base: /tmp` to move it back.
   - The env file PATH no longer ends with `.`. Because of this, an env file written by an older run now
     differs, and a rerun is refused unless forced or `oracle_database_install_role_env_path_include_cwd:
     true` is set.
   - Downloads are stored per database (`<prefix>/software/<DB>_<version>`).
   - Existing homes, env files and inventories are refused or reused instead of being overwritten.
   - `database_version` values other than the three supported ones are rejected. They no longer fall
     back to 12.1.0.2.
   - root.sh failures now fail the run.

See `CHANGELOG.md` for the full list.

## Testing

Static checks (the same ones CI runs, see `.github/workflows/ci.yml`):

```bash
yamllint .
shellcheck roles/*/files/*.bash
ansible-playbook -i inventory/example/hosts.yml --syntax-check oracle_database_install.yml -e target=dbhost01.example.com
ansible-lint                                   # production profile, no skips
ansible-playbook -i localhost, tests/mode_validation.yml    # permission-mode regression test, controller only
```

Molecule scenarios live under `molecule/`, and their CI workflow is `.github/workflows/molecule.yml`. It
runs on every pull request (no paths filter, because `lint` and `molecule` are required checks on `main`),
on push to `main`, and on demand. To run them locally (the scenarios need a container runtime or VMs, as
configured in each scenario):

```bash
pip install -r requirements-test.txt
molecule test                    # default scenario
molecule test -s <scenario>      # a named scenario; list them with: molecule list
```

Before production, do a dry run in a non-production environment (`--check`, then a real run). Use a host
that already has an Oracle home, to see the refusals, and a clean host, for a full install and patch.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `target is required` | Pass `-e target=<host>[,<host>...]`. |
| `Invalid or missing inputs: ...` | Every listed input failed validation; the message says what is expected. Secret values are never shown. |
| `Validation of arguments failed: missing required arguments: ...` | A required job or environment input is missing. Often the `target` host is not in the `oracle_db_servers` group: pass `-e ansible_inventory_groups=oracle_db_servers` or add the host to `hosts.yml`. |
| `Failed: OS not supported (<system>)` | The kernel is not in `oracle_common_supported_systems`, or there is no `vars/<system>.yml`. |
| `The module interpreter ... was not found` / Python version errors | The target needs Python 3.9 or later. Set `ansible_python_interpreter` (see [Supported platforms](#supported-platforms-and-oracle-versions)). |
| `Host key verification failed` | Add the host key to `known_hosts` (see [Security defaults](#security-defaults)). |
| `Failed to set permissions on the temporary files Ansible needs to create when becoming an unprivileged user` | Install `acl`, set `ansible_common_remote_group`, or connect as root. |
| ORACLE_HOME `exists and is not empty` | That home is in use. For a side-by-side install, set a new `oracle_home`. To reinstall on purpose, set `oracle_force_reinstall: true`. |
| Environment file differs | Another run wrote `<DB>.env` with other content (for example an older run with `.` in PATH). Check it, then force it or align the settings. |
| Inventory pointer / group mismatch, or `db_owner` not in the inventory group | The existing `/etc/oraInst.loc` is not rewritten by default. Add `db_owner` to its `inst_group`, or clear the explicit inventory settings, or (only if you mean to move the host to another inventory) set `oracle_database_install_role_force_inventory_pointer: true`. |
| `Missing prerequisite packages on <host> (N): ...` | Install them (nothing was changed on the host), or set `oracle_ignore_prereqs: true` knowingly. |
| `no checksum for ...` / checksum mismatch | Add the correct digest to `oracle_common_artifact_checksums`. A mismatch means the file differs from the one you recorded. |
| `Download of <file> failed (HTTP ...)` | Check the repository URL, credentials, CA bundle and proxy settings. The URL and password are redacted in the message. |
| `root.sh ... did not succeed (wrapper method, rc=N: ...)`: rc 1 invalid wrapper environment, 2 timed out waiting for a prompt, 3 wrapper ended early, 4 unexpected prompt or question, 5 wrapper exited non-zero; or `Output lacks the success pattern` | Check the wrapper's prompts against `files/root_wrapper.exp`. If the wrapper hides root.sh's output, set `oracle_common_root_sh_success_regex: ""`. Or use the `become` method. |
| `database_install.bash (runInstaller)` / `database_patch.bash (OPatch)` failed | See `install_status.txt` / `opatch_status.txt` / `opatch_jvm_status.txt` in the log directory, and the installer logs in the central inventory's `logs/`. |
| `still running when polling stopped` / `Timeout exceeded` | Raise `oracle_database_install_role_install_timeout` / `_patch_timeout`. |
| `WARNING: ... notification was not sent` | Check the webhook URL, proxy and CA settings. The run is not affected. |
| Staging directory `must be a real directory owned by <db_owner>` | Something else created that path. Remove it, or choose another `oracle_common_staging_base`. |

## License

The automation code in this repository is licensed under the GNU General Public License v3.0 or later
(`GPL-3.0-or-later`). The full text is in [LICENSE](LICENSE).

The licence does not cover Oracle Database software, OPatch, Oracle patches or the Oracle installer
response-file format, which you must license from Oracle. It also does not cover Red Hat Enterprise
Linux, IBM AIX or their packages, which Red Hat and IBM license under their own terms. Artifacts
downloaded from your repository keep their own licences. [NOTICE](NOTICE) gives the details, the
trademarks, and the files that are covered only in part.
