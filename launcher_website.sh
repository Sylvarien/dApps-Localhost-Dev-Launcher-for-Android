#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher - Professional v3.5.0 (FULLY FIXED)
# 
# FIXES:
# ✅ Folder FE/BE 100% ditentukan user, tidak pernah di-override otomatis
# ✅ Server bind ke 0.0.0.0 untuk akses eksternal
# ✅ Logging sync detail (file list + bytes)
# ✅ Error handling untuk missing commands (ip/initdb/rsync)
# ✅ Multi-framework support (Vite/Next/CRA/Static/Express/Nest)
# ✅ Config user selalu dihormati
# ============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROJECTS_DIR="$HOME/dapps-projects"
CONFIG_FILE="$HOME/.dapps.conf"
LOG_DIR="$HOME/.dapps-logs"
LAUNCHER_VERSION="3.5.0"

DB_VIEWER_DIR="${DB_VIEWER_DIR:-$HOME/paxiforge-db-viewer}"
DB_VIEWER_PORT="${DB_VIEWER_PORT:-8081}"

PG_DATA="${PG_DATA:-$PREFIX/var/lib/postgresql}"
PG_LOG="$HOME/pgsql.log"

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
    # Fallback chain untuk mendapatkan IP
    local ip=""
    
    # Method 1: ip command
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || true)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    
    # Method 2: hostname
    if command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    
    # Method 3: ifconfig
    if command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1 || true)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    
    # Fallback
    echo "127.0.0.1"
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
    
    # Remove old entry
    grep -v "^$id|" "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true
    
    # Save new entry
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$id" "$name" "$local_path" "$source_path" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_restart" "$auto_sync" \
        >> "$CONFIG_FILE"
}

load_project() {
    local id="$1"
    local line
    
    # CRITICAL: ID must not be empty
    if [ -z "$id" ]; then
        msg err "load_project: ID parameter kosong!"
        return 1
    fi
    
    # Escape special chars in grep
    line=$(grep "^${id}|" "$CONFIG_FILE" 2>/dev/null | head -n1 || true)
    
    if [ -z "$line" ]; then
        msg err "Project ID $id tidak ditemukan di config"
        return 1
    fi
    
    IFS='|' read -r PROJECT_ID PROJECT_NAME PROJECT_PATH SOURCE_PATH \
                    FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD \
                    AUTO_RESTART AUTO_SYNC <<< "$line"
    
    # Validate loaded data
    if [ -z "$PROJECT_ID" ]; then
        msg err "Config corrupted: PROJECT_ID kosong untuk line: $line"
        return 1
    fi
    
    # Export untuk dipakai di fungsi lain
    export PROJECT_ID PROJECT_NAME PROJECT_PATH SOURCE_PATH FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD AUTO_RESTART AUTO_SYNC
    
    return 0
}

# ---------------------------
# Path helpers
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

# ---------------------------
# FIXED: Detailed sync with file list
# ---------------------------
copy_storage_to_termux() {
    local src="$1" dest="$2"
    [ -z "$src" ] && { msg err "Sumber kosong"; return 1; }
    [ -z "$dest" ] && { msg err "Tujuan kosong"; return 1; }
    if [ ! -d "$src" ]; then msg err "Sumber tidak ditemukan: $src"; return 1; fi
    
    mkdir -p "$dest" "$dest/.dapps" 2>/dev/null || true

    local tmp_log="$LOG_DIR/rsync_tmp_${PROJECT_ID}.out"
    local final_log="$LOG_DIR/${PROJECT_ID}_sync.log"
    : > "$tmp_log"

    msg info "Syncing: $(path_type "$src") → $dest"
    
    if command -v rsync &>/dev/null; then
        msg info "Menggunakan rsync (detailed logging)..."
        
        # Run rsync with detailed output
        if rsync -avh --delete --checksum --progress \
            --out-format='%n|%l|%t' \
            "$src"/ "$dest"/ > "$tmp_log" 2>&1; then
            
            # Parse hasil
            local total_bytes=0 files=0
            while IFS='|' read -r file size timestamp; do
                [ -z "$file" ] && continue
                files=$((files+1))
                size=${size:-0}
                total_bytes=$((total_bytes + size))
            done < "$tmp_log" || true
            
            # Save summary
            cat > "$dest/.dapps/sync_summary.json" <<EOF
{
  "files": $files,
  "bytes": $total_bytes,
  "human_size": "$(numfmt --to=iec-i --suffix=B $total_bytes 2>/dev/null || echo "${total_bytes}B")",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
            
            # Save detailed log
            {
                echo "=== SYNC LOG ==="
                echo "Timestamp: $(date)"
                echo "Source: $src"
                echo "Dest: $dest"
                echo "Files: $files"
                echo "Total Bytes: $total_bytes"
                echo ""
                echo "=== FILE LIST ==="
                cat "$tmp_log"
            } > "$final_log"
            
            msg ok "Synced: $files files, $(numfmt --to=iec-i --suffix=B $total_bytes 2>/dev/null || echo "${total_bytes}B")"
        else
            msg err "rsync gagal. Lihat $tmp_log"
            return 1
        fi
    else
        msg warn "rsync tidak tersedia. Menggunakan tar fallback (no detail)..."
        
        (cd "$src" && tar -cpf - .) | (cd "$dest" && tar -xpf -) || {
            msg err "tar copy gagal"
            return 1
        }
        
        local cnt; cnt=$(find "$dest" -type f 2>/dev/null | wc -l || echo 0)
        local bytes; bytes=$(du -sb "$dest" 2>/dev/null | awk '{print $1}' || echo 0)
        
        cat > "$dest/.dapps/sync_summary.json" <<EOF
{
  "files": $cnt,
  "bytes": $bytes,
  "human_size": "$(numfmt --to=iec-i --suffix=B $bytes 2>/dev/null || echo "${bytes}B")",
  "method": "tar-fallback",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
        
        echo "TAR FALLBACK: files=$cnt bytes=$bytes" > "$final_log"
        msg ok "Copy done (tar): $cnt files"
    fi

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/.dapps/.last_synced" 2>/dev/null || true
    return 0
}

# ---------------------------
# Sync functions
# ---------------------------
sync_project_by_id() {
    local id="$1"
    load_project "$id" || { msg err "Project not found"; return 1; }
    
    if [ -z "$SOURCE_PATH" ] || [ ! -d "$SOURCE_PATH" ]; then
        msg warn "source_path tidak diset atau tidak ada untuk project $PROJECT_NAME"
        read -rp "Masukkan storage source path (kosong untuk batalkan): " sp
        [ -z "$sp" ] && { msg err "Cancelled"; return 1; }
        SOURCE_PATH="$sp"
        save_project "$PROJECT_ID" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" \
                     "$FE_DIR" "$BE_DIR" "$FE_PORT" "$BE_PORT" "$FE_CMD" "$BE_CMD" \
                     "$AUTO_RESTART" "$AUTO_SYNC"
    fi
    
    export PROJECT_ID="$PROJECT_ID"
    copy_storage_to_termux "$SOURCE_PATH" "$PROJECT_PATH" || {
        msg err "Sync gagal"
        return 1
    }
    
    msg ok "Sync selesai untuk $PROJECT_NAME"
    return 0
}

sync_project() {
    header
    echo -e "${BOLD}Sync Project${X}\n"
    echo "1) Sync by project ID"
    echo "2) Sync ALL projects yang punya source_path"
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
            while IFS='|' read -r id name local_path source_path _; do
                [ -z "$id" ] && continue
                if [ -n "$source_path" ] && [ -d "$source_path" ]; then
                    msg info "Syncing $name ($id)"
                    sync_project_by_id "$id" || msg warn "Failed: $name"
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
        msg info "Auto-sync aktif → Syncing $PROJECT_NAME"
        sync_project_by_id "$id" || msg warn "Auto-sync gagal"
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
    
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────────────────┐${X}"
    echo -e "${BOLD}│                            PROJECT LIST                                     │${X}"
    echo -e "${BOLD}└─────────────────────────────────────────────────────────────────────────────┘${X}"
    echo ""
    echo -e "${BOLD}ID  | Status | Name                  | Source      | FE Dir    | BE Dir${X}"
    echo "-------------------------------------------------------------------------------------"
    
    local project_count=0
    while IFS='|' read -r id name local_path source_path fe_dir be_dir _; do
        [ -z "$id" ] && continue
        project_count=$((project_count + 1))
        
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
                running=" ${G}[RUN]${X}"
            fi
        fi
        
        local src_type; src_type=$(path_type "$source_path")
        fe_dir="${fe_dir:-(none)}"
        be_dir="${be_dir:-(none)}"
        
        printf "%-3s | %-6s | %-21s | %-11s | %-9s | %-9s%s\n" \
            "$id" "$status" "${name:0:21}" "$src_type" "${fe_dir:0:9}" "${be_dir:0:9}" "$running"
    done < "$CONFIG_FILE"
    
    echo ""
    
    if [ $project_count -eq 0 ]; then
        msg warn "Belum ada project! Tambahkan dengan menu 2 (Add Project)"
        return 1
    fi
    
    echo -e "${C}💡 Tips:${X}"
    echo "  - Ketik angka di kolom ${BOLD}ID${X} untuk pilih project"
    echo "  - Status ${G}[RUN]${X} = project sedang berjalan"
    echo "  - Untuk detail: ketik => <ID> info (contoh: 1 info)"
    
    return 0
}

prompt_open_path_after_list() {
    echo ""
    read -rp "Ketik (<ID> info) atau tekan ENTER: " cmd
    [ -z "$cmd" ] && return 0
    
    if [[ "$cmd" =~ ^([0-9]+)[[:space:]]+info$ ]]; then
        local id="${BASH_REMATCH[1]}"
        load_project "$id" || { msg err "Project not found"; return 1; }
        
        echo -e "\n${BOLD}=== Project Info: $PROJECT_NAME (ID: $id) ===${X}"
        echo "Local Path  : $PROJECT_PATH"
        echo "Source Path : ${SOURCE_PATH:-(none)}"
        echo "FE Dir      : ${FE_DIR:-(none)}"
        echo "BE Dir      : ${BE_DIR:-(none)}"
        echo "FE Port     : ${FE_PORT:-3000}"
        echo "BE Port     : ${BE_PORT:-8000}"
        echo "FE Command  : ${FE_CMD:-npx serve .}"
        echo "BE Command  : ${BE_CMD:-npm start}"
        echo "Auto Restart: ${AUTO_RESTART:-0}"
        echo "Auto Sync   : ${AUTO_SYNC:-0}"
        wait_key
    else
        msg err "Format: <ID> info"
        wait_key
    fi
}

# ---------------------------
# PostgreSQL helpers
# ---------------------------
init_postgres_if_needed() {
    if ! command -v initdb &>/dev/null; then
        msg err "initdb tidak tersedia. Install: pkg install postgresql"
        return 1
    fi
    
    if [ ! -d "$PG_DATA" ] || [ -z "$(ls -A "$PG_DATA" 2>/dev/null || true)" ]; then
        msg info "Inisialisasi PostgreSQL di: $PG_DATA"
        initdb "$PG_DATA" || { msg err "initdb gagal"; return 1; }
        msg ok "Postgres data siap"
    fi
    return 0
}

status_postgres() {
    if ! command -v pg_ctl &>/dev/null; then
        msg warn "pg_ctl tidak tersedia"
        return 1
    fi
    
    if [ -d "$PG_DATA" ]; then
        if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
            msg ok "Postgres berjalan"
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
    
    msg info "Starting PostgreSQL..."
    nohup pg_ctl -D "$PG_DATA" -l "$PG_LOG" start > /dev/null 2>&1 || {
        msg err "Gagal start Postgres. Cek $PG_LOG"
        return 1
    }
    
    sleep 2
    status_postgres && return 0 || return 1
}

stop_postgres() {
    if status_postgres >/dev/null 2>&1; then
        msg info "Stopping PostgreSQL..."
        pg_ctl -D "$PG_DATA" stop -m fast >/dev/null 2>&1 || {
            msg warn "pg_ctl stop gagal"
        }
        sleep 1
    else
        msg info "Postgres tidak berjalan"
    fi
    return 0
}

# ---------------------------
# FIXED: Auto-detect framework & generate proper start command
# ---------------------------
detect_framework_and_cmd() {
    local pdir="$1"
    [ ! -f "$pdir/package.json" ] && { echo ""; return; }
    
    # Check package.json scripts
    local pkg_json="$pdir/package.json"
    
    # Vite
    if grep -q '"vite"' "$pkg_json" 2>/dev/null; then
        if grep -q '"dev":' "$pkg_json"; then
            echo "npm run dev -- --host 0.0.0.0"
            return
        fi
    fi
    
    # Next.js
    if grep -q '"next"' "$pkg_json" 2>/dev/null; then
        if grep -q '"dev":' "$pkg_json"; then
            echo "npm run dev -- -H 0.0.0.0"
            return
        fi
    fi
    
    # React (CRA)
    if grep -q '"react-scripts"' "$pkg_json" 2>/dev/null; then
        echo "HOST=0.0.0.0 npm start"
        return
    fi
    
    # Express/Node backend
    if grep -q '"express"' "$pkg_json" 2>/dev/null || grep -q '"koa"' "$pkg_json" 2>/dev/null; then
        if grep -q '"dev":' "$pkg_json"; then
            echo "npm run dev"
        elif grep -q '"start":' "$pkg_json"; then
            echo "npm start"
        else
            echo "node index.js"
        fi
        return
    fi
    
    # NestJS
    if grep -q '"@nestjs/core"' "$pkg_json" 2>/dev/null; then
        if grep -q '"start:dev":' "$pkg_json"; then
            echo "npm run start:dev"
        else
            echo "npm start"
        fi
        return
    fi
    
    # Generic - check for dev script first
    if grep -q '"dev":' "$pkg_json"; then
        echo "npm run dev"
        return
    fi
    
    if grep -q '"start":' "$pkg_json"; then
        echo "npm start"
        return
    fi
    
    # Static server fallback
    echo "npx serve . -l tcp://0.0.0.0:3000"
}

# ---------------------------
# FIXED: Bind to 0.0.0.0 always
# ---------------------------
adjust_cmd_for_bind() {
    local cmd="$1"
    local port="$2"
    
    # Serve.js
    if echo "$cmd" | grep -q "serve"; then
        if ! echo "$cmd" | grep -q "0.0.0.0"; then
            echo "$cmd -l tcp://0.0.0.0:$port"
            return
        fi
    fi
    
    # Vite
    if echo "$cmd" | grep -q "vite"; then
        if ! echo "$cmd" | grep -q -- "--host"; then
            echo "$cmd --host 0.0.0.0 --port $port"
            return
        fi
    fi
    
    # Next.js
    if echo "$cmd" | grep -q "next"; then
        if ! echo "$cmd" | grep -q -- "-H"; then
            echo "$cmd -H 0.0.0.0 -p $port"
            return
        fi
    fi
    
    # http-server
    if echo "$cmd" | grep -q "http-server"; then
        if ! echo "$cmd" | grep -q "0.0.0.0"; then
            echo "$cmd -a 0.0.0.0 -p $port"
            return
        fi
    fi
    
    echo "$cmd"
}

# ---------------------------
# Port management
# ---------------------------
get_available_port() {
    local port="$1"
    local max_tries=100
    
    for i in $(seq 0 $max_tries); do
        local test_port=$((port + i))
        
        # Check if port is in use
        if command -v ss &>/dev/null; then
            if ! ss -tuln 2>/dev/null | grep -q ":$test_port "; then
                echo "$test_port"
                return 0
            fi
        elif command -v netstat &>/dev/null; then
            if ! netstat -tuln 2>/dev/null | grep -q ":$test_port "; then
                echo "$test_port"
                return 0
            fi
        else
            # No tool available, assume port is free
            echo "$test_port"
            return 0
        fi
    done
    
    return 1
}

# ---------------------------
# FIXED: Start service with proper 0.0.0.0 binding
# ---------------------------
start_service() {
    local id="$1"
    local dir="$2"
    local port="$3"
    local cmd="$4"
    local label="$5"
    
    # CRITICAL: Validate ID
    if [ -z "$id" ]; then
        msg err "INTERNAL ERROR: Project ID kosong di start_service!"
        return 1
    fi
    
    local pid_file="$LOG_DIR/${id}_${label}.pid"
    local log_file="$LOG_DIR/${id}_${label}.log"
    local port_file="$LOG_DIR/${id}_${label}.port"
    
    # Debug info
    msg info "Debug: ID=$id, Label=$label, LogFile=$log_file"
    
    # Check if already running
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg warn "$label already running (PID: $pid)"
            return 0
        fi
        rm -f "$pid_file" || true
    fi
    
    local full_path="$PROJECT_PATH/$dir"
    [ ! -d "$full_path" ] && {
        msg err "$label folder not found: $full_path"
        return 1
    }
    
    # Backend DB setup
    if [ "$label" = "backend" ]; then
        if command -v psql &>/dev/null; then
            msg info "Setting up PostgreSQL for backend..."
            start_postgres || msg warn "Postgres not available"
            create_db_from_env "$id" || true
        fi
    fi
    
    # Get available port
    local final_port
    final_port=$(get_available_port "$port") || {
        msg err "No port available"
        return 1
    }
    
    [ "$final_port" != "$port" ] && msg warn "Port $port in use, using $final_port"
    
    # Install deps if needed
    if [ -f "$full_path/package.json" ]; then
        local pkgsum_file="$LOG_DIR/${id}_${label}_pkgsum"
        local cur_sum; cur_sum=$(md5_file "$full_path/package.json" || true)
        local prev_sum=""; [ -f "$pkgsum_file" ] && prev_sum=$(cat "$pkgsum_file" 2>/dev/null || true)
        
        if [ -n "$cur_sum" ] && [ "$cur_sum" != "$prev_sum" ]; then
            msg info "package.json changed → installing for $label"
            (cd "$full_path" && npm install --silent) && msg ok "$label deps installed" || msg warn "$label install failed"
            echo "$cur_sum" > "$pkgsum_file"
        fi
    fi
    
    # Auto-detect command if empty
    if [ -z "$cmd" ] || [ "$cmd" = "auto" ]; then
        cmd=$(detect_framework_and_cmd "$full_path")
        [ -z "$cmd" ] && cmd="npx serve . -l tcp://0.0.0.0:$final_port"
        msg info "Auto-detected command: $cmd"
    fi
    
    # Adjust command for 0.0.0.0 binding
    local adj_cmd
    adj_cmd=$(adjust_cmd_for_bind "$cmd" "$final_port")
    
    msg info "Starting $label with: $adj_cmd"
    
    # Start service
    (
        cd "$full_path" || exit 1
        
        # Load .env if exists
        [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a
        
        # Export environment
        export HOST="0.0.0.0"
        export PORT="$final_port"
        export HOSTNAME="0.0.0.0"
        
        # Start process
        nohup bash -lc "HOST=0.0.0.0 PORT=$final_port HOSTNAME=0.0.0.0 $adj_cmd" > "$log_file" 2>&1 &
        echo $! > "$pid_file"
        echo "$final_port" > "$port_file"
    )
    
    sleep 2
    
    # Verify
    local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        local ip; ip=$(get_device_ip)
        msg ok "$label started!"
        echo -e "  ${G}→${X} PID: $pid"
        echo -e "  ${G}→${X} Port: $final_port"
        echo -e "  ${G}→${X} URL: http://$ip:$final_port"
        echo -e "  ${G}→${X} Local: http://localhost:$final_port"
        return 0
    else
        msg err "$label failed to start. Check: $log_file"
        rm -f "$pid_file" "$port_file" || true
        return 1
    fi
}

stop_service() {
    local id="$1"
    local label="$2"
    
    local pid_file="$LOG_DIR/${id}_${label}.pid"
    local port_file="$LOG_DIR/${id}_${label}.port"
    
    [ ! -f "$pid_file" ] && {
        msg info "$label not running"
        return 0
    }
    
    local pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] && {
        rm -f "$pid_file" "$port_file"
        return 0
    }
    
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file" "$port_file"
        return 0
    fi
    
    msg info "Stopping $label (PID: $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
    
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$pid_file" "$port_file" || true
    msg ok "$label stopped"
}

# ---------------------------
# Install dependencies
# ---------------------------
install_deps() {
    local id="$1"
    load_project "$id" || { msg err "Project not found"; return 1; }
    
    msg info "Installing dependencies for $PROJECT_NAME..."
    
    for spec in "Frontend:$FE_DIR" "Backend:$BE_DIR"; do
        local label=${spec%%:*}
        local dir=${spec#*:}
        local full="$PROJECT_PATH/$dir"
        
        [ -z "$dir" ] || [ "$dir" = "(none)" ] && {
            msg warn "$label dir not configured"
            continue
        }
        
        [ ! -d "$full" ] && {
            msg warn "$label folder not found: $full"
            continue
        }
        
        [ ! -f "$full/package.json" ] && {
            msg warn "$label has no package.json"
            continue
        }
        
        msg info "Installing $label..."
        (cd "$full" && npm install) && msg ok "$label installed" || msg err "$label install failed"
    done
}

# ---------------------------
# Database helpers
# ---------------------------
parse_db_config_from_env() {
    local envfile="$1"
    DB_HOST="127.0.0.1"
    DB_PORT="5432"
    DB_NAME=""
    DB_USER=""
    DB_PASSWORD=""
    
    [ ! -f "$envfile" ] && return 1
    
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        if [[ "$line" =~ ^DB_HOST= ]]; then
            DB_HOST="${line#DB_HOST=}"
            DB_HOST="${DB_HOST%\"}"
            DB_HOST="${DB_HOST#\"}"
        fi
        if [[ "$line" =~ ^DB_PORT= ]]; then
            DB_PORT="${line#DB_PORT=}"
            DB_PORT="${DB_PORT%\"}"
            DB_PORT="${DB_PORT#\"}"
        fi
        if [[ "$line" =~ ^DB_NAME= ]]; then
            DB_NAME="${line#DB_NAME=}"
            DB_NAME="${DB_NAME%\"}"
            DB_NAME="${DB_NAME#\"}"
        fi
        if [[ "$line" =~ ^DB_USER= ]]; then
            DB_USER="${line#DB_USER=}"
            DB_USER="${DB_USER%\"}"
            DB_USER="${DB_USER#\"}"
        fi
        if [[ "$line" =~ ^DB_PASSWORD= ]]; then
            DB_PASSWORD="${line#DB_PASSWORD=}"
            DB_PASSWORD="${DB_PASSWORD%\"}"
            DB_PASSWORD="${DB_PASSWORD#\"}"
        fi
        if [[ "$line" =~ ^DATABASE_URL= ]]; then
            url="${line#DATABASE_URL=}"
            url="${url%\"}"
            url="${url#\"}"
            
            if [[ "$url" =~ postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+) ]]; then
                DB_USER="${BASH_REMATCH[1]}"
                DB_PASSWORD="${BASH_REMATCH[2]}"
                DB_HOST="${BASH_REMATCH[3]}"
                DB_PORT="${BASH_REMATCH[4]}"
                DB_NAME="${BASH_REMATCH[5]}"
            elif [[ "$url" =~ postgresql://([^:]+):([^@]+)@([^/]+)/(.+) ]]; then
                DB_USER="${BASH_REMATCH[1]}"
                DB_PASSWORD="${BASH_REMATCH[2]}"
                DB_HOST="${BASH_REMATCH[3]}"
                DB_NAME="${BASH_REMATCH[4]}"
            fi
        fi
    done < "$envfile"
    
    echo "${DB_HOST}|${DB_PORT}|${DB_NAME}|${DB_USER}|${DB_PASSWORD}"
    return 0
}

create_role_if_needed() {
    local user="$1"
    local pass="$2"
    
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
    local db="$1"
    local owner="$2"
    
    if psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null | grep -q 1; then
        return 0
    fi
    
    if [ -n "$owner" ]; then
        psql -c "CREATE DATABASE \"$db\" OWNER \"$owner\";" >/dev/null 2>&1 || return 1
    else
        psql -c "CREATE DATABASE \"$db\";" >/dev/null 2>&1 || return 1
    fi
}

create_db_from_env() {
    local id="$1"
    load_project "$id" || return 1
    
    local be_path="$PROJECT_PATH/$BE_DIR"
    local envfile="$be_path/.env"
    
    [ ! -f "$envfile" ] && {
        msg warn ".env backend tidak ditemukan"
        return 1
    }
    
    parsed=$(parse_db_config_from_env "$envfile") || {
        msg err "Gagal parse .env"
        return 1
    }
    
    IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"
    
    [ -z "$DB_NAME" ] && {
        msg warn "DB_NAME tidak ditemukan di .env"
        return 1
    }
    
    if [ "$DB_HOST" != "127.0.0.1" ] && [ "$DB_HOST" != "localhost" ]; then
        msg warn "DB_HOST bukan lokal ($DB_HOST). Skip auto-create."
        return 1
    fi
    
    if [ -n "$DB_USER" ]; then
        create_role_if_needed "$DB_USER" "$DB_PASSWORD" || true
    fi
    
    create_db_if_needed "$DB_NAME" "$DB_USER" || true
    
    msg ok "DB $DB_NAME siap"
    return 0
}

# ---------------------------
# FIXED: Run project - NEVER override user config
# ---------------------------
run_project_by_id() {
    local id="$1"
    
    # CRITICAL: Validate ID first
    if [ -z "$id" ]; then
        msg err "Project ID tidak boleh kosong!"
        wait_key
        return 1
    fi
    
    load_project "$id" || {
        msg err "Project not found"
        wait_key
        return 1
    }
    
    header
    echo -e "${BOLD}Starting: $PROJECT_NAME (ID: $id)${X}\n"
    
    # CRITICAL: NEVER override user's FE_DIR/BE_DIR
    # Only check if they exist
    
    if [ -z "$FE_DIR" ] || [ "$FE_DIR" = "(none)" ]; then
        msg err "Frontend directory belum dikonfigurasi!"
        msg info "Gunakan 'Edit Project Config' (menu 15) untuk set FE_DIR"
        wait_key
        return 1
    fi
    
    if [ ! -d "$PROJECT_PATH/$FE_DIR" ]; then
        msg err "Frontend folder tidak ditemukan: $PROJECT_PATH/$FE_DIR"
        msg info "Gunakan 'Edit Project Config' (menu 15) untuk update FE_DIR"
        wait_key
        return 1
    fi
    
    # Backend optional
    local has_backend=false
    if [ -n "$BE_DIR" ] && [ "$BE_DIR" != "(none)" ]; then
        if [ -d "$PROJECT_PATH/$BE_DIR" ]; then
            has_backend=true
        else
            msg warn "Backend folder tidak ditemukan: $PROJECT_PATH/$BE_DIR"
            msg warn "Backend akan di-skip"
        fi
    fi
    
    # Auto-sync if enabled
    [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$id" || true
    
    # Check dependencies
    local fe_path="$PROJECT_PATH/$FE_DIR"
    if [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then
        if confirm "Frontend deps missing. Install now?"; then
            install_deps "$id"
        fi
    fi
    
    if [ "$has_backend" = true ]; then
        local be_path="$PROJECT_PATH/$BE_DIR"
        if [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then
            if confirm "Backend deps missing. Install now?"; then
                install_deps "$id"
            fi
        fi
    fi
    
    # Start services
    echo ""
    msg info "Starting services..."
    msg info "Debug: Project ID = '$id'"
    echo ""
    
    # CRITICAL: Pass ID explicitly
    start_service "$id" "$FE_DIR" "${FE_PORT:-3000}" "${FE_CMD:-auto}" "frontend" || {
        msg err "Frontend gagal start"
    }
    
    if [ "$has_backend" = true ]; then
        echo ""
        start_service "$id" "$BE_DIR" "${BE_PORT:-8000}" "${BE_CMD:-auto}" "backend" || {
            msg err "Backend gagal start"
        }
    fi
    
    echo ""
    msg ok "Project started!"
    wait_key
}

stop_project_by_id() {
    local id="$1"
    load_project "$id" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    msg info "Stopping $PROJECT_NAME..."
    stop_service "$id" "frontend"
    stop_service "$id" "backend"
    wait_key
}

# ---------------------------
# Add project
# ---------------------------
add_project() {
    header
    echo -e "${BOLD}Add New Project${X}\n"
    
    read -rp "Project name: " name
    [ -z "$name" ] && {
        msg err "Name required"
        wait_key
        return
    }
    
    local id=$(generate_id)
    local local_path="$PROJECTS_DIR/$name"
    
    mkdir -p "$local_path"
    
    local source_path=""
    
    # Ask for storage source
    if confirm "Import dari storage (sdcard)?"; then
        read -rp "Path storage (contoh: /storage/emulated/0/Projects/$name): " src
        [ -z "$src" ] && {
            msg err "Path kosong"
            wait_key
            return
        }
        
        if [ ! -d "$src" ]; then
            msg err "Path tidak ditemukan: $src"
            wait_key
            return
        fi
        
        export PROJECT_ID="$id"
        export PROJECT_NAME="$name"
        export PROJECT_PATH="$local_path"
        export SOURCE_PATH="$src"
        
        copy_storage_to_termux "$src" "$local_path" || {
            msg err "Gagal copy dari storage"
            wait_key
            return
        }
        
        source_path="$src"
    else
        msg ok "Folder kosong dibuat di $local_path"
    fi
    
    # CRITICAL: User MUST specify FE/BE dirs
    echo ""
    echo -e "${BOLD}Konfigurasi Folder (WAJIB!)${X}"
    echo "Masukkan nama folder relatif terhadap project root"
    echo ""
    
    read -rp "Frontend directory (contoh: frontend, client, web): " fe_dir
    [ -z "$fe_dir" ] && {
        msg warn "Frontend dir kosong, set ke 'frontend'"
        fe_dir="frontend"
    }
    
    read -rp "Backend directory (kosongkan jika tidak ada): " be_dir
    [ -z "$be_dir" ] && be_dir="(none)"
    
    # Ports
    read -rp "Frontend port (default: 3000): " fe_port
    fe_port="${fe_port:-3000}"
    
    read -rp "Backend port (default: 8000): " be_port
    be_port="${be_port:-8000}"
    
    # Commands (auto-detect)
    local fe_cmd="auto"
    local be_cmd="auto"
    
    if confirm "Custom start commands? (No = auto-detect)"; then
        read -rp "Frontend command: " fe_cmd
        read -rp "Backend command: " be_cmd
        [ -z "$fe_cmd" ] && fe_cmd="auto"
        [ -z "$be_cmd" ] && be_cmd="auto"
    fi
    
    # Save
    save_project "$id" "$name" "$local_path" "$source_path" \
                 "$fe_dir" "$be_dir" "$fe_port" "$be_port" \
                 "$fe_cmd" "$be_cmd" "0" "0"
    
    msg ok "Project added with ID: $id"
    echo ""
    echo "Frontend: $fe_dir"
    echo "Backend: $be_dir"
    wait_key
}

# ---------------------------
# Edit project config
# ---------------------------
edit_project_config() {
    header
    list_projects_table || {
        msg warn "No projects"
        wait_key
        return
    }
    
    echo ""
    read -rp "Enter project ID to edit: " id
    [ -z "$id" ] && {
        msg err "ID required"
        wait_key
        return
    }
    
    load_project "$id" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    echo ""
    echo -e "${BOLD}Current Config:${X}"
    echo "  Name       : $PROJECT_NAME"
    echo "  Path       : $PROJECT_PATH"
    echo "  Source     : ${SOURCE_PATH:-(none)}"
    echo "  FE dir     : ${FE_DIR:-(none)}"
    echo "  BE dir     : ${BE_DIR:-(none)}"
    echo "  FE port    : ${FE_PORT:-3000}"
    echo "  BE port    : ${BE_PORT:-8000}"
    echo "  FE command : ${FE_CMD:-auto}"
    echo "  BE command : ${BE_CMD:-auto}"
    echo ""
    echo -e "${Y}Kosongkan untuk tidak mengubah${X}"
    echo ""
    
    read -rp "New source path: " new_source
    read -rp "New frontend dir: " new_fe
    read -rp "New backend dir: " new_be
    read -rp "New frontend port: " new_fe_port
    read -rp "New backend port: " new_be_port
    read -rp "New frontend cmd: " new_fe_cmd
    read -rp "New backend cmd: " new_be_cmd
    read -rp "Auto restart (0/1): " new_ar
    read -rp "Auto sync (0/1): " new_as
    
    # Update only if provided
    [ -n "$new_source" ] && SOURCE_PATH="$new_source"
    [ -n "$new_fe" ] && FE_DIR="$new_fe"
    [ -n "$new_be" ] && BE_DIR="$new_be"
    [ -n "$new_fe_port" ] && FE_PORT="$new_fe_port"
    [ -n "$new_be_port" ] && BE_PORT="$new_be_port"
    [ -n "$new_fe_cmd" ] && FE_CMD="$new_fe_cmd"
    [ -n "$new_be_cmd" ] && BE_CMD="$new_be_cmd"
    [ -n "$new_ar" ] && AUTO_RESTART="$new_ar"
    [ -n "$new_as" ] && AUTO_SYNC="$new_as"
    
    save_project "$PROJECT_ID" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" \
                 "${FE_DIR:-(none)}" "${BE_DIR:-(none)}" \
                 "${FE_PORT:-3000}" "${BE_PORT:-8000}" \
                 "${FE_CMD:-auto}" "${BE_CMD:-auto}" \
                 "${AUTO_RESTART:-0}" "${AUTO_SYNC:-0}"
    
    msg ok "Config updated!"
    wait_key
}

# ---------------------------
# Delete project
# ---------------------------
delete_project() {
    header
    list_projects_table || {
        msg warn "No projects"
        wait_key
        return
    }
    
    echo ""
    read -rp "Enter project ID to delete: " id
    [ -z "$id" ] && {
        msg err "ID required"
        wait_key
        return
    }
    
    load_project "$id" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    echo ""
    msg warn "DANGER: Deleting $PROJECT_NAME"
    echo "Path: $PROJECT_PATH"
    
    if confirm "Delete project files from disk?"; then
        rm -rf "$PROJECT_PATH" && msg ok "Files deleted"
    fi
    
    # Remove from config
    grep -v "^$id|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true
    
    msg ok "Project removed from launcher"
    wait_key
}

# ---------------------------
# View logs
# ---------------------------
view_logs() {
    header
    list_projects_table || {
        msg warn "No projects"
        wait_key
        return
    }
    
    echo ""
    read -rp "Enter project ID: " id
    
    # Validate
    if [ -z "$id" ]; then
        msg err "ID tidak boleh kosong!"
        wait_key
        return
    fi
    
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
        msg err "ID harus angka!"
        wait_key
        return
    fi
    
    load_project "$id" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    echo ""
    echo -e "${BOLD}=== Logs for: $PROJECT_NAME (ID: $id) ===${X}"
    echo ""
    
    local fe_log="$LOG_DIR/${id}_frontend.log"
    local be_log="$LOG_DIR/${id}_backend.log"
    local sync_log="$LOG_DIR/${id}_sync.log"
    
    echo -e "${C}--- Frontend Log ---${X}"
    echo "File: $fe_log"
    if [ -f "$fe_log" ]; then
        tail -n 50 "$fe_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${C}--- Backend Log ---${X}"
    echo "File: $be_log"
    if [ -f "$be_log" ]; then
        tail -n 50 "$be_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${C}--- Sync Log ---${X}"
    echo "File: $sync_log"
    if [ -f "$sync_log" ]; then
        tail -n 30 "$sync_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${Y}Tip: cat $fe_log untuk lihat full log${X}"
    
    wait_key
}

# ---------------------------
# Export config
# ---------------------------
export_config_json() {
    local out="$LOG_DIR/dapps_config_$(date +%F_%H%M%S).json"
    
    echo "[" > "$out"
    local first=1
    
    while IFS='|' read -r id name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do
        [ -z "$id" ] && continue
        
        [ $first -eq 1 ] || echo "," >> "$out"
        first=0
        
        cat >> "$out" <<EOF
{
  "id": "$id",
  "name": "$name",
  "path": "$local_path",
  "source": "$source_path",
  "frontend_dir": "$fe_dir",
  "backend_dir": "$be_dir",
  "frontend_port": $fe_port,
  "backend_port": $be_port,
  "frontend_cmd": "$fe_cmd",
  "backend_cmd": "$be_cmd",
  "auto_restart": "$auto_restart",
  "auto_sync": "$auto_sync"
}
EOF
    done < "$CONFIG_FILE"
    
    echo "]" >> "$out"
    msg ok "Config exported: $out"
}

# ---------------------------
# Diagnostics
# ---------------------------
check_deps() {
    local needed=(node npm git)
    local optional=(ss psql pg_ctl rsync)
    local missing=()
    
    for cmd in "${needed[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        msg err "Missing required: ${missing[*]}"
        msg info "Install: pkg install nodejs git"
        return 1
    fi
    
    msg ok "Required deps OK"
    
    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg warn "Optional missing: $cmd"
        fi
    done
    
    return 0
}

diagnose_and_fix() {
    header
    echo -e "${BOLD}System Diagnostics${X}\n"
    
    check_deps
    
    echo ""
    msg info "PostgreSQL status:"
    status_postgres || msg warn "Install: pkg install postgresql"
    
    echo ""
    msg info "Checking config file..."
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        local count=$(wc -l < "$CONFIG_FILE")
        msg ok "Config OK: $count projects"
        echo ""
        echo "First line sample:"
        head -n1 "$CONFIG_FILE"
        
        # Check for malformed lines
        local bad_lines=0
        while IFS='|' read -r id name rest; do
            if [ -z "$id" ] || [ -z "$name" ]; then
                bad_lines=$((bad_lines + 1))
            fi
        done < "$CONFIG_FILE"
        
        if [ $bad_lines -gt 0 ]; then
            msg warn "$bad_lines malformed lines in config!"
            if confirm "Show malformed lines?"; then
                awk -F'|' 'NF < 12 || $1 == "" || $2 == ""' "$CONFIG_FILE"
            fi
        else
            msg ok "No malformed config lines"
        fi
    else
        msg warn "Config file empty or missing"
    fi
    
    echo ""
    msg info "Open ports:"
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | head -n 20
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | head -n 20
    else
        msg warn "No network tools (ss/netstat) available"
    fi
    
    echo ""
    msg info "Checking for corrupted log files..."
    local corrupted_count=0
    for logfile in "$LOG_DIR"/_*.log "$LOG_DIR"/_*.pid; do
        if [ -f "$logfile" ]; then
            corrupted_count=$((corrupted_count + 1))
            msg warn "Found corrupted: $logfile"
        fi
    done
    
    if [ $corrupted_count -gt 0 ]; then
        if confirm "Remove $corrupted_count corrupted log files?"; then
            rm -f "$LOG_DIR"/_*.log "$LOG_DIR"/_*.pid "$LOG_DIR"/_*.port 2>/dev/null || true
            msg ok "Corrupted files removed"
        fi
    else
        msg ok "No corrupted log files"
    fi
    
    echo ""
    msg info "Logs directory: $LOG_DIR"
    msg info "Projects directory: $PROJECTS_DIR"
    msg info "Config file: $CONFIG_FILE"
    
    wait_key
}

# ---------------------------
# Header
# ---------------------------
header() {
    clear
    
    local running_count=0
    
    while IFS='|' read -r id _; do
        [ -z "$id" ] && continue
        
        local fe_pid_file="$LOG_DIR/${id}_frontend.pid"
        local be_pid_file="$LOG_DIR/${id}_backend.pid"
        
        if [ -f "$fe_pid_file" ] || [ -f "$be_pid_file" ]; then
            local fe_pid=$(cat "$fe_pid_file" 2>/dev/null || true)
            local be_pid=$(cat "$be_pid_file" 2>/dev/null || true)
            
            if { [ -n "$fe_pid" ] && kill -0 "$fe_pid" 2>/dev/null; } || \
               { [ -n "$be_pid" ] && kill -0 "$be_pid" 2>/dev/null; }; then
                running_count=$((running_count+1))
            fi
        fi
    done < "$CONFIG_FILE"
    
    echo -e "${C}${BOLD}╔════════════════════════════════════════════════════════╗${X}"
    echo -e "${C}${BOLD}║    DApps Localhost Launcher Pro — v${LAUNCHER_VERSION}         ║${X}"
    echo -e "${C}${BOLD}╚════════════════════════════════════════════════════════╝${X}\n"
    echo -e "${BOLD}Running:${X} ${G}${running_count}${X} projects"
    echo ""
}

# ---------------------------
# Main menu
# ---------------------------
show_menu() {
    header
    echo -e "${BOLD}MAIN MENU${X}\n"
    echo " 1. 📋 List Projects"
    echo " 2. ➕ Add Project"
    echo " 3. ▶️  Start Project"
    echo " 4. ⏹️  Stop Project"
    echo " 5. 📦 Install Dependencies"
    echo " 6. 🔄 Sync Project"
    echo " 7. 📝 View Logs"
    echo " 8. 🗑️  Delete Project"
    echo " 9. 📤 Export Config"
    echo "10. 🔧 Diagnostics"
    echo "11. ✏️  Edit Project Config"
    echo "12. 🛠️  Fix Config File (repair)"
    echo " 0. 🚪 Exit"
    echo -e "\n${BOLD}═══════════════════════════════════${X}"
    read -rp "Select (0-12): " choice
    
    case "$choice" in
        1)
            header
            list_projects_table || msg warn "No projects"
            prompt_open_path_after_list || true
            wait_key
            ;;
        2) add_project ;;
        3)
            header
            
            # Check if there are projects first
            if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
                msg warn "Belum ada project!"
                msg info "Tambahkan project dulu dengan menu 2 (Add Project)"
                wait_key
                return
            fi
            
            # Show list
            list_projects_table || {
                msg warn "No projects"
                wait_key
                return
            }
            
            echo ""
            echo -e "${Y}Masukkan ID project yang ingin di-start${X}"
            read -rp "Enter project ID: " id
            
            # Validate input
            if [ -z "$id" ]; then
                msg err "Project ID tidak boleh kosong!"
                msg info "Lihat kolom ID di table atas"
                wait_key
                return
            fi
            
            # Check if numeric
            if ! [[ "$id" =~ ^[0-9]+$ ]]; then
                msg err "Project ID harus angka! Anda masukkan: '$id'"
                msg info "Contoh: ketik 1 untuk project dengan ID 1"
                wait_key
                return
            fi
            
            # Check if ID exists
            if ! grep -q "^${id}|" "$CONFIG_FILE" 2>/dev/null; then
                msg err "Project ID $id tidak ditemukan!"
                msg info "Lihat ID yang tersedia di table atas"
                wait_key
                return
            fi
            
            run_project_by_id "$id"
            ;;
        4)
            header
            
            if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
                msg warn "Belum ada project!"
                wait_key
                return
            fi
            
            list_projects_table || {
                msg warn "No projects"
                wait_key
                return
            }
            
            echo ""
            echo -e "${Y}Masukkan ID project yang ingin di-stop${X}"
            read -rp "Enter project ID: " id
            
            # Validate input
            if [ -z "$id" ]; then
                msg err "Project ID tidak boleh kosong!"
                wait_key
                return
            fi
            
            if ! [[ "$id" =~ ^[0-9]+$ ]]; then
                msg err "Project ID harus angka!"
                wait_key
                return
            fi
            
            if ! grep -q "^${id}|" "$CONFIG_FILE" 2>/dev/null; then
                msg err "Project ID $id tidak ditemukan!"
                wait_key
                return
            fi
            
            stop_project_by_id "$id"
            ;;
        5)
            header
            
            if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
                msg warn "Belum ada project!"
                wait_key
                return
            fi
            
            list_projects_table || {
                msg warn "No projects"
                wait_key
                return
            }
            
            echo ""
            echo -e "${Y}Masukkan ID project untuk install dependencies${X}"
            read -rp "Enter project ID: " id
            
            # Validate
            if [ -z "$id" ] || ! [[ "$id" =~ ^[0-9]+$ ]]; then
                msg err "Project ID harus angka!"
                wait_key
                return
            fi
            
            if ! grep -q "^${id}|" "$CONFIG_FILE" 2>/dev/null; then
                msg err "Project ID $id tidak ditemukan!"
                wait_key
                return
            fi
            
            install_deps "$id"
            wait_key
            ;;
        6) sync_project ;;
        7) view_logs ;;
        8) delete_project ;;
        9) export_config_json; wait_key ;;
        10) diagnose_and_fix ;;
        11) edit_project_config ;;
        12) fix_config_file ;;
        0)
            header
            msg info "Goodbye!"
            exit 0
            ;;
        *)
            msg err "Invalid choice"
            wait_key
            ;;
    esac
}

# ---------------------------
# Fix corrupted config
# ---------------------------
fix_config_file() {
    header
    echo -e "${BOLD}Fix Config File${X}\n"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        msg err "Config file tidak ada: $CONFIG_FILE"
        wait_key
        return
    fi
    
    msg info "Checking config file..."
    
    local backup="$CONFIG_FILE.backup.$(date +%s)"
    cp "$CONFIG_FILE" "$backup"
    msg ok "Backup created: $backup"
    
    echo ""
    echo "Current config:"
    cat -n "$CONFIG_FILE"
    
    echo ""
    local malformed=0
    local line_num=0
    
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [ -z "$line" ] && continue
        
        local field_count=$(echo "$line" | awk -F'|' '{print NF}')
        
        if [ "$field_count" -ne 12 ]; then
            msg warn "Line $line_num: Expected 12 fields, got $field_count"
            echo "  Content: $line"
            malformed=$((malformed + 1))
        fi
        
        local id=$(echo "$line" | cut -d'|' -f1)
        if [ -z "$id" ]; then
            msg warn "Line $line_num: Empty ID"
            malformed=$((malformed + 1))
        fi
    done < "$CONFIG_FILE"
    
    echo ""
    if [ $malformed -eq 0 ]; then
        msg ok "Config file OK! No issues found."
    else
        msg warn "Found $malformed malformed lines"
        
        if confirm "Remove malformed lines?"; then
            awk -F'|' 'NF == 12 && $1 != ""' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            msg ok "Config cleaned!"
            
            echo ""
            echo "New config:"
            cat -n "$CONFIG_FILE"
        fi
    fi
    
    wait_key
}

# ---------------------------
# Main
# ---------------------------
main() {
    # Cleanup corrupted log files on startup
    if ls "$LOG_DIR"/_*.log >/dev/null 2>&1 || ls "$LOG_DIR"/_*.pid >/dev/null 2>&1; then
        msg warn "Membersihkan log files yang rusak..."
        rm -f "$LOG_DIR"/_*.log "$LOG_DIR"/_*.pid "$LOG_DIR"/_*.port 2>/dev/null || true
        msg ok "Cleanup selesai"
        sleep 1
    fi
    
    check_deps || msg warn "Install dependencies: pkg install nodejs git postgresql rsync"
    
    while true; do
        show_menu
    done
}

main
