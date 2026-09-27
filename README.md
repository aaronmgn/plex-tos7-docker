# Plex on TerraMaster TOS

Production-oriented Plex Media Server deployment for a TerraMaster TNAS running TOS and Docker Compose.

This setup is based on the working TNAS configuration:

- Plex runs from the official `plexinc/pms-docker` image.
- Plex uses host networking.
- Intel Quick Sync is exposed through `/dev/dri`.
- Plex persistent data lives under `/Volume1/Docker/plex`.
- Compose and `.env` live under `/Volume1/Docker/compose-files/plex`.
- Media lives under `/Volume1/VideoFS`.
- Media is mounted read-only inside Plex.
- TNAS ACL access is provided through the host `admin` group.
- The installer is idempotent and does **not** wipe an existing Plex installation.
- The installer never starts a Plex library scan.

## Files

The installer manages:

```text
/Volume1/Docker/compose-files/plex/
├── .env
├── docker-compose.yaml
└── setup-plex.sh
```

Plex persistent state is stored separately:

```text
/Volume1/Docker/plex/
├── config/
└── transcode/
```

Media defaults to:

```text
/Volume1/VideoFS/
├── Movies/
├── TV/
├── Anime/
├── Other/
└── YouTube/
```

Inside the Plex container those directories become:

```text
/media/Movies
/media/TV
/media/Anime
/media/Other
/media/YouTube
```

The names are case-sensitive.

---

## Installation

Place `setup-plex.sh` at:

```text
/Volume1/Docker/compose-files/plex/setup-plex.sh
```

Make it executable:

```bash
chmod +x /Volume1/Docker/compose-files/plex/setup-plex.sh
```

Run it:

```bash
/Volume1/Docker/compose-files/plex/setup-plex.sh
```

On the first run the script creates:

```text
/Volume1/Docker/compose-files/plex/.env
```

The script then validates the TNAS, prepares permissions, generates `docker-compose.yaml`, pulls Plex, and starts or updates the container.

Running the script again is safe. It does not delete the Plex database, metadata, libraries, account state, or media.

---

## `.env`

Default configuration:

```dotenv
TZ=America/Vancouver

PLEX_UID=1000
PLEX_GID=1000

PLEX_DATA_ROOT=/Volume1/Docker/plex
PLEX_MEDIA_ROOT=/Volume1/VideoFS

PLEX_MEDIA_DIRS=Movies,TV,Anime,Other,YouTube

PLEX_MEDIA_GID=998

PLEX_CLAIM=

PLEX_ADVERTISE_IP=
PLEX_ENABLE_ADVERTISE_IP=false
```

### Selecting media directories

`PLEX_MEDIA_DIRS` controls which folders are exposed to Plex.

For example:

```dotenv
PLEX_MEDIA_DIRS=Movies,TV,Anime
```

generates these read-only mounts:

```text
/Volume1/VideoFS/Movies -> /media/Movies
/Volume1/VideoFS/TV     -> /media/TV
/Volume1/VideoFS/Anime  -> /media/Anime
```

To expose all current libraries:

```dotenv
PLEX_MEDIA_DIRS=Movies,TV,Anime,Other,YouTube
```

Directory names are case-sensitive. `YouTube` and `Youtube` are different paths on Linux.

If a directory name contains spaces, quote the `.env` value:

```dotenv
PLEX_MEDIA_DIRS="Movies,TV,Home Videos"
```

---

## Claiming Plex

An existing claimed server does not need another claim code.

For a brand-new or unclaimed Plex server:

1. Sign in to Plex.
2. Open `https://www.plex.tv/claim`.
3. Copy the temporary `claim-...` code.
4. Edit `.env`:

```dotenv
PLEX_CLAIM=claim-xxxxxxxxxxxxxxxxxxxx
```

5. Immediately run:

```bash
/Volume1/Docker/compose-files/plex/setup-plex.sh
```

Claim codes are short-lived.

The official Plex container ignores `PLEX_CLAIM` when the server is already signed in, but after a successful first claim it is still reasonable to clear the temporary code:

```dotenv
PLEX_CLAIM=
```

The installer backs up the existing `Preferences.xml` before a Compose update. If a previously claimed server unexpectedly loses its claim during deployment, the installer attempts to restore the saved account state.

---

## Intel Quick Sync

The script requires:

```text
/dev/dri/card0
/dev/dri/renderD128
```

It discovers their numeric group IDs dynamically and adds them to the Plex container using Compose `group_add`.

On the current TNAS they have been:

```text
card0       -> GID 44
renderD128  -> GID 109
```

The media ACL group is configured separately:

```dotenv
PLEX_MEDIA_GID=998
```

On this TNAS, GID `998` is the TOS `admin` group that has access to the `VideoFS` ACL tree.

The resulting Compose configuration includes all required supplementary groups.

After Plex is running, enable hardware transcoding in Plex under:

```text
Settings
→ Transcoder
→ Use hardware acceleration when available
→ Use hardware-accelerated video encoding
```

A Plex Pass is required for Plex hardware transcoding.

---

## TNAS permissions

TOS applies ACLs in addition to normal Unix ownership and mode bits.

The installer ensures the TNAS `admin` ACL exists on:

```text
/Volume1/Docker/plex
/Volume1/VideoFS
```

and each media directory selected through `PLEX_MEDIA_DIRS`.

It also enables ACL inheritance on the configured media folders.

This matters because a directory may appear to have normal Linux read permissions while TOS still denies access through its ACL layer.

Media is exposed to Plex with `:ro`, so Plex receives read-only Docker mounts even though the host-side TNAS ACL permits the host admin group to access the files.

---

## Media library setup

The installer intentionally does **not** create Plex libraries or trigger a media scan.

Add the libraries manually through Plex Web.

Recommended paths:

| Plex library | Container path |
|---|---|
| Movies | `/media/Movies` |
| TV Shows | `/media/TV` |
| Anime | `/media/Anime` |
| Other Videos | `/media/Other` |
| YouTube | `/media/YouTube` |

The actual media remains at `/Volume1/VideoFS/...` on the TNAS. Plex only sees the container paths.

---

## Plex access

With host networking, Plex listens directly on the TNAS:

```text
http://<TNAS-IP>:32400/web
```

Find TNAS addresses with:

```bash
hostname -I
```

Verify Plex is listening with:

```bash
ss -lntp | grep ':32400'
```

---

## Optional advertised address / external IP

The generated Compose contains the following setting commented out by default:

```yaml
# ADVERTISE_IP: "${PLEX_ADVERTISE_IP:-}"
```

Plex documents `ADVERTISE_IP` as an additional address the server advertises to clients. It does **not** force the WAN/Public IP shown on Plex's Remote Access page.

It is normally unnecessary with `network_mode: host`.

If you intentionally need it, edit `.env`:

```dotenv
PLEX_ADVERTISE_IP=http://203.0.113.10:32400/
PLEX_ENABLE_ADVERTISE_IP=true
```

Then rerun:

```bash
./setup-plex.sh
```

To disable it again:

```dotenv
PLEX_ENABLE_ADVERTISE_IP=false
```

and rerun the script.

---

## Updating Plex

The image uses:

```yaml
image: plexinc/pms-docker:latest
```

To update Plex, simply rerun:

```bash
cd /Volume1/Docker/compose-files/plex
./setup-plex.sh
```

The script performs:

```text
docker compose pull
docker compose up -d
```

It deliberately does **not** use `--force-recreate`.

If the resolved configuration has not changed, Docker leaves the existing container alone.

---

## Verify the deployment

Container status:

```bash
cd /Volume1/Docker/compose-files/plex
docker compose -f docker-compose.yaml ps
```

Health:

```bash
docker inspect plex --format='{{.State.Health.Status}}'
```

Claim state:

```bash
docker exec plex curl -fsS http://127.0.0.1:32400/identity
```

Look for:

```text
claimed="1"
```

GPU devices:

```bash
docker exec plex ls -ln /dev/dri
```

Configured supplementary groups:

```bash
docker inspect plex --format='{{json .HostConfig.GroupAdd}}'
```

Mounts:

```bash
docker inspect plex --format \
'{{range .Mounts}}{{println .Source "->" .Destination "RW:" .RW}}{{end}}'
```

Check what Plex can actually read:

```bash
for d in Movies TV Anime Other YouTube; do
    printf '%-12s ' "$d"
    docker exec -u 1000:1000 plex \
        sh -c "find '/media/$d' -type f 2>/dev/null | wc -l"
done
```

This does not trigger a Plex scan.

---

## Troubleshooting media permissions

If Plex can mount a directory but cannot scan its contents, first test it as the Plex UID:

```bash
docker exec -u 1000:1000 plex ls /media/Movies
```

Compare host and container file counts:

```bash
HOST=$(find /Volume1/VideoFS/Movies -type f 2>/dev/null | wc -l)
PLEX=$(docker exec -u 1000:1000 plex \
    sh -c "find /media/Movies -type f 2>/dev/null | wc -l")

echo "host=$HOST plex=$PLEX"
```

Check the TNAS ACL:

```bash
tmacltool get /Volume1/VideoFS
tmacltool get /Volume1/VideoFS/Movies
```

Check a newly created file and its parent:

```bash
tmacltool get "/Volume1/VideoFS/Movies/<folder>/<file>"
tmacltool get "/Volume1/VideoFS/Movies/<folder>"
```

Plex must be able to traverse every parent directory and read the media file.

---

## Movies visible to Plex but not added

If host and container file counts match and Plex can read the files, permissions are no longer the problem.

Plex recommends organizing movies as:

```text
Movies/
└── Movie Name (Year)/
    └── Movie Name (Year).mkv
```

Release-group prefixes, torrent-site names, and excessive release metadata in the directory name can make matching less reliable.

When Plex logs show it successfully processing the movie directory but the title still does not appear, investigate naming and matching rather than filesystem permissions.

---

## YouTube capitalization

The working convention for this deployment is:

```text
Host:
/Volume1/VideoFS/YouTube

Container:
/media/YouTube
```

Keep the capital `T` consistent in `.env`, Compose, and Plex.

---

## Backups

The Plex database, server identity, account token, metadata, artwork, and library configuration are all under:

```text
/Volume1/Docker/plex/config
```

Back this directory up.

The installer may also create:

```text
/Volume1/Docker/plex/Preferences.xml.setup-plex.backup
```

before applying a configuration that could recreate the container.

The media itself is not stored under the Plex config tree.

---

## Resetting Plex

The installer does **not** reset Plex.

If a full reset is ever intentionally required, stop Plex first and separately remove:

```text
/Volume1/Docker/plex/config
/Volume1/Docker/plex/transcode
```

Do not add that behavior to the normal installer. Keeping reset and deployment as separate operations prevents an accidental run from destroying the Plex database.

---

## References

- Official Plex Docker image: https://github.com/plexinc/pms-docker
- Plex claim page: https://www.plex.tv/claim
- Docker Compose service reference: https://docs.docker.com/reference/compose-file/services/
