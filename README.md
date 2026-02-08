# pi-homelab

A lightweight, reproducible **Raspberry Pi homelab stack** built around **Docker Compose**.

This repository provides a clean folder structure, ready-to-run Compose files, and an optional installation helper script to quickly bootstrap a fresh Raspberry Pi OS system.

---

## ✨ Included Services (Container Stack)

- **Home Assistant** (`homeassistant`)
- **Mosquitto MQTT Broker** (`mosquitto`)
- **InfluxDB** (`influxdb`)
- **Grafana** (`grafana`)
- **Pi-hole DNS** (`pihole`)
- **Unbound Recursive DNS Resolver** (`unbound`)
- **Portainer** (`portainer`)
- *(Optional)* **Traefik Reverse Proxy** (`traefik`)

---

## 🎯 Goals of this Repo

- Minimal complexity (easy to understand and maintain)
- Reproducible setup (works the same on every Pi)
- Clean Docker Compose structure (one stack per folder)
- Easy extension (add more services later without redesigning everything)
- Suitable for Home Assistant + Energy Monitoring setups

---

## 📁 Repository Structure

Example layout:

```
pi-homelab/
├─ README.md
├─ install.sh
├─ containers/
│  ├─ dns/
│  │  ├─ docker-compose.yml
│  │  ├─ .env.example
│  │  ├─ pihole/
│  │  │  └─ etc-pihole/
│  │  └─ unbound/
│  │     └─ unbound.conf
│  ├─ portainer/
│  │  ├─ docker-compose.yml
│  │  └─ .env.example
│  ├─ homeassistant/
│  │  ├─ docker-compose.yml
│  │  └─ .env.example
│  ├─ mqtt/
│  │  ├─ docker-compose.yml
│  │  └─ mosquitto.conf
│  ├─ influxdb/
│  │  ├─ docker-compose.yml
│  │  └─ .env.example
│  └─ grafana/
│     ├─ docker-compose.yml
│     └─ .env.example
└─ docs/
   └─ cheatsheet.md
```

Each stack is self-contained and can be started independently.

---

## 🚀 Installation (Raspberry Pi OS)

### 1) Clone the repo

```bash
git clone https://github.com/<your-user>/pi-homelab.git
cd pi-homelab
```

### 2) Run install script (optional)

```bash
chmod +x install.sh
./install.sh
```

The install script is intended to:

- install Docker + Docker Compose
- create `/opt/containers/`
- copy all stack folders from `containers/` into `/opt/containers/`
- copy `.env.example` → `.env` if missing
- set correct permissions

---

## 🧩 Starting Services

After installation, stacks are located under:

```
/opt/containers/<stack-name>
```

Example:

```bash
cd /opt/containers/dns
docker compose up -d
```

Check status:

```bash
docker compose ps
```

View logs:

```bash
docker compose logs -f
```

Stop stack:

```bash
docker compose down
```

---

## 🛠️ Configuration

### Environment Files

Most stacks use a `.env` file.

Example:

```bash
cp .env.example .env
nano .env
```

---

## 🧠 Recommended Startup Order

Suggested order for first deployment:

1. `dns` (Pi-hole + Unbound)
2. `portainer`
3. `homeassistant`
4. `mqtt`
5. `influxdb`
6. `grafana`
7. *(optional)* `traefik`

---

## 🔒 Notes about DNS (Pi-hole + Unbound)

Pi-hole uses Unbound as upstream DNS resolver.

This setup provides:

- local DNS filtering (ads, tracking)
- recursive DNS resolution (no third-party upstream resolver needed)
- optional DNSSEC validation

---

## 📊 Notes about Metrics (InfluxDB + Grafana)

InfluxDB is intended as long-term storage for:

- Home Assistant sensor history
- Shelly energy meter data
- MQTT sensor streams

Grafana is used for:

- dashboards
- energy monitoring visualization
- long-term trend analytics

---

## 🧰 Portainer

Portainer provides a web UI to manage Docker containers.

Default access:

- `https://<pi-ip>:9443`

---

## 🌐 Optional Traefik (Future)

Traefik can be added later for:

- HTTPS reverse proxy
- local domains like `pihole.home`, `grafana.home`, `ha.home`
- internal TLS using a custom CA

This is intentionally optional to keep the base setup minimal.

---

## 📌 System Updates

Recommended update cycle:

```bash
sudo apt update
sudo apt upgrade -y
```

Docker containers do not need to be stopped during apt upgrades in most cases.

To update container images:

```bash
docker compose pull
docker compose up -d
```

---

## 📜 License

This repository is intended for personal / homelab use.
Feel free to fork and adapt it for your own setup.

---

## 👨‍🔧 Author Notes

Built and tested for Raspberry Pi OS (Debian based) with a Raspberry Pi 4 booting from SSD.
