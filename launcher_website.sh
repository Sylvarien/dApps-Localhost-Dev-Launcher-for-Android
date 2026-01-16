#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher — Ultimate Dev Edition v2.4.0
# Platform : Android Termux
# Purpose  : Full-featured launcher untuk static/frontend/backend/fullstack dev
# Notes    : Code lengkap — taruh sebagai $PREFIX/bin/dapps atau jalankan langsung.
#            Mengutamakan: AUTO-SYNC dari /storage -> $HOME, build, watch, health.
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME_DIR/dapps-projects}"
CONFIG_FILE="${CONFIG_FILE:-$HOME_DIR/.dapps.conf}"
LOG_DIR="${LOG_DIR:-$HOME_DIR/.dapps-logs}"
LAUNCHER_VERSION="2.4.0"

mkdir -p "$PROJECTS_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# COLORS / UI
# ----------------------------------------------------------------------------
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; C="\033[36m"; X="\033[0m"; BOLD="\033[1m"
msg() { case "$1" in ok) echo -e "${G}✓${X} $2" ;; err) echo -e "${R}✗${X} $2" ;; warn) echo -e "${Y}!${X} $2" ;; info) echo -e "${B}i${X} $2" ;; *) echo -e "$1" ;; esac; }
header() { clear; echo -e "${C}${BOLD}DApps Localhost Launcher — v${LAUNCHER_VERSION}${X}\n"; }
wait_key() { echo -e "\nTekan ENTER..."; read -r; }
confirm() { read -rp "$1 (y/N): " a; [[ "$a" =~ ^[Yy]$ ]]; }

# ----------------------------------------------------------------------------
# UTIL: dependencies, package manager, ports
# ----------------------------------------------------------------------------
require_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }
detect_pkg_manager() { if require_cmd pnpm; then echo "pnpm"; elif require_cmd yarn; then echo "yarn"; else echo "npm"; fi; }
get_free_port() {
    local base="${1:-3000}"
    for i in $(seq 0 200); do
        local p=$((base + i))
        if ! (netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null) | grep -q ":$p\b"; then
            echo "$p"; return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------------------
# SYNC: copy project from /storage or external into TERMUX HOME workspace
# - rsync preferred (kehilangan symlink di sdcard); excludes node_modules/.git by default
# - returns destination path on success, empty on failure
# ----------------------------------------------------------------------------
sync_to_home() {
    local src="$1" name="$2" dst="$PROJECTS_DIR/$name"
    # if already inside projects dir, nothing to do
    case "$src" in "$PROJECTS_DIR"/*) echo "$src"; return 0 ;; esac

    msg info "Syncing '$src' -> '$dst' (exclude: node_modules, .git)"
    mkdir -p "$dst"

    if require_cmd rsync; then
        rsync -a --delete --copy-links \
            --exclude 'node_modules' --exclude '.git' --exclude '*.log' \
            "$src"/ "$dst"/ || { msg err "rsync gagal"; return 1; }
    else
        # fallback cp: try safe copy (mirror)
        rm -rf "$dst"/* "$dst"/.[!.]* 2>/dev/null || true
        cp -a "$src"/. "$dst"/ || { msg err "cp gagal"; return 1; }
    fi

    msg ok "Sync selesai ke: $dst"
    echo "$dst"
}

# ----------------------------------------------------------------------------
# CONFIG FORMAT (tab-separated to avoid pipe issues)
# name<TAB>path<TAB>type<TAB>fe_dir<TAB>be_dir<TAB>fe_port<TAB>be_port<TAB>fe_cmd<TAB>be_cmd<TAB>auto_sync
# type: static|frontend|backend|fullstack
# ----------------------------------------------------------------------------
save_project() {
    local name="$1" path="$2" type="$3" fe_dir="$4" be_dir="$5" fe_port="$6" be_port="$7" fe_cmd="$8" be_cmd="$9" auto_sync="${10:-0}"
    awk -F'\t' -v n="$name" '$1!=n {print}' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$name" "$path" "$type" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_sync" >> "$CONFIG_FILE"
}

load_project() {
    local name="$1"
    local line
    line=$(grep "^${name}\	" "$CONFIG_FILE" 2>/dev/null || true)
    [ -z "$line" ] && return 1
    IFS=$'\t' read -r P_NAME P_PATH P_TYPE P_FE_DIR P_BE_DIR P_FE_PORT P_BE_PORT P_FE_CMD P_BE_CMD P_AUTO_SYNC <<< "$line"
    return 0
}

list_projects_verbose() {
    [ ! -f "$CONFIG_FILE" ] && return 0
    nl -w2 -s'. ' -ba "$CONFIG_FILE" | while IFS=$'\t' read -r num line; do
        # line format printed by nl includes row number; print content nicely
        true
    done
    # simpler listing:
    awk -F'\t' '{printf "%2d) %s — %s\n", NR, $1, $2}' "$CONFIG_FILE"
}

# ----------------------------------------------------------------------------
# DETECT START COMMAND (smart)
# ----------------------------------------------------------------------------
detect_start_command() {
    local dir="$1" role="$2" # role: fe/be/static
    [ -z "$dir" ] && echo "" && return
    if [ -f "$dir/package.json" ]; then
        # check scripts: prefer dev, start, serve
        local hasdev hasstart hasserve
        hasdev=$(node -e "try{const p=require('$dir/package.json');console.log(!!(p.scripts&&p.scripts.dev))}catch(e){console.log(false)}" 2>/dev/null || echo "false")
        hasstart=$(node -e "try{const p=require('$dir/package.json');console.log(!!(p.scripts&&p.scripts.start))}catch(e){console.log(false)}" 2>/dev/null || echo "false")
        hasserve=$(node -e "try{const p=require('$dir/package.json');console.log(!!(p.scripts&&p.scripts.serve))}catch(e){console.log(false)}" 2>/dev/null || echo "false")
        if [ "$hasdev" = "true" ]; then echo "npm run dev"; return; fi
        if [ "$hasserve" = "true" ]; then echo "npm run serve"; return; fi
        if [ "$hasstart" = "true" ]; then echo "npm start"; return; fi
    fi
    # special for static
    if [ "$role" = "static" ]; then
        if require_cmd serve; then echo "serve -s . -l \$PORT"; return; fi
        if require_cmd python || require_cmd python3; then echo "python -m http.server \$PORT"; return; fi
    fi
    echo ""
}

# ----------------------------------------------------------------------------
# INSTALL DEPENDENCIES (with retry/cleanup)
# ----------------------------------------------------------------------------
install_deps_safely() {
    local dir="$1"
    [ ! -f "$dir/package.json" ] && return 0
    local pm; pm=$(detect_pkg_manager)
    msg info "Install deps di $dir (pakai $pm)"
    (cd "$dir" && $pm install) || {
        msg warn "Install gagal, menghapus node_modules dan coba ulang"
        rm -rf "$dir/node_modules"
        (cd "$dir" && $pm install) || { msg err "Install tetap gagal di $dir"; return 1; }
    }
    return 0
}

# ----------------------------------------------------------------------------
# START / STOP SERVICE (records pid & port)
# ----------------------------------------------------------------------------
start_service() {
    local proj="$1" label="$2" dir="$3" preferred_port="$4" cmd="$5"
    local pidf="$LOG_DIR/${proj}_${label}.pid" logf="$LOG_DIR/${proj}_${label}.log" portf="$LOG_DIR/${proj}_${label}.port"
    [ ! -d "$dir" ] && { msg err "$label folder tidak ditemukan: $dir"; return 1; }
    if [ -f "$pidf" ]; then
        local pid; pid=$(cat "$pidf" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then msg warn "$label sudah running (PID $pid)"; return 0; fi
        rm -f "$pidf" || true
    fi
    local port; port=$(get_free_port "$preferred_port") || { msg err "Tidak ada port tersedia mulai $preferred_port"; return 1; }
    msg info "Starting $label di $dir (port $port) ..."
    # load .env if exists
    (cd "$dir" && [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a) || true
    nohup bash -lc "PORT=$port $cmd" > "$logf" 2>&1 &
    echo $! > "$pidf"
    echo "$port" > "$portf"
    sleep 1
    if kill -0 "$(cat "$pidf")" 2>/dev/null; then msg ok "$label started (PID $(cat "$pidf"), Port $port)"; return 0; else msg err "$label gagal start. cek log: $logf"; rm -f "$pidf" "$portf"; return 1; fi
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

# ----------------------------------------------------------------------------
# HEALTH CHECK (simple HTTP probe for a port) - requires curl
# ----------------------------------------------------------------------------
health_check() {
    local host="${1:-127.0.0.1}" port="$2" path="${3:-/}"
    if ! require_cmd curl; then msg warn "curl tidak tersedia, install untuk health checks"; return 2; fi
    local url="http://${host}:${port}${path}"
    if curl -sSf --max-time 3 "$url" >/dev/null 2>&1; then msg ok "Health OK: $url"; return 0; else msg err "Health FAIL: $url"; return 1; fi
}

# ----------------------------------------------------------------------------
# BUILD FRONTEND if script present
# ----------------------------------------------------------------------------
build_frontend() {
    local dir="$1"
    [ ! -f "$dir/package.json" ] && { msg warn "Tidak ada package.json di $dir"; return 1; }
    if node -e "try{const p=require('$dir/package.json'); console.log(!!p.scripts && !!p.scripts.build)}catch(e){console.log(false)}" 2>/dev/null | grep -q true; then
        msg info "Menjalankan build di $dir"
        (cd "$dir" && npm run build) || { msg err "Build gagal di $dir"; return 1; }
        msg ok "Build selesai"
        return 0
    else
        msg info "Tidak ada script build di $dir"
        return 2
    fi
}

# ----------------------------------------------------------------------------
# WATCH: monitor source folder and re-sync on changes (inotify if available, else polling)
# ----------------------------------------------------------------------------
watch_and_sync() {
    local src="$1" name="$2" interval="${3:-3}"
    if require_cmd inotifywait; then
        msg info "Watching $src (inotify)"
        inotifywait -m -r -e modify,create,delete,move "$src" --format '%w%f' | while read -r f; do
            msg info "Perubahan terdeteksi: $f — sinkronisasi..."
            sync_to_home "$src" "$name" >/dev/null || msg warn "Sync gagal saat watch"
        done
    else
        msg info "inotifywait tidak ada — fallback polling setiap ${interval}s"
        local last
        last=$(find "$src" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f1 || echo 0)
        while true; do
            sleep "$interval"
            local now
            now=$(find "$src" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f1 || echo 0)
            if [ "$now" != "$last" ]; then
                msg info "Perubahan terdeteksi (poll) — sync..."
                sync_to_home "$src" "$name" >/dev/null || msg warn "Sync gagal saat polling"
                last="$now"
            fi
        done
    fi
}

# ----------------------------------------------------------------------------
# COMMAND FLOWS: add, run, stop, status, logs, update, export/import
# ----------------------------------------------------------------------------
add_project_interactive() {
    header
    echo "=== Tambah Project Baru ==="
    read -rp "Nama project: " name
    [ -z "$name" ] && { msg err "Nama kosong"; return; }
    if grep "^${name}\	" "$CONFIG_FILE" >/dev/null 2>&1; then
    msg err "Project sudah ada"
    return
    fi

    echo "Sumber: (1) Git clone (2) Folder lokal (/storage atau home)"
    read -rp "Pilih (1/2): " s
    local src
    if [ "$s" = "1" ]; then
        read -rp "Git URL: " giturl
        src="$giturl"
    else
        read -rp "Path folder sumber: " src
        [ ! -d "$src" ] && { msg err "Folder tidak ditemukan"; return; }
    fi

    read -rp "Type (static/frontend/backend/fullstack) [frontend]: " t; t=${t:-frontend}
    read -rp "Frontend folder relatif [frontend]: " fe; fe=${fe:-frontend}
    read -rp "Backend folder relatif  [backend]: " be; be=${be:-backend}
    read -rp "Frontend port default [3000]: " fport; fport=${fport:-3000}
    read -rp "Backend port default  [8000]: " bport; bport=${bport:-8000}
    read -rp "Auto-sync dari sumber? (y/N): " as; as=${as:-N}; auto_sync=0; [[ "$as" =~ ^[Yy]$ ]] && auto_sync=1

    # handle git or local
    local final_path
    if [[ "$src" =~ ^git@|https?:// ]]; then
        final_path="$PROJECTS_DIR/$name"
        msg info "Cloning $src -> $final_path"
        git clone "$src" "$final_path" || { msg err "Git clone gagal"; return; }
    else
        final_path=$(sync_to_home "$src" "$name") || { msg err "Sync awal gagal"; return; }
    fi

    # detect start commands
    local fe_full="$final_path/$fe" be_full="$final_path/$be"
    local fe_cmd be_cmd
    fe_cmd=$(detect_start_command "$fe_full" "fe"); fe_cmd=${fe_cmd:-"npm run dev"}
    be_cmd=$(detect_start_command "$be_full" "be"); be_cmd=${be_cmd:-"npm start"}

    save_project "$name" "$final_path" "$t" "$fe" "$be" "$fport" "$bport" "$fe_cmd" "$be_cmd" "$auto_sync"
    msg ok "Project '$name' disimpan."
    if [ "$auto_sync" = "1" ] && ! [[ "$src" =~ ^git@|https?:// ]]; then
        msg info "Menjalankan watch & sync background..."
        (watch_and_sync "$src" "$name" 3 &>/dev/null &) || msg warn "Tidak bisa start watch background"
    fi
}

select_project_prompt() {
    [ ! -f "$CONFIG_FILE" ] && { msg warn "Belum ada project tersimpan"; return 1; }
    echo "Daftar project:"
    awk -F'\t' '{printf "%2d) %s — %s\n", NR, $1, $2}' "$CONFIG_FILE"
    read -rp "Pilih nomor atau nama project: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        name=$(sed -n "${sel}p" "$CONFIG_FILE" | cut -f1)
    else
        name="$sel"
    fi
    [ -z "$name" ] && { msg err "Pilihan kosong"; return 1; }
    load_project "$name" || { msg err "Project tidak ditemukan: $name"; return 1; }
    echo "$name"
    return 0
}

run_project_flow() {
    header
    echo "=== Run Project ==="
    if ! name=$(select_project_prompt); then wait_key; return; fi
    load_project "$name"
    msg info "Running $P_NAME (type: $P_TYPE)"

    # if original path in config points to /storage, we assume user might want to keep source in sdcard;
    # we will operate on the copy in $PROJECTS_DIR (if auto_sync enabled or not)
    if echo "$P_PATH" | grep -Eq '^/storage/|^/sdcard/'; then
        msg info "Project path berada di storage -> akan disalin ke Termux home"
        newp=$(sync_to_home "$P_PATH" "$P_NAME") || { msg err "Sync gagal"; wait_key; return; }
        P_PATH="$newp"
        save_project "$P_NAME" "$P_PATH" "$P_TYPE" "$P_FE_DIR" "$P_BE_DIR" "$P_FE_PORT" "$P_BE_PORT" "$P_FE_CMD" "$P_BE_CMD" "$P_AUTO_SYNC"
    fi

    case "$P_TYPE" in
        static)
            local static_dir="$P_PATH/$P_FE_DIR"
            [ ! -d "$static_dir" ] && { msg err "Static folder tidak ada: $static_dir"; wait_key; return; }
            start_service "$P_NAME" "static" "$static_dir" "$P_FE_PORT" "$(detect_start_command "$static_dir" "static")"
            ;;
        frontend)
            local fe_dir="$P_PATH/$P_FE_DIR"
            install_deps_safely "$fe_dir"
            # allow build then serve if build exists
            if node -e "try{const p=require('$fe_dir/package.json'); console.log(!!(p.scripts&&p.scripts.build))}catch(e){console.log(false)}" 2>/dev/null | grep -q true; then
                if confirm "Ada script build — mau build dulu?"; then build_frontend "$fe_dir"; fi
            fi
            start_service "$P_NAME" "frontend" "$fe_dir" "$P_FE_PORT" "$P_FE_CMD"
            ;;
        backend)
            local be_dir="$P_PATH/$P_BE_DIR"
            install_deps_safely "$be_dir"
            start_service "$P_NAME" "backend" "$be_dir" "$P_BE_PORT" "$P_BE_CMD"
            ;;
        fullstack)
            local fe_dir="$P_PATH/$P_FE_DIR" be_dir="$P_PATH/$P_BE_DIR"
            install_deps_safely "$fe_dir" || true
            install_deps_safely "$be_dir" || true
            if confirm "Build frontend jika tersedia?"; then build_frontend "$fe_dir" || true; fi
            start_service "$P_NAME" "frontend" "$fe_dir" "$P_FE_PORT" "$P_FE_CMD"
            start_service "$P_NAME" "backend" "$be_dir" "$P_BE_PORT" "$P_BE_CMD"
            ;;
        *)
            msg err "Unknown type: $P_TYPE"
            ;;
    esac

    # health checks (if curl available)
    if require_cmd curl; then
        # check frontend then backend
        if [ -f "$LOG_DIR/${P_NAME}_frontend.port" ]; then hport=$(cat "$LOG_DIR/${P_NAME}_frontend.port") && sleep 1 && health_check "127.0.0.1" "$hport" || true; fi
        if [ -f "$LOG_DIR/${P_NAME}_backend.port" ]; then hport=$(cat "$LOG_DIR/${P_NAME}_backend.port") && sleep 1 && health_check "127.0.0.1" "$hport" || true; fi
    fi

    wait_key
}

stop_project_flow() {
    header
    echo "=== Stop Project ==="
    if ! name=$(select_project_prompt); then wait_key; return; fi
    stop_service "$name" "frontend"
    stop_service "$name" "backend"
    stop_service "$name" "static"
    wait_key
}

status_flow() {
    header
    echo "=== Status Semua Project ==="
    [ ! -f "$CONFIG_FILE" ] && { msg warn "Belum ada project"; wait_key; return; }
    while IFS=$'\t' read -r nm p t _; do
        [ -z "$nm" ] && continue
        echo -e "${BOLD}$nm${X} — $p ($t)"
        for svc in frontend backend static; do
            pidf="$LOG_DIR/${nm}_${svc}.pid"
            portf="$LOG_DIR/${nm}_${svc}.port"
            if [ -f "$pidf" ]; then
                pid=$(cat "$pidf" 2>/dev/null || true)
                port=$(cat "$portf" 2>/dev/null || true)
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
    echo "=== View Logs ==="
    if ! name=$(select_project_prompt); then wait_key; return; fi
    echo "1) Frontend log  2) Backend log  3) Static log  4) Tail all"
    read -rp "Pilih: " c
    case "$c" in
        1) f="$LOG_DIR/${name}_frontend.log" ;;
        2) f="$LOG_DIR/${name}_backend.log" ;;
        3) f="$LOG_DIR/${name}_static.log" ;;
        4) tail -n 200 -f "$LOG_DIR/${name}_frontend.log" "$LOG_DIR/${name}_backend.log" "$LOG_DIR/${name}_static.log"; wait_key; return ;;
        *) msg err "Pilihan invalid"; wait_key; return ;;
    esac
    [ -f "$f" ] && { echo -e "\n--- last 200 lines ---\n"; tail -n 200 "$f"; } || msg warn "Log tidak ditemukan: $f"
    wait_key
}

edit_project_flow() {
    header
    echo "=== Edit Project ==="
    if ! name=$(select_project_prompt); then wait_key; return; fi
    load_project "$name"
    echo "Kosongkan input untuk mempertahankan nilai saat ini."
    read -rp "Nama [$P_NAME]: " n; n=${n:-$P_NAME}
    read -rp "Path [$P_PATH]: " p; p=${p:-$P_PATH}
    read -rp "Type [$P_TYPE]: " t; t=${t:-$P_TYPE}
    read -rp "Frontend dir [$P_FE_DIR]: " fe; fe=${fe:-$P_FE_DIR}
    read -rp "Backend dir [$P_BE_DIR]: " be; be=${be:-$P_BE_DIR}
    read -rp "Frontend port [$P_FE_PORT]: " fp; fp=${fp:-$P_FE_PORT}
    read -rp "Backend port [$P_BE_PORT]: " bp; bp=${bp:-$P_BE_PORT}
    read -rp "Frontend cmd [$P_FE_CMD]: " fcmd; fcmd=${fcmd:-$P_FE_CMD}
    read -rp "Backend cmd [$P_BE_CMD]: " bcmd; bcmd=${bcmd:-$P_BE_CMD}
    read -rp "Auto-sync (0/1) [$P_AUTO_SYNC]: " as; as=${as:-$P_AUTO_SYNC}
    save_project "$n" "$p" "$t" "$fe" "$be" "$fp" "$bp" "$fcmd" "$bcmd" "$as"
    msg ok "Project diperbarui."
    wait_key
}

update_from_git_flow() {
    header
    echo "=== Update from Git ==="
    if ! name=$(select_project_prompt); then wait_key; return; fi
    load_project "$name"
    if [ ! -d "$P_PATH/.git" ]; then msg err "Folder bukan git repo: $P_PATH"; wait_key; return; fi
    (cd "$P_PATH" && git pull --rebase) && msg ok "Git pull selesai" || msg err "Git pull gagal"
    # if original source was /storage, keep copy updated? We'll ensure config points to home copy already.
    wait_key
}

export_config_flow() {
    header
    echo "=== Export Config ==="
    read -rp "File name (output) [dapps-export.json]: " fname; fname=${fname:-dapps-export.json}
    jq -R -s -c 'split("\n")|map(select(length>0))|map(split("\t")|{name:.[0],path:.[1],type:.[2],fe_dir:.[3],be_dir:.[4],fe_port:.[5],be_port:.[6],fe_cmd:.[7],be_cmd:.[8],auto_sync:.[9]})' "$CONFIG_FILE" > "$fname" 2>/dev/null || awk -F'\t' 'BEGIN{print "["}{if(NR>1)print ","; printf("{\"name\":\"%s\",\"path\":\"%s\"}",$1,$2)}END{print "]"}' "$CONFIG_FILE" > "$fname"
    msg ok "Config diexport ke $fname"
    wait_key
}

import_config_flow() {
    header
    echo "=== Import Config ==="
    read -rp "File name (input): " fname
    [ ! -f "$fname" ] && { msg err "File tidak ditemukan"; wait_key; return; }
    # simple importer expects array of objects with keys name,path,type,...
    jq -c '.[]' "$fname" 2>/dev/null | while read -r obj; do
        n=$(echo "$obj" | jq -r '.name'); p=$(echo "$obj" | jq -r '.path'); t=$(echo "$obj" | jq -r '.type'); fe=$(echo "$obj" | jq -r '.fe_dir'); be=$(echo "$obj" | jq -r '.be_dir'); fp=$(echo "$obj" | jq -r '.fe_port'); bp=$(echo "$obj" | jq -r '.be_port'); fcmd=$(echo "$obj" | jq -r '.fe_cmd'); bcmd=$(echo "$obj" | jq -r '.be_cmd'); as=$(echo "$obj" | jq -r '.auto_sync')
        save_project "$n" "$p" "$t" "$fe" "$be" "$fp" "$bp" "$fcmd" "$bcmd" "$as"
    done
    msg ok "Import selesai"
    wait_key
}

self_update_flow() {
    header
    echo "=== Update Launcher ==="
    if ! require_cmd curl && ! require_cmd wget; then msg err "curl/wget tidak ada"; wait_key; return; fi
    local url="https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh"
    tmp="$(mktemp -t dapps_update.XXXXXX)" || tmp="/tmp/dapps_update.$$"
    if require_cmd curl; then curl -fsSL "$url" -o "$tmp" || { msg err "Download gagal"; rm -f "$tmp"; wait_key; return; }; else wget -qO "$tmp" "$url" || { msg err "Download gagal"; rm -f "$tmp"; wait_key; return; }; fi
    sed -i "1c #!/data/data/com.termux/files/usr/bin/bash" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" "$PREFIX/bin/dapps"
    chmod +x "$PREFIX/bin/dapps"
    msg ok "Launcher diperbarui di $PREFIX/bin/dapps"
    wait_key
}

uninstall_flow() {
    header
    echo "=== Uninstall Launcher ==="
    if confirm "Yakin uninstall launcher?"; then
        rm -f "$PREFIX/bin/dapps" || true
        msg ok "Uninstalled (binary removed). Manual: hapus $PROJECTS_DIR / logs jika perlu."
    else
        msg info "Batal uninstall."
    fi
    wait_key
}

# ----------------------------------------------------------------------------
# MAIN MENU
# ----------------------------------------------------------------------------
main_menu() {
    while true; do
        header
        echo "1) ▶️  Jalankan Project"
        echo "2) ⏹️  Stop Project"
        echo "3) ➕ Tambah Project"
        echo "4) ✏️  Edit Project"
        echo "5) 📦 Install/Update Dependencies"
        echo "6) 🔁 Update dari Git"
        echo "7) 📊 Status Semua Project"
        echo "8) 📝 Lihat Logs"
        echo "9) ⚙️  Export Config"
        echo "10) 🔄 Import Config"
        echo "11) 🔍 Health Check"
        echo "12) 🔁 Self-update Launcher"
        echo "13) 🧹 Clean project node_modules (hapus)"
        echo "14) 🧱 Build Frontend"
        echo "15) 🚨 Watch & Auto-sync (background)"
        echo "99) ❌ Uninstall Launcher"
        echo "0) 🚪 Keluar"
        read -rp $'\n''Pilih menu: ' choice
        case "$choice" in
            1) run_project_flow ;;
            2) stop_project_flow ;;
            3) add_project_interactive ;;
            4) edit_project_flow ;;
            5)
                if ! name=$(select_project_prompt); then wait_key; else load_project "$name"; install_deps_safely "$P_PATH/$P_FE_DIR" || true; install_deps_safely "$P_PATH/$P_BE_DIR" || true; wait_key; fi
                ;;
            6) update_from_git_flow ;;
            7) status_flow ;;
            8) logs_flow ;;
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
                if ! name=$(select_project_prompt); then wait_key; else load_project "$name"; read -rp "Hapus node_modules di semua folder project? (y/N): " yn; [[ "$yn" =~ ^[Yy]$ ]] && { rm -rf "$P_PATH/node_modules" "$P_PATH/$P_FE_DIR/node_modules" "$P_PATH/$P_BE_DIR/node_modules"; msg ok "node_modules dihapus"; } fi
                wait_key
                ;;
            14)
                if ! name=$(select_project_prompt); then wait_key; else load_project "$name"; build_frontend "$P_PATH/$P_FE_DIR"; fi
                wait_key
                ;;
            15)
                if ! name=$(select_project_prompt); then wait_key; else load_project "$name"; read -rp "Sumber to watch (path): " src; src=${src:-$P_PATH}; (watch_and_sync "$src" "$P_NAME" 3 &>/dev/null &) && msg ok "Watch background started" || msg warn "Gagal start watch"; wait_key; fi
                ;;
            99) uninstall_flow ;;
            0) header; msg info "Keluar..."; exit 0 ;;
            *) msg err "Pilihan invalid"; wait_key ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Entrypoint
# ----------------------------------------------------------------------------
check_deps() {
    for c in node npm git; do require_cmd "$c" || msg warn "Missing: $c"; done
}
check_deps
main_menu

# End of file
