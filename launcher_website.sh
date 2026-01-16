#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher - Improved v2.1.0
# Platform: Android Termux
# Tujuan: Launcher yang lebih berguna untuk developer (multi-start command,
#        auto-detect package manager, update from git, sync, restart, tail logs)
# Note: Designed to be installed once (see installer snippet below) as `dapps`.
# ============================================================================

set -euo pipefail

# ---------------------------
# Configuration (ubah sesuai kebutuhan)
# ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROJECTS_DIR="${HOME:-$HOME}/dapps-projects"
CONFIG_FILE="${HOME:-$HOME}/.dapps.conf"
LOG_DIR="${HOME:-$HOME}/.dapps-logs"
LAUNCHER_VERSION="2.1.0"

# Colors
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; C="\033[36m"; X="\033[0m"; BOLD="\033[1m"

# Ensure dirs
mkdir -p "$PROJECTS_DIR" "$LOG_DIR"
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

header() {
    clear
    echo -e "${C}${BOLD}╔════════════════════════════════════════════════════════╗${X}"
    echo -e "${C}${BOLD}║        DApps Localhost Launcher — Improved v${LAUNCHER_VERSION}        ║${X}"
    echo -e "${C}${BOLD}╚════════════════════════════════════════════════════════╝${X}\n"
}

wait_key() {
    echo -e "\n${C}Tekan ENTER untuk kembali...${X}"
    read -r
}

confirm() {
    # confirm "Pesan"
    read -rp "$1 (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------
# Config format (per baris):
# name|path|fe_dir|be_dir|fe_port|be_port|fe_cmd|be_cmd|auto_restart
# - fe_cmd / be_cmd : custom start command (jika kosong pakai default)
# - auto_restart : 0/1
# ---------------------------

save_project() {
    local name="$1" path="$2" fe_dir="$3" be_dir="$4" fe_port="$5" be_port="$6" fe_cmd="$7" be_cmd="$8" auto_restart="$9"
    # remove old
    grep -v "^$name|" "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true
    echo "$name|$path|$fe_dir|$be_dir|$fe_port|$be_port|$fe_cmd|$be_cmd|$auto_restart" >> "$CONFIG_FILE"
}

load_project() {
    local name="$1"
    local line
    line=$(grep "^$name|" "$CONFIG_FILE" 2>/dev/null | head -n1 || true)
    [ -z "$line" ] && return 1
    IFS='|' read -r PROJECT_NAME PROJECT_PATH FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD AUTO_RESTART <<< "$line"
    return 0
}

list_projects() {
    [ ! -f "$CONFIG_FILE" ] && return 1
    local num=1
    while IFS='|' read -r name _; do
        [ -z "$name" ] && continue
        local status="❌"
        [ -d "$(echo "$line" | cut -d'|' -f2)" ] # no-op to satisfy shellcheck
        [ -d "$PROJECTS_DIR/$name" ] && status="✅"
        echo "$num. $status $name"
        num=$((num+1))
    done < "$CONFIG_FILE"
}

# Better listing for menus (with status)
list_projects_verbose() {
    [ ! -f "$CONFIG_FILE" ] && return 1
    local num=1
    while IFS='|' read -r name path _; do
        [ -z "$name" ] && continue
        local status="❌"
        [ -d "$path" ] && status="✅"
        echo "$num) $status $name — $path"
        num=$((num+1))
    done < "$CONFIG_FILE"
}

# ---------------------------
# Dependency checks
# ---------------------------
check_deps() {
    local needed=(node npm git netstat)
    local missing=()
    for cmd in "${needed[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        msg warn "Beberapa dependency tidak ada: ${missing[*]}"
        msg info "Install yang diperlukan (node, git, net-tools/netstat) sebelum lanjut."
        return 1
    fi
    return 0
}

# ---------------------------
# Port utilities
# ---------------------------
get_available_port() {
    local port="$1"
    local max_tries=100
    for i in $(seq 0 $max_tries); do
        local test_port=$((port + i))
        if ! netstat -tuln 2>/dev/null | grep -q ":$test_port[[:space:]]"; then
            echo "$test_port"
            return 0
        fi
    done
    return 1
}

# ---------------------------
# Service control
# ---------------------------
start_service() {
    local proj="$1" dir="$2" port="$3" cmd="$4" label="$5"
    local pid_file="$LOG_DIR/${proj}_${label}.pid"
    local log_file="$LOG_DIR/${proj}_${label}.log"
    local port_file="$LOG_DIR/${proj}_${label}.port"

    # if already running, report
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg warn "$label sudah running (PID: $pid)"
            return 0
        fi
        rm -f "$pid_file" || true
    fi

    local full_path="$PROJECT_PATH/$dir"
    [ ! -d "$full_path" ] && { msg err "$label folder tidak ada: $full_path"; return 1; }

    local final_port
    final_port="$(get_available_port "$port")" || { msg err "Tidak ada port tersedia mulai $port"; return 1; }
    [ "$final_port" != "$port" ] && msg warn "Port $port digunakan, pakai $final_port"

    msg info "Starting $label di $full_path (port $final_port)..."

    # export port to environment for npm scripts that use $PORT
    (cd "$full_path" || exit 1
        # load .env if present
        [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a
        PORT="$final_port"
        # record started process with nohup, disown
        nohup bash -lc "PORT=$PORT $cmd" > "$log_file" 2>&1 &
        echo $! > "$pid_file"
        echo "$final_port" > "$port_file"
    )

    sleep 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        msg ok "$label started (PID: $pid, Port: $final_port)"
        return 0
    else
        msg err "$label gagal start. Cek log: $log_file"
        rm -f "$pid_file" "$port_file" || true
        return 1
    fi
}

stop_service() {
    local proj="$1" label="$2"
    local pid_file="$LOG_DIR/${proj}_${label}.pid"
    local port_file="$LOG_DIR/${proj}_${label}.port"

    if [ ! -f "$pid_file" ]; then
        msg info "$label tidak running"
        return 0
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -z "$pid" ]; then
        rm -f "$pid_file" "$port_file" || true
        msg info "$label: PID file kosong, dihapus"
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        msg info "$label tidak berjalan (PID tidak valid), membersihkan file"
        rm -f "$pid_file" "$port_file" || true
        return 0
    fi

    msg info "Stopping $label (PID: $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$pid_file" "$port_file" || true
    msg ok "$label stopped"
}

# monitor and restart (background supervisor) - optional simple implementation
supervise_service() {
    local proj="$1" label="$2" dir="$3" port="$4" cmd="$5"
    local pid_file="$LOG_DIR/${proj}_${label}.pid"
    local log_file="$LOG_DIR/${proj}_${label}.log"
    local port_file="$LOG_DIR/${proj}_${label}.port"
    (
        # run forever until pid file removed (stop_service removes pid file)
        while true; do
            # if pid exists and process alive -> sleep
            if [ -f "$pid_file" ]; then
                local pid
                pid=$(cat "$pid_file" 2>/dev/null || true)
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    sleep 2
                    continue
                fi
            fi
            # try start
            start_service "$proj" "$dir" "$port" "$cmd" "$label" || {
                sleep 2
                continue
            }
            # now wait for process to exit
            local pid
            pid=$(cat "$pid_file" 2>/dev/null || true)
            while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
                sleep 2
                pid=$(cat "$pid_file" 2>/dev/null || true)
            done
            # if pid_file still exists, loop to restart
            sleep 1
        done
    ) &
    # supervise runs in background; its pid is not tracked separately (supervisor stops when pid file removed)
}

# ---------------------------
# Utilities: detect package manager & default commands
# ---------------------------
detect_pkg_manager() {
    # prefer pnpm -> yarn -> npm
    if command -v pnpm &>/dev/null; then echo "pnpm"
    elif command -v yarn &>/dev/null; then echo "yarn"
    else echo "npm"; fi
}

detect_start_command() {
    # arguments: project_dir type(frontend/backend)
    local pdir="$1" type="$2"
    if [ -f "$pdir/package.json" ]; then
        local has_script
        has_script=$(node -e "const p=require('$pdir/package.json'); console.log(!!(p.scripts && p.scripts.dev || p.scripts && p.scripts.start))" 2>/dev/null || true)
        if [ "$has_script" = "true" ]; then
            # prefer dev script
            local has_dev
            has_dev=$(node -e "const p=require('$pdir/package.json'); console.log(!!(p.scripts && p.scripts.dev))" 2>/dev/null || true)
            if [ "$has_dev" = "true" ]; then
                echo "npm run dev"
                return
            fi
            echo "npm start"
            return
        fi
    fi
    # fallback: simple python http.server or static serve
    if command -v serve &>/dev/null; then
        echo "serve -s . -l \$PORT"
    elif command -v python &>/dev/null; then
        echo "python -m http.server \$PORT"
    else
        echo ""
    fi
}

# ---------------------------
# Project flows
# ---------------------------
add_project() {
    header
    echo -e "${BOLD}═══ Tambah Project Baru ═══${X}\n"
    read -rp "Nama project: " name
    [ -z "$name" ] && { msg err "Nama tidak boleh kosong"; wait_key; return; }
    if grep -q "^$name|" "$CONFIG_FILE" 2>/dev/null; then
        msg err "Project '$name' sudah ada!"
        wait_key; return
    fi

    echo -e "\nPilih sumber:"
    echo "1) Clone dari GitHub"
    echo "2) Gunakan folder lokal yang sudah ada"
    read -rp "Pilih (1/2): " source

    local project_path=""
    case "$source" in
        1)
            read -rp "Git URL: " git_url
            [ -z "$git_url" ] && { msg err "URL kosong"; wait_key; return; }
            project_path="$PROJECTS_DIR/$name"
            msg info "Cloning..."
            git clone "$git_url" "$project_path" || { msg err "Clone gagal"; wait_key; return; }
            msg ok "Clone sukses: $project_path"
            ;;
        2)
            read -rp "Path folder (contoh: $HOME/my-project): " project_path
            [ -z "$project_path" ] && { msg err "Path kosong"; wait_key; return; }
            [ ! -d "$project_path" ] && { msg err "Folder tidak ditemukan"; wait_key; return; }
            ;;
        *)
            msg err "Pilihan tidak valid"; wait_key; return
            ;;
    esac

    read -rp "Folder frontend [frontend]: " fe_dir; fe_dir=${fe_dir:-frontend}
    read -rp "Folder backend [backend]: " be_dir; be_dir=${be_dir:-backend}
    read -rp "Port frontend [3000]: " fe_port; fe_port=${fe_port:-3000}
    read -rp "Port backend [8000]: " be_port; be_port=${be_port:-8000}

    # detect default commands
    local fe_full="$project_path/$fe_dir"
    local be_full="$project_path/$be_dir"
    local fe_cmd="" be_cmd=""
    fe_cmd=$(detect_start_command "$fe_full" "frontend" || true)
    be_cmd=$(detect_start_command "$be_full" "backend" || true)
    [ -z "$fe_cmd" ] && fe_cmd="npm run dev"
    [ -z "$be_cmd" ] && be_cmd="npm start"

    read -rp "Custom frontend command [$fe_cmd]: " tmp; [ -n "$tmp" ] && fe_cmd="$tmp"
    read -rp "Custom backend command  [$be_cmd]: " tmp; [ -n "$tmp" ] && be_cmd="$tmp"
    read -rp "Auto-restart on crash? (y/N): " tmp; auto_restart=0
    [[ "$tmp" =~ ^[Yy]$ ]] && auto_restart=1

    save_project "$name" "$project_path" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_restart"
    msg ok "Project '$name' disimpan."
    if confirm "Install dependencies sekarang?"; then
        install_deps "$name"
    fi
    wait_key
}

install_deps() {
    local name="$1"
    load_project "$name" || { msg err "Project tidak ditemukan"; return 1; }
    msg info "Installing dependencies untuk $PROJECT_NAME..."
    for spec in "Frontend:$FE_DIR:$FE_PORT:$FE_CMD" "Backend:$BE_DIR:$BE_PORT:$BE_CMD"; do
        local label=${spec%%:*}
        local dir=${spec#*:}; dir=${dir%%:*}
        local full="$PROJECT_PATH/$dir"
        if [ -d "$full" ] && [ -f "$full/package.json" ]; then
            msg info "Installing $label..."
            (cd "$full" && detect_pkg_manager >/dev/null 2>&1 && $(detect_pkg_manager) install) || {
                msg warn "$label install failed"
                continue
            }
            msg ok "$label dependencies installed"
        else
            msg warn "$label tidak ditemukan atau tidak ada package.json"
        fi
    done
}

run_project() {
    header
    echo -e "${BOLD}═══ Pilih Project untuk Dijalankan ═══${X}\n"
    local projects
    projects=$(list_projects_verbose)
    if [ -z "$projects" ]; then msg warn "Belum ada project"; wait_key; return; fi
    echo "$projects"
    read -rp $'\n''Pilih nomor: ' num
    local selected
    selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    load_project "$selected" || { msg err "Gagal load project"; wait_key; return; }

    header
    echo -e "${BOLD}═══ Running: $PROJECT_NAME ═══${X}\n"

    # Validate paths
    if [ ! -d "$PROJECT_PATH" ]; then
        msg err "Project folder tidak ditemukan: $PROJECT_PATH"
        wait_key; return
    fi

    # Ask to install deps if node_modules missing
    local fe_path="$PROJECT_PATH/$FE_DIR" be_path="$PROJECT_PATH/$BE_DIR"
    if [ -d "$fe_path" ] && [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then
        if confirm "Frontend dependencies belum terinstall. Install sekarang?"; then install_deps "$PROJECT_NAME"; fi
    fi
    if [ -d "$be_path" ] && [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then
        if confirm "Backend dependencies belum terinstall. Install sekarang?"; then install_deps "$PROJECT_NAME"; fi
    fi

    # start services (frontend then backend)
    start_service "$PROJECT_NAME" "$FE_DIR" "$FE_PORT" "$FE_CMD" "frontend" || true
    start_service "$PROJECT_NAME" "$BE_DIR" "$BE_PORT" "$BE_CMD" "backend" || true

    # start supervisors if auto_restart enabled
    if [ "${AUTO_RESTART:-0}" = "1" ]; then
        supervise_service "$PROJECT_NAME" "frontend" "$FE_DIR" "$FE_PORT" "$FE_CMD"
        supervise_service "$PROJECT_NAME" "backend" "$BE_DIR" "$BE_PORT" "$BE_CMD"
        msg info "Auto-restart aktif untuk $PROJECT_NAME"
    fi

    # Show URLs
    echo -e "\n${BOLD}${G}═══ Akses URLs ═══${X}"
    [ -f "$LOG_DIR/${PROJECT_NAME}_frontend.port" ] && {
        local p; p=$(cat "$LOG_DIR/${PROJECT_NAME}_frontend.port")
        echo -e "Frontend: ${C}http://127.0.0.1:$p${X}"
    } || echo "Frontend: -"
    [ -f "$LOG_DIR/${PROJECT_NAME}_backend.port" ] && {
        local p; p=$(cat "$LOG_DIR/${PROJECT_NAME}_backend.port")
        echo -e "Backend:  ${C}http://127.0.0.1:$p${X}"
    } || echo "Backend: -"

    wait_key
}

stop_project() {
    header
    echo -e "${BOLD}═══ Stop Running Project ═══${X}\n"
    local projects
    projects=$(list_projects_verbose)
    [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
    echo "$projects"
    read -rp $'\n''Pilih nomor: ' num
    local selected
    selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    load_project "$selected" || { msg err "Gagal load project"; wait_key; return; }
    stop_service "$PROJECT_NAME" "frontend"
    stop_service "$PROJECT_NAME" "backend"
    wait_key
}

show_status() {
    header
    echo -e "${BOLD}═══ Status Semua Project ═══${X}\n"
    [ ! -f "$CONFIG_FILE" ] && { msg warn "Belum ada project"; wait_key; return; }
    while IFS='|' read -r name path _; do
        [ -z "$name" ] && continue
        echo -e "${BOLD}$name${X}"
        for svc in "frontend" "backend"; do
            local pid_file="$LOG_DIR/${name}_${svc}.pid"
            local port_file="$LOG_DIR/${name}_${svc}.port"
            if [ -f "$pid_file" ]; then
                local pid port
                pid=$(cat "$pid_file" 2>/dev/null || true)
                port=$(cat "$port_file" 2>/dev/null || true)
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    echo -e "  ${G}● $svc${X} running (PID: $pid, Port: $port)"
                else
                    echo -e "  ${Y}○ $svc${X} stopped (stale pid cleaned)"
                    rm -f "$pid_file" "$port_file" || true
                fi
            else
                echo -e "  ${R}○ $svc${X} stopped"
            fi
        done
        echo ""
    done < "$CONFIG_FILE"
    wait_key
}

view_logs() {
    header
    echo -e "${BOLD}═══ View Logs ═══${X}\n"
    local projects
    projects=$(list_projects_verbose)
    [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
    echo "$projects"
    read -rp $'\n''Pilih project: ' num
    local selected
    selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    header
    echo -e "${BOLD}═══ Logs: $selected ═══${X}\n"
    echo "1) Frontend log"
    echo "2) Backend log"
    echo "3) Tail all (follow)"
    read -rp "Pilih: " choice
    case "$choice" in
        1) log="$LOG_DIR/${selected}_frontend.log" ;;
        2) log="$LOG_DIR/${selected}_backend.log" ;;
        3)
            echo -e "${BOLD}Follow mode (CTRL+C to stop)${X}\n"
            tail -n 100 -f "$LOG_DIR/${selected}_frontend.log" "$LOG_DIR/${selected}_backend.log"
            wait_key; return
            ;;
        *) msg err "Pilihan tidak valid"; wait_key; return ;;
    esac
    if [ -f "$log" ]; then
        echo -e "\n${BOLD}═══ Last 200 lines ═══${X}\n"
        tail -n 200 "$log" || true
    else
        msg warn "Log file tidak ditemukan: $log"
    fi
    wait_key
}

edit_project() {
    header
    echo -e "${BOLD}═══ Edit Project ═══${X}\n"
    local projects
    projects=$(list_projects_verbose)
    [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
    echo "$projects"
    read -rp $'\n''Pilih nomor: ' num
    local selected
    selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    load_project "$selected" || { msg err "Gagal load project"; wait_key; return; }
    echo -e "Edit nilai kosong untuk tetap sama\n"
    read -rp "Nama project [$PROJECT_NAME]: " name; name=${name:-$PROJECT_NAME}
    read -rp "Path project [$PROJECT_PATH]: " path; path=${path:-$PROJECT_PATH}
    read -rp "Folder frontend [$FE_DIR]: " fe_dir; fe_dir=${fe_dir:-$FE_DIR}
    read -rp "Folder backend  [$BE_DIR]: " be_dir; be_dir=${be_dir:-$BE_DIR}
    read -rp "Port frontend [$FE_PORT]: " fe_port; fe_port=${fe_port:-$FE_PORT}
    read -rp "Port backend  [$BE_PORT]: " be_port; be_port=${be_port:-$BE_PORT}
    read -rp "Custom frontend command [$FE_CMD]: " fe_cmd; fe_cmd=${fe_cmd:-$FE_CMD}
    read -rp "Custom backend command  [$BE_CMD]: " be_cmd; be_cmd=${be_cmd:-$BE_CMD}
    read -rp "Auto-restart (y/N) [${AUTO_RESTART:-0}]: " tmp
    auto_restart=0; [[ "$tmp" =~ ^[Yy]$ ]] && auto_restart=1
    # save (delete old)
    save_project "$name" "$path" "$fe_dir" "$be_dir" "$fe_port" "$be_port" "$fe_cmd" "$be_cmd" "$auto_restart"
    msg ok "Project diperbarui."
    wait_key
}

update_from_git() {
    header
    echo -e "${BOLD}═══ Update Project dari Git ═══${X}\n"
    local projects
    projects=$(list_projects_verbose)
    [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
    echo "$projects"
    read -rp $'\n''Pilih nomor: ' num
    local selected
    selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    load_project "$selected" || { msg err "Gagal load project"; wait_key; return; }
    if [ ! -d "$PROJECT_PATH/.git" ]; then msg err "Folder bukan repo git"; wait_key; return; fi
    (cd "$PROJECT_PATH" && git pull --rebase) && msg ok "Git pull selesai" || msg err "Git pull gagal"
    wait_key
}

create_scaffold() {
    header
    echo -e "${BOLD}═══ Create Project Scaffold (simple) ═══${X}\n"
    read -rp "Nama project baru: " name
    [ -z "$name" ] && { msg err "Nama kosong"; wait_key; return; }
    read -rp "Init git? (y/N): " initgit; initgit=${initgit:-N}
    local dir="$PROJECTS_DIR/$name"
    mkdir -p "$dir/frontend" "$dir/backend"
    echo "{}" > "$dir/frontend/package.json"
    echo "{}" > "$dir/backend/package.json"
    if [[ "$initgit" =~ ^[Yy]$ ]]; then
        (cd "$dir" && git init >/dev/null 2>&1)
    fi
    save_project "$name" "$dir" "frontend" "backend" "3000" "8000" "npm run dev" "npm start" "0"
    msg ok "Scaffold $name dibuat di $dir"
    wait_key
}

export_config() {
    header
    echo -e "${BOLD}═══ Export Config ═══${X}\n"
    read -rp "Nama file export (contoh: dapps-export.json): " fname
    [ -z "$fname" ] && { msg err "Nama file kosong"; wait_key; return; }
    jq -R -s -c 'split("\n") | map(select(length>0)) | map(split("|") | {
        name: .[0],
        path: .[1],
        fe_dir: .[2],
        be_dir: .[3],
        fe_port: .[4],
        be_port: .[5],
        fe_cmd: .[6],
        be_cmd: .[7],
        auto_restart: .[8]
    })' "$CONFIG_FILE" > "$fname" 2>/dev/null || {
        # fallback simple transform if jq not available
        awk -F'|' 'NF>=1{printf("{\"name\":\"%s\",\"path\":\"%s\"}\n",$1,$2)}' "$CONFIG_FILE" > "$fname"
    }
    msg ok "Config diexport ke $fname"
    wait_key
}

# ---------------------------
# Self-update & uninstall helpers (if script installed into $PREFIX/bin/dapps)
# ---------------------------
self_update() {
    header
    echo -e "${BOLD}═══ Update Launcher dari GitHub ═══${X}\n"
    local url="https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh"
    local tmp
    tmp="$(mktemp -t dapps_update.XXXXXX)" || tmp="/tmp/dapps_update.$$"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$tmp" || { msg err "Download gagal"; rm -f "$tmp"; wait_key; return; }
    else
        wget -qO "$tmp" "$url" || { msg err "Download gagal (wget)"; rm -f "$tmp"; wait_key; return; }
    fi
    # normalize shebang
    sed -i "1c #!/data/data/com.termux/files/usr/bin/bash" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" "$PREFIX/bin/dapps"
    chmod +x "$PREFIX/bin/dapps"
    msg ok "Launcher diperbarui."
    wait_key
}

self_uninstall() {
    header
    echo -e "${BOLD}═══ Uninstall DApps Launcher ═══${X}\n"
    if confirm "Yakin uninstall launcher dan helper?"; then
        rm -f "$PREFIX/bin/dapps" "$PREFIX/bin/dapps-update" "$PREFIX/bin/dapps-uninstall" || true
        msg ok "Uninstalled."
    else
        msg info "Dibatalkan."
    fi
    wait_key
}

# ---------------------------
# Main menu
# ---------------------------
show_menu() {
    header
    echo -e "${BOLD}MENU UTAMA${X}\n"
    echo "1. ▶️  Jalankan Project"
    echo "2. ⏹️  Stop Project"
    echo "3. ➕ Tambah Project Baru"
    echo "4. 🛠️  Edit Project"
    echo "5. 📦 Install/Update Dependencies"
    echo "6. 🔄 Update Project dari Git"
    echo "7. 📊 Status Semua Project"
    echo "8. 📝 Lihat Logs"
    echo "9. ✨ Create Scaffold (baru)"
    echo "10. 🔁 Export Config"
    echo "11. ⬆️  Update Launcher (self-update)"
    echo "12. 🗑️  Uninstall Launcher"
    echo "0. 🚪 Keluar"
    echo -e "\n${BOLD}════════════════════════════════════${X}"
    read -rp "Pilih menu (0-12): " choice
    case "$choice" in
        1) run_project ;;
        2) stop_project ;;
        3) add_project ;;
        4) edit_project ;;
        5)
            header
            local projects
            projects=$(list_projects_verbose)
            [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
            echo "$projects"
            read -rp $'\n''Pilih project: ' num
            local selected
            selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
            [ -n "$selected" ] && install_deps "$selected"
            wait_key
            ;;
        6) update_from_git ;;
        7) show_status ;;
        8) view_logs ;;
        9) create_scaffold ;;
        10) export_config ;;
        11) self_update ;;
        12) self_uninstall ;;
        0)
            header
            msg info "Terima kasih! Keluar..."
            exit 0
            ;;
        *) msg err "Pilihan tidak valid"; wait_key ;;
    esac
}

# Entry point
if ! check_deps; then
    msg warn "Some dependencies are missing — beberapa fitur mungkin terbatas."
fi

# If script executed from installer context, allow running directly as installed
show_menu

# End of file
