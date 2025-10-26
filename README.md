# Online Users (SSH + UDP) – Port 81

Tiny HTTP endpoint that shows **online user count** for your VPS:
- `/server/online` → number (SSH + UDP total)
- `/server/online?mode=ssh` → SSH only
- `/server/online?mode=udp` → UDP only
- `/server/online.json` → JSON breakdown

Default UDP ports counted: **36712/udp** (AGN-UDP/Hysteria).  
You can add more via `UDP_PORTS` (comma-separated).

## Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR_GH_USER>/<YOUR_REPO>/main/online-user.sh | sudo bash
