# join

One script, `j.txt`, that adds a Windows PC to a private mining-monitor setup. It holds no secrets: only the address of one private server (reachable over Tailscale only) and that server's certificate fingerprint.

It asks for a one-time join code, installs Tailscale (signature checked) or reuses the one already on the PC, and then fetches the real installer from the server over Tailscale. Read `j.txt` before running anything as administrator.
