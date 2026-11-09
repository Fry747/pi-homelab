# Working on pi-homelab

- Treat this repository as public. Edit Compose, scripts, documentation, and reviewed configuration templates in the local checkout. Keep real host configuration, credentials, databases, OAuth state, exports, and backups outside commits, logs, and chat.
- Use `.env.example` for validation. Do not read, print, or copy live `.env` files, HA `.storage`, private keys, or container environment values. Run `docker compose config --quiet` so it does not print resolved values.
- Use the existing `pi` SSH alias. Start with a single read-only command. Show the full command and request one-time approval for remote access. Never use a persistent approval for `ssh pi`, a shell, `sudo`, or Docker.
- Prepare changes in a branch and show the diff and validation result. Ask for explicit approval before changing the Pi, deploying or restarting a stack, applying a migration, or merging a PR. Include the target stack, expected downtime, and rollback steps.
- Use only read-only Home Assistant MCP tools during routine work. Any change to a device, helper, automation, entity exposure, or permission needs a separate approval for the specific action. Keep locks, alarms, and other safety-critical devices outside the MCP scope.
