#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Backend Server Launcher - Professional v4.0.4 (Fixed Live Server)
# 
# CHANGES v4.0.4:
# ✅ Fixed server not staying alive
# ✅ Better process management with proper nohup
# ✅ Fixed PORT environment variable handling
# ✅ Better command execution
# ============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROJECTS_DIR="$HOME/dapps-projects"
CONFIG_FILE="$HOME/.dapps.conf"
LOG_DIR="$HOME/.dapps-logs"
LAUNCHER_VERSION="4.0.4"

DB_VIEWER_DIR="${DB_VIEWER_DIR:-$HOME/paxiforge-db-viewer}"
DB_VIEWER_PORT="${DB_VIEWER_PORT:-8081}"

PG_DATA="${PG_DATA:-$PREFIX/var/lib/postgresql}"
PG_LOG="$HOME/pgsql.log"

# Default PostgreSQL config
DEFAULT_DB_USER="termux"
DEFAULT_DB_PASS=""
DEFAULT_DB_HOST="localhost"
DEFAULT_DB_PORT="5432"

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
    [[ "$ans" =~ ^[Yy] ]]
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
    
    if command -v ifconfig >/dev/null 2>/dev/null; then
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
# Config format:
# name|local_path|source_path|app_dir|app_port|app_cmd|auto_restart|auto_sync
# ---------------------------

save_project() {
    local num="$1" name="$2" local_path="$3" source_path="$4"
    local app_dir="$5" app_port="$6" app_cmd="$7" auto_restart="$8" auto_sync="$9"
    
    local tmp_file="$CONFIG_FILE.tmp.$$"
    : > "$tmp_file"
    
    local current_line=1
    local updated=false
    
    while IFS='|' read -r old_name old_path old_src old_app old_app_port old_app_cmd old_ar old_as || [ -n "$old_name" ]; do
        if [ "$current_line" -eq "$num" ]; then
            printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
                "$name" "$local_path" "$source_path" "$app_dir" "$app_port" "$app_cmd" "$auto_restart" "$auto_sync" >> "$tmp_file"
            updated=true
        else
            printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
                "$old_name" "$old_path" "$old_src" "$old_app" "$old_app_port" "$old_app_cmd" "$old_ar" "$old_as" >> "$tmp_file"
        fi
        current_line=$((current_line + 1))
    done < "$CONFIG_FILE"
    
    if [ "$updated" = false ]; then
        printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
            "$name" "$local_path" "$source_path" "$app_dir" "$app_port" "$app_cmd" "$auto_restart" "$auto_sync" >> "$tmp_file"
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
    
    local line
    line=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null || true)
    
    if [ -z "$line" ]; then
        msg err "Project #$num tidak ditemukan"
        return 1
    fi
    
    IFS='|' read -r PROJECT_NAME PROJECT_PATH SOURCE_PATH \
                    APP_DIR APP_PORT APP_CMD \
                    AUTO_RESTART AUTO_SYNC <<< "$line"
    
    if [ -z "$PROJECT_NAME" ]; then
        msg err "Config corrupted pada line $num"
        return 1
    fi
    
    export PROJECT_NUM="$num"
    export PROJECT_NAME PROJECT_PATH SOURCE_PATH APP_DIR APP_PORT APP_CMD AUTO_RESTART AUTO_SYNC
    
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
# SYNC FUNCTIONS
# ---------------------------
copy_storage_to_termux() {
    local src="$1" dest="$2" proj_num="$3"
    [ -z "$src" ] && { msg err "Sumber kosong"; return 1; }
    [ -z "$dest" ] && { msg err "Tujuan kosong"; return 1; }
    if [ ! -d "$src" ]; then msg err "Sumber tidak ditemukan: $src"; return 1; fi
    
    mkdir -p "$dest" "$dest/.dapps" 2>/dev/null || true

    local tmp_log="${LOG_DIR}/rsync_tmp_${proj_num}.out"
    local final_log="${LOG_DIR}/${proj_num}_sync.log"
    : > "$tmp_log"

    msg info "Syncing: $(path_type "$src") → $dest"
    
    if command -v rsync &>/dev/null; then
        msg info "Menggunakan rsync (detailed logging)..."
        
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
            msg err "rsync gagal. Lihat $tmp_log"
            return 1
        fi
    else
        msg warn "rsync tidak tersedia. Menggunakan tar fallback..."
        
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

sync_project_by_num() {
    local num="$1"
    load_project "$num" || { msg err "Project not found"; return 1; }
    
    if [ -z "$SOURCE_PATH" ] || [ ! -d "$SOURCE_PATH" ]; then
        msg warn "source_path tidak diset untuk project $PROJECT_NAME"
        read -rp "Masukkan storage source path (kosong untuk batalkan): " sp
        [ -z "$sp" ] && { msg err "Cancelled"; return 1; }
        SOURCE_PATH="$sp"
        save_project "$num" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" \
                     "$APP_DIR" "$APP_PORT" "$APP_CMD" \
                     "$AUTO_RESTART" "$AUTO_SYNC"
    fi
    
    copy_storage_to_termux "$SOURCE_PATH" "$PROJECT_PATH" "$num" || {
        msg err "Sync gagal"
        return 1
    }
    
    msg ok "Sync selesai untuk $PROJECT_NAME"
    return 0
}

sync_project() {
    header
    echo -e "${BOLD}Sync Project${X}\n"
    echo "1) Sync by project number"
    echo "2) Sync ALL projects yang punya source_path"
    echo "0) Kembali"
    read -rp "Select: " ch
    
    case "$ch" in
        1)
            list_projects_table || { msg warn "No projects"; wait_key; return; }
            echo ""
            read -rp "Enter project number to sync: " num
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
                    msg info "Syncing $name (#$line_num)"
                    sync_project_by_num "$line_num" || msg warn "Failed: $name"
                else
                    msg warn "Skip $name (#$line_num) - no source_path"
                fi
            done < "$CONFIG_FILE"
            wait_key
            ;;
        0) return ;;
        *) msg err "Invalid"; wait_key ;;
    esac
}

auto_sync_project() {
    local num="$1"
    load_project "$num" || return 1
    [ "$AUTO_SYNC" != "1" ] && return 0
    
    if [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ]; then
        msg info "Auto-sync aktif → Syncing $PROJECT_NAME"
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
    echo -e "${BOLD}No. | Status | Name                  | Source      | App Dir${X}"
    echo "-------------------------------------------------------------------------------------"
    
    local line_num=0
    while IFS='|' read -r name local_path source_path app_dir _; do
        line_num=$((line_num + 1))
        [ -z "$name" ] && continue
        
        local status="${G}✓${X}"
        [ ! -d "$local_path" ] && status="${R}✗${X}"
        
        local running=""
        local pid_file="${LOG_DIR}/${line_num}_server.pid"
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null || true)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                running=" ${G}[RUN]${X}"
            fi
        fi
        
        local src_type; src_type=$(path_type "$source_path")
        app_dir="${app_dir:-(none)}"
        
        printf "%-3s | %-6s | %-21s | %-11s | %-9s%s\n" \
            "$line_num" "$status" "${name:0:21}" "$src_type" "${app_dir:0:9}" "$running"
    done < "$CONFIG_FILE"
    
    echo ""
    
    if [ "$line_num" -eq 0 ]; then
        msg warn "Belum ada project! Tambahkan dengan menu 2"
        return 1
    fi
    
    echo -e "${C}💡 Tips:${X}"
    echo "  - Ketik angka di kolom ${BOLD}No.${X} untuk pilih project"
    echo "  - Status ${G}[RUN]${X} = project sedang berjalan"
    
    return 0
}

prompt_open_path_after_list() {
    echo ""
    read -rp "Ketik (<nomor> info) atau tekan ENTER: " cmd
    [ -z "$cmd" ] && return 0
    
    if [[ "$cmd" == *" info" ]]; then
        local num=$(echo "$cmd" | awk '{print $1}')
        if [[ "$num" =~ ^[0-9]+$ ]]; then
            load_project "$num" || { msg err "Project not found"; return 1; }
        
            echo -e "\n${BOLD}=== Project Info: $PROJECT_NAME (#${num}) ===${X}"
            echo "Local Path  : $PROJECT_PATH"
            echo "Source Path : ${SOURCE_PATH:-(none)}"
            echo "App Dir     : ${APP_DIR:-(none)}"
            echo "App Port    : ${APP_PORT:-8000}"
            echo "App Command : ${APP_CMD:-auto}"
            echo "Auto Restart: ${AUTO_RESTART:-0}"
            echo "Auto Sync   : ${AUTO_SYNC:-0}"
            wait_key
        else
            msg err "Nomor tidak valid"
            wait_key
        fi
    else
        msg err "Format: <nomor> info"
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
# Framework detection for backend
# ---------------------------
detect_framework_and_cmd() {
    local pdir="$1"
    
    # Check if package.json exists
    if [ ! -f "$pdir/package.json" ]; then
        # No package.json, check for other frameworks
        if [ -f "$pdir/manage.py" ]; then
            echo "python manage.py runserver 0.0.0.0:\$PORT"
            return
        fi
        
        if [ -f "$pdir/app.py" ] || [ -f "$pdir/main.py" ]; then
            echo "python main.py"
            return
        fi
        
        # Default fallback
        echo ""
        return
    fi
    
    local pkg_json="$pdir/package.json"
    
    # Check for specific frameworks
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
    
    # Check for common scripts
    if grep -q '"dev":' "$pkg_json"; then
        echo "npm run dev"
        return
    fi
    
    if grep -q '"start":' "$pkg_json"; then
        echo "npm start"
        return
    fi
    
    # Default for Node.js projects
    echo "npm start"
}

adjust_cmd_for_bind() {
    local cmd="$1"
    local port="$2"
    
    # If command is just a port number, it means detect failed
    if [[ "$cmd" =~ ^[0-9]+$ ]]; then
        echo "npm start"
        return
    fi
    
    # Don't add PORT prefix - it will be exported as environment variable
    # Just return the command as-is
    echo "$cmd"
}

get_available_port() {
    local port="${1:-8000}"
    local max_tries=100
    
    # Validate port is a number
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        port=8000
    fi
    
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
            # No network tools, assume port is available
            echo "$test_port"
            return 0
        fi
    done
    
    # If all ports busy, return the original port anyway
    echo "$port"
    return 0
}

# ---------------------------
# Start/Stop services
# ---------------------------
start_service() {
    local num="$1"
    local dir="${2:-.}"
    local port="${3:-8000}"
    local cmd="${4:-auto}"
    
    if [ -z "$num" ]; then
        msg err "INTERNAL ERROR: Project number kosong!"
        return 1
    fi
    
    # Validate and sanitize port
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        msg warn "Invalid port '$port', using default 8000"
        port=8000
    fi
    
    local pid_file="${LOG_DIR}/${num}_server.pid"
    local log_file="${LOG_DIR}/${num}_server.log"
    local port_file="${LOG_DIR}/${num}_server.port"
    local start_script="${LOG_DIR}/${num}_start.sh"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg warn "Server already running (PID: $pid)"
            return 0
        fi
        rm -f "$pid_file" || true
    fi
    
    # Build full path - handle root directory case
    local full_path
    if [ -z "$dir" ] || [ "$dir" = "." ]; then
        full_path="$PROJECT_PATH"
    else
        full_path="$PROJECT_PATH/$dir"
    fi
    
    [ ! -d "$full_path" ] && {
        msg err "App folder not found: $full_path"
        return 1
    }
    
    local envfile="$full_path/.env"
    if [ ! -f "$envfile" ]; then
        msg warn ".env tidak ditemukan. Membuat sekarang..."
        create_env "$envfile"
    else
        if confirm ".env ada. Edit sekarang?"; then
            edit_env "$envfile"
        fi
    fi
    
    if command -v psql &>/dev/null; then
        msg info "Setting up PostgreSQL..."
        start_postgres || msg warn "Postgres not available"
        create_db_from_env "$num" "$full_path" || true
    fi
    
    local final_port
    final_port=$(get_available_port "$port")
    
    [ "$final_port" != "$port" ] && msg warn "Port $port in use, using $final_port"
    
    if [ -f "$full_path/package.json" ]; then
        local pkgsum_file="${LOG_DIR}/${num}_server_pkgsum"
        local cur_sum; cur_sum=$(md5_file "$full_path/package.json" || true)
        local prev_sum=""; [ -f "$pkgsum_file" ] && prev_sum=$(cat "$pkgsum_file" 2>/dev/null || true)
        
        if [ -n "$cur_sum" ] && [ "$cur_sum" != "$prev_sum" ]; then
            msg info "package.json changed → installing"
            (cd "$full_path" && npm install --silent) && msg ok "Deps installed" || msg warn "Install failed"
            echo "$cur_sum" > "$pkgsum_file"
        fi
    fi
    
    # Auto-detect or use provided command
    if [ -z "$cmd" ] || [ "$cmd" = "auto" ]; then
        cmd=$(detect_framework_and_cmd "$full_path")
        if [ -z "$cmd" ]; then
            cmd="npm start"
            msg warn "Could not detect framework, using: $cmd"
        else
            msg info "Auto-detected command: $cmd"
        fi
    else
        # Check if cmd is a port number (bad config)
        if [[ "$cmd" =~ ^[0-9]+$ ]]; then
            msg warn "APP_CMD is a port number, auto-detecting instead..."
            cmd=$(detect_framework_and_cmd "$full_path")
            [ -z "$cmd" ] && cmd="npm start"
        fi
        msg info "Using command: $cmd"
    fi
    
    msg info "Starting backend server..."
    msg info "  Directory: $full_path"
    msg info "  Command: $cmd"
    msg info "  Port: $final_port"
    
    # Create startup script with proper quoting
    cat > "$start_script" <<'EOFSCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
cd "PROJECT_PATH_PLACEHOLDER" || exit 1

# Source .env if exists
if [ -f ".env" ]; then
    set -a
    source .env 2>/dev/null || true
    set +a
fi

# Export environment variables
export HOST="0.0.0.0"
export PORT="PORT_PLACEHOLDER"
export HOSTNAME="0.0.0.0"
export NODE_ENV="${NODE_ENV:-development}"

# Execute the command with stdin redirected to /dev/null
# This prevents EBADF errors with nodemon and other interactive tools
exec < /dev/null
exec CMD_PLACEHOLDER
EOFSCRIPT
    
    # Replace placeholders with proper escaping
    sed -i "s|PROJECT_PATH_PLACEHOLDER|$full_path|g" "$start_script"
    sed -i "s|PORT_PLACEHOLDER|$final_port|g" "$start_script"
    sed -i "s|CMD_PLACEHOLDER|$cmd|g" "$start_script"
    
    chmod +x "$start_script"
    
    # Start the service in background with proper I/O redirection
    msg info "Launching server..."
    nohup bash "$start_script" < /dev/null > "$log_file" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$pid_file"
    echo "$final_port" > "$port_file"
    
    # Wait a bit for server to start
    sleep 4
    
    # Check if process is still running
    if ! kill -0 "$new_pid" 2>/dev/null; then
        msg err "Server process died immediately!"
        echo ""
        msg info "Checking log file for errors..."
        if [ -f "$log_file" ]; then
            echo -e "${R}--- Last 50 lines of log ---${X}"
            tail -n 50 "$log_file"
            echo -e "${R}--- End Log ---${X}"
        fi
        echo ""
        msg info "Possible issues:"
        echo "  1. Missing dependencies - check package.json"
        echo "  2. Module not found - run: cd '$full_path' && npm install"
        echo "  3. Wrong start command in package.json"
        echo "  4. Port already in use"
        echo "  5. Database connection error"
        echo ""
        msg info "To fix:"
        echo "  • Use menu 5 to install dependencies"
        echo "  • Check log: tail -f $log_file"
        echo "  • Manually test: cd '$full_path' && $cmd"
        rm -f "$pid_file" "$port_file" || true
        return 1
    fi
    
    # Check log for errors even if process is running
    if [ -f "$log_file" ]; then
        local error_count=$(grep -i "error\|crash\|exception\|MODULE_NOT_FOUND" "$log_file" 2>/dev/null | wc -l || echo 0)
        if [ "$error_count" -gt 0 ]; then
            msg warn "Found $error_count errors in log. Server might not be working correctly."
            echo ""
            echo -e "${Y}--- Recent errors ---${X}"
            grep -i "error\|crash\|exception\|MODULE_NOT_FOUND" "$log_file" 2>/dev/null | tail -n 10 || true
            echo ""
            msg warn "Server process is running but might not be responding to requests"
            msg info "Check full log: tail -f $log_file"
            echo ""
        fi
    fi
    
    # Try to verify server is actually listening on the port
    sleep 2
    if command -v ss &>/dev/null; then
        if ! ss -tuln 2>/dev/null | grep -q ":$final_port "; then
            msg warn "Server process running but not listening on port $final_port"
            msg info "This usually means the app crashed or is still starting"
            echo ""
        fi
    fi
    
    # Verify server is responding (optional check)
    local check_count=0
    local max_checks=5
    while [ $check_count -lt $max_checks ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$final_port" >/dev/null 2>&1; then
            break
        fi
        sleep 1
        check_count=$((check_count + 1))
    done
    
    local ip; ip=$(get_device_ip)
    msg ok "Server started and running!"
    echo ""
    echo -e "${BOLD}Server Information:${X}"
    echo -e "  ${G}→${X} PID: $new_pid"
    echo -e "  ${G}→${X} Port: $final_port"
    echo -e "  ${G}→${X} Directory: $full_path"
    echo ""
    echo -e "${BOLD}Access URLs:${X}"
    echo -e "  ${G}→${X} Network: http://$ip:$final_port"
    echo -e "  ${G}→${X} Local: http://localhost:$final_port"
    echo ""
    echo -e "${BOLD}Logs:${X}"
    echo -e "  ${G}→${X} File: $log_file"
    echo -e "  ${G}→${X} Live: tail -f $log_file"
    echo ""
    msg info "Server akan terus berjalan hingga di-stop manual atau Termux ditutup"
    
    return 0
}

stop_service() {
    local num="$1"
    
    local pid_file="${LOG_DIR}/${num}_server.pid"
    local port_file="${LOG_DIR}/${num}_server.port"
    
    [ ! -f "$pid_file" ] && {
        msg info "Server not running"
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
    
    msg info "Stopping server (PID: $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
    
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$pid_file" "$port_file" || true
    msg ok "Server stopped"
}

# ---------------------------
# Install dependencies
# ---------------------------
install_deps() {
    local num="$1"
    load_project "$num" || { msg err "Project not found"; return 1; }
    
    msg info "Installing dependencies for $PROJECT_NAME..."
    
    # Build full path
    local full
    if [ -z "$APP_DIR" ] || [ "$APP_DIR" = "." ] || [ "$APP_DIR" = "(none)" ]; then
        full="$PROJECT_PATH"
    else
        full="$PROJECT_PATH/$APP_DIR"
    fi
    
    [ ! -d "$full" ] && {
        msg warn "App folder not found: $full"
        return 1
    }
    
    [ ! -f "$full/package.json" ] && {
        msg warn "No package.json found in $full"
        return 1
    }
    
    msg info "Installing in: $full"
    
    # Clean install for better reliability
    if confirm "Do a clean install (remove node_modules first)?"; then
        msg info "Removing old node_modules..."
        rm -rf "$full/node_modules" "$full/package-lock.json"
    fi
    
    msg info "Running npm install..."
    if (cd "$full" && npm install); then
        msg ok "Dependencies installed successfully"
        
        # Check for vulnerabilities
        if (cd "$full" && npm audit --json 2>/dev/null | grep -q '"severity"'); then
            msg warn "Vulnerabilities detected"
            if confirm "Run npm audit fix?"; then
                (cd "$full" && npm audit fix) && msg ok "Vulnerabilities fixed" || msg warn "Some vulnerabilities remain"
            fi
        fi
    else
        msg err "npm install failed"
        return 1
    fi
    
    return 0
}

# ---------------------------
# .env Create/Edit Helpers
# ---------------------------
create_env() {
    local envfile="$1"
    : > "$envfile"
    
    msg info "Creating .env file..."
    while true; do
        read -rp "Enter variable name (or empty to finish): " var_name
        [ -z "$var_name" ] && break
        read -rp "Enter value for $var_name: " var_value
        echo "$var_name=$var_value" >> "$envfile"
    done
    msg ok ".env created with user-defined variables."
}

edit_env() {
    local envfile="$1"
    
    msg info "Editing .env file..."
    while true; do
        read -rp "Enter variable name to add/update (or empty to finish): " var_name
        [ -z "$var_name" ] && break
        read -rp "Enter value for $var_name: " var_value
        
        sed -i "/^$var_name=/d" "$envfile" 2>/dev/null || true
        echo "$var_name=$var_value" >> "$envfile"
    done
    msg ok ".env updated."
}

# ---------------------------
# Database helpers
# ---------------------------
# 1) parse_db_config_from_env (lebih robust; meng-handle DATABASE_URL dengan/ tanpa user:pass)
parse_db_config_from_env() {
    local envfile="$1"
    DB_HOST="${DEFAULT_DB_HOST}"
    DB_PORT="${DEFAULT_DB_PORT}"
    DB_NAME=""
    DB_USER=""
    DB_PASSWORD="${DEFAULT_DB_PASS}"

    [ ! -f "$envfile" ] && return 1

    while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "$line" ]] && continue

        if [[ "$line" == DB_HOST=* ]]; then
            DB_HOST="${line#DB_HOST=}"
            DB_HOST="${DB_HOST%\"}"
            DB_HOST="${DB_HOST#\"}"
        fi
        if [[ "$line" == DB_PORT=* ]]; then
            DB_PORT="${line#DB_PORT=}"
            DB_PORT="${DB_PORT%\"}"
            DB_PORT="${DB_PORT#\"}"
        fi
        if [[ "$line" == DB_NAME=* ]]; then
            DB_NAME="${line#DB_NAME=}"
            DB_NAME="${DB_NAME%\"}"
            DB_NAME="${DB_NAME#\"}"
        fi
        if [[ "$line" == DB_USER=* ]]; then
            DB_USER="${line#DB_USER=}"
            DB_USER="${DB_USER%\"}"
            DB_USER="${DB_USER#\"}"
        fi
        if [[ "$line" == DB_PASSWORD=* ]]; then
            DB_PASSWORD="${line#DB_PASSWORD=}"
            DB_PASSWORD="${DB_PASSWORD%\"}"
            DB_PASSWORD="${DB_PASSWORD#\"}"
        fi

        if [[ "$line" == DATABASE_URL=* ]]; then
            local url="${line#DATABASE_URL=}"
            url="${url%\"}"
            url="${url#\"}"

            # only parse postgresql:// style
            if [[ "$url" == postgresql://* ]]; then
                url="${url#postgresql://}"

                # split userinfo (optional) and hostinfo
                local userinfo=""
                local hostpart="$url"
                if [[ "$url" == *@* ]]; then
                    userinfo="${url%%@*}"
                    hostpart="${url#*@}"
                fi

                # parse userinfo
                if [ -n "$userinfo" ]; then
                    if [[ "$userinfo" == *:* ]]; then
                        DB_USER="${userinfo%%:*}"
                        DB_PASSWORD="${userinfo#*:}"
                    else
                        DB_USER="${userinfo}"
                        DB_PASSWORD=""
                    fi
                fi

                # parse hostpart -> host:port/dbname
                # ensure hostpart contains a slash (db part)
                if [[ "$hostpart" == */* ]]; then
                    local hostport="${hostpart%%/*}"
                    local dbpart="${hostpart#*/}"
                    DB_NAME="${dbpart%%\?*}"        # ignore possible query params
                else
                    local hostport="$hostpart"
                    DB_NAME=""
                fi

                if [[ "$hostport" == *:* ]]; then
                    DB_HOST="${hostport%%:*}"
                    DB_PORT="${hostport#*:}"
                else
                    # host might be empty (e.g. postgresql:///mydb) -> treat as localhost / socket
                    if [ -z "$hostport" ]; then
                        DB_HOST="${DEFAULT_DB_HOST}"
                    else
                        DB_HOST="$hostport"
                    fi
                fi

                # fallback defaults
                DB_PORT="${DB_PORT:-$DEFAULT_DB_PORT}"
                DB_HOST="${DB_HOST:-$DEFAULT_DB_HOST}"
            fi
        fi
    done < "$envfile"

    echo "${DB_HOST}|${DB_PORT}|${DB_NAME}|${DB_USER}|${DB_PASSWORD}"
    return 0
}

# 2) create_role_if_needed (DIUBAH: tidak auto-create role secara default)
#    Jika kamu memang ingin auto-create role, set env AUTO_CREATE_DB_ROLE=1 di .dapps.conf atau .env
create_role_if_needed() {
    local user="$1"
    local pass="$2"

    # Safety: jangan auto-create role kecuali eksplisit diizinkan
    # Default: skip role creation (sesuai permintaan "tanpa role")
    if [ "${AUTO_CREATE_DB_ROLE:-0}" != "1" ]; then
        msg info "Skipping role creation for '$user' (AUTO_CREATE_DB_ROLE not enabled)"
        return 0
    fi

    [ -z "$user" ] && return 0

    # create only if not exist
    if psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='${user}'" 2>/dev/null | grep -q 1; then
        return 0
    fi

    if [ -z "$pass" ]; then
        psql -d postgres -c "CREATE ROLE \"$user\" WITH LOGIN;" >/dev/null 2>&1 || return 1
    else
        psql -d postgres -c "CREATE ROLE \"$user\" WITH LOGIN PASSWORD '$pass';" >/dev/null 2>&1 || return 1
    fi
}

# 3) create_db_if_needed (aman: jika owner tidak ada, buat tanpa owner)
create_db_if_needed() {
    local db="$1"
    local owner="$2"

    # already exists?
    if psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null | grep -q 1; then
        return 0
    fi

    # try to create with owner if owner exists, otherwise create without owner
    if [ -n "$owner" ]; then
        if psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='${owner}'" 2>/dev/null | grep -q 1; then
            psql -d postgres -c "CREATE DATABASE \"${db}\" OWNER \"${owner}\";" >/dev/null 2>&1 || return 1
        else
            msg warn "Owner role '$owner' does not exist — creating database without explicit owner"
            psql -d postgres -c "CREATE DATABASE \"${db}\";" >/dev/null 2>&1 || return 1
        fi
    else
        psql -d postgres -c "CREATE DATABASE \"${db}\";" >/dev/null 2>&1 || return 1
    fi

    return 0
}

# 4) create_db_from_env (ubah: skip role creation, buat DB tanpa owner bila perlu)
create_db_from_env() {
    local num="$1"
    local app_path="$2"
    # load_project "$num" || return 1   # caller sudah memanggil load_project

    local envfile="$app_path/.env"

    [ ! -f "$envfile" ] && {
        msg warn ".env tidak ditemukan"
        return 1
    }

    parsed=$(parse_db_config_from_env "$envfile") || {
        msg err "Gagal parse .env"
        return 1
    }

    IFS='|' read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD <<< "$parsed"

    if [ -z "$DB_NAME" ]; then
        msg warn "DB_NAME tidak ditemukan di .env"
        read -rp "Masukkan DB_NAME untuk database baru (contoh: myapp_db) [kosong = skip]: " DB_NAME
        if [ -z "$DB_NAME" ]; then
            msg warn "DB_NAME tidak diberikan. Skip auto-create."
            return 1
        fi

        # validate
        if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
            msg err "DB_NAME hanya boleh huruf, angka, underscore"
            return 1
        fi

        # persist minimal config
        echo "" >> "$envfile"
        echo "# Database Configuration (auto-added)" >> "$envfile"
        echo "DB_NAME=$DB_NAME" >> "$envfile"
        echo "DB_HOST=${DB_HOST:-$DEFAULT_DB_HOST}" >> "$envfile"
        echo "DB_PORT=${DB_PORT:-$DEFAULT_DB_PORT}" >> "$envfile"
        echo "DB_USER=${DB_USER:-}" >> "$envfile"
        echo "DATABASE_URL=postgresql://${DB_USER:+$DB_USER}${DB_USER:+:${DB_PASSWORD}}@${DB_HOST}:${DB_PORT}/${DB_NAME}" >> "$envfile" 2>/dev/null || true
        msg ok "Database config ditambahkan ke .env"
    fi

    # only handle local DB auto-create; remote hosts are skipped
    if [ "$DB_HOST" != "127.0.0.1" ] && [ "$DB_HOST" != "localhost" ]; then
        msg warn "DB_HOST bukan lokal ($DB_HOST). Skip auto-create."
        return 1
    fi

    # do NOT auto-create role unless explicitly allowed (see create_role_if_needed)
    create_role_if_needed "$DB_USER" "$DB_PASSWORD" || msg warn "create_role_if_needed failed (ignored)"

    # create database: if owner exists it will be used, otherwise database is created without owner
    create_db_if_needed "$DB_NAME" "$DB_USER" || {
        msg err "Gagal membuat DB $DB_NAME"
        return 1
    }

    msg ok "DB $DB_NAME siap (host=$DB_HOST port=$DB_PORT user='${DB_USER:-(none)}')"
    return 0
}
# ---------------------------
# Run/Stop project
# ---------------------------
run_project_by_num() {
    local num="$1"
    
    if [ -z "$num" ]; then
        msg err "Nomor project tidak boleh kosong!"
        wait_key
        return 1
    fi
    
    load_project "$num" || {
        msg err "Project not found"
        wait_key
        return 1
    }
    
    header
    echo -e "${BOLD}Starting: $PROJECT_NAME (#${num})${X}\n"
    
    if [ -z "$APP_DIR" ] || [ "$APP_DIR" = "(none)" ]; then
        msg err "App directory belum dikonfigurasi!"
        msg info "Gunakan 'Edit Project Config' (menu 11) untuk set APP_DIR"
        wait_key
        return 1
    fi
    
    # Build full path - handle empty APP_DIR (root of project)
    local app_full_path
    if [ -z "$APP_DIR" ] || [ "$APP_DIR" = "." ]; then
        app_full_path="$PROJECT_PATH"
    else
        app_full_path="$PROJECT_PATH/$APP_DIR"
    fi
    
    if [ ! -d "$app_full_path" ]; then
        msg err "App folder tidak ditemukan: $app_full_path"
        echo ""
        echo "Struktur project saat ini:"
        ls -la "$PROJECT_PATH" 2>/dev/null || echo "  (tidak bisa membaca directory)"
        echo ""
        msg info "Gunakan 'Edit Project Config' (menu 11) untuk update APP_DIR"
        msg info "Atau gunakan '.' jika backend ada di root project"
        wait_key
        return 1
    fi
    
    [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$num" || true
    
    if [ -f "$app_full_path/package.json" ] && [ ! -d "$app_full_path/node_modules" ]; then
        if confirm "Deps missing. Install now?"; then
            install_deps "$num"
        fi
    fi
    
    echo ""
    msg info "Starting server..."
    echo ""
    
    # Ensure APP_PORT and APP_CMD have proper values
    local use_port="${APP_PORT:-8000}"
    local use_cmd="${APP_CMD:-auto}"
    local use_dir="${APP_DIR:-.}"
    
    # Validate port is a number
    if ! [[ "$use_port" =~ ^[0-9]+$ ]]; then
        msg warn "Invalid APP_PORT '$use_port', using 8000"
        use_port="8000"
    fi
    
    start_service "$num" "$use_dir" "$use_port" "$use_cmd" || {
        msg err "Server gagal start"
    }
    
    echo ""
    msg ok "Project started!"
    if [ "$AUTO_RESTART" = "1" ]; then
        monitor_project "$num" &
    fi
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
    stop_service "$num"
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
    
    # Sanitize project name for filesystem (replace spaces with underscores)
    local safe_name="${name// /_}"
    if [ "$safe_name" != "$name" ]; then
        msg warn "Project name contains spaces, sanitizing to: $safe_name"
        name="$safe_name"
    fi
    
    local local_path="$PROJECTS_DIR/$name"
    mkdir -p "$local_path"
    
    local source_path=""
    
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
    echo -e "${BOLD}Konfigurasi Backend Directory${X}"
    echo "Masukkan nama folder backend relatif terhadap project root"
    echo ""
    echo "Contoh struktur project:"
    echo "  $local_path/"
    echo "  ├── backend/      ← jika backend di folder 'backend'"
    echo "  ├── server/       ← jika backend di folder 'server'"
    echo "  ├── api/          ← jika backend di folder 'api'"
    echo "  └── package.json  ← jika backend di root, ketik: ."
    echo ""
    
    # Auto-detect backend folder
    local detected_dir=""
    for dir in "backend" "server" "api" "src" "."; do
        local check_path="$local_path/$dir"
        [ "$dir" = "." ] && check_path="$local_path"
        
        if [ -f "$check_path/package.json" ]; then
            detected_dir="$dir"
            msg info "Detected package.json in: $dir"
            break
        fi
    done
    
    read -rp "Backend directory [detected: ${detected_dir:-(none)}]: " app_dir
    
    if [ -z "$app_dir" ]; then
        if [ -n "$detected_dir" ]; then
            app_dir="$detected_dir"
            msg ok "Using detected: $app_dir"
        else
            msg warn "No directory specified, defaulting to 'backend'"
            app_dir="backend"
        fi
    fi
    
    # Normalize "." to empty string for root
    [ "$app_dir" = "." ] && app_dir=""
    
    # Verify the directory exists
    local verify_path="$local_path/$app_dir"
    [ -z "$app_dir" ] && verify_path="$local_path"
    
    if [ ! -d "$verify_path" ]; then
        msg warn "Directory '$app_dir' not found in project"
        if confirm "Create directory '$app_dir' now?"; then
            mkdir -p "$verify_path"
            msg ok "Directory created"
        else
            msg warn "You can set this later with menu 11"
        fi
    fi
    
    read -rp "Backend port (default: 3000): " app_port
    app_port="${app_port:-3000}"
    
    local app_cmd="auto"
    
    if confirm "Custom start command? (No = auto-detect)"; then
        read -rp "Start command: " app_cmd
        [ -z "$app_cmd" ] && app_cmd="auto"
    fi
    
    local new_num=$(get_project_count)
    new_num=$((new_num + 1))
    
    save_project "$new_num" "$name" "$local_path" "$source_path" \
                 "$app_dir" "$app_port" "$app_cmd" "0" "0"
    
    msg ok "Project added as #$new_num"
    echo ""
    echo "Project: $name"
    echo "Path: $local_path"
    echo "Backend: $app_dir"
    echo "Port: $app_port"
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
    echo "  App dir    : ${APP_DIR:-(none)}"
    echo "  App port   : ${APP_PORT:-8000}"
    echo "  App command: ${APP_CMD:-auto}"
    echo ""
    echo -e "${Y}Kosongkan untuk tidak mengubah${X}"
    echo ""
    
    read -rp "New source path: " new_source
    read -rp "New app dir: " new_app
    read -rp "New app port: " new_app_port
    read -rp "New app cmd: " new_app_cmd
    read -rp "Auto restart (0/1): " new_ar
    read -rp "Auto sync (0/1): " new_as
    
    [ -n "$new_source" ] && SOURCE_PATH="$new_source"
    [ -n "$new_app" ] && APP_DIR="$new_app"
    [ -n "$new_app_port" ] && APP_PORT="$new_app_port"
    [ -n "$new_app_cmd" ] && APP_CMD="$new_app_cmd"
    [ -n "$new_ar" ] && AUTO_RESTART="$new_ar"
    [ -n "$new_as" ] && AUTO_SYNC="$new_as"
    
    save_project "$num" "$PROJECT_NAME" "$PROJECT_PATH" "$SOURCE_PATH" \
                 "${APP_DIR:-(none)}" \
                 "${APP_PORT:-8000}" \
                 "${APP_CMD:-auto}" \
                 "${AUTO_RESTART:-0}" \
                 "${AUTO_SYNC:-0}"
    
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
    
    sed -i "${num}d" "$CONFIG_FILE"
    
    rm -f "${LOG_DIR}/${num}_"*.{pid,log,port,out} 2>/dev/null || true
    
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
    read -rp "Enter project number (or 'live' for live tail): " num
    
    if [ -z "$num" ]; then
        msg err "Number kosong!"
        wait_key
        return
    fi
    
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        msg err "Number harus angka!"
        wait_key
        return
    fi
    
    load_project "$num" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    echo ""
    echo -e "${BOLD}=== Logs for: $PROJECT_NAME (#${num}) ===${X}"
    echo ""
    
    local server_log="${LOG_DIR}/${num}_server.log"
    local sync_log="${LOG_DIR}/${num}_sync.log"
    local pid_file="${LOG_DIR}/${num}_server.pid"
    
    # Check if server is running
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg ok "Server is RUNNING (PID: $pid)"
        else
            msg warn "Server is NOT running"
        fi
    else
        msg warn "Server is NOT running"
    fi
    
    echo ""
    echo -e "${C}--- Server Log (last 50 lines) ---${X}"
    echo "File: $server_log"
    if [ -f "$server_log" ]; then
        tail -n 50 "$server_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${C}--- Sync Log (last 30 lines) ---${X}"
    echo "File: $sync_log"
    if [ -f "$sync_log" ]; then
        tail -n 30 "$sync_log"
    else
        echo "(no log yet)"
    fi
    
    echo ""
    echo -e "${Y}Commands:${X}"
    echo "  tail -f $server_log  # Live tail"
    echo "  cat $server_log      # Full log"
    
    wait_key
}

# ---------------------------
# Export config
# ---------------------------
export_config_json() {
    local out="${LOG_DIR}/dapps_config_$(date +%F_%H%M%S).json"
    
    echo "[" > "$out"
    local first=1
    local line_num=0
    
    while IFS='|' read -r name local_path source_path app_dir app_port app_cmd auto_restart auto_sync; do
        line_num=$((line_num + 1))
        [ -z "$name" ] && continue
        
        [ "$first" -eq 1 ] || echo "," >> "$out"
        first=0
        
        cat >> "$out" <<EOF
{
  "number": $line_num,
  "name": "$name",
  "path": "$local_path",
  "source": "$source_path",
  "app_dir": "$app_dir",
  "app_port": $app_port,
  "app_cmd": "$app_cmd",
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
        
        local bad_lines=0
        while IFS='|' read -r name _; do
            if [ -z "$name" ]; then
                bad_lines=$((bad_lines + 1))
            fi
        done < "$CONFIG_FILE"
        
        if [ "$bad_lines" -gt 0 ]; then
            msg warn "$bad_lines malformed lines in config!"
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
        msg warn "No network tools available"
    fi
    
    echo ""
    msg info "Logs directory: $LOG_DIR"
    msg info "Projects directory: $PROJECTS_DIR"
    msg info "Config file: $CONFIG_FILE"
    
    wait_key
}

# ---------------------------
# Fitur Tambahan: Test Server Connection
# ---------------------------
test_server_connection() {
    header
    echo -e "${BOLD}Test Server Connection${X}\n"
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        msg warn "No projects configured"
        wait_key
        return
    fi
    
    list_projects_table || {
        msg warn "No projects"
        wait_key
        return
    }
    
    echo ""
    read -rp "Enter project number to test: " num
    
    if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
        msg err "Invalid number"
        wait_key
        return
    fi
    
    load_project "$num" || {
        msg err "Project not found"
        wait_key
        return
    }
    
    local pid_file="${LOG_DIR}/${num}_server.pid"
    local port_file="${LOG_DIR}/${num}_server.port"
    local log_file="${LOG_DIR}/${num}_server.log"
    
    echo ""
    echo -e "${BOLD}Testing: $PROJECT_NAME${X}\n"
    
    # Check if process is running
    msg info "1. Checking process status..."
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg ok "Process is running (PID: $pid)"
        else
            msg err "Process is NOT running"
            echo ""
            msg info "Start the server first with menu 3"
            wait_key
            return
        fi
    else
        msg err "No PID file found"
        echo ""
        msg info "Start the server first with menu 3"
        wait_key
        return
    fi
    
    # Check port
    msg info "2. Checking port binding..."
    local port=$(cat "$port_file" 2>/dev/null || echo "3000")
    
    if command -v ss &>/dev/null; then
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            msg ok "Server is listening on port $port"
        else
            msg err "Server is NOT listening on port $port"
            msg warn "Process running but not accepting connections"
        fi
    else
        msg warn "Cannot verify port (ss command not available)"
    fi
    
    # Test local connection
    msg info "3. Testing local connection..."
    if command -v curl &>/dev/null; then
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:$port" 2>/dev/null || echo "000")
        if [ "$http_code" != "000" ]; then
            msg ok "Local connection successful (HTTP $http_code)"
        else
            msg err "Local connection FAILED"
            msg warn "Server might be crashed or not responding"
        fi
    else
        msg warn "Cannot test (curl not available)"
    fi
    
    # Test network connection
    msg info "4. Testing network connection..."
    local ip; ip=$(get_device_ip)
    if command -v curl &>/dev/null; then
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://$ip:$port" 2>/dev/null || echo "000")
        if [ "$http_code" != "000" ]; then
            msg ok "Network connection successful (HTTP $http_code)"
        else
            msg err "Network connection FAILED"
            msg warn "Firewall might be blocking or server only binding to localhost"
        fi
    fi
    
    # Check recent logs
    msg info "5. Checking recent log errors..."
    if [ -f "$log_file" ]; then
        local error_lines=$(grep -i "error\|crash\|exception\|fail" "$log_file" 2>/dev/null | tail -n 5 || true)
        if [ -n "$error_lines" ]; then
            msg warn "Found recent errors in log:"
            echo -e "${Y}$error_lines${X}"
        else
            msg ok "No recent errors in log"
        fi
    fi
    
    echo ""
    echo -e "${BOLD}Summary:${X}"
    echo "  Local URL: http://localhost:$port"
    echo "  Network URL: http://$ip:$port"
    echo ""
    echo -e "${BOLD}Troubleshooting:${X}"
    echo "  • View full log: tail -f $log_file"
    echo "  • Restart server: Use menu 4 to stop, then menu 3 to start"
    echo "  • Reinstall deps: Use menu 5"
    echo "  • Check if PORT env variable is correctly set to $port"
    
    wait_key
}

# ---------------------------
# Fitur Tambahan: Check Server Status
# ---------------------------
check_all_servers_status() {
    header
    echo -e "${BOLD}Server Status Check${X}\n"
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        msg warn "No projects configured"
        wait_key
        return
    fi
    
    local line_num=0
    local running_count=0
    
    echo -e "${BOLD}No. | Project               | Status      | PID     | Port${X}"
    echo "-----------------------------------------------------------------------"
    
    while IFS='|' read -r name local_path _ app_dir app_port _; do
        line_num=$((line_num + 1))
        [ -z "$name" ] && continue
        
        local pid_file="${LOG_DIR}/${line_num}_server.pid"
        local port_file="${LOG_DIR}/${line_num}_server.port"
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null || true)
            local port=$(cat "$port_file" 2>/dev/null || echo "N/A")
            
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                printf "%-3s | %-21s | ${G}%-11s${X} | %-7s | %s\n" \
                    "$line_num" "${name:0:21}" "RUNNING" "$pid" "$port"
                running_count=$((running_count + 1))
            else
                printf "%-3s | %-21s | ${R}%-11s${X} | %-7s | %s\n" \
                    "$line_num" "${name:0:21}" "STOPPED" "-" "-"
            fi
        else
            printf "%-3s | %-21s | ${Y}%-11s${X} | %-7s | %s\n" \
                "$line_num" "${name:0:21}" "NOT STARTED" "-" "-"
        fi
    done < "$CONFIG_FILE"
    
    echo ""
    msg info "Total running servers: $running_count"
    
    if [ $running_count -gt 0 ]; then
        echo ""
        local ip; ip=$(get_device_ip)
        msg info "Network IP: $ip"
        echo ""
        echo "Access URLs:"
        
        line_num=0
        while IFS='|' read -r name _ _ _ _; do
            line_num=$((line_num + 1))
            [ -z "$name" ] && continue
            
            local pid_file="${LOG_DIR}/${line_num}_server.pid"
            local port_file="${LOG_DIR}/${line_num}_server.port"
            
            if [ -f "$pid_file" ]; then
                local pid=$(cat "$pid_file" 2>/dev/null || true)
                local port=$(cat "$port_file" 2>/dev/null || true)
                
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -n "$port" ]; then
                    echo "  → $name: http://$ip:$port"
                fi
            fi
        done < "$CONFIG_FILE"
    fi
    
    wait_key
}

# ---------------------------
# Fitur Tambahan: Self Update
# ---------------------------
self_update() {
    header
    echo -e "${BOLD}Self Update Launcher${X}\n"
    if confirm "Update launcher sekarang?"; then
        curl -fsSL https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/installer.sh | bash
        msg ok "Update selesai. Restart launcher."
        exit 0
    else
        msg info "Update dibatalkan."
    fi
    wait_key
}

# ---------------------------
# Fitur Tambahan: Monitor & Auto-Restart
# ---------------------------
monitor_project() {
    local num="$1"
    load_project "$num" || return 1
    
    while true; do
        local pid_file="${LOG_DIR}/${num}_server.pid"
        
        local pid=$(cat "$pid_file" 2>/dev/null || true)
        
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            msg warn "Server crashed! Restarting..."
            start_service "$num" "$APP_DIR" "${APP_PORT:-8000}" "${APP_CMD:-auto}"
        fi
        
        sleep 30
    done
}

# ---------------------------
# Fitur Tambahan: Backup Project
# ---------------------------
backup_project() {
    header
    echo -e "${BOLD}Backup Project${X}\n"
    
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    
    echo ""
    read -rp "Enter project number to backup: " num
    [ -z "$num" ] && { msg err "Number required"; wait_key; return; }
    
    load_project "$num" || { msg err "Project not found"; wait_key; return; }
    
    local backup_dir="$HOME/dapps-backups/${PROJECT_NAME}_$(date +%F_%H%M%S)"
    mkdir -p "$backup_dir"
    
    msg info "Backing up $PROJECT_NAME to $backup_dir"
    cp -r "$PROJECT_PATH" "$backup_dir" && msg ok "Backup selesai" || msg err "Backup gagal"
    
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
        
        local pid_file="${LOG_DIR}/${line_num}_server.pid"
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null || true)
            
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                running_count=$((running_count+1))
            fi
        fi
    done < "$CONFIG_FILE" 2>/dev/null
    
    echo -e "${C}${BOLD}╔════════════════════════════════════════════════════════╗${X}"
    echo -e "${C}${BOLD}║    DApps Backend Server Launcher — v${LAUNCHER_VERSION}      ║${X}"
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
    echo "12. 🔄 Self Update"
    echo "13. 🛡️ Backup Project"
    echo "14. 🔍 Check Server Status"
    echo "15. 🩺 Test Server Connection"
    echo " 0. 🚪 Exit"
    echo -e "\n${BOLD}═══════════════════════════════════${X}"
    read -rp "Select (0-15): " choice
    
    case "$choice" in
        1)
            header
            list_projects_table || msg warn "No projects"
            prompt_open_path_after_list || true
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
                msg info "Tambahkan project dulu dengan menu 2"
                wait_key
                continue
            fi
            
            local project_count=$(wc -l < "$CONFIG_FILE" 2>/dev/null || echo "0")
            if [ "$project_count" -eq 0 ]; then
                msg warn "Config file ada tapi tidak ada project valid"
                msg info "Tambahkan project dengan menu 2"
                wait_key
                continue
            fi
            
            if ! list_projects_table; then
                msg err "Gagal menampilkan project list"
                wait_key
                continue
            fi
            
            echo ""
            echo -e "${BOLD}${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
            echo -e "${BOLD}Pilih project yang ingin di-start${X}"
            echo -e "${BOLD}${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
            echo ""
            read -rp "Masukkan nomor project (atau 0 untuk batal): " num
            
            [ "$num" = "0" ] && continue
            
            if [ -z "$num" ]; then
                msg err "Nomor tidak boleh kosong!"
                wait_key
                continue
            fi
            
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                msg err "Nomor harus ANGKA!"
                wait_key
                continue
            fi
            
            run_project_by_num "$num"
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
            read -rp "Enter project number: " num
            
            if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
                msg err "Nomor harus angka!"
                wait_key
                return
            fi
            
            stop_project_by_num "$num"
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
            read -rp "Enter project number: " num
            
            if [ -z "$num" ] || ! [[ "$num" =~ ^[0-9]+$ ]]; then
                msg err "Nomor harus angka!"
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
        12) self_update ;;
        13) backup_project ;;
        14) check_all_servers_status ;;
        15) test_server_connection ;;
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

main "$@"
