# Operating pi-homelab with Git and Codex

## What belongs in Git

Keep the existing `containers/<stack>/` layout. Track Compose manifests, `.env.example` files with placeholders, reviewed service configuration, scripts, and this runbook. Keep the developer checkout separate from the live installation under `/opt/pi-homelab`. The live Home Assistant `config/` directory is a runtime mount. If you add versioned Home Assistant YAML, keep reviewed source files in `containers/homeassistant/managed/` and deploy each selected file explicitly. Use Home Assistant `!secret` references for values stored on the Pi.

Store the live `.env` files, Home Assistant `secrets.yaml`, OAuth credentials, databases, and backups outside Git. Keep encrypted HA backups and service-specific database or volume backups on separate storage. Keep the [HA backup emergency kit](https://www.home-assistant.io/more-info/backup-emergency-kit) separately in a password manager or other protected storage. Test restoring a backup before relying on it for rollback.

## Review and deploy one stack at a time

1. Create a feature branch. Validate the files with placeholders from the checkout, then review the staged diff before publishing.

   ```bash
   bash -n install.sh
   for file in containers/*/docker-compose.yml; do
     docker compose --env-file "${file%/*}/.env.example" -f "$file" config --quiet || break
   done
   git ls-files -ci --exclude-standard
   git diff --cached --check
   ```

2. Open a pull request to `main`. In [GitHub branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches), require a pull request and the `validate` status check after its first successful run. Block force pushes and deletion. Require an approving review when a second maintainer is available. Enable [secret scanning and push protection](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-security-and-analysis-settings-for-your-repository) where available. The workflow uses placeholders and has read-only repository access.
3. On the Pi, compare the reviewed manifest with the running stack's paths, ports, and Compose project name. Record the current image version or digest and keep the previous manifest. Pin the tested image version or digest in the deployment change. Verify a recent backup outside Git before any update that could migrate data.
4. After approving the deploy, stage only the reviewed files for that stack. Preserve the existing `.env`, named volumes, and bind mounts. From the existing deployment directory, validate using `docker compose config --quiet`. Apply the reviewed Compose change in an agreed maintenance window with `docker compose up -d`, then check `docker compose ps` and the service's own health. For rollback, use the prior manifest and image. If the new version migrated persistent data, restore the compatible backup as part of rollback.

`install.sh` is for a fresh target directory. It will refuse an existing target before it installs anything. On a running Pi, deploy one reviewed stack at a time. For Pi-hole, check the running data path before deploying the DNS manifest. Older setups may use `etc-pihole/` or `pihole/etc-pihole/`. Set `PIHOLE_DATA_DIR` in the live DNS `.env` to the exact existing path if it differs from the manifest's default.

```bash
docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' pihole
```

## Codex and SSH in VS Code

Open the local checkout in VS Code. The Codex extension uses the local SSH client and the existing `Host pi` entry in `~/.ssh/config`. Verify the Pi's host key independently if SSH reports that it is unknown or changed. Use the VS Code [Remote - SSH](https://code.visualstudio.com/docs/remote/ssh) extension when you explicitly need a remote workspace. It runs the remote terminal on the Pi.

For manual prompts, set the following top-level keys in the local Codex user config, `~/.codex/config.toml`. Merge them with your existing settings and keep them above the first table. See [Codex permissions](https://learn.chatgpt.com/docs/sandboxing).

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
approvals_reviewer = "user"
```

Keep network access restricted and approve individual SSH commands. An `ssh pi` prefix includes arbitrary remote commands, so use **Allow once** for a reviewed command. For unattended diagnostics, use a dedicated SSH account and key with a server-side fixed diagnostic command, no forwarding, and no `sudo` or Docker socket access. [Docker group membership grants root-level privileges](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user).

First prompt for Codex in VS Code:

> Ask for one-time approval to run only `ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o ClearAllForwardings=yes -o ForwardAgent=no -T pi 'uname -srm'`. Return the OS, kernel, and architecture.

Second prompt:

> Review the local branch diff and validate the Compose files using only `.env.example` and `config --quiet`. Report the changed files and checks that ran.

## Home Assistant MCP

Use [Home Assistant's official Model Context Protocol integration](https://www.home-assistant.io/integrations/mcp_server#configuration), the server integration. Server-side **Read-only** requires [Home Assistant 2026.11 or later](https://www.home-assistant.io/changelogs/core-2026.11). Schedule a separate, backed-up update of the Home Assistant Container if the running version is older.

1. As a Home Assistant administrator, go to **Settings → Devices & services → Add integration → Model Context Protocol**. Open **Configure**. Disable **Expose all AI tools**, select only **Device control**, enable **Read-only**, and disable **Require an administrator account** to permit a dedicated non-admin OAuth account. Choose one harmless sensor to test and review the entities already exposed to Assist. Assist exposure is shared with the voice assistant.
2. Copy the **Main URL** from **Settings → System → AI**. It ends in `/api/mcp`. Use the URL reachable from the local Codex process over your LAN or VPN, preferably HTTPS. The per-tool-set endpoint `/api/mcp/assist` bypasses the main URL's read-only setting.
3. In this trusted checkout, create `.codex/config.toml` or edit the existing local configuration. Use your own Main URL and keep the file local. See [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=ide).

   ```toml
   [mcp_servers.homeassistant]
   url = "https://homeassistant.example.invalid/api/mcp"
   enabled = true
   default_tools_approval_mode = "prompt"
   ```

4. From that same checkout, run `codex mcp login homeassistant` and sign in in the browser as the dedicated Home Assistant account. If your CLI cannot find the project-scoped server, pass the same Main URL for this login using `codex mcp login homeassistant -c 'mcp_servers.homeassistant.url="https://homeassistant.example.invalid/api/mcp"'`. Use `/mcp` in a new Codex session in the trusted VS Code project to check the connection. If OAuth discovery fails, verify the URL and Home Assistant's configured internal URL, and update Codex to a version that supports OAuth Client ID Metadata Documents.
5. Ask Codex to use only the Home Assistant MCP server, list the available tool names, then read the state of the test sensor. A healthy first test lists read tools, returns the selected state, and offers no device-control actions through the configured Main URL. If write tools appear, stop and check the Home Assistant integration options and URL.

To disconnect, set `enabled = false` and revoke the client's refresh token in the dedicated Home Assistant user's profile. Run `codex mcp logout homeassistant` to clear Codex's saved credentials, using the same URL override if needed.
