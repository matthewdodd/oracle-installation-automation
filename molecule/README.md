# Molecule tests

`molecule/default` runs the unmodified `oracle_database_install.yml` end to end in RHEL-compatible
containers (docker driver). The Oracle software in the test is fake: stub `runInstaller`, `root.sh`,
`opatch` and a stub site root wrapper (`default/files/stubs/`) that behave like the parts the playbook
relies on and print the success lines its scripts check.

| Instance | Image | Covers |
|---|---|---|
| `el8-clean` | Rocky Linux 8.10 | Clean target. root.sh through the stub root wrapper (`wrapper` method, expect dialogue). |
| `el9-clean` | AlmaLinux 9.6 | Clean target. root.sh directly through become (`become` method). |
| `el9-sbs` | AlmaLinux 9.6 | Side-by-side. Another Oracle home at the default path, `/etc/oraInst.loc` with its central inventory, and another database's environment file already exist. Uses the original input names `oracle_home`, `GROUP_NAME` and `oracle_root_script_method`. |

`prepare.yml` installs the role's own prerequisite package list for the release, creates the OS users
and groups, builds the fake repository (`default/files/build_artifacts.bash`) and serves it over HTTP on
127.0.0.1 inside each container. Downloads are checked against published SHA-256 files, so the
"checksum required" default stays on.

`verify.yml` checks:

- the home exists (owner, mode), is registered in the central inventory, and root.sh ran as root;
- the installer was called without `-ignorePrereq`, with the expected response file;
- `/etc/oraInst.loc` was created on clean targets and left byte-for-byte unchanged on `el9-sbs`, together
  with the existing home and environment file;
- the environment file content (sourced with bash; no `.` on PATH);
- the Release Update and OJVM patch are applied and OPatch was upgraded;
- the software and script staging are removed and the logs kept, and the group membership;
- the guards refuse the installed home, the existing home, and the existing database's environment file;
- idempotence: `converge.yml` runs a second time, is refused by the ORACLE_HOME guard with `changed=0`,
  and nothing under the mountpoint, the site prefix or `/etc/oraInst.loc` changes (content, mode,
  owner, timestamps). This replaces Molecule's built-in `idempotence` step, which needs a second run
  that succeeds. The playbook refuses on purpose to install over the home it created.

Run from the repository root, with Docker and rsync available:

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-test.txt
molecule test                      # create, prepare, converge, verify, destroy
molecule converge && molecule verify   # keep the containers for debugging; molecule destroy afterwards
```

CI runs the same on pull requests that change roles, the playbook or the tests
(`.github/workflows/molecule.yml`).

Not covered: AIX (no container image; `rootpre.sh`, `lslpp` and `chgrpmem` are tested only by reading
and by the controller-side checks), real Oracle software, and the Teams notification (no webhook).
