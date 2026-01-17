#!/data/data/com.termux/files/usr/bin/bash
# DApps Localhost Launcher — Fixed v2.5.1
# Platform : Termux (Android)
# Fix      : Proper sync logic, dotfiles handling, storage->home workflow
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------
# CONFIG / PATHS
# -----------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME_DIR/dapps-projects}"
CONFIG_FILE="${CONFIG_FILE:-$HOME_DIR/.dapps.conf}"
LOG_DIR="${LOG_DIR:-$HOME_DIR/.dapps-logs}"
LAUNCHER_VERSION="2.5.1"

mkdir -p "$PROJECTS_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

# -----------------------
# UI helpers
# -----------------------
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; C="\033[36m"; X="\033[0m"; BOLD="\033[1m"
msg() { case "$1" in ok) echo -e "${G}✓${X} $2" ;; err) echo -e "${R}✗${X} $2" ;; warn) echo -e "${Y}!${X} $2" ;; info) echo -e "${B}i${X} $2" ;; *) echo -e "$1" ;; esac; }
header() { clear; echo -e "${C}${BOLD}DApps Localhost Launcher — v${LAUNCHER_VERSION}${X}\n"; }
wait_key() { echo -e "\nTekan ENTER..."; read -r; }
confirm() { read -rp "$1 (y/N): " a; [[ "$a" =~ ^[Yy]$ ]]; }

# -----------------------
# Utilities
# -----------------------
require_cmd() { command -v "$1" >/dev/null 2>&1; }
detect_pkg_manager() { if require_cmd pnpm; then echo "pnpm"; elif require_cmd yarn; then echo "yarn"; else echo "npm"; fi; }

get_free_port() {
    local base="${1:-3000}"
    local used=""
    if require_cmd ss; then used="$(ss -tuln 2>/dev/null || true)"; fi
    if [ -z "$used" ] && require_cmd netstat; then used="$(netstat -tuln 2>/dev/null || true)"; fi
    for i in $(seq 0 200); do
        local p=$((base + i))
        if [ -z "$used" ]; then echo "$p"; return 0; fi
        if ! echo "$used" | grep -q -E "[: ]$p\b"; then echo "$p"; return 0; fi
    done
    return 1
}

# Check if path is in storage (not home)
is_in_storage() {
    case "$1" in
        /storage/*|/sdcard/*) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------
# FIXED SYNC: storage -> home (include dotfiles!)
# -----------------------
sync_to_home() {
    local src="$1" name="$2" dst="$PROJECTS_DIR/$name"
    
    # Jika sudah di workspace, return langsung
    case "$src" in "$PROJECTS_DIR"/*) echo "$src"; return 0 ;; esac
    
    msg info "Syncing: $src -> $dst (termasuk dotfiles)"
    mkdir -p "$dst"
    
    if require_cmd rsync; then
        # PERBAIKAN: tambahkan flag untuk copy dotfiles, exclude node_modules
        rsync -a --delete \
              --copy-links \
              --exclude 'node_modules/' \
              --exclude '.git/' \
              --include '.*' \
              "$src"/ "$dst"/ || { msg err "rsync gagal"; return 1; }
    else
        # Fallback cp dengan dotfiles
        msg warn "Menggunakan cp (lebih lambat dari rsync)"
        
        # Hapus dulu isi dst (kecuali node_modules)
        find "$dst" -mindepth 1 -maxdepth 1 ! -name 'node_modules' -exec rm -rf {} + 2>/dev/null || true
        
        # Copy dengan dotfiles menggunakan find
        (cd "$src" && find . -name 'node_modules' -prune -o -name '.git' -prune -o -print0 | cpio -pdm0 "$dst" 2>/dev/null) || {
            # Fallback manual jika cpio gagal
            cp -r "$src"/. "$dst"/ 2>/dev/null || true
            cp -r "$src"/.??* "$dst"/ 2>/dev/null || true
        }
    fi
    
    msg ok "Sync selesai: $dst"
    echo "$dst"
    return 0
}

# Sync balik home -> storage (untuk update)
sync_to_storage() {
    local home_path="$1" storage_path="$2"
    
    if [ ! -d "$home_path" ]; then
        msg err "Home path tidak ada: $home_path"
        return 1
    fi
    
    msg info "Sync balik: $home_path -> $storage_path"
    mkdir -p "$storage_path"
    
    if require_cmd rsync; then
        rsync -a --delete \
              --copy-links \
              --exclude 'node_modules/' \
              --exclude '.git/' \
              --include '.*' \
              "$home_path"/ "$storage_path"/ || { msg err "sync balik gagal"; return 1; }
    else
        # Manual copy excluding node_modules
        (cd "$home_path" && find . -name 'node_modules' -prune -o -name '.git' -prune -o -print0 | cpio -pdm0 "$storage_path" 2>/dev/null) || {
            cp -r "$home_path"/. "$storage_path"/ 2>/dev/null || true
            cp -r "$home_path"/.??* "$storage_path"/ 2>/dev/null || true
        }
    fi
    
    msg ok "Sync balik selesai"
    return 0
}

# -----------------------
# Config format (TAB separated)
# name<TAB>path<TAB>original_path<TAB>type<TAB>fe_dir<TAB>be_dir<TAB>fe_port<TAB>be_port<TAB>fe_cmd<TAB>be_cmd<TAB>auto_sync<TAB>supervise
# path: working copy di home (untuk run)
# original_path: sumber asli (jika dari storage)
# -----------------------
save_project() {
    local name="$1" path="$2" original_path="$3" type="$4" fe_dir="$5" be_dir="$6" fe_port="$7" be_port="$8" fe_cmd="$9" be_cmd="${10}" auto_sync="${11:-0}" supervise="${12:-0}"
    awk -F'\t' -v n="$name" 'BEGIN{OFS=FS} $1!=n {print $0}' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true
    mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$name" "$path" "$original_path" "$type" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_sync" "$supervise" >> "$CONFIG_FILE"
}

load_project() {
    local sel="$1"
    local line
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        line=$(sed -n "${sel}p" "$CONFIG_FILE" 2>/dev/null || true)
    else
        line=$(awk -F'\t' -v n="$sel" '$1==n{print; exit}' "$CONFIG_FILE" || true)
    fi
    [ -z "$line" ] && return 1
    IFS=$'\t' read -r P_NAME P_PATH P_ORIGINAL_PATH P_TYPE P_FE_DIR P_BE_DIR P_FE_PORT P_BE_PORT P_FE_CMD P_BE_CMD P_AUTO_SYNC P_SUPERVISE <<< "$line"
    return 0
}

list_projects() {
    [ ! -f "$CONFIG_FILE" ] && { echo "— belum ada project —"; return 0; }
    awk -F'\t' '{printf "%2d) %-20s %s\n", NR, $1, $2}' "$CONFIG_FILE"
}

# -----------------------
# Detect start command
# -----------------------
detect_start_command() {
    local dir="$1" role="$2"
    [ ! -d "$dir" ] && { echo ""; return; }
    if [ -f "$dir/package.json" ] && require_cmd node; then
        if node -e "try{const p=require('$dir/package.json'); console.log(Boolean(p.scripts && p.scripts.dev))}catch(e){console.log(false)}" 2>/dev/null | grep -q true; then echo "npm run dev"; return; fi
        if node -e "try{const p=require('$dir/package.json'); console.log(Boolean(p.scripts && p.scripts.serve))}catch(e){console.log(false)}" 2>/dev/null | grep -q true; then echo "npm run serve"; return; fi
        if node -e "try{const p=require('$dir/package.json'); console.log(Boolean(p.scripts && p.scripts.start))}catch(e){console.log(false)}" 2>/dev/null | grep -q true; then echo "npm start"; return; fi
    fi
    if [ "$role" = "static" ]; then
        if require_cmd serve; then echo "serve -s . -l \$PORT"; return; fi
        if require_cmd python3; then echo "python3 -m http.server \$PORT"; return; fi
        if require_cmd python; then echo "python -m http.server \$PORT"; return; fi
    fi
    echo ""
}

# -----------------------
# Install deps (HARUS di home!)
# -----------------------
install_deps_safely() {
    local dir="$1"
    [ ! -f "$dir/package.json" ] && return 0
    
    # VALIDASI: harus di home, bukan storage
    if is_in_storage "$dir"; then
        msg err "TIDAK BISA install deps di storage! Path: $dir"
        msg err "Project harus di-sync ke home dulu"
        return 1
    fi
    
    local pm; pm=$(detect_pkg_manager)
    msg info "Installing deps di $dir using $pm"
    (cd "$dir" && $pm install) || {
        msg warn "Install gagal, coba hapus node_modules dan retry"
        rm -rf "$dir/node_modules"
        (cd "$dir" && $pm install) || { msg err "Install masih gagal di $dir"; return 1; }
    }
    msg ok "Dependencies terinstall di $dir"
    return 0
}

# -----------------------
# Build frontend
# -----------------------
build_frontend() {
    local dir="$1"
    [ ! -f "$dir/package.json" ] && { msg warn "Tidak ada package.json di $dir"; return 1; }
    if node -e "try{const p=require('$dir/package.json'); console.log(Boolean(p.scripts && p.scripts.build))}catch(e){console.log(false)}" 2>/dev/null | grep -q true; then
        msg info "Running build di $dir"
        (cd "$dir" && npm run build) || { msg err "Build gagal di $dir"; return 1; }
        msg ok "Build selesai"
        return 0
    fi
    msg info "Tidak ada script build"
    return 2
}

# -----------------------
# Start / Stop services
# -----------------------
start_service() {
    local proj="$1" label="$2" dir="$3" preferred_port="$4" cmd="$5"
    local pidf="$LOG_DIR/${proj}_${label}.pid" logf="$LOG_DIR/${proj}_${label}.log" portf="$LOG_DIR/${proj}_${label}.port"
    
    [ ! -d "$dir" ] && { msg err "$label folder tidak ditemukan: $dir"; return 1; }
    
    # VALIDASI: tidak boleh run dari storage
    if is_in_storage "$dir"; then
        msg err "TIDAK BISA run service dari storage! Path: $dir"
        msg err "Sync project ke home dulu"
        return 1
    fi
    
    if [ -f "$pidf" ]; then
        local pid; pid=$(cat "$pidf" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then 
            msg warn "$label sudah running (PID $pid)"
            return 0
        fi
        rm -f "$pidf" || true
    fi
    
    local port; port=$(get_free_port "$preferred_port") || { msg err "Port tidak tersedia mulai dari $preferred_port"; return 1; }
    msg info "Starting $label di $dir (port $port)..."
    
    (cd "$dir" && [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a) || true
    nohup bash -lc "PORT=$port $cmd" > "$logf" 2>&1 &
    echo $! > "$pidf"
    echo "$port" > "$portf"
    sleep 1
    
    if kill -0 "$(cat "$pidf")" 2>/dev/null; then 
        msg ok "$label started (PID $(cat "$pidf"), Port $port)"
        return 0
    else 
        msg err "$label gagal start (lihat $logf)"
        rm -f "$pidf" "$portf"
        return 1
    fi
}

stop_service() {
    local proj="$1" label="$2"
    local pidf="$LOG_DIR/${proj}_${label}.pid" portf="$LOG_DIR/${proj}_${label}.port"
    [ ! -f "$pidf" ] && { msg info "$label tidak running"; return 0; }
    local pid; pid=$(cat "$pidf" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        msg info "Stopping $label (PID $pid)"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf" "$portf" || true
    msg ok "$label stopped"
}

supervise_service() {
    local proj="$1" label="$2" dir="$3" preferred_port="$4" cmd="$5"
    local pidf="$LOG_DIR/${proj}_${label}.pid"
    (
        while true; do
            if [ -f "$pidf" ]; then
                local pid; pid=$(cat "$pidf" 2>/dev/null || true)
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then sleep 2; continue; fi
            fi
            start_service "$proj" "$label" "$dir" "$preferred_port" "$cmd" || sleep 2
            local pid; pid=$(cat "$pidf" 2>/dev/null || true)
            while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do sleep 2; pid=$(cat "$pidf" 2>/dev/null || true); done
            sleep 1
        done
    ) &
    msg ok "Supervisor started untuk $proj/$label"
}

# -----------------------
# Health check
# -----------------------
health_check() {
    local host="${1:-127.0.0.1}" port="$2" path="${3:-/}"
    if ! require_cmd curl; then msg warn "curl tidak tersedia"; return 2; fi
    local url="http://${host}:${port}${path}"
    if curl -sSf --max-time 3 "$url" >/dev/null 2>&1; then 
        msg ok "Health OK: $url"
        return 0
    else 
        msg err "Health FAIL: $url"
        return 1
    fi
}

# -----------------------
# Watch & auto-sync (storage -> home)
# -----------------------
watch_and_sync() {
    local storage_src="$1" name="$2" interval="${3:-3}"
    
    if ! is_in_storage "$storage_src"; then
        msg warn "Watch hanya untuk path di storage. Path ini sudah di home: $storage_src"
        return 1
    fi
    
    if require_cmd inotifywait; then
        msg info "Watching $storage_src (inotify) -> auto sync ke home"
        inotifywait -m -r -e modify,create,delete,move "$storage_src" --format '%w%f' 2>/dev/null | while read -r f; do
            msg info "Perubahan terdeteksi: $f"
            sync_to_home "$storage_src" "$name" >/dev/null || msg warn "Auto-sync gagal"
        done
    else
        msg info "inotifywait tidak ada -> polling setiap ${interval}s"
        local last
        last=$(find "$storage_src" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f1 || echo 0)
        while true; do
            sleep "$interval"
            local now
            now=$(find "$storage_src" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f1 || echo 0)
            if [ "$now" != "$last" ]; then
                msg info "Perubahan terdeteksi (poll)"
                sync_to_home "$storage_src" "$name" >/dev/null || msg warn "Auto-sync gagal"
                last="$now"
            fi
        done
    fi
}

# -----------------------
# Interactive flows
# -----------------------
add_project_interactive() {
    header
    echo "Tambah project baru"
    read -rp "Nama project: " name || return
    [ -z "$name" ] && { msg err "Nama kosong"; return; }
    if awk -F'\t' -v n="$name" '$1==n{exit 1}' "$CONFIG_FILE"; then :; else msg err "Project sudah ada"; return; fi

    echo "Sumber: (1) Git clone  (2) Folder lokal"
    read -rp "Pilih (1/2): " srcopt
    local src original_path
    if [ "$srcopt" = "1" ]; then
        read -rp "Git URL: " src
        [ -z "$src" ] && { msg err "URL kosong"; return; }
        original_path=""  # git tidak punya original path
    else
        read -rp "Path folder sumber (contoh: /storage/emulated/0/Download/myproject): " src
        [ ! -d "$src" ] && { msg err "Folder tidak ditemukan"; return; }
        original_path="$src"  # simpan original path dari storage
    fi

    read -rp "Type (static/frontend/backend/fullstack) [frontend]: " t; t=${t:-frontend}
    read -rp "Frontend dir [frontend]: " fe; fe=${fe:-frontend}
    read -rp "Backend dir [backend]: " be; be=${be:-backend}
    read -rp "Frontend port [3000]: " fport; fport=${fport:-3000}
    read -rp "Backend port [8000]: " bport; bport=${bport:-8000}
    read -rp "Auto-sync dari source? (y/N): " as; auto_sync=0; [[ "$as" =~ ^[Yy]$ ]] && auto_sync=1
    read -rp "Supervise (auto-restart)? (y/N): " sp; supervise=0; [[ "$sp" =~ ^[Yy]$ ]] && supervise=1

    local working_path
    if [[ "$src" =~ ^git@|https?:// ]]; then
        working_path="$PROJECTS_DIR/$name"
        msg info "Cloning $src -> $working_path"
        git clone "$src" "$working_path" || { msg err "Clone gagal"; return; }
        original_path=""  # git clone tidak perlu original path
    else
        # Sync dari storage ke home
        working_path=$(sync_to_home "$src" "$name") || { msg err "Sync awal gagal"; return; }
    fi

    local fe_cmd be_cmd
    fe_cmd=$(detect_start_command "$working_path/$fe" "fe"); fe_cmd=${fe_cmd:-"npm run dev"}
    be_cmd=$(detect_start_command "$working_path/$be" "be"); be_cmd=${be_cmd:-"npm start"}

    save_project "$name" "$working_path" "$original_path" "$t" "$fe" "$be" "$fport" "$bport" "$fe_cmd" "$be_cmd" "$auto_sync" "$supervise"
    msg ok "Project '$name' tersimpan"
    msg info "Working copy: $working_path"
    [ -n "$original_path" ] && msg info "Original source: $original_path"

    # Start auto-watch jika diminta dan source dari storage
    if [ "$auto_sync" = "1" ] && [ -n "$original_path" ] && is_in_storage "$original_path"; then
        if require_cmd inotifywait; then
            (watch_and_sync "$original_path" "$name" 3 &>/dev/null &)
            msg ok "Background watch dimulai untuk: $original_path"
        else
            msg warn "inotifywait belum terinstall. Install dengan: pkg install inotify-tools"
            msg info "Atau gunakan menu 'Watch & Auto-sync' manual nanti"
        fi
    fi
}

select_project_prompt() {
    [ ! -f "$CONFIG_FILE" ] && { msg warn "Belum ada project"; return 1; }
    echo "Daftar project:"
    awk -F'\t' '{printf "%2d) %-20s %s\n", NR, $1, $2}' "$CONFIG_FILE"
    read -rp "Pilih nomor atau nama project: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        name=$(sed -n "${sel}p" "$CONFIG_FILE" | cut -f1) || true
    else
        name="$sel"
    fi
    [ -z "${name:-}" ] && { msg err "Pilihan kosong"; return 1; }
    if ! awk -F'\t' -v n="$name" '$1==n{found=1} END{exit(!found)}' "$CONFIG_FILE"; then
        msg err "Project tidak ditemukan: $sel"
        return 1
    fi
    echo "$name"
    return 0
}

run_project_flow() {
    header
    echo "Run project"
    if ! name=$(select_project_prompt); then wait_key; return; fi
    load_project "$name" || { msg err "Load project gagal"; wait_key; return; }

    # Validasi: working path harus ada
    if [ ! -d "$P_PATH" ]; then
        msg err "Working copy tidak ditemukan: $P_PATH"
        if [ -n "$P_ORIGINAL_PATH" ] && [ -d "$P_ORIGINAL_PATH" ]; then
            msg info "Mencoba sync ulang dari: $P_ORIGINAL_PATH"
            newp=$(sync_to_home "$P_ORIGINAL_PATH" "$P_NAME") || { msg err "Sync gagal"; wait_key; return; }
            P_PATH="$newp"
            save_project "$P_NAME" "$P_PATH" "$P_ORIGINAL_PATH" "$P_TYPE" "$P_FE_DIR" "$P_BE_DIR" "$P_FE_PORT" "$P_BE_PORT" "$P_FE_CMD" "$P_BE_CMD" "$P_AUTO_SYNC" "$P_SUPERVISE"
        else
            wait_key
            return
        fi
    fi

    # Auto-sync dari storage jika perlu
    if [ -n "$P_ORIGINAL_PATH" ] && is_in_storage "$P_ORIGINAL_PATH"; then
        msg info "Syncing dari storage: $P_ORIGINAL_PATH"
        sync_to_home "$P_ORIGINAL_PATH" "$P_NAME" >/dev/null || msg warn "Sync gagal, lanjut dengan copy lama"
    fi

    case "$P_TYPE" in
        static)
            local static_dir="$P_PATH/$P_FE_DIR"
            [ ! -d "$static_dir" ] && { msg err "Static dir tidak ada: $static_dir"; wait_key; return; }
            start_service "$P_NAME" "static" "$static_dir" "$P_FE_PORT" "$(detect_start_command "$static_dir" "static")"
            ;;
        frontend)
            local fe_dir="$P_PATH/$P_FE_DIR"
            install_deps_safely "$fe_dir"
            if confirm "Build frontend jika tersedia?"; then build_frontend "$fe_dir" || true; fi
            if [ "$P_SUPERVISE" = "1" ]; then 
                supervise_service "$P_NAME" "frontend" "$fe_dir" "$P_FE_PORT" "$P_FE_CMD"
            else 
                start_service "$P_NAME" "frontend" "$fe_dir" "$P_FE_PORT" "$P_FE_CMD"
            fi
            ;;
        backend)
            local be_dir="$P_PATH/$P_BE_DIR"
            install_deps_safely "$be_dir"
            if [ "$P_SUPERVISE" = "1" ]; then 
                supervise_service "$P_NAME" "backend" "$be_dir" "$P_BE_PORT" "$P_BE_CMD"
            else 
                start_service "$P_NAME" "backend" "$be_dir" "$P_BE_PORT" "$P_BE_CMD"
            fi
            ;;
        fullstack)
            local fe_dir="$P_PATH/$P_FE_DIR" be_dir="$P_PATH/$P_BE_DIR"
            install_deps_safely "$fe_dir" || true
            install_deps_safely "$be_dir" || true
            if confirm "Build frontend jika tersedia?"; then build_frontend "$fe_dir" || true; fi
            if [ "$P_SUPERVISE" = "1" ]; then 
                supervise_service "$P_NAME" "frontend" "$fe_dir" "$P_FE_PORT" "$P_FE_CMD"
                supervise_service "$P_NAME" "backend" "$be_dir" "$P_BE_PORT" "$P_BE_CMD"
            else 
                start_service "$P_NAME" "frontend" "$fe_dir" "$P_FE_PORT" "$P_FE_CMD"
                start_service "$P_NAME" "backend" "$be_dir" "$P_BE_PORT" "$P_BE_CMD"
            fi
            ;;
        *)
            msg err "Type tidak dikenal: $P_TYPE"
            ;;
    esac

    # Health check
    if require_cmd curl; then
        if [ -f "$LOG_DIR/${P_NAME}_frontend.port" ]; then 
            hport=$(cat "$LOG_DIR/${P_NAME}_frontend.port")
            sleep 2
            health_check "127.0.0.1" "$hport" || true
        fi
        if [ -f "$LOG_DIR/${P_NAME}_backend.port" ]; then 
            hport=$(cat "$LOG_DIR/${P_NAME}_backend.port")
            sleep 2
            health_check "127.0.0.1" "$hport" || true
        fi
    fi

    wait_key
}

stop_project_flow() {
    header
    echo "Stop project"
    if ! name=$(select_project_prompt); then wait_key; return; fi
    stop_service "$name" "frontend"
    stop_service "$name" "backend"
    stop_service "$name" "static"
    wait_key
}

status_flow() {
    header
    echo "Status semua project"
    [ ! -f "$CONFIG_FILE" ] && { msg warn "Belum ada project"; wait_key; return; }
    while IFS=$'\t' read -r nm p op t _; do
        [ -z "$nm" ] && continue
        echo -e "${BOLD}$nm${X} — $p ($t)"
        [ -n "$op" ] && echo -e "  ${Y}Source:${X} $op"
        for svc in frontend backend static; do
            pidf="$LOG_DIR/${nm}_${svc}.pid"; portf="$LOG_DIR/${nm}_${svc}.port"
            if [ -f "$pidf" ]; then
                pid=$(cat "$pidf" 2>/dev/null || true); port=$(cat "$portf" 2>/dev/null || true)
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    echo -e "  ${G}● $svc${X} running (PID:$pid Port:$port)"
                else
                    echo -e "  ${Y}○ $svc${X} stopped (stale pid)"
                    rm -f "$pidf" "$portf" || true
                fi
            else
                echo -e "  ${R}○ $svc${X} stopped"
            fi
        done
        echo ""
    done < "$CONFIG_FILE"
    wait_key
}

logs_flow() {
    header
    echo "View logs"
    if ! name=$(select_project_prompt); then wait_key; return; fi
    echo "1) Frontend  2) Backend  3) Static  4) Tail all"
    read -rp "Pilih: " c
    case "$c" in
        1) f="$LOG_DIR/${name}_frontend.log" ;;
        2) f="$LOG_DIR/${name}_backend.log" ;;
        3) f="$LOG_DIR/${name}_static.log" ;;
        4) tail -n 200 -f "$LOG_DIR/${name}_frontend.log" "$LOG_DIR/${name}_backend.log" "$LOG_DIR/${name}_static.log" 2>/dev/null; wait_key; return ;;
        *) msg err "Pilihan invalid"; wait_key; return ;;
    esac
    [ -f "$f" ] && { echo -e "\n--- last 200 lines ---\n"; tail -n 200 "$f"; } || msg warn "Log tidak ditemukan: $f"
    wait_key
}

sync_back_flow() {
    header
    echo "Sync balik: Home -> Storage"
    if ! name=$(select_project_prompt); then wait_key; return; fi
    load_project "$name" || { msg err "Load gagal"; wait_key; return; }
    
    if [ -z "$P_ORIGINAL_PATH" ]; then
        msg err "Project ini tidak punya original path di storage"
        msg info "Project berasal dari git clone atau sudah di home"
        wait_key
        return
    fi
    
    if ! is_in_storage "$P_ORIGINAL_PATH"; then
        msg err "Original path bukan di storage: $P_ORIGINAL_PATH"
        wait_key
        return
    fi
    
    msg info "Akan sync dari:"
    echo "  Home    : $P_PATH"
    echo "  Storage : $P_ORIGINAL_PATH"
    
    if ! confirm "Lanjutkan sync balik?"; then
        msg info "Dibatalkan"
        wait_key
        return
    fi
    
    sync_to_storage "$P_PATH" "$P_ORIGINAL_PATH" || { msg err "Sync balik gagal"; wait_key; return; }
    msg ok "Sync balik selesai!"
    wait_key
}

export_config_flow() {
    header
    echo "Export config"
    read -rp "Nama file output [dapps-export.json]: " fname; fname=${fname:-dapps-export.json}
    if require_cmd jq; then
        jq -R -s -c 'split("\n")|map(select(length>0))|map(split("\t")|{name:.[0],path:.[1],original_path:.[2],type:.[3],fe_dir:.[4],be_dir:.[5],fe_port:.[6],be_port:.[7],fe_cmd:.[8],be_cmd:.[9],auto_sync:.[10],supervise:.[11]})' "$CONFIG_FILE" > "$fname" 2>/dev/null
    else
        awk -F'\t' 'BEGIN{print "["}{if(NR>1)print ","; printf("{\"name\":\"%s\",\"path\":\"%s\",\"type\":\"%s\"}",$1,$2,$4)}END{print "]"}' "$CONFIG_FILE" > "$fname"
    fi
    msg ok "Config diexport ke $fname"
    wait_key
}

import_config_flow() {
    header
    echo "Import config"
    read -rp "Nama file input: " fname
    [ ! -f "$fname" ] && { msg err "File tidak ditemukan"; wait_key; return; }
    if require_cmd jq; then
        jq -c '.[]' "$fname" 2>/dev/null | while read -r obj; do
            n=$(echo "$obj" | jq -r '.name')
            p=$(echo "$obj" | jq -r '.path')
            op=$(echo "$obj" | jq -r '.original_path // ""')
            t=$(echo "$obj" | jq -r '.type')
            fe=$(echo "$obj" | jq -r '.fe_dir // "frontend"')
            be=$(echo "$obj" | jq -r '.be_dir // "backend"')
            fp=$(echo "$obj" | jq -r '.fe_port // "3000"')
            bp=$(echo "$obj" | jq -r '.be_port // "8000"')
            fcmd=$(echo "$obj" | jq -r '.fe_cmd // "npm run dev"')
            bcmd=$(echo "$obj" | jq -r '.be_cmd // "npm start"')
            as=$(echo "$obj" | jq -r '.auto_sync // "0"')
            sp=$(echo "$obj" | jq -r '.supervise // "0"')
            save_project "$n" "$p" "$op" "$t" "$fe" "$be" "$fp" "$bp" "$fcmd" "$bcmd" "$as" "$sp"
        done
    fi
    msg ok "Import selesai"
    wait_key
}

update_from_git_flow() {
    header
    echo "Update from Git"
    if ! name=$(select_project_prompt); then wait_key; return; fi
    load_project "$name"
    if [ ! -d "$P_PATH/.git" ]; then 
        msg err "Bukan git repo: $P_PATH"
        wait_key
        return
    fi
    msg info "Git pull di: $P_PATH"
    (cd "$P_PATH" && git pull --rebase) && msg ok "Git pull selesai" || msg err "Git pull gagal"
    wait_key
}

self_update_flow() {
    header
    echo "Self-update launcher"
    if ! require_cmd curl && ! require_cmd wget; then 
        msg err "curl atau wget diperlukan"
        wait_key
        return
    fi
    local url="https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh"
    tmp="$(mktemp -t dapps_update.XXXXXX)" || tmp="/tmp/dapps_update.$$"
    if require_cmd curl; then 
        curl -fsSL "$url" -o "$tmp" || { msg err "Download gagal"; rm -f "$tmp"; wait_key; return; }
    else 
        wget -qO "$tmp" "$url" || { msg err "Download gagal"; rm -f "$tmp"; wait_key; return; }
    fi
    sed -i "1c #!/data/data/com.termux/files/usr/bin/bash" "$tmp" || true
    chmod +x "$tmp"
    mv -f "$tmp" "$PREFIX/bin/dapps"
    chmod +x "$PREFIX/bin/dapps"
    msg ok "Launcher updated di $PREFIX/bin/dapps"
    wait_key
}

uninstall_flow() {
    header
    echo "Uninstall launcher"
    if confirm "Yakin uninstall?"; then 
        rm -f "$PREFIX/bin/dapps" || true
        msg ok "Uninstalled (binary dihapus)"
    else 
        msg info "Dibatalkan"
    fi
    wait_key
}

# -----------------------
# CLI parsing
# -----------------------
print_help() {
    cat <<EOF
DApps Launcher v${LAUNCHER_VERSION}
Usage:
  dapps                     -> interactive menu
  dapps run <name|#>        -> run project
  dapps stop <name|#>       -> stop project
  dapps add --git URL --name NAME [options]
  dapps status
  dapps logs <name>
  dapps sync-back <name>    -> sync dari home ke storage
  dapps export [file]
  dapps import <file>
  dapps watch <storage_path> <name>
  dapps help
EOF
}

cli_add_noninteractive() {
    local git="" path="" name="" type="frontend" fe="frontend" be="backend" fport=3000 bport=8000 auto_sync=0 supervise=0
    while [ $# -gt 0 ]; do 
        case "$1" in 
            --git) git="$2"; shift 2 ;;
            --path) path="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --fe) fe="$2"; shift 2 ;;
            --be) be="$2"; shift 2 ;;
            --fport) fport="$2"; shift 2 ;;
            --bport) bport="$2"; shift 2 ;;
            --auto-sync) auto_sync=1; shift ;;
            --supervise) supervise=1; shift ;;
            *) shift ;;
        esac
    done
    
    [ -z "$name" ] && { msg err "Missing --name"; exit 1; }
    
    local working_path original_path=""
    if [ -n "$git" ]; then
        working_path="$PROJECTS_DIR/$name"
        git clone "$git" "$working_path" || { msg err "git clone gagal"; exit 1; }
    elif [ -n "$path" ]; then
        original_path="$path"
        working_path=$(sync_to_home "$path" "$name") || { msg err "sync gagal"; exit 1; }
    else
        msg err "Either --git or --path required"
        exit 1
    fi
    
    fe_cmd=$(detect_start_command "$working_path/$fe" "fe"); fe_cmd=${fe_cmd:-"npm run dev"}
    be_cmd=$(detect_start_command "$working_path/$be" "be"); be_cmd=${be_cmd:-"npm start"}
    save_project "$name" "$working_path" "$original_path" "$type" "$fe" "$be" "$fport" "$bport" "$fe_cmd" "$be_cmd" "$auto_sync" "$supervise"
    msg ok "Project $name ditambahkan"
}

# -----------------------
# Main menu
# -----------------------
main_menu() {
    while true; do
        header
        echo "1) ▶  Run Project"
        echo "2) ⏹  Stop Project"
        echo "3) ➕  Add Project"
        echo "4) 📦  Install/Update Dependencies"
        echo "5) 🔁  Update from Git"
        echo "6) 📊  Status"
        echo "7) 📝  Logs"
        echo "8) ⬅️  Sync Back (Home -> Storage)"
        echo "9) ⚙️  Export Config"
        echo "10) 🔄 Import Config"
        echo "11) 🔍 Health Check"
        echo "12) 🔁 Self-update"
        echo "13) 🧹 Clean node_modules"
        echo "14) 🧱 Build Frontend"
        echo "15) 🚨 Watch & Auto-sync (background)"
        echo "16) 🛡️ Supervisor (start supervise processes)"
        echo "99) ❌ Uninstall"
        echo "0)  Exit"
        read -rp $'\n''Pilih: ' ch
        case "$ch" in
            1) run_project_flow ;;
            2) stop_project_flow ;;
            3) add_project_interactive ;;
            4)
                if ! name=$(select_project_prompt); then wait_key; else 
                    load_project "$name"
                    install_deps_safely "$P_PATH/$P_FE_DIR" || true
                    install_deps_safely "$P_PATH/$P_BE_DIR" || true
                    wait_key
                fi
                ;;
            5) update_from_git_flow ;;
            6) status_flow ;;
            7) logs_flow ;;
            8) sync_back_flow ;;
            9) export_config_flow ;;
            10) import_config_flow ;;
            11)
                read -rp "Host [127.0.0.1]: " host; host=${host:-127.0.0.1}
                read -rp "Port: " port
                health_check "$host" "$port"
                wait_key
                ;;
            12) self_update_flow ;;
            13)
                if ! name=$(select_project_prompt); then wait_key; else 
                    load_project "$name"
                    read -rp "Hapus node_modules di project ini? (y/N): " yn
                    [[ "$yn" =~ ^[Yy]$ ]] && {
                        rm -rf "$P_PATH/node_modules" "$P_PATH/$P_FE_DIR/node_modules" "$P_PATH/$P_BE_DIR/node_modules"
                        msg ok "node_modules dihapus"
                    }
                    wait_key
                fi
                ;;
            14)
                if ! name=$(select_project_prompt); then wait_key; else 
                    load_project "$name"
                    build_frontend "$P_PATH/$P_FE_DIR"
                    wait_key
                fi
                ;;
            15)
                if ! name=$(select_project_prompt); then wait_key; else 
                    load_project "$name"
                    if [ -n "$P_ORIGINAL_PATH" ] && is_in_storage "$P_ORIGINAL_PATH"; then
                        src="$P_ORIGINAL_PATH"
                    else
                        read -rp "Source path di storage untuk watch: " src
                        [ ! -d "$src" ] && { msg err "Path tidak ditemukan"; wait_key; continue; }
                    fi
                    (watch_and_sync "$src" "$P_NAME" 3 &>/dev/null &) && msg ok "Watch dimulai" || msg warn "Watch start gagal"
                    wait_key
                fi
                ;;
            16)
                awk -F'\t' '$12=="1"{print $1}' "$CONFIG_FILE" | while read -r proj; do 
                    load_project "$proj"
                    if [ "$P_TYPE" = "frontend" ] || [ "$P_TYPE" = "fullstack" ]; then 
                        supervise_service "$P_NAME" "frontend" "$P_PATH/$P_FE_DIR" "$P_FE_PORT" "$P_FE_CMD"
                    fi
                    if [ "$P_TYPE" = "backend" ] || [ "$P_TYPE" = "fullstack" ]; then 
                        supervise_service "$P_NAME" "backend" "$P_PATH/$P_BE_DIR" "$P_BE_PORT" "$P_BE_CMD"
                    fi
                done
                wait_key
                ;;
            99) uninstall_flow ;;
            0) exit 0 ;;
            *) msg err "Pilihan invalid"; wait_key ;;
        esac
    done
}

# -----------------------
# Entrypoint
# -----------------------
if [ $# -gt 0 ]; then
    case "$1" in
        run) 
            shift
            [ $# -ge 1 ] || { msg err "Usage: dapps run <name|#>"; exit 1; }
            sel="$1"
            load_project "$sel" || { msg err "Project tidak ditemukan: $sel"; exit 1; }
            # Non-interactive run
            name="$P_NAME"
            if [ -n "$P_ORIGINAL_PATH" ] && is_in_storage "$P_ORIGINAL_PATH"; then
                msg info "Auto-syncing dari storage..."
                sync_to_home "$P_ORIGINAL_PATH" "$P_NAME" >/dev/null || true
            fi
            case "$P_TYPE" in
                frontend)
                    install_deps_safely "$P_PATH/$P_FE_DIR"
                    start_service "$P_NAME" "frontend" "$P_PATH/$P_FE_DIR" "$P_FE_PORT" "$P_FE_CMD"
                    ;;
                backend)
                    install_deps_safely "$P_PATH/$P_BE_DIR"
                    start_service "$P_NAME" "backend" "$P_PATH/$P_BE_DIR" "$P_BE_PORT" "$P_BE_CMD"
                    ;;
                fullstack)
                    install_deps_safely "$P_PATH/$P_FE_DIR"
                    install_deps_safely "$P_PATH/$P_BE_DIR"
                    start_service "$P_NAME" "frontend" "$P_PATH/$P_FE_DIR" "$P_FE_PORT" "$P_FE_CMD"
                    start_service "$P_NAME" "backend" "$P_PATH/$P_BE_DIR" "$P_BE_PORT" "$P_BE_CMD"
                    ;;
            esac
            exit 0
            ;;
        stop) 
            shift
            [ $# -ge 1 ] || { msg err "Usage: dapps stop <name|#>"; exit 1; }
            sel="$1"
            load_project "$sel" || { msg err "Project tidak ditemukan: $sel"; exit 1; }
            stop_service "$P_NAME" "frontend"
            stop_service "$P_NAME" "backend"
            stop_service "$P_NAME" "static"
            exit 0
            ;;
        add) 
            shift
            cli_add_noninteractive "$@"
            exit 0
            ;;
        status) 
            status_flow
            exit 0
            ;;
        logs) 
            shift
            [ $# -ge 1 ] || { msg err "Usage: dapps logs <name|#>"; exit 1; }
            sel="$1"
            load_project "$sel" || { msg err "Project tidak ditemukan: $sel"; exit 1; }
            logs_flow
            exit 0
            ;;
        sync-back)
            shift
            [ $# -ge 1 ] || { msg err "Usage: dapps sync-back <name|#>"; exit 1; }
            sel="$1"
            load_project "$sel" || { msg err "Project tidak ditemukan: $sel"; exit 1; }
            if [ -n "$P_ORIGINAL_PATH" ] && is_in_storage "$P_ORIGINAL_PATH"; then
                sync_to_storage "$P_PATH" "$P_ORIGINAL_PATH"
            else
                msg err "Tidak ada original path di storage"
                exit 1
            fi
            exit 0
            ;;
        export) 
            shift
            fname=${1:-dapps-export.json}
            export_config_flow
            exit 0
            ;;
        import) 
            shift
            [ $# -ge 1 ] || { msg err "Usage: dapps import <file>"; exit 1; }
            fname="$1"
            import_config_flow
            exit 0
            ;;
        watch) 
            shift
            [ $# -ge 2 ] || { msg err "Usage: dapps watch <storage_path> <name>"; exit 1; }
            watch_and_sync "$1" "$2" &
            exit 0
            ;;
        help|-h|--help) 
            print_help
            exit 0
            ;;
        *) 
            print_help
            exit 1
            ;;
    esac
else
    main_menu
fi
