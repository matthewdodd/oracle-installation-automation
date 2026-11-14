# Inventories

One directory per environment. `dev/`, `test/` and `prod/` are skeletons with default names: rename
them or add more to match your environments. `example/` is a filled-in reference and is used by CI.

```
inventory/<env>/
  hosts.yml                                       hosts, in group oracle_db_servers (empty in the skeletons)
  group_vars/oracle_db_servers/main.yml           environment configuration (non-secret)
  group_vars/oracle_db_servers/vault.yml.example  fake secrets and the vault steps for this environment
  group_vars/oracle_db_servers/vault.yml          secrets, encrypted with --vault-id <env> (you create it)
  host_vars/<host>.yml                            per-host overrides (optional)
```

Always pass the inventory explicitly (`ansible.cfg` names none):

```sh
ansible-playbook -i inventory/<env>/hosts.yml --vault-id <env>@prompt oracle_database_install.yml -e target=...
```

## Filling in a skeleton

1. `hosts.yml`: replace `hosts: {}` with the environment's database servers. Hosts given only in
   `-e target=...` get this environment's `group_vars` only with `-e ansible_inventory_groups=oracle_db_servers`.
2. `group_vars/oracle_db_servers/main.yml`: replace every `<CHANGE_ME>` (repository URL, site prefix, root
   wrapper path or `oracle_common_root_script_method: become`, group name or
   `oracle_common_manage_group_membership: false`, and the sha256 checksums). The input validation rejects
   the placeholders, so a run stops before changing any host until they are replaced. Optional settings
   are commented out.
3. Secrets (optional: Teams webhook URL, repository credentials): create `vault.yml` as below. The
   `vault_*` mappings at the end of `main.yml` are already wired; without `vault.yml` they fall back to
   the role defaults (no notification, no credentials).

## Renaming or adding an environment

- Rename: `git mv inventory/dev inventory/<name>`, then replace `dev` in the comments of its files and use
  `<name>` as the vault id (`--vault-id <name>@prompt`, the AAP Vault credential's Vault Identifier).
  A `vault.yml` that already exists must be re-keyed to the new id:
  `ansible-vault rekey --vault-id dev@prompt --new-vault-id <name>@prompt <path>/vault.yml`.
- Add: `cp -R inventory/test inventory/<name>`, replace `test` in the copied comments, and give it its own
  vault id and password.

## Secrets (Ansible Vault)

One vault id and password per environment, so a dev password never opens prod secrets:

```sh
cp inventory/<env>/group_vars/oracle_db_servers/vault.yml.example inventory/<env>/group_vars/oracle_db_servers/vault.yml
$EDITOR inventory/<env>/group_vars/oracle_db_servers/vault.yml
ansible-vault encrypt --vault-id <env>@prompt inventory/<env>/group_vars/oracle_db_servers/vault.yml
head -n 1 inventory/<env>/group_vars/oracle_db_servers/vault.yml   # $ANSIBLE_VAULT;1.2;AES256;<env>
```

Edit later with `ansible-vault edit --vault-id <env>@prompt ...`; rotate with
`ansible-vault rekey --vault-id <env>@prompt --new-vault-id <env>@prompt ...`. In AAP, attach a Vault
credential with Vault Identifier `<env>` to the environment's job template. Never commit a vault password
file (`.gitignore` excludes `.vault_pass*` and `vault_pass*`).

**CI rejects unencrypted vault files.** The `lint` job of `.github/workflows/ci.yml` fails when any
committed `vault.yml` / `vault.yaml`, or any file under `group_vars/` or `host_vars/` whose name (or
directory) starts with `vault`, does not start with the `$ANSIBLE_VAULT;` header. `*.example` files are
exempt (Ansible does not load them). If it fires, the secrets are already in the git history: rotate them,
then encrypt the file.
