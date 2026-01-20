#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher - Professional v4.0.0 (NO ID SYSTEM)
# 
# MAJOR CHANGES:
# ✅ Sistem ID dihapus - menggunakan urutan list (nomor baris)
# ✅ Config lebih simpel: name|local_path|source_path|fe_dir|be_dir|...
# ✅ Akses project dengan nomor urut (1, 2, 3, dst)
# ✅ Auto-reindex saat delete project
# ============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROJECTS_DIR="$HOME/dapps-projects"
CONFIG_FILE="$HOME/.dapps.conf"
LOG_DIR="$HOME/.dapps-logs"
LAUNCHER_VERSION="4.0.0"

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
    local ip=""
    
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || true)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    
    if command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    
    if command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1 || true)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    
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
# Config format (NO ID):
# name|local_path|source_path|fe_dir|be_dir|fe_port|be_port|fe_cmd|be_cmd|auto_restart|auto_sync
# ---------------------------

save_project() {
    local num="$1" name="$2" local_path="$3" source_path="$4"
    local fe_dir="$5" be_dir="$6" fe_port="$7" be_port="$8"
    local fe_cmd="$9" be_cmd="${10}" auto_restart="${11}" auto_sync="${12}"
    
    # Create temp file
    local tmp_file="$CONFIG_FILE.tmp.$$"
    : > "$tmp_file"
    
    local current_line=1
    local updated=false
    
    # Read existing config and update/insert
    while IFS='|' read -r old_name old_path old_src old_fe old_be old_fe_port old_be_port old_fe_cmd old_be_cmd old_ar old_as || [ -n "$old_name" ]; do
        if [ $current_line -eq $num ]; then
            # Update this line
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
                "$name" "$local_path" "$source_path" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_restart" "$auto_sync" >> "$tmp_file"
            updated=true
        else
            # Keep existing line
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
                "$old_name" "$old_path" "$old_src" "$old_fe" "$old_be" "$old_fe_port" "$old_be_port" "$old_fe_cmd" "$old_be_cmd" "$old_ar" "$old_as" >> "$tmp_file"
        fi
        current_line=$((current_line + 1))
    done < "$CONFIG_FILE"
    
    # If line number is greater than current lines, append
    if [ "$updated" = false ]; then
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
            "$name" "$local_path" "$source_path" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_restart" "$auto_sync" >> "$tmp_file"
    fi
    
    mv "$tmp_file" "$CONFIG_FILE"
}

load_project() {
    local num="$1"
    
    if [ -z "$num" ]; then
        msg err "Nomor project kosong!"
        return 1
    fi
    
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        msg err "Nomor harus angka!"
        return 1
    fi
    
    # Get line by number
    local line
    line=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null || true)
    
    if [ -z "$line" ]; then
        msg err "Project #$num tidak ditemukan"
        return 1
    fi
    
    # Parse
    IFS='|' read -r PROJECT_NAME PROJECT_PATH SOURCE_PATH \
                    FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD \
                    AUTO_RESTART AUTO_SYNC <<< "$line"
    
    if [ -z "$PROJECT_NAME" ]; then
        msg err "Config corrupted pada line $num"
        return 1
    fi
    
    # Export
    export PROJECT_NUM="$num"
    export PROJECT_NAME PROJECT_PATH SOURCE_PATH FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD AUTO_RESTART AUTO_SYNC
    
    return 0
}

get_project_count() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "0"
        return
    fi
    wc -l < "$CONFIG_FILE" 2>/dev/null || echo "0"
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
# Sync functions
# ---------------------------
copy_storage_to_termux() {
    local src="$1" dest="$2" proj_num="$3"
    [ -z "$src" ] && { msg err "Sumber kosong"; return 1; }
    [ -z "$dest" ] && { msg err "Tujuan kosong"; return 1; }
    if [ ! -d "$src" ]; then msg err "Sumber tidak ditemukan: $src"; return 1; fi
    
    mkdir -p "$dest" "$dest/.dapps" 2>/dev/null || true

    local tmp_log="$LOG_DIR/rsync_tmp_${proj_num}.out"
    local final_log="$LOG_DIR/${proj_num}_sync.log"
    : > "$tmp_log"

    msg info "Syncing: $(path_type "$src") → $dest"
    
    if command -v rsync &>/dev/null; then
        msg info "Menggunakan rsync..."
        
        if rsync -avh --delete --checksum --progress \
            --out-format='%n|%l|%t' \
            "$src"/ "$dest"/ > "$tmp_log" 2>&1; then
            
            local total_bytes=0 files=0
            while IFS='|' read -r file size timestamp; do
                [ -z "$file" ] && continue
                files=$((files+1))
                size=${size:-0}
                total_bytes=$((total_bytes + size))
            done < "$tmp_log" || true
            
            cat > "$dest/.dapps/sync_summary.json" <<EOF
{
  "files": $files,
  "bytes": $total_bytes,
  "human_size": "$(numfmt --to=iec-i --suffix=B $total_bytes 2>/dev/null || echo "${total_bytes}B")",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
            
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
            msg err "rsync gagal"
            return 1
        fi
    else
        msg warn "rsync tidak tersedia. Menggunakan tar..."
        
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
        
        echo "TAR: files=$cnt bytes=$bytes" > "$final_log"
        msg ok "Copy done: $cnt files"
    fi

    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/.dapps/.last_synced" 2>/dev/null || true
    return 0
}

sync_project_by_num() {
    local num="$1"
    load_project "$num" || { msg err "Project not found"; return 1; }
    
    if [ -z "$SOURCE_PATH" ] || [ ! -d "$SOURCE_PATH" ]; then
        msg warn "source_path tidak diset untuk project #$num"
        read -rp "Masukkan storage source path: " sp
        [ -z "$sp" ] && { msg err "Cancelled"; return 1; }
        SOURCE_PATH="$sp"
        save_project "$num" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" \
                     "$FE_DIR" "$BE_DIR" "$FE_PORT" "$BE_PORT" "$FE_CMD" "$BE_CMD" \
                     "$AUTO_RESTART" "$AUTO_SYNC"
    fi
    
    copy_storage_to_termux "$SOURCE_PATH" "$PROJECT_PATH" "$num" || {
        msg err "Sync gagal"
        return 1
    }
    
    msg ok "Sync selesai untuk $PROJECT_NAME"
    return 0
}

auto_sync_project() {
    local num="$1"
    load_project "$num" || return 1
    [ "$AUTO_SYNC" != "1" ] && return 0
    
    if [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ]; then
        msg info "Auto-sync → $PROJECT_NAME"
        sync_project_by_num "$num" || msg warn "Auto-sync gagal"
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
    echo -e "${BOLD}No. | Status | Name                  | Source      | FE Dir    | BE Dir${X}"
    echo "-------------------------------------------------------------------------------------"
    
    local line_num=0
    while IFS='|' read -r name local_path source_path fe_dir be_dir _; do
        line_num=$((line_num + 1))
        [ -z "$name" ] && continue
        
        local status="${G}✓${X}"
        [ ! -d "$local_path" ] && status="${R}✗${X}"
        
        local running=""
        local fe_pid_file="$LOG_DIR/${line_num}_frontend.pid"
        local be_pid_file="$LOG_DIR/${line_num}_backend.pid"
        
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
            "$line_num" "$status" "${name:0:21}" "$src_type" "${fe_dir:0:9}" "${be_dir:0:9}" "$running"
    done < "$CONFIG_FILE"
    
    echo ""
    
    if [ $line_num -eq 0 ]; then
        msg warn "Belum ada project!"
        return 1
    fi
    
    echo -e "${C}💡 Tips:${X} Ketik angka di kolom ${BOLD}No.${X} untuk pilih project"
    
    return 0
}

# ---------------------------
# PostgreSQL
# ---------------------------
init_postgres_if_needed() {
    if ! command -v initdb &>/dev/null; then
        msg err "initdb tidak tersedia. Install: pkg install postgresql"
        return 1
    fi
    
    if [ ! -d "$PG_DATA" ] || [ -z "$(ls -A "$PG_DATA" 2>/dev/null || true)" ]; then
        msg info "Inisialisasi PostgreSQL"
        initdb "$PG_DATA" || { msg err "initdb gagal"; return 1; }
        msg ok "Postgres data siap"
    fi
    return 0
}

start_postgres() {
    init_postgres_if_needed || return 1
    
    if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
        msg info "Postgres sudah berjalan"
        return 0
    fi
    
    msg info "Starting PostgreSQL..."
    nohup pg_ctl -D "$PG_DATA" -l "$PG_LOG" start > /dev/null 2>&1 || {
        msg err "Gagal start Postgres"
        return 1
    }
    
    sleep 2
    return 0
}

stop_postgres() {
    if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
        msg info "Stopping PostgreSQL..."
        pg_ctl -D "$PG_DATA" stop -m fast >/dev/null 2>&1 || true
    fi
    return 0
}

# ---------------------------
# Framework detection
# ---------------------------
detect_framework_and_cmd() {
    local pdir="$1"
    [ ! -f "$pdir/package.json" ] && { echo ""; return; }
    
    local pkg_json="$pdir/package.json"
    
    if grep -q '"vite"' "$pkg_json" 2>/dev/null; then
        if grep -q '"dev":' "$pkg_json"; then
            echo "npm run dev -- --host 0.0.0.0"
            return
        fi
    fi
    
    if grep -q '"next"' "$pkg_json" 2>/dev/null; then
        if grep -q '"dev":' "$pkg_json"; then
            echo "npm run dev -- -H 0.0.0.0"
            return
        fi
    fi
    
    if grep -q '"react-scripts"' "$pkg_json" 2>/dev/null; then
        echo "HOST=0.0.0.0 npm start"
        return
    fi
    
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
    
    if grep -q '"@nestjs/core"' "$pkg_json" 2>/dev/null; then
        if grep -q '"start:dev":' "$pkg_json"; then
            echo "npm run start:dev"
        else
            echo "npm start"
        fi
        return
    fi
    
    if grep -q '"dev":' "$pkg_json"; then
        echo "npm run dev"
        return
    fi
    
    if grep -q '"start":' "$pkg_json"; then
        echo "npm start"
        return
    fi
    
    echo "npx serve . -l tcp://0.0.0.0:3000"
}

adjust_cmd_for_bind() {
    local cmd="$1"
    local port="$2"
    
    if echo "$cmd" | grep -q "serve"; then
        if ! echo "$cmd" | grep -q "0.0.0.0"; then
            echo "$cmd -l tcp://0.0.0.0:$port"
            return
        fi
    fi
    
    if echo "$cmd" | grep -q "vite"; then
        if ! echo "$cmd" | grep -q -- "--host"; then
            echo "$cmd --host 0.0.0.0 --port $port"
            return
        fi
    fi
    
    if echo "$cmd" | grep -q "next"; then
        if ! echo "$cmd" | grep -q -- "-H"; then
            echo "$cmd -H 0.0.0.0 -p $port"
            return
        fi
    fi
    
    if echo "$cmd" | grep -q "http-server"; then
        if ! echo "$cmd" | grep -q "0.0.0.0"; then
            echo "$cmd -a 0.0.0.0 -p $port"
            return
        fi
    fi
    
    echo "$cmd"
}

get_available_port() {
    local port="$1"
    local max_tries=100
    
    for i in $(seq 0 $max_tries); do
        local test_port=$((port + i))
        
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
            echo "$test_port"
            return 0
        fi
    done
    
    return 1
}

# ---------------------------
# Start/Stop services
# ---------------------------
start_service() {
    local num="$1"
    local dir="$2"
    local port="$3"
    local cmd="$4"
    local label="$5"
    
    if [ -z "$num" ]; then
        msg err "INTERNAL ERROR: Project number kosong!"
        return 1
    fi
    
    local pid_file="$LOG_DIR/${num}_${label}.pid"
    local log_file="$LOG_DIR/${num}_${label}.log"
    local port_file="$LOG_DIR/${num}_${label}.port"
    
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
    
    if [ "$label" = "backend" ]; then
        if command -v psql &>/dev/null; then
            start_postgres || true
        fi
    fi
    
    local final_port
    final_port=$(get_available_port "$port") || {
        msg err "No port available"
        return 1
    }
    
    [ "$final_port" != "$port" ] && msg warn "Port $port in use, using $final_port"
    
    if [ -f "$full_path/package.json" ]; then
        local pkgsum_file="$LOG_DIR/${num}_${label}_pkgsum"
        local cur_sum; cur_sum=$(md5_file "$full_path/package.json" || true)
        local prev_sum=""; [ -f "$pkgsum_file" ] && prev_sum=$(cat "$pkgsum_file" 2>/dev/null || true)
        
        if [ -n "$cur_sum" ] && [ "$cur_sum" != "$prev_sum" ]; then
            msg info "package.json changed → installing"
            (cd "$full_path" && npm install --silent) && msg ok "deps installed" || msg warn "install failed"
            echo "$cur_sum" > "$pkgsum_file"
        fi
    fi
    
    if [ -z "$cmd" ] || [ "$cmd" = "auto" ]; then
        cmd=$(detect_framework_and_cmd "$full_path")
        [ -z "$cmd" ] && cmd="npx serve . -l tcp://0.0.0.0:$final_port"
        msg info "Auto-detected: $cmd"
    fi
    
    local adj_cmd
    adj_cmd=$(adjust_cmd_for_bind "$cmd" "$final_port")
    
    msg info "Starting $label: $adj_cmd"
    
    (
        cd "$full_path" || exit 1
        
        [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a
        
        export HOST="0.0.0.0"
        export PORT="$final_port"
        export HOSTNAME="0.0.0.0"
        
        nohup bash -lc "HOST=0.0.0.0 PORT=$final_port HOSTNAME=0.0.0.0 $adj_cmd" > "$log_file" 2>&1 &
        echo $! > "$pid_file"
        echo "$final_port" > "$port_file"
    )
    
    sleep 2
    
    local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        local ip; ip=$(get_device_ip)
        msg ok "$label started!"
        echo -e "  ${G}→${X} PID: $pid"
        echo -e "  ${G}→${X} Port: $final_port"
        echo -e "  ${G}→${X} URL: http://$ip:$final_port"
        return 0
    else
        msg err "$label failed. Check: $log_file"
        rm -f "$pid_file" "$port_file" || true
        return 1
    fi
}

stop_service() {
    local num="$1"
    local label="$2"
    
    local pid_file="$LOG_DIR/${num}_${label}.pid"
    local port_file="$LOG_DIR/${num}_${label}.port"
    
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
# Install deps
# ---------------------------
install_deps() {
    local num="$1"
    load_project "$num" || { msg err "Project not found"; return 1; }
    
    msg info "Installing deps for $PROJECT_NAME..."
    
    for spec in "Frontend:$FE_DIR" "Backend:$BE_DIR"; do
        local label=${spec%%:*}
        local dir=${spec#*:}
        local full="$PROJECT_PATH/$dir"
        
        [ -z "$dir" ] || [ "$dir" = "(none)" ] && continue
        [ ! -d "$full" ] && { msg warn "$label not found"; continue; }
        [ ! -f "$full/package.json" ] && { msg warn "$label no package.json"; continue; }
        
        msg info "Installing $label..."
        (cd "$full" && npm install) && msg ok "$label installed" || msg err "$label install failed"
    done
}

# ---------------------------
# Run/Stop project
# ---------------------------
run_project_by_num() {
    local num="$1"
    
    if [ -z "$num" ]; then
        msg err "Nomor project kosong!"
        wait_key
        return 1
    fi
    
    load_project "$num" || {
        msg err "Project #$num not found"
        wait_key
        return 1
    }
    
    header
    echo -e "${BOLD}Starting: $PROJECT_NAME (#$num)${X}\n"
    
    if [ -z "$FE_DIR" ] || [ "$FE_DIR" = "(none)" ]; then
        msg err "Frontend directory belum dikonfigurasi!"
        wait_key
        return 1
    fi
    
    if [ ! -d "$PROJECT_PATH/$FE_DIR" ]; then
        msg err "Frontend folder not found: $PROJECT_PATH/$FE_DIR"
        wait_key
        return 1
    fi
    
    local has_backend=false
    if [ -n "$BE_DIR" ] && [ "$BE_DIR" != "(none)" ]; then
        if [ -d "$PROJECT_PATH/$BE_DIR" ]; then
            has_backend=true
        else
            msg warn "Backend folder not found, skipping"
        fi
    fi
    
    [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$num" || true
    
    local fe_path="$PROJECT_PATH/$FE_DIR"
    if [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then
        if confirm "Frontend deps missing. Install now?"; then
            install_deps "$num"
        fi
    fi
    
    if [ "$has_backend" = true ]; then
        local be_path="$PROJECT_PATH/$BE_DIR"
        if [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then
            if confirm "Backend deps missing. Install now?"; then
                install_deps "$num"
            fi
        fi
    fi
    
    echo ""
    msg info "Starting services..."
    echo ""
    
    start_service "$num" "$FE_DIR" "${FE_PORT:-3000}" "${FE_CMD:-auto}" "frontend" || {
        msg err "Frontend gagal start"
    }
    
    if [ "$has_backend" = true ]; then
        echo ""
        start_service "$num" "$BE_DIR" "${BE_PORT:-8000}" "${BE_CMD:-auto}" "backend" || {
            msg err "Backend gagal start"
        }
    fi
    
    echo ""
    msg ok "Project started!"
    wait_key
}

stop_project_by_num() {
    local num="$1"
    load_project "$num" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    msg info "Stopping $PROJECT_NAME..."
    stop_service "$num" "frontend"
    stop_service "$num" "backend"
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
    
    local local_path="$PROJECTS_DIR/$name"
    mkdir -p "$local_path"
    
    local source_path=""
    
    if confirm "Import dari storage (sdcard)?"; then
        read -rp "Path storage: " src
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
        
        local temp_num=$(get_project_count)
        temp_num=$((temp_num + 1))
        
        copy_storage_to_termux "$src" "$local_path" "$temp_num" || {
            msg err "Gagal copy dari storage"
            wait_key
            return
        }
        
        source_path="$src"
    else
        msg ok "Folder kosong dibuat di $local_path"
    fi
    
    echo ""
    echo -e "${BOLD}Konfigurasi Folder${X}"
    echo ""
    
    read -rp "Frontend directory (contoh: frontend, client, web): " fe_dir
    [ -z "$fe_dir" ] && {
        msg warn "Frontend dir kosong, set ke 'frontend'"
        fe_dir="frontend"
    }
    
    read -rp "Backend directory (kosongkan jika tidak ada): " be_dir
    [ -z "$be_dir" ] && be_dir="(none)"
    
    read -rp "Frontend port (default: 3000): " fe_port
    fe_port="${fe_port:-3000}"
    
    read -rp "Backend port (default: 8000): " be_port
    be_port="${be_port:-8000}"
    
    local fe_cmd="auto"
    local be_cmd="auto"
    
    if confirm "Custom start commands?"; then
        read -rp "Frontend command: " fe_cmd
        read -rp "Backend command: " be_cmd
        [ -z "$fe_cmd" ] && fe_cmd="auto"
        [ -z "$be_cmd" ] && be_cmd="auto"
    fi
    
    local new_num=$(get_project_count)
    new_num=$((new_num + 1))
    
    save_project "$new_num" "$name" "$local_path" "$source_path" \
                 "$fe_dir" "$be_dir" "$fe_port" "$be_port" \
                 "$fe_cmd" "$be_cmd" "0" "0"
    
    msg ok "Project added as #$new_num"
    echo ""
    echo "Frontend: $fe_dir"
    echo "Backend: $be_dir"
    wait_key
}

# ---------------------------
# Edit project
# ---------------------------
edit_project_config() {
    header
    list_projects_table || {
        msg warn "No projects"
        wait_key
        return
    }
    
    echo ""
    read -rp "Enter project number to edit: " num
    [ -z "$num" ] && {
        msg err "Number required"
        wait_key
        return
    }
    
    load_project "$num" || {
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
    
    [ -n "$new_source" ] && SOURCE_PATH="$new_source"
    [ -n "$new_fe" ] && FE_DIR="$new_fe"
    [ -n "$new_be" ] && BE_DIR="$new_be"
    [ -n "$new_fe_port" ] && FE_PORT="$new_fe_port"
    [ -n "$new_be_port" ] && BE_PORT="$new_be_port"
    [ -n "$new_fe_cmd" ] && FE_CMD="$new_fe_cmd"
    [ -n "$new_be_cmd" ] && BE_CMD="$new_be_cmd"
    [ -n "$new_ar" ] && AUTO_RESTART="$new_ar"
    [ -n "$new_as" ] && AUTO_SYNC="$new_as"
    
    save_project "$num" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" \
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
    read -rp "Enter project number to delete: " num
    [ -z "$num" ] && {
        msg err "Number required"
        wait_key
        return
    }
    
    load_project "$num" || {
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
    
    # Remove line from config
    sed -i "${num}d" "$CONFIG_FILE"
    
    # Clean up log files for this project number
    rm -f "$LOG_DIR/${num}_"*.{pid,log,port,out} 2>/dev/null || true
    
    msg ok "Project removed"
    msg info "Project numbers akan ter-reindex otomatis"
    wait_key
}

# ---------------------------
# Sync menu
# ---------------------------
sync_project() {
    header
    echo -e "${BOLD}Sync Project${X}\n"
    echo "1) Sync by project number"
    echo "2) Sync ALL projects"
    echo "0) Kembali"
    read -rp "Select: " ch
    
    case "$ch" in
        1)
            list_projects_table || { msg warn "No projects"; wait_key; return; }
            echo ""
            read -rp "Enter project number: " num
            [ -z "$num" ] && { msg err "Number required"; wait_key; return; }
            sync_project_by_num "$num"
            wait_key
            ;;
        2)
            local line_num=0
            while IFS='|' read -r name local_path source_path _; do
                line_num=$((line_num + 1))
                [ -z "$name" ] && continue
                if [ -n "$source_path" ] && [ -d "$source_path" ]; then
                    msg info "Syncing #$line_num: $name"
                    sync_project_by_num "$line_num" || msg warn "Failed"
                else
                    msg warn "Skip #$line_num - no source"
                fi
            done < "$CONFIG_FILE"
            wait_key
            ;;
        0) return ;;
        *) msg err "Invalid"; wait_key ;;
    esac
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
    read -rp "Enter project number: " num
    
    if [ -z "$num" ]; then
        msg err "Number required"
        wait_key
        return
    fi
    
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        msg err "Must be number"
        wait_key
        return
    fi
    
    load_project "$num" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    echo ""
    echo -e "${BOLD}=== Logs: $PROJECT_NAME (#$num) ===${X}"
    echo ""
    
    local fe_log="$LOG_DIR/${num}_frontend.log"
    local be_log="$LOG_DIR/${num}_backend.log"
    local sync_log="$LOG_DIR/${num}_sync.log"
    
    echo -e "${C}--- Frontend Log ---${X}"
    if [ -f "$fe_log" ]; then
        tail -n 50 "$fe_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${C}--- Backend Log ---${X}"
    if [ -f "$be_log" ]; then
        tail -n 50 "$be_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${C}--- Sync Log ---${X}"
    if [ -f "$sync_log" ]; then
        tail -n 30 "$sync_log"
    else
        echo "(no log yet)"
    fi
    
    wait_key
}

# ---------------------------
# Export config
# ---------------------------
export_config_json() {
    local out="$LOG_DIR/dapps_config_$(date +%F_%H%M%S).json"
    
    echo "[" > "$out"
    local first=1
    local line_num=0
    
    while IFS='|' read -r name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do
        line_num=$((line_num + 1))
        [ -z "$name" ] && continue
        
        [ $first -eq 1 ] || echo "," >> "$out"
        first=0
        
        cat >> "$out" <<EOF
{
  "number": $line_num,
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
    if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
        msg ok "Postgres running"
    else
        msg warn "Postgres not running"
    fi
    
    echo ""
    msg info "Config file check..."
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        local count=$(wc -l < "$CONFIG_FILE")
        msg ok "Config OK: $count projects"
        echo ""
        echo "Sample:"
        head -n3 "$CONFIG_FILE"
    else
        msg warn "Config empty"
    fi
    
    echo ""
    msg info "Running services:"
    local running=0
    for pidfile in "$LOG_DIR"/*_frontend.pid "$LOG_DIR"/*_backend.pid; do
        [ -f "$pidfile" ] || continue
        local pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            running=$((running + 1))
            echo "  - PID $pid (${pidfile##*/})"
        fi
    done
    
    if [ $running -eq 0 ]; then
        msg info "No services running"
    else
        msg ok "$running services running"
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
    local line_num=0
    
    while IFS='|' read -r name _; do
        line_num=$((line_num + 1))
        [ -z "$name" ] && continue
        
        local fe_pid_file="$LOG_DIR/${line_num}_frontend.pid"
        local be_pid_file="$LOG_DIR/${line_num}_backend.pid"
        
        if [ -f "$fe_pid_file" ] || [ -f "$be_pid_file" ]; then
            local fe_pid=$(cat "$fe_pid_file" 2>/dev/null || true)
            local be_pid=$(cat "$be_pid_file" 2>/dev/null || true)
            
            if { [ -n "$fe_pid" ] && kill -0 "$fe_pid" 2>/dev/null; } || \
               { [ -n "$be_pid" ] && kill -0 "$be_pid" 2>/dev/null; }; then
                running_count=$((running_count+1))
            fi
        fi
    done < "$CONFIG_FILE" 2>/dev/null
    
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
    echo " 0. 🚪 Exit"
    echo -e "\n${BOLD}═══════════════════════════════════${X}"
    read -rp "Select (0-11): " choice
    
    case "$choice" in
        1)
            header
            list_projects_table || msg warn "No projects"
            wait_key
            ;;
        2) add_project ;;
        3)
            clear
            echo -e "${C}${BOLD}╔════════════════════════════════════════════════════════╗${X}"
            echo -e "${C}${BOLD}║              START PROJECT                             ║${X}"
            echo -e "${C}${BOLD}╚════════════════════════════════════════════════════════╝${X}\n"
            
            if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
                msg warn "Belum ada project!"
                wait_key
                continue
            fi
            
            if ! list_projects_table; then
                msg err "No projects"
                wait_key
                continue
            fi
            
            echo ""
            read -rp "Masukkan nomor project (0 untuk batal): " num
            
            [ "$num" = "0" ] && continue
            
            if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
                msg err "Nomor harus angka!"
                wait_key
                continue
            fi
            
            run_project_by_num "$num"
            ;;
        4)
            header
            
            if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
                msg warn "No projects"
                wait_key
                return
            fi
            
            list_projects_table || {
                msg warn "No projects"
                wait_key
                return
            }
            
            echo ""
            read -rp "Enter project number: " num
            
            if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
                msg err "Must be number"
                wait_key
                return
            fi
            
            stop_project_by_num "$num"
            ;;
        5)
            header
            
            if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
                msg warn "No projects"
                wait_key
                return
            fi
            
            list_projects_table || {
                msg warn "No projects"
                wait_key
                return
            }
            
            echo ""
            read -rp "Enter project number: " num
            
            if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
                msg err "Must be number"
                wait_key
                return
            fi
            
            install_deps "$num"
            wait_key
            ;;
        6) sync_project ;;
        7) view_logs ;;
        8) delete_project ;;
        9) export_config_json; wait_key ;;
        10) diagnose_and_fix ;;
        11) edit_project_config ;;
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
# Main
# ---------------------------
main() {
    if [ "${DEBUG_LAUNCHER:-0}" = "1" ]; then
        set -x
        msg info "Debug mode enabled"
    fi
    
    check_deps || msg warn "Install: pkg install nodejs git postgresql rsync"
    
    while true; do
        show_menu
    done
}

main "$@"
