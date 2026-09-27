#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Plex on TerraMaster TOS
#
# Idempotent, non-destructive deployment/configuration script.
#
# - Preserves existing Plex database, metadata, libraries, and claim state
# - Does NOT delete media
# - Does NOT trigger a Plex library scan
# - Creates/updates docker-compose.yaml
# - Creates .env on first run and preserves it thereafter
# - Configures TNAS ACLs required for Plex to read VideoFS
# - Configures Intel Quick Sync /dev/dri passthrough
# - Dynamically exposes media directories listed in .env
###############################################################################

COMPOSE_DIR="/Volume1/Docker/compose-files/plex"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yaml"
LEGACY_COMPOSE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"

mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

###############################################################################
# Helpers
###############################################################################

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

ensure_env_key() {
    local key="$1"
    local value="$2"

    if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

ensure_acl() {
    local pathname="$1"
    local acl="$2"
    local current

    current="$(tmacltool get "$pathname" 2>/dev/null || true)"

    if printf '%s\n' "$current" | grep -Fq "$acl"; then
        echo "ACL already present: $pathname"
    else
        echo "Adding ACL: $pathname"
        tmacltool add "$pathname" "$acl"
    fi
}

wait_for_health() {
    echo
    echo '=== WAITING FOR PLEX HEALTH ==='

    local i health

    for i in $(seq 1 30); do
        if ! docker inspect plex >/dev/null 2>&1; then
            echo "Waiting for container... $i/30"
            sleep 2
            continue
        fi

        health="$(
            docker inspect plex \
                --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                2>/dev/null || true
        )"

        echo "Health: $health"

        if [ "$health" = "healthy" ]; then
            return 0
        fi

        sleep 2
    done

    return 1
}

###############################################################################
# Create/update .env
###############################################################################

if [ ! -f "$ENV_FILE" ]; then
    echo '=== CREATING DEFAULT .env ==='

    cat > "$ENV_FILE" <<'EOF'
###############################################################################
# Plex TNAS configuration
###############################################################################

TZ=America/Vancouver

# Plex process identity inside the container.
PLEX_UID=1000
PLEX_GID=1000

# Persistent Plex storage.
PLEX_DATA_ROOT=/Volume1/Docker/plex

# Host directory containing Plex media libraries.
PLEX_MEDIA_ROOT=/Volume1/VideoFS

# Comma-separated directories to expose to Plex.
#
# Each:
#   /Volume1/VideoFS/<name>
#
# is exposed read-only as:
#   /media/<name>
#
# Names are CASE-SENSITIVE.
PLEX_MEDIA_DIRS=Movies,TV,Anime,Other,YouTube

# TNAS group with ACL access to VideoFS.
# On this TNAS, admin is GID 998.
PLEX_MEDIA_GID=998

# Optional first-run Plex claim code.
#
# Get a fresh code from:
#   https://www.plex.tv/claim
#
# Then set:
#   PLEX_CLAIM=claim-xxxxxxxxxxxxxxxxxxxx
#
# Run setup-plex.sh immediately after obtaining the code.
#
# Leave blank for an already-claimed server.
PLEX_CLAIM=

# Optional additional address Plex should advertise.
#
# This is normally unnecessary with network_mode: host and does NOT force
# the WAN/Public IP displayed by Plex Remote Access.
#
# Example:
# PLEX_ADVERTISE_IP=http://203.0.113.10:32400/
PLEX_ADVERTISE_IP=

# Leave false to keep ADVERTISE_IP commented out in docker-compose.yaml.
# Set true only if you intentionally want the generated Compose to enable it.
PLEX_ENABLE_ADVERTISE_IP=false
EOF

    chmod 600 "$ENV_FILE"
    echo "Created: $ENV_FILE"
else
    echo '=== USING EXISTING .env ==='

    # Add newly introduced keys without replacing the user's existing values.
    ensure_env_key TZ "America/Vancouver"
    ensure_env_key PLEX_UID "1000"
    ensure_env_key PLEX_GID "1000"
    ensure_env_key PLEX_DATA_ROOT "/Volume1/Docker/plex"
    ensure_env_key PLEX_MEDIA_ROOT "/Volume1/VideoFS"
    ensure_env_key PLEX_MEDIA_DIRS "Movies,TV,Anime,Other,YouTube"
    ensure_env_key PLEX_MEDIA_GID "998"
    ensure_env_key PLEX_CLAIM ""
    ensure_env_key PLEX_ADVERTISE_IP ""
    ensure_env_key PLEX_ENABLE_ADVERTISE_IP "false"

    chmod 600 "$ENV_FILE"
fi

###############################################################################
# Load .env
###############################################################################

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${TZ:?TZ is required}"
: "${PLEX_UID:?PLEX_UID is required}"
: "${PLEX_GID:?PLEX_GID is required}"
: "${PLEX_DATA_ROOT:?PLEX_DATA_ROOT is required}"
: "${PLEX_MEDIA_ROOT:?PLEX_MEDIA_ROOT is required}"
: "${PLEX_MEDIA_DIRS:?PLEX_MEDIA_DIRS is required}"
: "${PLEX_MEDIA_GID:?PLEX_MEDIA_GID is required}"

###############################################################################
# Parse media directories
###############################################################################

MEDIA_DIRS=""

old_ifs="$IFS"
IFS=','

for raw_dir in $PLEX_MEDIA_DIRS; do
    dir="$(
        printf '%s' "$raw_dir" |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    )"

    [ -n "$dir" ] || continue

    case "$dir" in
        *"/"*|*".."*)
            die "Invalid PLEX_MEDIA_DIRS entry: $dir"
            ;;
    esac

    MEDIA_DIRS="${MEDIA_DIRS}${dir}
"
done

IFS="$old_ifs"

[ -n "$MEDIA_DIRS" ] || die "PLEX_MEDIA_DIRS contains no directories"

###############################################################################
# Verify TNAS prerequisites
###############################################################################

echo
echo '========================================='
echo ' PLEX TNAS SETUP'
echo '========================================='

echo
echo '=== VERIFYING DOCKER ==='

docker version >/dev/null 2>&1 ||
    die "Docker is not available"

docker compose version >/dev/null 2>&1 ||
    die "Docker Compose plugin is not available"

echo 'Docker: OK'
echo 'Docker Compose: OK'

echo
echo '=== VERIFYING TMACLTOOL ==='

command -v tmacltool >/dev/null 2>&1 ||
    die "tmacltool is not available"

echo 'tmacltool: OK'

echo
echo '=== VERIFYING LOCALHOST ==='

grep -Eq '(^|[[:space:]])localhost([[:space:]]|$)' /etc/hosts ||
    die "localhost is missing from /etc/hosts"

echo 'localhost: OK'

###############################################################################
# Intel GPU
###############################################################################

echo
echo '=== VERIFYING INTEL GPU ==='

[ -c /dev/dri/card0 ] ||
    die "/dev/dri/card0 does not exist"

[ -c /dev/dri/renderD128 ] ||
    die "/dev/dri/renderD128 does not exist"

GPU_CARD_GID="$(stat -c '%g' /dev/dri/card0)"
GPU_RENDER_GID="$(stat -c '%g' /dev/dri/renderD128)"

echo "card0 GID:       $GPU_CARD_GID"
echo "renderD128 GID:  $GPU_RENDER_GID"
echo "media ACL GID:   $PLEX_MEDIA_GID"

ls -ln /dev/dri

if command -v getent >/dev/null 2>&1; then
    detected_admin_gid="$(getent group admin 2>/dev/null | awk -F: 'NR==1 {print $3}')"

    if [ -n "${detected_admin_gid:-}" ] &&
       [ "$detected_admin_gid" != "$PLEX_MEDIA_GID" ]; then
        echo
        echo "WARNING: TNAS admin GID is $detected_admin_gid but"
        echo "PLEX_MEDIA_GID is configured as $PLEX_MEDIA_GID."
        echo "Update $ENV_FILE if this is not intentional."
    fi
fi

###############################################################################
# Plex persistent storage
###############################################################################

echo
echo '=== PREPARING PLEX STORAGE ==='

mkdir -p "$PLEX_DATA_ROOT"

ensure_acl \
    "$PLEX_DATA_ROOT" \
    'group:admin:allow:rwxpdDaARWc--:fd--'

mkdir -p \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Cache" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Logs" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Metadata" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Media" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Plug-in Support" \
    "$PLEX_DATA_ROOT/transcode"

tmacltool enable-inheritance "$PLEX_DATA_ROOT/config" >/dev/null
tmacltool enable-inheritance "$PLEX_DATA_ROOT/transcode" >/dev/null

# Only enforce ownership/mode on the directory skeleton. Do not recursively
# chown/chmod an established Plex database and metadata tree on every run.
for pathname in \
    "$PLEX_DATA_ROOT/config" \
    "$PLEX_DATA_ROOT/config/Library" \
    "$PLEX_DATA_ROOT/config/Library/Application Support" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Cache" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Logs" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Metadata" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Media" \
    "$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Plug-in Support" \
    "$PLEX_DATA_ROOT/transcode"
do
    chown "$PLEX_UID:$PLEX_GID" "$pathname"
    chmod u+rwx,go+rx "$pathname"
done

echo 'Plex storage: OK'

###############################################################################
# VideoFS ACLs
###############################################################################

echo
echo '=== PREPARING MEDIA ACLs ==='

[ -d "$PLEX_MEDIA_ROOT" ] ||
    die "Media root does not exist: $PLEX_MEDIA_ROOT"

# Plex receives PLEX_MEDIA_GID through group_add. VideoFS and each selected
# library retain the TNAS admin ACL that has proven to work on this system.
ensure_acl \
    "$PLEX_MEDIA_ROOT" \
    'group:admin:allow:rwxpdDaARWc--:fd--'

while IFS= read -r dir; do
    [ -n "$dir" ] || continue

    host_path="$PLEX_MEDIA_ROOT/$dir"

    [ -d "$host_path" ] ||
        die "Configured media directory does not exist: $host_path"

    echo
    echo "--- $host_path ---"

    ensure_acl \
        "$host_path" \
        'group:admin:allow:rwxpdDaARWc--:fd--'

    tmacltool enable-inheritance "$host_path" >/dev/null

    echo 'ACL/inheritance: OK'
done <<EOF
$MEDIA_DIRS
EOF

###############################################################################
# Preserve Plex account state before any possible container recreation
###############################################################################

PREF="$PLEX_DATA_ROOT/config/Library/Application Support/Plex Media Server/Preferences.xml"
PREF_BACKUP="$PLEX_DATA_ROOT/Preferences.xml.setup-plex.backup"

WAS_CLAIMED=0

if [ -f "$PREF" ]; then
    cp -p "$PREF" "$PREF_BACKUP"

    if grep -q 'PlexOnlineToken="[^"]' "$PREF"; then
        WAS_CLAIMED=1
        echo
        echo 'Existing Plex account token: PRESENT'
    fi
fi

###############################################################################
# Generate docker-compose.yaml
###############################################################################

echo
echo '=== GENERATING docker-compose.yaml ==='

TMP_COMPOSE="$COMPOSE_DIR/.docker-compose.yaml.tmp"
rm -f "$TMP_COMPOSE"

cat > "$TMP_COMPOSE" <<'EOF'
services:
  plex:
    image: plexinc/pms-docker:latest
    container_name: plex
    hostname: plex
    restart: unless-stopped

    network_mode: host

    devices:
      - /dev/dri:/dev/dri

    group_add:
EOF

# Add GPU groups + TNAS media ACL group, de-duplicated.
printf '%s\n' \
    "$GPU_CARD_GID" \
    "$GPU_RENDER_GID" \
    "$PLEX_MEDIA_GID" |
awk 'NF && !seen[$0]++' |
while IFS= read -r gid; do
    printf '      - "%s"\n' "$gid" >> "$TMP_COMPOSE"
done

cat >> "$TMP_COMPOSE" <<'EOF'

    environment:
      TZ: "${TZ}"
      PLEX_UID: "${PLEX_UID}"
      PLEX_GID: "${PLEX_GID}"
      VERSION: docker

      # Optional first-run account claim.
      # Configure PLEX_CLAIM in .env.
      # Plex ignores this once the server is already signed in.
      PLEX_CLAIM: "${PLEX_CLAIM:-}"

      # TNAS config permissions are prepared by setup-plex.sh.
      CHANGE_CONFIG_DIR_OWNERSHIP: "false"

      # Optional additional URL Plex should advertise.
      #
      # This is normally unnecessary with network_mode: host.
      # It does not force Plex Remote Access to detect a particular WAN IP.
      #
      # ADVERTISE_IP: "${PLEX_ADVERTISE_IP:-}"

    volumes:
      - "${PLEX_DATA_ROOT}/config:/config"
      - "${PLEX_DATA_ROOT}/transcode:/transcode"
EOF

# Default behavior is to leave ADVERTISE_IP commented out. If explicitly
# enabled in .env, activate it in the generated Compose file.
case "${PLEX_ENABLE_ADVERTISE_IP:-false}" in
    true|TRUE|yes|YES|1)
        [ -n "${PLEX_ADVERTISE_IP:-}" ] ||
            die "PLEX_ENABLE_ADVERTISE_IP=true but PLEX_ADVERTISE_IP is empty"

        sed -i \
            's|^[[:space:]]*# ADVERTISE_IP: "${PLEX_ADVERTISE_IP:-}"|      ADVERTISE_IP: "${PLEX_ADVERTISE_IP:-}"|' \
            "$TMP_COMPOSE"
        ;;
esac

while IFS= read -r dir; do
    [ -n "$dir" ] || continue

    printf '      - "%s/%s:/media/%s:ro"\n' \
        "$PLEX_MEDIA_ROOT" \
        "$dir" \
        "$dir" \
        >> "$TMP_COMPOSE"
done <<EOF
$MEDIA_DIRS
EOF

cat >> "$TMP_COMPOSE" <<'EOF'

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

    ulimits:
      nofile:
        soft: 65536
        hard: 65536

    stop_grace_period: 30s
EOF

###############################################################################
# Validate generated Compose
###############################################################################

docker compose \
    --env-file "$ENV_FILE" \
    -f "$TMP_COMPOSE" \
    config >/dev/null

echo 'Generated Compose: VALID'

###############################################################################
# Install Compose atomically
###############################################################################

if [ -f "$COMPOSE_FILE" ] &&
   cmp -s "$TMP_COMPOSE" "$COMPOSE_FILE"; then

    echo 'docker-compose.yaml already current.'
    rm -f "$TMP_COMPOSE"

else
    if [ -f "$COMPOSE_FILE" ]; then
        cp -p "$COMPOSE_FILE" "$COMPOSE_FILE.previous"
    fi

    mv "$TMP_COMPOSE" "$COMPOSE_FILE"
    chmod 644 "$COMPOSE_FILE"

    echo "Updated: $COMPOSE_FILE"
fi

# Migrate the old filename out of the way so there is one canonical Compose.
if [ -f "$LEGACY_COMPOSE" ]; then
    if [ ! -f "$COMPOSE_DIR/docker-compose.yml.pre-managed-backup" ]; then
        cp -p \
            "$LEGACY_COMPOSE" \
            "$COMPOSE_DIR/docker-compose.yml.pre-managed-backup"
    fi

    rm -f "$LEGACY_COMPOSE"
    echo 'Legacy docker-compose.yml backed up and disabled.'
fi

###############################################################################
# Pull and deploy
###############################################################################

echo
echo '=== PULLING PLEX ==='

docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    pull

echo
echo '=== APPLYING COMPOSE ==='

# Intentionally no --force-recreate.
# If the resolved configuration is unchanged, the working container remains.
docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    up -d

###############################################################################
# Health
###############################################################################

if ! wait_for_health; then
    echo
    echo '=== PLEX LOGS ==='
    docker logs plex --tail 150 2>&1 || true
    die "Plex did not become healthy"
fi

###############################################################################
# Protect an existing claim
###############################################################################

echo
echo '=== ACCOUNT STATE ==='

IDENTITY="$(
    docker exec plex \
        curl -fsS http://127.0.0.1:32400/identity \
        2>/dev/null || true
)"

CLAIMED=0

if printf '%s' "$IDENTITY" | grep -q 'claimed="1"'; then
    CLAIMED=1
fi

if [ "$WAS_CLAIMED" -eq 1 ] &&
   { [ "$CLAIMED" -ne 1 ] ||
     ! grep -q 'PlexOnlineToken="[^"]' "$PREF" 2>/dev/null; }; then

    echo 'Existing claim disappeared after deployment.'
    echo 'Restoring Preferences.xml backup.'

    docker compose \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        stop plex

    cp -p "$PREF_BACKUP" "$PREF"
    chown "$PLEX_UID:$PLEX_GID" "$PREF"

    docker compose \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        start plex

    wait_for_health ||
        die "Plex failed after restoring Preferences.xml"

    IDENTITY="$(
        docker exec plex \
            curl -fsS http://127.0.0.1:32400/identity \
            2>/dev/null || true
    )"

    if ! printf '%s' "$IDENTITY" | grep -q 'claimed="1"'; then
        die "Plex claim could not be restored"
    fi

    CLAIMED=1
fi

###############################################################################
# First-run claim handling
###############################################################################

if [ "$CLAIMED" -eq 0 ] &&
   [ -n "${PLEX_CLAIM:-}" ]; then

    echo 'Waiting for Plex to complete account claim...'

    for i in $(seq 1 30); do
        IDENTITY="$(
            docker exec plex \
                curl -fsS http://127.0.0.1:32400/identity \
                2>/dev/null || true
        )"

        if printf '%s' "$IDENTITY" | grep -q 'claimed="1"'; then
            CLAIMED=1
            break
        fi

        sleep 1
    done

    if [ "$CLAIMED" -ne 1 ]; then
        die "PLEX_CLAIM was supplied but the server did not become claimed. Obtain a fresh claim code and rerun the script."
    fi
fi

if [ "$CLAIMED" -eq 1 ]; then
    echo 'Plex claim: CLAIMED'

    if grep -q 'PlexOnlineToken="[^"]' "$PREF" 2>/dev/null; then
        echo 'Permanent PlexOnlineToken: PRESENT'
    else
        echo 'WARNING: server reports claimed but PlexOnlineToken is not present yet'
    fi
else
    echo
    echo 'Plex claim: UNCLAIMED'
    echo
    echo 'To claim it:'
    echo '  1. Get a fresh code from https://www.plex.tv/claim'
    echo "  2. Edit $ENV_FILE"
    echo '  3. Set PLEX_CLAIM=claim-xxxxxxxxxxxxxxxxxxxx'
    echo '  4. Run this script again immediately'
fi

###############################################################################
# Verification -- intentionally NO Plex library scan
###############################################################################

echo
echo '=== CONTAINER SUPPLEMENTARY GROUPS ==='

docker inspect plex \
    --format='group_add={{json .HostConfig.GroupAdd}}'

echo
echo '=== GPU INSIDE CONTAINER ==='

docker exec plex ls -ln /dev/dri

echo
echo '=== CONFIG WRITE TEST ==='

docker exec -u "$PLEX_UID:$PLEX_GID" plex sh -c '
TEST="/config/Library/Application Support/Plex Media Server/Cache/.setup-plex-test"
touch "$TEST"
rm "$TEST"

touch /transcode/.setup-plex-test
rm /transcode/.setup-plex-test

echo "CONFIG + TRANSCODE WRITE: OK"
'

echo
echo '=== MEDIA ACCESS ==='

MEDIA_FAILED=0

while IFS= read -r dir; do
    [ -n "$dir" ] || continue

    printf '%-16s ' "$dir"

    if docker exec \
        -u "$PLEX_UID:$PLEX_GID" \
        plex \
        sh -c "ls '/media/$dir' >/dev/null 2>&1"
    then
        count="$(
            docker exec \
                -u "$PLEX_UID:$PLEX_GID" \
                plex \
                sh -c "find '/media/$dir' -type f 2>/dev/null | wc -l"
        )"

        echo "READABLE ($count files)"
    else
        echo 'PERMISSION DENIED'
        MEDIA_FAILED=1
    fi
done <<EOF
$MEDIA_DIRS
EOF

###############################################################################
# Final status
###############################################################################

echo
echo '=== PORT 32400 ==='

ss -lntp | grep ':32400' ||
    die "Plex is healthy but port 32400 is not listening"

echo
echo '=== FINAL STATUS ==='

docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    ps

echo
echo '=== FILES ==='
echo "Compose:     $COMPOSE_FILE"
echo "Environment: $ENV_FILE"
echo "Plex data:   $PLEX_DATA_ROOT"

echo
echo '=== TNAS ADDRESSES ==='
hostname -I

echo
if [ "$MEDIA_FAILED" -eq 0 ]; then
    echo 'ALL CONFIGURED MEDIA DIRECTORIES ARE READABLE BY PLEX'
else
    echo 'WARNING: ONE OR MORE MEDIA DIRECTORIES ARE NOT READABLE'
fi

echo
echo 'NO PLEX MEDIA SCAN WAS TRIGGERED.'
