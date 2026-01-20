#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher - Professional v3.4.0 (FULL)
# - Sync from Android storage -> Termux
# - Web UI (DB Viewer) can trigger sync + view sync log
# - Detailed sync logging (file list & bytes)
# - Masked source path type in UI (storage / termux)
# - Numeric incremental project IDs
# - Flexible frontend/backend detection
# ============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROJECTS_DIR="$HOME/dapps-projects"
CONFIG_FILE="$HOME/.dapps.conf"
LOG_DIR="$HOME/.dapps-logs"
LAUNCHER_VERSION="3.4.0"

DB_VIEWER_DIR="${DB_VIEWER_DIR:-$HOME/paxiforge-db-viewer}"
DB_VIEWER_PORT="${DB_VIEWER_PORT:-8081}"

PG_DATA="${PG_DATA:-$PREFIX/var/lib/postgresql}"
PG_LOG="$HOME/pgsql.log"

GIT_REPO="https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/installer.sh"   # <-- ganti jika perlu

# Colors
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; C="\033[36m"; X="\033[0m"; BOLD="\033[1m"

# Ensure dirs
mkdir -p "$PROJECTS_DIR" "$LOG_DIR" "$DB_VIEWER_DIR"
touch "$CONFIG_FILE"

# ---------------------------
# Helpers
# ---------------------------
msg() {
    case "$1" in
        ok)   echo -e "${G}✓${X} $2" ;;
        err)  echo -e "${R}✗${X} $2" ;;
        warn) echo -e "${Y}!${X} $2" ;;
        info) echo -e "${B}i${X} $2" ;;
        *)    echo -e "$1" ;;
    esac
}

confirm() {
    read -rp "$1 (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

get_device_ip() {
    local ip
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7; exit}')
    [ -z "$ip" ] && ip=$(ip -4 addr show scope global | awk '/inet/ && $2 !~ /127/ {split($2,a,"/"); print a[1]; exit}')
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-127.0.0.1}"
}

wait_key() {
    echo -e "\n${C}Tekan ENTER untuk kembali...${X}"
    read -r
}

md5_file() {
    if command -v md5sum &>/dev/null; then
        md5sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v md5 &>/dev/null; then
        md5 -q "$1" 2>/dev/null
    else
        echo ""
    fi
}

# ---------------------------
# Config format:
# id|name|local_path|source_path|fe_dir|be_dir|fe_port|be_port|fe_cmd|be_cmd|auto_restart|auto_sync
# id numeric incremental
# ---------------------------
generate_id() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "1"; return 0
    fi
    awk -F'|' '{ if ($1+0>m) m=$1+0 } END { print m+1 }' "$CONFIG_FILE"
}

save_project() {
    local id="$1" name="$2" local_path="$3" source_path="$4"
    local fe_dir="$5" be_dir="$6" fe_port="$7" be_port="$8"
    local fe_cmd="$9" be_cmd="${10}" auto_restart="${11}" auto_sync="${12}"
    # remove old line if exists
    grep -v "^$id|" "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$id" "$name" "$local_path" "$source_path" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_restart" "$auto_sync" \
        >> "$CONFIG_FILE"
}

load_project() {
    local id="$1"
    local line
    line=$(grep "^$id|" "$CONFIG_FILE" 2>/dev/null | head -n1 || true)
    [ -z "$line" ] && return 1
    IFS='|' read -r PROJECT_ID PROJECT_NAME PROJECT_PATH SOURCE_PATH \
                    FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD \
                    AUTO_RESTART AUTO_SYNC <<< "$line"
    return 0
}

# ---------------------------
# Flexible dir detection
# ---------------------------
detect_dirs_if_needed() {
    # expects PROJECT_PATH, PROJECT_NAME available (load_project set them)
    local p="$PROJECT_PATH"
    [ -z "$p" ] && return 1
    local f_candidates=("frontend" "client" "web" "ui" "app" "src" "public")
    local b_candidates=("backend" "server" "api" "srv" "service")

    if [ -z "$FE_DIR" ] || [ ! -d "$p/$FE_DIR" ]; then
        FE_DIR=""
        for d in "${f_candidates[@]}"; do
            [ -d "$p/$d" ] && { FE_DIR="$d"; break; }
        done
        if [ -z "$FE_DIR" ]; then
            for d in "$p"/*/; do
                [ -d "${d%/}" ] || continue
                [ -f "${d%/}/package.json" ] && { FE_DIR="$(basename "${d%/}")"; break; }
            done
        fi
    fi

    if [ -z "$BE_DIR" ] || [ ! -d "$p/$BE_DIR" ]; then
        BE_DIR=""
        for d in "${b_candidates[@]}"; do
            [ -d "$p/$d" ] && { BE_DIR="$d"; break; }
        done
        if [ -z "$BE_DIR" ]; then
            for d in "$p"/*/; do
                [ -d "${d%/}" ] || continue
                [ -f "${d%/}/package.json" ] && {
                    if [ "$(basename "${d%/}")" != "$FE_DIR" ]; then BE_DIR="$(basename "${d%/}")"; break; fi
                }
            done
        fi
    fi

    FE_DIR="${FE_DIR:-frontend}"
    BE_DIR="${BE_DIR:-backend}"
    return 0
}

# ---------------------------
# Path helpers (masked)
# ---------------------------
path_type() {
    local p="$1"
    [ -z "$p" ] && { echo "(none)"; return; }
    if [[ "$p" =~ ^/storage ]] || [[ "$p" =~ ^/sdcard ]] || [[ "$p" =~ ^/mnt/media_rw ]]; then
        echo "storage"
    else
        echo "termux"
    fi
}

short_path() { path_type "$1"; }

# ---------------------------
# copy/storage sync helpers
# ---------------------------
copy_storage_to_termux() {
    local src="$1" dest="$2"
    [ -z "$src" ] && { msg err "Sumber kosong"; return 1; }
    [ -z "$dest" ] && { msg err "Tujuan kosong"; return 1; }
    if [ ! -d "$src" ]; then msg err "Sumber tidak ditemukan: $src"; return 1; fi
    mkdir -p "$dest" "$dest/.dapps" 2>/dev/null || true

    # prepare log
    local tmp_log="$LOG_DIR/rsync_tmp.out"
    : > "$tmp_log"

    if command -v rsync &>/dev/null; then
        msg info "Meng-copy (rsync) dari $src -> $dest"
        # out-format: filename|size
        rsync -a --delete --checksum --no-perms --omit-dir-times --out-format='%n|%l' "$src"/ "$dest"/ > "$tmp_log" 2>&1 || {
            msg err "rsync gagal. Lihat $tmp_log"; return 1; }
        # parse rsync output
        local total_bytes=0 files=0
        while IFS='|' read -r file size; do
            [ -z "$file" ] && continue
            files=$((files+1))
            size=${size:-0}
            total_bytes=$((total_bytes + size))
        done < "$tmp_log" || true
        printf '{"files":%d,"bytes":%d}\n' "$files" "$total_bytes" > "$dest/.dapps/sync_summary.json" 2>/dev/null || true
        mv "$tmp_log" "$LOG_DIR/${PROJECT_ID}_sync.log" 2>/dev/null || true
    else
        msg warn "rsync tidak tersedia. Menggunakan tar-stream fallback"
        (cd "$src" && tar -cpf - .) | (cd "$dest" && tar -xpf -) || { msg err "tar copy gagal"; return 1; }
        local cnt; cnt=$(find "$dest" -type f 2>/dev/null | wc -l || echo 0)
        local bytes; bytes=$(du -sb "$dest" 2>/dev/null | awk '{print $1}' || echo 0)
        printf '{"files":%d,"bytes":%d}\n' "$cnt" "$bytes" > "$dest/.dapps/sync_summary.json" 2>/dev/null || true
        echo "tar fallback: files=$cnt bytes=$bytes" > "$LOG_DIR/${PROJECT_ID}_sync.log" 2>/dev/null || true
    fi

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/.dapps/.last_synced" 2>/dev/null || true
    msg ok "Copy selesai: $dest"
    return 0
}

# ---------------------------
# Sync functions (CLI)
# ---------------------------
sync_project_by_id() {
    local id="$1"
    load_project "$id" || { msg err "Project not found"; return 1; }
    detect_dirs_if_needed || true
    if [ -z "$SOURCE_PATH" ] || [ ! -d "$SOURCE_PATH" ]; then
        msg warn "source_path tidak diset atau tidak ada untuk project $PROJECT_NAME"
        read -rp "Masukkan storage source path untuk project (kosong untuk batalkan): " sp
        [ -z "$sp" ] && { msg err "Cancelled"; return 1; }
        SOURCE_PATH="$sp"
        # update config with source_path
        save_project "$PROJECT_ID" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" "$FE_DIR" "$BE_DIR" "$FE_PORT" "$BE_PORT" "$FE_CMD" "$BE_CMD" "$AUTO_RESTART" "$AUTO_SYNC"
    fi
    msg info "Sinkronisasi: $(path_type "$SOURCE_PATH") -> $PROJECT_PATH"
    export PROJECT_ID="$PROJECT_ID"
    copy_storage_to_termux "$SOURCE_PATH" "$PROJECT_PATH" || { msg err "Sync gagal"; return 1; }
    msg ok "Sync selesai untuk $PROJECT_NAME"
    return 0
}

sync_project() {
    header
    echo -e "${BOLD}Sync Project${X}\n"
    echo "1) Sync by project ID"
    echo "2) Sync ALL projects that have source_path set"
    echo "0) Kembali"
    read -rp "Select: " ch
    case "$ch" in
        1)
            list_projects_table || { msg warn "No projects"; wait_key; return; }
            echo ""
            read -rp "Enter project ID to sync: " id
            [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
            sync_project_by_id "$id"
            wait_key
            ;;
        2)
            while IFS='|' read -r id name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do
                [ -z "$id" ] && continue
                if [ -n "$source_path" ] && [ -d "$source_path" ]; then
                    msg info "Syncing $name ($id)"; sync_project_by_id "$id" || msg warn "Fail: $name"
                else
                    msg warn "Skip $name ($id) - no source_path"
                fi
            done < "$CONFIG_FILE"
            wait_key
            ;;
        0) return ;;
        *) msg err "Invalid"; wait_key ;;
    esac
}

auto_sync_project() {
    local id="$1"
    load_project "$id" || return 1
    [ "$AUTO_SYNC" != "1" ] && return 0
    if [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ]; then
        msg info "Auto-sync aktif -> Syncing $PROJECT_NAME"
        sync_project_by_id "$id" || msg warn "Auto-sync gagal untuk $PROJECT_NAME"
    else
        msg warn "Auto-sync: source tidak ada untuk $PROJECT_NAME"
    fi
    return 0
}

# ---------------------------
# Listing
# ---------------------------
list_projects_table() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        return 1
    fi
    echo -e "${BOLD}ID  | Status | Name                  | Source${X}"
    echo "---------------------------------------------------------------------"
    while IFS='|' read -r id name local_path source_path _; do
        [ -z "$id" ] && continue
        local status="${G}✓${X}"
        [ ! -d "$local_path" ] && status="${R}✗${X}"
        local running=""
        local fe_pid_file="$LOG_DIR/${id}_frontend.pid"
        local be_pid_file="$LOG_DIR/${id}_backend.pid"
        if [ -f "$fe_pid_file" ] || [ -f "$be_pid_file" ]; then
            local fe_pid=$(cat "$fe_pid_file" 2>/dev/null || true)
            local be_pid=$(cat "$be_pid_file" 2>/dev/null || true)
            if { [ -n "$fe_pid" ] && kill -0 "$fe_pid" 2>/dev/null; } || \
               { [ -n "$be_pid" ] && kill -0 "$be_pid" 2>/dev/null; }; then
                running=" ${G}[RUNNING]${X}"
            fi
        fi
        local src_type; src_type=$(path_type "$source_path")
        printf "%-3s | %-6s | %-21s | %s%s\n" "$id" "$status" "${name:0:21}" "$src_type" "$running"
    done < "$CONFIG_FILE"
    echo ""
    echo "Untuk melihat path asli: ketik => <ID> open path"
    return 0
}

prompt_open_path_after_list() {
    echo ""
    read -rp "Ketik (<ID> open path) atau tekan ENTER: " cmd
    [ -z "$cmd" ] && return 0
    if [[ "$cmd" =~ ^([0-9]+)[[:space:]]+open[[:space:]]+path$ ]]; then
        local id="${BASH_REMATCH[1]}"
        load_project "$id" || { msg err "Project not found"; return 1; }
        echo -e "\nFull path for $PROJECT_NAME ($id):\n$PROJECT_PATH\nSOURCE_PATH:\n$SOURCE_PATH\n"
        wait_key
    else
        msg err "Format tidak dikenali"
        wait_key
    fi
}

# ---------------------------
# PostgreSQL helpers
# ---------------------------
init_postgres_if_needed() {
    if [ ! -d "$PG_DATA" ] || [ -z "$(ls -A "$PG_DATA" 2>/dev/null || true)" ]; then
        msg info "Inisialisasi PostgreSQL di: $PG_DATA"
        initdb "$PG_DATA" || { msg err "initdb gagal"; return 1; }
        msg ok "Postgres data siap"
    fi
    return 0
}

status_postgres() {
    if command -v pg_ctl &>/dev/null && [ -d "$PG_DATA" ]; then
        if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
            msg ok "Postgres berjalan (data: $PG_DATA)"
            return 0
        fi
    fi
    msg warn "Postgres tidak berjalan"
    return 1
}

start_postgres() {
    init_postgres_if_needed || return 1
    if status_postgres >/dev/null 2>&1; then
        msg info "Postgres sudah berjalan"
        return 0
    fi
    msg info "Menjalankan PostgreSQL..."
    nohup pg_ctl -D "$PG_DATA" -l "$PG_LOG" start > /dev/null 2>&1 || {
        msg err "Gagal memulai Postgres. Cek $PG_LOG"
        return 1
    }
    sleep 1
    status_postgres && return 0 || return 1
}

stop_postgres() {
    if status_postgres >/dev/null 2>&1; then
        msg info "Menghentikan PostgreSQL..."
        pg_ctl -D "$PG_DATA" stop -m fast >/dev/null 2>&1 || { msg warn "pg_ctl stop gagal"; }
        sleep 1
    else
        msg info "Postgres tidak berjalan"
    fi
    return 0
}

create_role_if_needed() {
    local user="$1" pass="$2"
    if psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='${user}';" 2>/dev/null | grep -q 1; then
        return 0
    fi
    if [ -z "$pass" ]; then
        psql -c "CREATE ROLE \"$user\" WITH LOGIN;" >/dev/null 2>&1 || return 1
    else
        psql -c "CREATE ROLE \"$user\" WITH LOGIN PASSWORD '$pass';" >/dev/null 2>&1 || return 1
    fi
}

create_db_if_needed() {
    local db="$1" owner="$2"
    if psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null | grep -q 1; then
        return 0
    fi
    if [ -n "$owner" ]; then
        psql -c "CREATE DATABASE \"$db\" OWNER \"$owner\";" >/dev/null 2>&1 || return 1
    else
        psql -c "CREATE DATABASE \"$db\";" >/dev/null 2>&1 || return 1
    fi
}

pg_size_for_db_quiet() {
    local db="$1" user="$2" pass="$3"
    if [ -z "$db" ]; then echo ""; return 0; fi
    if [ -n "$pass" ]; then
        PGPASSWORD="$pass" psql -At -c "SELECT pg_size_pretty(pg_database_size('$db'));" 2>/dev/null || echo ""
    else
        psql -At -c "SELECT pg_size_pretty(pg_database_size('$db'));" 2>/dev/null || echo ""
    fi
}

clean_db_schema_public() {
    local db="$1" user="$2" pass="$3"
    if [ -z "$db" ]; then msg err "DB name kosong"; return 1; fi
    msg info "Membersihkan DB: $db ..."
    if [ -n "$pass" ]; then
        PGPASSWORD="$pass" psql -v "ON_ERROR_STOP=1" -d "$db" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO public;" >/dev/null 2>&1 || { msg err "Gagal clean $db"; return 1; }
    else
        psql -v "ON_ERROR_STOP=1" -d "$db" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO public;" >/dev/null 2>&1 || { msg err "Gagal clean $db"; return 1; }
    fi
    msg ok "DB $db dibersihkan"
    return 0
}

# ---------------------------
# Parse .env for DB config
# ---------------------------
parse_db_config_from_env() {
    local envfile="$1"
    DB_HOST="127.0.0.1"; DB_PORT="5432"; DB_NAME=""; DB_USER=""; DB_PASSWORD=""
    [ ! -f "$envfile" ] && { echo ""; return 1; }
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^DB_HOST= ]]; then DB_HOST="${line#DB_HOST=}"; DB_HOST="${DB_HOST%\"}"; DB_HOST="${DB_HOST#\"}"; fi
        if [[ "$line" =~ ^DB_PORT= ]]; then DB_PORT="${line#DB_PORT=}"; DB_PORT="${DB_PORT%\"}"; DB_PORT="${DB_PORT#\"}"; fi
        if [[ "$line" =~ ^DB_NAME= ]]; then DB_NAME="${line#DB_NAME=}"; DB_NAME="${DB_NAME%\"}"; DB_NAME="${DB_NAME#\"}"; fi
        if [[ "$line" =~ ^DB_USER= ]]; then DB_USER="${line#DB_USER=}"; DB_USER="${DB_USER%\"}"; DB_USER="${DB_USER#\"}"; fi
        if [[ "$line" =~ ^DB_PASSWORD= ]]; then DB_PASSWORD="${line#DB_PASSWORD=}"; DB_PASSWORD="${DB_PASSWORD%\"}"; DB_PASSWORD="${DB_PASSWORD#\"}"; fi
        if [[ "$line" =~ ^DATABASE_URL= ]]; then
            url="${line#DATABASE_URL=}"; url="${url%\"}"; url="${url#\"}"
            if [[ "$url" =~ postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+) ]]; then
                DB_USER="${BASH_REMATCH[1]}"; DB_PASSWORD="${BASH_REMATCH[2]}"; DB_HOST="${BASH_REMATCH[3]}"; DB_PORT="${BASH_REMATCH[4]}"; DB_NAME="${BASH_REMATCH[5]}"
            elif [[ "$url" =~ postgresql://([^:]+):([^@]+)@([^/]+)/(.+) ]]; then
                DB_USER="${BASH_REMATCH[1]}"; DB_PASSWORD="${BASH_REMATCH[2]}"; DB_HOST="${BASH_REMATCH[3]}"; DB_NAME="${BASH_REMATCH[4]}"
            fi
        fi
    done < "$envfile"
    echo "${DB_HOST}|${DB_PORT}|${DB_NAME}|${DB_USER}|${DB_PASSWORD}"
    return 0
}

# ---------------------------
# DB Viewer creation (server + UI)
# ---------------------------
ensure_db_viewer_files() {
    mkdir -p "$DB_VIEWER_DIR/public"
    # package.json
    if [ ! -f "$DB_VIEWER_DIR/package.json" ]; then
        cat > "$DB_VIEWER_DIR/package.json" <<'JSON'
{
  "name": "dapps-db-viewer",
  "version": "0.4.0",
  "main": "index.js",
  "dependencies": {
    "express": "^4.18.2",
    "pg": "^8.11.0"
  },
  "scripts": { "start": "node index.js" }
}
JSON
    fi

    # server index.js (with sync endpoints) - returns masked source type instead of full path in /api/projects
    cat > "$DB_VIEWER_DIR/index.js" <<'NODE'
const fs = require('fs');
const path = require('path');
const express = require('express');
const { exec } = require('child_process');
const { Client } = require('pg');
const app = express();
app.use(express.json());
const CONFIG_FILE = process.env.CONFIG_FILE || path.join(process.env.HOME, '.dapps.conf');
const PUBLIC_DIR = path.join(__dirname, 'public');
const LOG_DIR = process.env.LOG_DIR || path.join(process.env.HOME, '.dapps-logs');

function parseConfig() {
  if (!fs.existsSync(CONFIG_FILE)) return [];
  const lines = fs.readFileSync(CONFIG_FILE,'utf8').split(/\r?\n/).filter(Boolean);
  return lines.map(l=>{
    const parts = l.split('|');
    return {
      id: parts[0],
      name: parts[1],
      path: parts[2],
      source: parts[3],
      fe_dir: parts[4],
      be_dir: parts[5],
    };
  });
}
function pathType(p){
  if(!p) return '(none)';
  if(p.startsWith('/storage')||p.startsWith('/sdcard')||p.startsWith('/mnt/media_rw')) return 'storage';
  return 'termux';
}
function readEnv(projectPath, be_dir) {
  const file = path.join(projectPath, be_dir, '.env');
  if (!fs.existsSync(file)) return null;
  const data = fs.readFileSync(file,'utf8').split(/\r?\n/);
  const obj = {};
  for (const line of data) {
    if (!line || line.trim().startsWith('#')) continue;
    const parts = line.split('=');
    const k = parts.shift();
    const v = parts.join('=').replace(/^"/,'').replace(/"$/,'');
    obj[k] = v;
  }
  if (obj.DATABASE_URL && !obj.DB_NAME) {
    const m = obj.DATABASE_URL.match(/postgres(?:ql)?:\/\/([^:]+):([^@]+)@([^:\/]+):?([0-9]*)\/(.+)/);
    if (m) {
      obj.DB_USER = m[1]; obj.DB_PASSWORD = m[2]; obj.DB_HOST = m[3]; obj.DB_PORT = m[4]||'5432'; obj.DB_NAME = m[5];
    }
  }
  return obj;
}
function buildPgClientFromEnv(env) {
  return new Client({
    host: env.DB_HOST||'127.0.0.1',
    port: env.DB_PORT||5432,
    user: env.DB_USER||process.env.USER,
    password: env.DB_PASSWORD||undefined,
    database: env.DB_NAME
  });
}
app.use(express.static(PUBLIC_DIR));
app.get('/api/projects', (req,res)=>{
  const projects = parseConfig().map(p=>{
    const env = readEnv(p.path, p.be_dir) || {};
    return { id: p.id, name: p.name, source_type: pathType(p.source), be_dir: p.be_dir, db: { host: env.DB_HOST||null, port: env.DB_PORT||null, name: env.DB_NAME||null, user: env.DB_USER||null } };
  });
  res.json(projects);
});

// Sync endpoint remains
app.post('/api/project/:id/sync', async (req,res)=>{
  const projects = parseConfig();
  const p = projects.find(x=>x.id===req.params.id);
  if (!p) return res.status(404).json({error:'project not found'});
  const src = p.source || req.body.source;
  const dest = p.path;
  if (!src || !fs.existsSync(src)) return res.status(400).json({error:'source path not configured or not exists'});
  try { fs.mkdirSync(LOG_DIR, { recursive: true }); } catch(e){}
  const logFile = path.join(LOG_DIR, `${p.id}_sync.log`);
  const rsyncCmd = `rsync -a --delete --checksum --out-format='%n|%l' ${escapeShell(src)}/ ${escapeShell(dest)}/`;
  exec(rsyncCmd, {maxBuffer: 1024*1024*50}, (err, stdout, stderr)=>{
    const now = new Date().toISOString();
    const header = `SYNC ${now} from ${src} -> ${dest}\n`;
    fs.appendFileSync(logFile, header+stdout+(stderr?('\nERR:\n'+stderr):'')+'\n---\n');
    const lines = stdout.split(/\r?\n/).filter(Boolean);
    let files=0, bytes=0;
    for (const l of lines) {
      const m = l.split('|');
      if (m.length>=2) { files++; bytes += parseInt(m[1]||0,10); }
    }
    const summary = { files, bytes };
    try {
      const dappsdir = path.join(dest,'.dapps'); fs.mkdirSync(dappsdir, {recursive:true});
      fs.writeFileSync(path.join(dappsdir,'sync_summary.json'), JSON.stringify(summary));
      fs.writeFileSync(path.join(dappsdir,'.last_synced'), new Date().toISOString());
    } catch(e){}
    if (err) return res.status(500).json({error: 'rsync failed', details: stderr.slice(0,2000), summary});
    return res.json({ok:true, summary, log: header + lines.slice(-200).join('\n')});
  });
});

app.get('/api/project/:id/sync/log', (req,res)=>{
  const projects = parseConfig();
  const p = projects.find(x=>x.id===req.params.id);
  if (!p) return res.status(404).json({error:'project not found'});
  const logFile = path.join(LOG_DIR, `${p.id}_sync.log`);
  if (!fs.existsSync(logFile)) return res.json({ok:false, msg:'no log'});
  const txt = fs.readFileSync(logFile,'utf8');
  res.json({ok:true, log: txt.slice(-10000)});
});

// DB endpoints: basic implementations
app.get('/api/db/:id/tables', async (req,res)=>{
  const projects = parseConfig();
  const p = projects.find(x=>x.id===req.params.id);
  if (!p) return res.status(404).json({error:'project not found'});
  const env = readEnv(p.path, p.be_dir);
  if (!env || !env.DB_NAME) return res.status(400).json({error:'.env DB not configured'});
  const client = buildPgClientFromEnv(env);
  try {
    await client.connect();
    const r = await client.query("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename");
    await client.end();
    res.json(r.rows.map(r=>r.tablename));
  } catch (e) {
    res.status(500).json({error: e.message});
  }
});

app.get('/api/db/:id/table/:table', async (req,res)=>{
  const { id, table } = req.params;
  const limit = Math.min(parseInt(req.query.limit||'200',10), 1000);
  const offset = Math.max(parseInt(req.query.offset||'0',10), 0);
  const projects = parseConfig();
  const p = projects.find(x=>x.id===id);
  if (!p) return res.status(404).json({error:'project not found'});
  const env = readEnv(p.path,p.be_dir);
  if (!env || !env.DB_NAME) return res.status(400).json({error:'.env DB not configured'});
  const client = buildPgClientFromEnv(env);
  try {
    await client.connect();
    if (!/^[A-Za-z0-9_\."]+$/.test(table)) { await client.end(); return res.status(400).json({error:'invalid table name'}); }
    const q = `SELECT * FROM "${table.replace(/"/g,'""')}" LIMIT $1 OFFSET $2`;
    const r = await client.query(q, [limit, offset]);
    await client.end();
    res.json({rows: r.rows, rowCount: r.rowCount});
  } catch (e) {
    res.status(500).json({error: e.message});
  }
});

app.get('/api/db/:id/info', async (req,res)=>{
  const projects = parseConfig();
  const p = projects.find(x=>x.id===req.params.id);
  if (!p) return res.status(404).json({error:'project not found'});
  const env = readEnv(p.path,p.be_dir);
  if (!env || !env.DB_NAME) return res.status(400).json({error:'.env DB not configured'});
  const client = buildPgClientFromEnv(env);
  try {
    await client.connect();
    const sizeR = await client.query("SELECT pg_size_pretty(pg_database_size($1)) AS size, pg_database_size($1) as size_bytes", [env.DB_NAME]);
    const tablesR = await client.query("SELECT count(*) as tcount FROM pg_tables WHERE schemaname='public'");
    await client.end();
    res.json({db: env.DB_NAME, size: sizeR.rows[0].size, size_bytes: sizeR.rows[0].size_bytes, tables: parseInt(tablesR.rows[0].tcount,10)});
  } catch (e) {
    res.status(500).json({error: e.message});
  }
});

app.post('/api/db/:id/clean', async (req,res)=>{
  const projects = parseConfig();
  const p = projects.find(x=>x.id===req.params.id);
  if (!p) return res.status(404).json({error:'project not found'});
  const env = readEnv(p.path,p.be_dir);
  if (!env || !env.DB_NAME) return res.status(400).json({error:'.env DB not configured'});
  const client = buildPgClientFromEnv(env);
  try {
    await client.connect();
    await client.query("DROP SCHEMA public CASCADE");
    await client.query("CREATE SCHEMA public");
    await client.query("GRANT ALL ON SCHEMA public TO public");
    await client.end();
    res.json({ok:true, msg:'DB cleaned'});
  } catch (e) {
    res.status(500).json({error: e.message});
  }
});

app.post('/api/db/clean-all', async (req,res)=>{
  const projects = parseConfig();
  const results = [];
  for (const p of projects) {
    const env = readEnv(p.path,p.be_dir);
    if (!env || !env.DB_NAME) { results.push({id:p.id, ok:false, reason:'no db configured'}); continue; }
    try {
      const client = buildPgClientFromEnv(env);
      await client.connect();
      await client.query("DROP SCHEMA public CASCADE");
      await client.query("CREATE SCHEMA public");
      await client.query("GRANT ALL ON SCHEMA public TO public");
      await client.end();
      results.push({id:p.id, ok:true});
    } catch (e) {
      results.push({id:p.id, ok:false, reason:e.message});
    }
  }
  res.json({results});
});

app.post('/api/project/:id/create-env', (req,res)=>{
  const projects = parseConfig();
  const p = projects.find(x=>x.id===req.params.id);
  if (!p) return res.status(404).json({error:'project not found'});
  const example = path.join(p.path, p.be_dir, '.env.example');
  const dest = path.join(p.path, p.be_dir, '.env');
  if (!fs.existsSync(example)) return res.status(400).json({error:'.env.example not found'});
  if (fs.existsSync(dest)) return res.status(400).json({error:'.env already exists'});
  fs.copyFileSync(example, dest);
  return res.json({ok:true, msg:'.env created from .env.example'});
});

app.get('/', (req,res)=> res.sendFile(path.join(PUBLIC_DIR,'index.html')));
const PORT = process.env.PORT || 8081;
app.listen(PORT, ()=> { console.log(`DApps DB Viewer running on port ${PORT}`); });

function escapeShell(s){ return '"'+String(s).replace(/"/g,'\\"')+'"'; }
NODE

    # public/index.html (simpler, masked paths, Sync + Log)
    cat > "$DB_VIEWER_DIR/public/index.html" <<'HTML'
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>DApps DB Viewer + Sync</title>
  <style>
    :root{--bg:#0b0c0d;--surface:#141516;--muted:#b3b3b3;--text:#f5f5f5}
    body{margin:0;font-family:system-ui,Segoe UI,Roboto;background:var(--bg);color:var(--text)}
    header{padding:12px 16px;background:linear-gradient(90deg,#0f1112,#121314);display:flex;align-items:center;justify-content:space-between}
    h1{font-size:16px;margin:0}
    .panel{background:var(--surface);border-radius:8px;padding:12px;margin:12px}
    ul{padding:0;margin:0}
    li{list-style:none;padding:8px;margin:6px 0;border-radius:6px;display:flex;justify-content:space-between;align-items:center}
    button{background:transparent;border:1px solid rgba(255,255,255,0.06);color:var(--text);padding:6px 8px;border-radius:6px;cursor:pointer}
    pre{white-space:pre-wrap;max-height:60vh;overflow:auto;background:#070708;padding:8px;border-radius:6px}
  </style>
</head>
<body>
  <header><h1>DApps DB Viewer + Sync</h1><div class="meta">Lokal · Dev only</div></header>
  <div class="panel" id="projectsPanel">
    <h3>Projects</h3>
    <ul id="projects"></ul>
  </div>
  <div class="panel" id="logPanel">
    <h3>Output / Log</h3>
    <pre id="output">Pilih project lalu Sync atau lihat Log</pre>
  </div>

<script>
(async function(){
  const p = document.getElementById('projects'), o = document.getElementById('output');
  async function load(){
    p.innerHTML = 'Memuat...';
    try {
      const res = await fetch('/api/projects'); const list = await res.json();
      p.innerHTML = '';
      list.forEach(x=>{
        const li = document.createElement('li');
        li.textContent = `${x.id} • ${x.name} — [${x.source_type}]`;
        const bSync = document.createElement('button'); bSync.textContent='Sync'; bSync.onclick=async ()=>{ o.textContent='Syncing...'; const r=await fetch(`/api/project/${x.id}/sync`,{method:'POST'}); const j=await r.json(); o.textContent=JSON.stringify(j,null,2); };
        const bLog = document.createElement('button'); bLog.textContent='Sync Log'; bLog.onclick=async ()=>{ o.textContent='Memuat log...'; const r=await fetch(`/api/project/${x.id}/sync/log`); const t=await r.text(); o.textContent=t; };
        li.appendChild(bSync); li.appendChild(bLog);
        p.appendChild(li);
      });
    } catch (e) { p.innerHTML = 'Gagal: '+e.message; }
  }
  await load();
})();
</script>
</body>
</html>
HTML

    chmod -R 755 "$DB_VIEWER_DIR"
    msg ok "DB Viewer files siap di: $DB_VIEWER_DIR"
}

start_db_viewer() {
    ensure_db_viewer_files
    if [ ! -d "$DB_VIEWER_DIR/node_modules" ]; then
        msg info "Menginstall dependencies untuk DB Viewer..."
        (cd "$DB_VIEWER_DIR" && npm install --silent) || { msg err "npm install viewer gagal"; return 1; }
    fi
    local pidf="$LOG_DIR/db_viewer.pid"; local logf="$LOG_DIR/db_viewer.log"
    if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
        msg info "DB Viewer sudah berjalan (PID: $(cat "$pidf"))"
        return 0
    fi
    (cd "$DB_VIEWER_DIR" && nohup PORT="$DB_VIEWER_PORT" CONFIG_FILE="$CONFIG_FILE" LOG_DIR="$LOG_DIR" node index.js > "$logf" 2>&1 & echo $! > "$pidf")
    sleep 1
    if kill -0 "$(cat "$pidf")" 2>/dev/null; then
        msg ok "DB Viewer started (http://0.0.0.0:$DB_VIEWER_PORT)"
        return 0
    else
        msg err "DB Viewer gagal start. Cek $logf"
        return 1
    fi
}

stop_db_viewer() {
    local pidf="$LOG_DIR/db_viewer.pid"
    if [ -f "$pidf" ]; then
        local pid=$(cat "$pidf")
        kill "$pid" 2>/dev/null || true
        rm -f "$pidf"
        msg ok "DB Viewer dihentikan"
    else
        msg info "DB Viewer tidak berjalan"
    fi
}

# ---------------------------
# Env editor & DB clean CLI
# ---------------------------
edit_env_file() {
    local id="$1"
    load_project "$id" || { msg err "Project not found"; wait_key; return; }
    local be_path="$PROJECT_PATH/$BE_DIR"
    [ ! -d "$be_path" ] && { msg err "Backend folder not found: $be_path"; wait_key; return; }
    local env_file="$be_path/.env"
    local env_example="$be_path/.env.example"
    if [ ! -f "$env_file" ] && [ -f "$env_example" ]; then
        cp "$env_example" "$env_file"
        msg ok ".env dibuat dari .env.example"
    elif [ ! -f "$env_file" ]; then
        cat > "$env_file" <<EOF
# Created by DApps Launcher
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=${PROJECT_NAME}_db
DB_USER=${PROJECT_NAME}_user
DB_PASSWORD=changeme
EOF
        msg ok ".env default dibuat"
    fi
    local editor="${EDITOR:-nano}"
    msg info "Opening $env_file with $editor"
    $editor "$env_file"
    msg ok ".env disimpan"
    wait_key
}

clean_db_project_menu() {
    header
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    echo ""
    read -rp "Enter project ID to CLEAN DB (drop all public schema): " id
    [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
    load_project "$id" || { msg err "Project not found"; wait_key; return; }
    local be_path="$PROJECT_PATH/$BE_DIR"
    local envfile="$be_path/.env"
    if [ ! -f "$envfile" ]; then msg err ".env backend tidak ditemukan: $envfile"; wait_key; return; fi
    parsed=$(parse_db_config_from_env "$envfile") || { msg err "Gagal parse .env"; wait_key; return; }
    IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
    if [ -z "$DB_NAME" ]; then msg err "DB_NAME tidak ditemukan di .env"; wait_key; return; fi
    if ! confirm "Yakin DROP semua objek di DB '$DB_NAME' untuk project $PROJECT_NAME?"; then msg info "Cancelled"; wait_key; return; fi
    start_postgres || true
    clean_db_schema_public "$DB_NAME" "$DB_USER" "$DB_PASSWORD"
    wait_key
}

clean_all_projects_db() {
    header
    if ! confirm "Yakin CLEAN semua DB dari semua project yang dikonfigurasi?"; then msg info "Cancelled"; wait_key; return; fi
    start_postgres || true
    while IFS='|' read -r id name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do
        [ -z "$id" ] && continue
        load_project "$id" || continue
        local envfile="$PROJECT_PATH/$BE_DIR/.env"
        [ ! -f "$envfile" ] && { msg warn "Skip $PROJECT_NAME (no .env)"; continue; }
        parsed=$(parse_db_config_from_env "$envfile") || { msg warn "Skip $PROJECT_NAME (parse fail)"; continue; }
        IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
        if [ -z "$DB_NAME" ]; then msg warn "Skip $PROJECT_NAME (no DB_NAME)"; continue; fi
        msg info "Cleaning $PROJECT_NAME -> $DB_NAME"
        clean_db_schema_public "$DB_NAME" "$DB_USER" "$DB_PASSWORD" || msg warn "Gagal clean $DB_NAME"
    done < "$CONFIG_FILE"
    wait_key
}

# ---------------------------
# Services: start/stop project components
# ---------------------------
get_available_port() {
    local port="$1"; local max_tries=100
    for i in $(seq 0 $max_tries); do
        local test_port=$((port + i))
        if ! ss -tuln 2>/dev/null | grep -q ":$test_port[[:space:]]"; then
            echo "$test_port"; return 0
        fi
    done
    return 1
}

detect_pkg_manager() {
    if command -v pnpm &>/dev/null; then echo "pnpm"
    elif command -v yarn &>/dev/null; then echo "yarn"
    else echo "npm"; fi
}

detect_start_command() {
    local pdir="$1"
    [ ! -f "$pdir/package.json" ] && { echo ""; return; }
    local has_dev
    has_dev=$(node -e "try{const p=require('$pdir/package.json'); console.log(!!(p.scripts && p.scripts.dev))}catch(e){console.log(false)}" 2>/dev/null || echo "false")
    [ "$has_dev" = "true" ] && { echo "npm run dev"; return; }
    local has_start
    has_start=$(node -e "try{const p=require('$pdir/package.json'); console.log(!!(p.scripts && p.scripts.start))}catch(e){console.log(false)}" 2>/dev/null || echo "false")
    [ "$has_start" = "true" ] && { echo "npm start"; return; }
    echo ""
}

adjust_cmd_for_bind() {
    local cmd="$1"; local port="$2"
    if echo "$cmd" | grep -qE "serve|http-server"; then
        if echo "$cmd" | grep -q "serve"; then
            if echo "$cmd" | grep -qE "-l|--listen"; then
                echo "$cmd"; return
            else
                echo "$cmd -l 0.0.0.0:$port"; return
            fi
        fi
        echo "$cmd"; return
    fi
    if echo "$cmd" | grep -q "vite"; then
        if echo "$cmd" | grep -q -- "--host"; then echo "$cmd"; else echo "$cmd --host 0.0.0.0"; fi
        return
    fi
    echo "$cmd"
}

start_service() {
    local id="$1" dir="$2" port="$3" cmd="$4" label="$5"
    local pid_file="$LOG_DIR/${id}_${label}.pid"
    local log_file="$LOG_DIR/${id}_${label}.log"
    local port_file="$LOG_DIR/${id}_${label}.port"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg warn "$label already running (PID: $pid)"; return 0
        fi
        rm -f "$pid_file" || true
    fi
    local full_path="$PROJECT_PATH/$dir"
    [ ! -d "$full_path" ] && { msg err "$label folder not found: $full_path"; return 1; }

    if [ "$label" = "backend" ]; then
        msg info "Mempersiapkan PostgreSQL untuk backend..."
        start_postgres || { msg err "Gagal start postgres"; }
        create_db_from_env "$id" || true
    fi

    local final_port
    final_port=$(get_available_port "$port") || { msg err "No port available"; return 1; }
    [ "$final_port" != "$port" ] && msg warn "Port $port in use, using $final_port"

    if [ -f "$full_path/package.json" ]; then
        local pkgsum_file="$LOG_DIR/${id}_${label}_pkgsum"
        local cur_sum; cur_sum=$(md5_file "$full_path/package.json" || true)
        local prev_sum=""; [ -f "$pkgsum_file" ] && prev_sum=$(cat "$pkgsum_file" 2>/dev/null || true)
        if [ -n "$cur_sum" ] && [ "$cur_sum" != "$prev_sum" ]; then
            msg info "package.json changed -> running install for $label"
            (cd "$full_path" && $(detect_pkg_manager) install) && msg ok "$label deps installed" || msg warn "$label install failed"
            echo "$cur_sum" > "$pkgsum_file"
        fi
    fi

    local adj_cmd; adj_cmd=$(adjust_cmd_for_bind "$cmd" "$final_port")
    (
        cd "$full_path" || exit 1
        [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a
        HOST="0.0.0.0"; PORT="$final_port"
        nohup bash -lc "HOST=$HOST PORT=$PORT $adj_cmd" > "$log_file" 2>&1 &
        echo $! > "$pid_file"; echo "$final_port" > "$port_file"
    )
    sleep 1
    local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        msg ok "$label started (PID: $pid, Port: $final_port)"; return 0
    else
        msg err "$label failed to start. Check: $log_file"; rm -f "$pid_file" "$port_file" || true; return 1
    fi
}

stop_service() {
    local id="$1" label="$2"
    local pid_file="$LOG_DIR/${id}_${label}.pid"
    local port_file="$LOG_DIR/${id}_${label}.port"
    [ ! -f "$pid_file" ] && { msg info "$label not running"; return 0; }
    local pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] && { rm -f "$pid_file" "$port_file"; return 0; }
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$pid_file" "$port_file"; return 0; fi
    msg info "Stopping $label (PID: $pid)..."; kill "$pid" 2>/dev/null || true; sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$pid_file" "$port_file" || true; msg ok "$label stopped"
}

install_deps() {
    local id="$1"
    load_project "$id" || { msg err "Project not found"; return 1; }
    msg info "Installing dependencies for $PROJECT_NAME..."
    for spec in "Frontend:$FE_DIR" "Backend:$BE_DIR"; do
        local label=${spec%%:*}; local dir=${spec#*:}; local full="$PROJECT_PATH/$dir"
        [ ! -d "$full" ] && { msg warn "$label folder not found"; continue; }
        [ ! -f "$full/package.json" ] && { msg warn "$label has no package.json"; continue; }
        msg info "Installing $label with npm..."
        (cd "$full" && npm install --silent) && msg ok "$label installed" || msg err "$label install failed"
    done
}

# ---------------------------
# Add / Delete / Export
# ---------------------------
add_project() {
    header; read -rp "Project name: " name; [ -z "$name" ] && { msg err "Name required"; wait_key; return; }
    local id=$(generate_id); local local_path="$PROJECTS_DIR/$name"; mkdir -p "$local_path"
    local source_path=""
    if confirm "Ambil project dari storage (sdcard /storage/emulated/0)?"; then
        read -rp "Masukkan path sumber di storage (contoh: /storage/emulated/0/MyProjects/$name): " src
        [ -z "$src" ] && { msg err "Path sumber kosong"; wait_key; return; }
        export PROJECT_ID="$id"
        copy_storage_to_termux "$src" "$local_path" || { msg err "Gagal copy dari storage"; wait_key; return; }
        source_path="$src"
    else
        mkdir -p "$local_path"
        msg ok "Folder kosong dibuat di $local_path"
    fi
    FE_DIR=""; BE_DIR=""
    PROJECT_ID="$id"; PROJECT_NAME="$name"; PROJECT_PATH="$local_path"; SOURCE_PATH="$source_path"
    detect_dirs_if_needed
    save_project "$id" "$name" "$local_path" "$source_path" "$FE_DIR" "$BE_DIR" "3000" "8000" "npx serve ." "npm start" "0" "0"
    msg ok "Project added with ID: $id"
    wait_key
}

delete_project() {
    header; list_projects_table || { msg warn "No projects"; wait_key; return; }
    read -rp "Enter project ID to delete: " id; load_project "$id" || { msg err "Project not found"; wait_key; return; }
    if confirm "Delete project files?"; then rm -rf "$PROJECT_PATH" && msg ok "Files deleted"; fi
    grep -v "^$id|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true; mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true
    msg ok "Config removed"; wait_key
}

export_config_json() {
    local out="$LOG_DIR/dapps_config_$(date +%F_%H%M%S).json"; echo "[" > "$out"; local first=1
    while IFS='|' read -r id name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do
        [ -z "$id" ] && continue
        [ $first -eq 1 ] || echo "," >> "$out"; first=0
        cat >> "$out" <<EOF
{
  "id":"$id",
  "name":"$name",
  "path":"$local_path",
  "source":"$source_path",
  "frontend_dir":"$fe_dir",
  "backend_dir":"$be_dir",
  "frontend_port":$fe_port,
  "backend_port":$be_port,
  "frontend_cmd":"$fe_cmd",
  "backend_cmd":"$be_cmd",
  "auto_restart":"$auto_restart",
  "auto_sync":"$auto_sync"
}
EOF
    done < "$CONFIG_FILE"
    echo "]" >> "$out"; msg ok "Config exported: $out"
}

# ---------------------------
# Dump & Restore DB
# ---------------------------
dump_db_to_source() {
    local id="$1"; load_project "$id" || { msg err "Project tidak ditemukan"; return 1; }
    local src="$SOURCE_PATH"; [ -z "$src" ] && src="$PROJECT_PATH"; [ -z "$src" ] && { msg err "Source not configured"; return 1; }
    local be_path="$PROJECT_PATH/$BE_DIR"; local envfile="$be_path/.env"; [ ! -f "$envfile" ] && { msg err ".env missing"; return 1; }
    parsed=$(parse_db_config_from_env "$envfile") || { msg err "parse fail"; return 1; }
    IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
    if [ -z "$DB_NAME" ]; then msg err "DB_NAME kosong"; return 1; fi
    mkdir -p "$src"
    local outf="$src/${PROJECT_NAME}_db_${DB_NAME}_$(date +%F_%H%M%S).sql"
    if [ -n "$DB_PASSWORD" ]; then PGPASSWORD="$DB_PASSWORD" pg_dump -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${DB_USER:-$(whoami)}" -d "$DB_NAME" -F p -f "$outf" >/dev/null 2>&1 || { msg err "pg_dump gagal"; return 1; }; else pg_dump -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${DB_USER:-$(whoami)}" -d "$DB_NAME" -F p -f "$outf" >/dev/null 2>&1 || { msg err "pg_dump gagal"; return 1; }; fi
    msg ok "Dump selesai: $outf"; return 0
}

restore_db_from_file() {
    local id="$1" file="$2"; load_project "$id" || { msg err "Project not found"; return 1; }
    [ ! -f "$file" ] && { msg err "File dump not found"; return 1; }
    local be_path="$PROJECT_PATH/$BE_DIR"; local envfile="$be_path/.env"; [ ! -f "$envfile" ] && { msg err ".env missing"; return 1; }
    parsed=$(parse_db_config_from_env "$envfile") || { msg err "parse fail"; return 1; }
    IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
    if [ -z "$DB_NAME" ]; then msg err "DB_NAME kosong"; return 1; fi
    create_db_from_env "$id" || true
    if [ -n "$DB_PASSWORD" ]; then PGPASSWORD="$DB_PASSWORD" psql -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${DB_USER:-$(whoami)}" -d "$DB_NAME" -f "$file" >/dev/null 2>&1 || { msg err "Restore gagal"; return 1; }; else psql -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" -U "${DB_USER:-$(whoami)}" -d "$DB_NAME" -f "$file" >/dev/null 2>&1 || { msg err "Restore gagal"; return 1; }; fi
    msg ok "Restore selesai"; return 0
}

create_db_from_env() {
    local id="$1"; load_project "$id" || { msg err "Project tidak ditemukan"; return 1; }
    local be_path="$PROJECT_PATH/$BE_DIR"; local envfile="$be_path/.env"; [ ! -f "$envfile" ] && { msg warn ".env backend tidak ditemukan"; return 1; }
    start_postgres || { msg err "Postgres fail"; return 1; }
    parsed=$(parse_db_config_from_env "$envfile") || { msg err "Gagal parse .env"; return 1; }
    IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
    if [ -z "$DB_NAME" ]; then msg warn "DB_NAME tidak ditemukan di .env"; return 1; fi
    if [ "$DB_HOST" != "127.0.0.1" ] && [ "$DB_HOST" != "localhost" ]; then msg warn "DB_HOST bukan lokal ($DB_HOST). Lewati auto-create."; return 1; fi
    if [ -n "$DB_USER" ]; then create_role_if_needed "$DB_USER" "$DB_PASSWORD" || true; fi
    create_db_if_needed "$DB_NAME" "$DB_USER" || true
    mkdir -p "$PROJECT_PATH/.dapps"; echo "{\"db_name\":\"$DB_NAME\",\"db_user\":\"$DB_USER\",\"created_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" > "$PROJECT_PATH/.dapps/db_created.json"
    msg ok "Skema DB siap untuk project $PROJECT_NAME"; return 0
}

# ---------------------------
# Small header & menu
# ---------------------------
header() {
    clear
    local running_count=0
    local total_db_size_bytes=0
    while IFS='|' read -r id name local_path source_path _; do
        [ -z "$id" ] && continue
        local fe_pid_file="$LOG_DIR/${id}_frontend.pid"
        local be_pid_file="$LOG_DIR/${id}_backend.pid"
        if { [ -f "$fe_pid_file" ] && kill -0 "$(cat "$fe_pid_file")" 2>/dev/null; } || \
           { [ -f "$be_pid_file" ] && kill -0 "$(cat "$be_pid_file")" 2>/dev/null; }; then
            running_count=$((running_count+1))
        fi
    done < "$CONFIG_FILE"

    # sum DB sizes (best-effort)
    while IFS='|' read -r id name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do
        [ -z "$id" ] && continue
        local envf="$local_path/$be_dir/.env"
        if [ -f "$envf" ]; then
            parsed=$(parse_db_config_from_env "$envf") || true
            IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
            if [ -n "$DB_NAME" ]; then
                local size_bytes
                if [ -n "$DB_PASSWORD" ]; then
                    size_bytes=$(PGPASSWORD="$DB_PASSWORD" psql -At -c "SELECT pg_database_size('$DB_NAME')" 2>/dev/null || echo 0)
                else
                    size_bytes=$(psql -At -c "SELECT pg_database_size('$DB_NAME')" 2>/dev/null || echo 0)
                fi
                size_bytes=${size_bytes:-0}
                total_db_size_bytes=$((total_db_size_bytes + size_bytes))
            fi
        fi
    done < "$CONFIG_FILE"

    local pretty_total
    if [ "$total_db_size_bytes" -gt 0 ] 2>/dev/null; then
        pretty_total=$(awk -v s="$total_db_size_bytes" 'function human(x){
          split("B K M G T P",u);
          i=0; while(x>1024 && i<5){x/=1024; i++} return sprintf("%.1f%s",x,u[i+1])}
          END{print human(s)}')
    else
        pretty_total="0B"
    fi

    echo -e "${C}${BOLD}╔════════════════════════════════════════════════════════╗${X}"
    echo -e "${C}${BOLD}║    DApps Localhost Launcher Pro — v${LAUNCHER_VERSION}         ║${X}"
    echo -e "${C}${BOLD}╚════════════════════════════════════════════════════════╝${X}\n"
    echo -e "${BOLD}Running projects:${X} ${G}${running_count}${X}  •  ${BOLD}Total DB size:${X} ${G}${pretty_total}${X}"
    echo ""
}

menu_postgres_tools() {
    header
    echo -e "${BOLD}PostgreSQL & DB Tools${X}\n"
    echo "1) Status PostgreSQL"
    echo "2) Start PostgreSQL"
    echo "3) Stop PostgreSQL"
    echo "4) Init DB cluster (initdb) - jika belum"
    echo "5) Dump DB of project -> clone ke source folder"
    echo "6) Restore DB dari file ke project"
    echo "7) Start DB Web Viewer"
    echo "8) Stop DB Web Viewer"
    echo "9) Clean DB per project (drop all public schema)"
    echo "10) Clean ALL project DBs"
    echo "0) Kembali"
    read -rp "Select: " ch
    case "$ch" in
        1) status_postgres; wait_key ;;
        2) start_postgres; wait_key ;;
        3) stop_postgres; wait_key ;;
        4) init_postgres_if_needed; wait_key ;;
        5)
            header; list_projects_table || { msg warn "No projects"; wait_key; return; }
            read -rp "Enter project ID: " id
            [ -n "$id" ] && dump_db_to_source "$id"
            wait_key
            ;;
        6)
            header; list_projects_table || { msg warn "No projects"; wait_key; return; }
            read -rp "Enter project ID: " id
            [ -n "$id" ] || { wait_key; return; }
            read -rp "Enter dump file path to restore: " file
            [ -n "$file" ] && restore_db_from_file "$id" "$file"
            wait_key
            ;;
        7) start_db_viewer; wait_key ;;
        8) stop_db_viewer; wait_key ;;
        9) clean_db_project_menu ;;
        10) clean_all_projects_db ;;
        0) return ;;
        *) msg err "Invalid"; wait_key ;;
    esac
}

# ---------------------------
# Main menu
# ---------------------------
show_menu() {
    header
    echo -e "${BOLD}MAIN MENU${X}\n"
    echo " 1. 📋 List All Projects"
    echo " 2. ➕ Add New Project"
    echo " 3. ▶️  Start Project (by ID)"
    echo " 4. ⏹️  Stop Project (by ID)"
    echo " 5. 📦 Install Dependencies (by ID)"
    echo " 6. 🔄 Sync Project (by ID)"
    echo " 7. 📝 View Logs (by ID)"
    echo " 8. 🗑️  Delete Project"
    echo " 9. 🔁 Export Config"
    echo "10. 🔧 Diagnostic & Fix Tool"
    echo "11. ⬆️  Update Launcher (self-update)"
    echo "12. 🗑️  Uninstall Launcher"
    echo "13. ✏️  Edit backend .env (by ID)"
    echo "14. 🗄️  PostgreSQL & DB Tools"
    echo " 0. 🚪 Keluar"
    echo -e "\n${BOLD}═══════════════════════════════════${X}"
    read -rp "Select (0-14): " choice
    case "$choice" in
        1) header; list_projects_table || msg warn "No projects"; prompt_open_path_after_list || true; wait_key ;;
        2) add_project ;;
        3)
            header; list_projects_table || { msg warn "No projects"; wait_key; return; }
            read -rp "Enter project ID: " id; [ -n "$id" ] && run_project_by_id "$id";;
        4)
            header; list_projects_table || { msg warn "No projects"; wait_key; return; }
            read -rp "Enter project ID: " id; [ -n "$id" ] && stop_project_by_id "$id";;
        5)
            header; list_projects_table || { msg warn "No projects"; wait_key; return; }
            echo ""; read -rp "Enter project ID: " id; [ -n "$id" ] && install_deps "$id"; wait_key
            ;;
        6) sync_project ;;
        7) view_logs ;;
        8) delete_project ;;
        9) export_config_json; wait_key ;;
        10) diagnose_and_fix ;;
        11) self_update ;;
        12) uninstall_launcher ;;
        13)
            header; list_projects_table || { wait_key; return; }
            echo ""; read -rp "Enter project ID: " id; [ -n "$id" ] && edit_env_file "$id"
            ;;
        14) menu_postgres_tools ;;
        0) header; msg info "Goodbye!"; exit 0 ;;
        *) msg err "Invalid choice"; wait_key ;;
    esac
}

# wrappers to start/stop project by id
run_project_by_id() {
    local id="$1"; load_project "$id" || { msg err "Project not found"; wait_key; return; }
    header; echo -e "${BOLD}Starting: $PROJECT_NAME (ID: $id)${X}\n"
    (
        detect_dirs_if_needed || true
        [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$id" || true
        [ ! -d "$PROJECT_PATH" ] && { msg err "Project path not found"; wait_key; return; }
        local fe_path="$PROJECT_PATH/$FE_DIR"; local be_path="$PROJECT_PATH/$BE_DIR"
        if [ -d "$fe_path" ] && [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then confirm "Frontend deps missing. Install?" && install_deps "$id"; fi
        if [ -d "$be_path" ] && [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then confirm "Backend deps missing. Install?" && install_deps "$id"; fi
        start_service "$id" "$FE_DIR" "$FE_PORT" "$FE_CMD" "frontend"
        start_service "$id" "$BE_DIR" "$BE_PORT" "$BE_CMD" "backend"
        if [ -f "$LOG_DIR/${id}_frontend.port" ]; then p=$(cat "$LOG_DIR/${id}_frontend.port"); ip=$(get_device_ip); echo -e "Frontend (device): http://$ip:$p"; fi
        if [ -f "$LOG_DIR/${id}_backend.port" ]; then p2=$(cat "$LOG_DIR/${id}_backend.port"); ip2=$(get_device_ip); echo -e "Backend (device): http://$ip2:$p2"; fi
        wait_key
    )
}

stop_project_by_id() {
    local id="$1"; load_project "$id" || { msg err "Project not found"; wait_key; return; }
    stop_service "$id" "frontend"; stop_service "$id" "backend"; wait_key
}

# ---------------------------
# Diagnostics & helpers
# ---------------------------
diagnose_and_fix() {
    header; check_deps || msg warn "Dependencies missing (use pkg install nodejs git postgresql rsync)"; status_postgres || msg warn "Postgres mungkin tidak berjalan"
    msg info "Open ports (ss -tuln):"; ss -tuln 2>/dev/null | sed -n '1,120p'; msg info "Logs dir: $LOG_DIR"; wait_key
}

self_update() {
    header
    if ! command -v git &>/dev/null; then msg err "git tidak tersedia"; wait_key; return; fi
    if [ -d "$PROJECTS_DIR/.git" ]; then
        (cd "$PROJECTS_DIR" && git pull) && msg ok "Launcher updated" || msg err "Update gagal"
    else
        msg warn "Tidak ada repo local. install manual dari $GIT_REPO jika perlu."
    fi
    wait_key
}

uninstall_launcher() {
    header
    if confirm "Uninstall launcher?"; then
        rm -rf "$PROJECTS_DIR" "$LOG_DIR" "$CONFIG_FILE" "$DB_VIEWER_DIR"
        msg ok "Launcher removed"
    else
        msg info "Cancelled"
    fi
    wait_key
}

view_logs() {
    header
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    read -rp "Enter project ID for logs: " id
    [ -z "$id" ] && { wait_key; return; }
    load_project "$id" || { msg err "Project not found"; wait_key; return; }
    echo "---- frontend log ----"
    [ -f "$LOG_DIR/${id}_frontend.log" ] && tail -n 200 "$LOG_DIR/${id}_frontend.log" || echo "(no frontend log)"
    echo "---- backend log ----"
    [ -f "$LOG_DIR/${id}_backend.log" ] && tail -n 200 "$LOG_DIR/${id}_backend.log" || echo "(no backend log)"
    echo "---- sync log ----"
    [ -f "$LOG_DIR/${id}_sync.log" ] && tail -n 200 "$LOG_DIR/${id}_sync.log" || echo "(no sync log)"
    wait_key
}

check_deps() {
    local needed=(node npm git ss psql pg_ctl pg_dump initdb rsync)
    local missing=()
    for cmd in "${needed[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then missing+=("$cmd"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then msg warn "Missing: ${missing[*]}"; msg info "Install: pkg install nodejs git postgresql rsync"; return 1; fi
    return 0
}

# ---------------------------
# Entrypoint
# ---------------------------
main() {
    check_deps || msg warn "Beberapa dependencies mungkin hilang (jalankan pkg install nodejs git postgresql rsync)"
    while true; do show_menu; done
}

main
