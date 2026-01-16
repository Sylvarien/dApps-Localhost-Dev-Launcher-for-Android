#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher - Simple & Fast
# ============================================================================
# Version: 2.0.0
# Platform: Android Termux
# No loops, no hang, just simple menu execution
# ============================================================================

# Config
PROJECTS_DIR="$HOME/dapps-projects"
CONFIG_FILE="$HOME/.dapps.conf"
LOG_DIR="$HOME/.dapps-logs"

# Colors
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; C="\033[36m"; X="\033[0m"; BOLD="\033[1m"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

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
    echo -e "${C}${BOLD}╔══════════════════════════════════════════╗${X}"
    echo -e "${C}${BOLD}║     DApps Localhost Launcher v2.0       ║${X}"
    echo -e "${C}${BOLD}╚══════════════════════════════════════════╝${X}\n"
}

wait_key() {
    echo -e "\n${C}Tekan ENTER untuk kembali...${X}"
    read
}

check_deps() {
    for cmd in node npm git; do
        if ! command -v $cmd &>/dev/null; then
            msg warn "$cmd belum terinstall. Installing..."
            pkg install -y nodejs git || { msg err "Gagal install $cmd"; return 1; }
        fi
    done
    msg ok "Dependencies OK"
}

# ============================================================================
# PROJECT DATABASE
# ============================================================================

save_project() {
    local name="$1" path="$2" fe_dir="$3" be_dir="$4" fe_port="$5" be_port="$6"
    
    # Hapus entry lama jika ada
    if [ -f "$CONFIG_FILE" ]; then
        grep -v "^$name|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null
    fi
    
    # Simpan entry baru
    echo "$name|$path|$fe_dir|$be_dir|$fe_port|$be_port" >> "$CONFIG_FILE"
}

load_project() {
    local name="$1"
    local line=$(grep "^$name|" "$CONFIG_FILE" 2>/dev/null | head -1)
    
    [ -z "$line" ] && return 1
    
    PROJECT_NAME=$(echo "$line" | cut -d'|' -f1)
    PROJECT_PATH=$(echo "$line" | cut -d'|' -f2)
    FE_DIR=$(echo "$line" | cut -d'|' -f3)
    BE_DIR=$(echo "$line" | cut -d'|' -f4)
    FE_PORT=$(echo "$line" | cut -d'|' -f5)
    BE_PORT=$(echo "$line" | cut -d'|' -f6)
    
    return 0
}

list_projects() {
    [ ! -f "$CONFIG_FILE" ] && return 1
    
    local num=1
    while IFS='|' read -r name path _; do
        [ -z "$name" ] && continue
        local status="❌"
        [ -d "$path" ] && status="✅"
        echo "$num. $status $name"
        num=$((num+1))
    done < "$CONFIG_FILE"
}

# ============================================================================
# ADD NEW PROJECT
# ============================================================================

add_project() {
    header
    echo -e "${BOLD}═══ Tambah Project Baru ═══${X}\n"
    
    echo -n "Nama project: "
    read name
    [ -z "$name" ] && { msg err "Nama tidak boleh kosong"; wait_key; return; }
    
    if grep -q "^$name|" "$CONFIG_FILE" 2>/dev/null; then
        msg err "Project '$name' sudah ada!"
        wait_key
        return
    fi
    
    echo -e "\n${BOLD}Pilih sumber:${X}"
    echo "1. Clone dari GitHub"
    echo "2. Gunakan folder lokal yang sudah ada"
    echo -n "Pilih (1/2): "
    read source
    
    case "$source" in
        1)
            echo -n "Git URL: "
            read git_url
            [ -z "$git_url" ] && { msg err "URL tidak boleh kosong"; wait_key; return; }
            
            local project_path="$PROJECTS_DIR/$name"
            msg info "Cloning repository..."
            
            git clone "$git_url" "$project_path" || {
                msg err "Clone gagal!"
                wait_key
                return
            }
            msg ok "Repository berhasil di-clone"
            ;;
        2)
            echo -n "Path folder (contoh: $HOME/my-project): "
            read project_path
            [ -z "$project_path" ] && { msg err "Path tidak boleh kosong"; wait_key; return; }
            [ ! -d "$project_path" ] && { msg err "Folder tidak ditemukan!"; wait_key; return; }
            ;;
        *)
            msg err "Pilihan tidak valid"
            wait_key
            return
            ;;
    esac
    
    # Konfigurasi directories
    echo -e "\n${BOLD}Konfigurasi folder:${X}"
    echo -n "Folder frontend [frontend]: "
    read fe_dir
    [ -z "$fe_dir" ] && fe_dir="frontend"
    
    echo -n "Folder backend [backend]: "
    read be_dir
    [ -z "$be_dir" ] && be_dir="backend"
    
    echo -n "Port frontend [3000]: "
    read fe_port
    [ -z "$fe_port" ] && fe_port="3000"
    
    echo -n "Port backend [8000]: "
    read be_port
    [ -z "$be_port" ] && be_port="8000"
    
    # Simpan konfigurasi
    save_project "$name" "$project_path" "$fe_dir" "$be_dir" "$fe_port" "$be_port"
    
    msg ok "Project '$name' berhasil ditambahkan!"
    
    # Install dependencies
    echo -n "\nInstall dependencies sekarang? (y/n): "
    read install
    if [[ "$install" =~ ^[Yy]$ ]]; then
        install_deps "$name"
    fi
    
    wait_key
}

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================

install_deps() {
    local name="$1"
    
    load_project "$name" || { msg err "Project tidak ditemukan"; return; }
    
    msg info "Installing dependencies untuk $PROJECT_NAME..."
    
    for dir_type in "Frontend:$FE_DIR" "Backend:$BE_DIR"; do
        local label=$(echo "$dir_type" | cut -d: -f1)
        local dir=$(echo "$dir_type" | cut -d: -f2)
        local full_path="$PROJECT_PATH/$dir"
        
        if [ -d "$full_path" ] && [ -f "$full_path/package.json" ]; then
            msg info "Installing $label..."
            cd "$full_path" || continue
            
            npm install || {
                msg warn "$label install failed"
                cd - >/dev/null
                continue
            }
            
            cd - >/dev/null
            msg ok "$label dependencies installed"
        else
            msg warn "$label tidak ditemukan atau tidak ada package.json"
        fi
    done
}

# ============================================================================
# START/STOP SERVICES
# ============================================================================

get_available_port() {
    local port="$1"
    local max_tries=20
    
    for i in $(seq 0 $max_tries); do
        local test_port=$((port + i))
        if ! netstat -tuln 2>/dev/null | grep -q ":$test_port "; then
            echo "$test_port"
            return 0
        fi
    done
    return 1
}

start_service() {
    local name="$1" dir="$2" port="$3" cmd="$4" label="$5"
    
    local pid_file="$LOG_DIR/${name}_${label}.pid"
    local log_file="$LOG_DIR/${name}_${label}.log"
    local port_file="$LOG_DIR/${name}_${label}.port"
    
    # Check jika sudah running
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            msg warn "$label sudah running (PID: $pid)"
            return 0
        fi
        rm -f "$pid_file"
    fi
    
    local full_path="$PROJECT_PATH/$dir"
    [ ! -d "$full_path" ] && { msg warn "$label folder tidak ada"; return 1; }
    
    # Cari port yang available
    local final_port=$(get_available_port "$port")
    [ -z "$final_port" ] && { msg err "Tidak ada port tersedia"; return 1; }
    
    [ "$final_port" != "$port" ] && msg warn "Port $port digunakan, pakai port $final_port"
    
    msg info "Starting $label pada port $final_port..."
    
    cd "$full_path" || return 1
    
    # Load .env jika ada
    [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a
    
    # Start dengan nohup
    PORT=$final_port nohup $cmd > "$log_file" 2>&1 &
    local pid=$!
    
    echo "$pid" > "$pid_file"
    echo "$final_port" > "$port_file"
    
    cd - >/dev/null
    
    sleep 2
    
    if kill -0 "$pid" 2>/dev/null; then
        msg ok "$label started (PID: $pid, Port: $final_port)"
        return 0
    else
        msg err "$label gagal start. Cek log: $log_file"
        rm -f "$pid_file" "$port_file"
        return 1
    fi
}

stop_service() {
    local name="$1" label="$2"
    
    local pid_file="$LOG_DIR/${name}_${label}.pid"
    local port_file="$LOG_DIR/${name}_${label}.port"
    
    if [ ! -f "$pid_file" ]; then
        msg info "$label tidak running"
        return 0
    fi
    
    local pid=$(cat "$pid_file")
    
    if ! kill -0 "$pid" 2>/dev/null; then
        msg info "$label tidak running"
        rm -f "$pid_file" "$port_file"
        return 0
    fi
    
    msg info "Stopping $label (PID: $pid)..."
    
    kill "$pid" 2>/dev/null
    sleep 1
    
    # Force kill jika masih hidup
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    
    rm -f "$pid_file" "$port_file"
    msg ok "$label stopped"
}

# ============================================================================
# RUN PROJECT
# ============================================================================

run_project() {
    header
    echo -e "${BOLD}═══ Pilih Project untuk Dijalankan ═══${X}\n"
    
    local projects=$(list_projects)
    if [ -z "$projects" ]; then
        msg warn "Belum ada project. Tambah dulu!"
        wait_key
        return
    fi
    
    echo "$projects"
    echo -n "\nPilih nomor: "
    read num
    
    local selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    
    load_project "$selected" || { msg err "Gagal load project"; wait_key; return; }
    
    header
    echo -e "${BOLD}═══ Running: $PROJECT_NAME ═══${X}\n"
    
    # Check apakah project sudah terinstall
    if [ ! -d "$PROJECT_PATH" ]; then
        msg err "Project folder tidak ditemukan di: $PROJECT_PATH"
        msg info "Mungkin project ini dari GitHub dan belum di-clone?"
        wait_key
        return
    fi
    
    # Check dependencies
    local fe_path="$PROJECT_PATH/$FE_DIR"
    local be_path="$PROJECT_PATH/$BE_DIR"
    
    if [ -d "$fe_path" ] && [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then
        echo -n "Frontend dependencies belum terinstall. Install sekarang? (y/n): "
        read install
        [[ "$install" =~ ^[Yy]$ ]] && install_deps "$selected"
    fi
    
    if [ -d "$be_path" ] && [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then
        echo -n "Backend dependencies belum terinstall. Install sekarang? (y/n): "
        read install
        [[ "$install" =~ ^[Yy]$ ]] && install_deps "$selected"
    fi
    
    # Start services
    start_service "$PROJECT_NAME" "$FE_DIR" "$FE_PORT" "npm run dev" "frontend"
    echo ""
    start_service "$PROJECT_NAME" "$BE_DIR" "$BE_PORT" "npm start" "backend"
    
    # Show URLs
    echo -e "\n${BOLD}${G}═══ Akses URLs ═══${X}"
    [ -f "$LOG_DIR/${PROJECT_NAME}_frontend.port" ] && {
        local port=$(cat "$LOG_DIR/${PROJECT_NAME}_frontend.port")
        echo -e "Frontend: ${C}http://127.0.0.1:$port${X}"
    }
    [ -f "$LOG_DIR/${PROJECT_NAME}_backend.port" ] && {
        local port=$(cat "$LOG_DIR/${PROJECT_NAME}_backend.port")
        echo -e "Backend:  ${C}http://127.0.0.1:$port${X}"
    }
    
    wait_key
}

# ============================================================================
# STOP PROJECT
# ============================================================================

stop_project() {
    header
    echo -e "${BOLD}═══ Stop Running Project ═══${X}\n"
    
    local projects=$(list_projects)
    if [ -z "$projects" ]; then
        msg warn "Belum ada project"
        wait_key
        return
    fi
    
    echo "$projects"
    echo -n "\nPilih nomor: "
    read num
    
    local selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    
    load_project "$selected" || { msg err "Gagal load project"; wait_key; return; }
    
    echo ""
    stop_service "$PROJECT_NAME" "frontend"
    stop_service "$PROJECT_NAME" "backend"
    
    wait_key
}

# ============================================================================
# STATUS
# ============================================================================

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
                local pid=$(cat "$pid_file")
                if kill -0 "$pid" 2>/dev/null; then
                    local port=$(cat "$port_file" 2>/dev/null)
                    echo -e "  ${G}● $svc${X} running (PID: $pid, Port: $port)"
                else
                    echo -e "  ${R}○ $svc${X} stopped"
                    rm -f "$pid_file" "$port_file"
                fi
            else
                echo -e "  ${R}○ $svc${X} stopped"
            fi
        done
        echo ""
    done < "$CONFIG_FILE"
    
    wait_key
}

# ============================================================================
# LOGS
# ============================================================================

view_logs() {
    header
    echo -e "${BOLD}═══ View Logs ═══${X}\n"
    
    local projects=$(list_projects)
    [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
    
    echo "$projects"
    echo -n "\nPilih project: "
    read num
    
    local selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
    [ -z "$selected" ] && { msg err "Pilihan tidak valid"; wait_key; return; }
    
    header
    echo -e "${BOLD}═══ Logs: $selected ═══${X}\n"
    echo "1. Frontend log"
    echo "2. Backend log"
    echo -n "\nPilih: "
    read choice
    
    case "$choice" in
        1) local log="$LOG_DIR/${selected}_frontend.log" ;;
        2) local log="$LOG_DIR/${selected}_backend.log" ;;
        *) msg err "Pilihan tidak valid"; wait_key; return ;;
    esac
    
    if [ -f "$log" ]; then
        echo -e "\n${BOLD}═══ Last 50 lines ═══${X}\n"
        tail -50 "$log"
    else
        msg warn "Log file tidak ditemukan"
    fi
    
    wait_key
}

# ============================================================================
# MAIN MENU
# ============================================================================

show_menu() {
    header
    
    echo -e "${BOLD}MENU UTAMA${X}\n"
    echo "1. ▶️  Jalankan Project"
    echo "2. ⏹️  Stop Project"
    echo "3. ➕ Tambah Project Baru"
    echo "4. 📊 Status Semua Project"
    echo "5. 📝 Lihat Logs"
    echo "6. 🔄 Install/Update Dependencies"
    echo "7. 🚪 Keluar"
    
    echo -e "\n${BOLD}════════════════════════════════════${X}"
    echo -n "Pilih menu (1-7): "
    read choice
    
    case "$choice" in
        1) run_project ;;
        2) stop_project ;;
        3) add_project ;;
        4) show_status ;;
        5) view_logs ;;
        6) 
            header
            local projects=$(list_projects)
            [ -z "$projects" ] && { msg warn "Belum ada project"; wait_key; return; }
            echo "$projects"
            echo -n "\nPilih project: "
            read num
            local selected=$(sed -n "${num}p" "$CONFIG_FILE" 2>/dev/null | cut -d'|' -f1)
            [ -n "$selected" ] && install_deps "$selected"
            wait_key
            ;;
        7)
            header
            msg info "Terima kasih!"
            exit 0
            ;;
        *)
            msg err "Pilihan tidak valid"
            wait_key
            ;;
    esac
}

# ============================================================================
# INIT & RUN
# ============================================================================

mkdir -p "$PROJECTS_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

check_deps || exit 1

# Run menu ONLY ONCE - no loop!
show_menu
