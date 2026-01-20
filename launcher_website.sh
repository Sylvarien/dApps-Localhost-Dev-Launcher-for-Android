#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Launcher - Professional v3.0.0
# Platform: Android Termux
# Features: Auto-sync, ID-based management, Smart operations
# ============================================================================

set -euo pipefail

# ---------------------------
# Configuration
# ---------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PROJECTS_DIR="$HOME/dapps-projects"
CONFIG_FILE="$HOME/.dapps.conf"
LOG_DIR="$HOME/.dapps-logs"
LAUNCHER_VERSION="3.0.0"

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
    echo -e "${C}${BOLD}║    DApps Localhost Launcher Pro — v${LAUNCHER_VERSION}         ║${X}"
    echo -e "${C}${BOLD}╚════════════════════════════════════════════════════════╝${X}\n"
}

wait_key() {
    echo -e "\n${C}Tekan ENTER untuk kembali...${X}"
    read -r
}

confirm() {
    read -rp "$1 (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------
# Config format (pipe-separated):
# id|name|local_path|source_path|fe_dir|be_dir|fe_port|be_port|fe_cmd|be_cmd|auto_restart|auto_sync
# ---------------------------

generate_id() {
    # Generate unique 6-char ID
    echo "$(date +%s%N | md5sum | head -c 6)"
}

save_project() {
    local id="$1" name="$2" local_path="$3" source_path="$4"
    local fe_dir="$5" be_dir="$6" fe_port="$7" be_port="$8"
    local fe_cmd="$9" be_cmd="${10}" auto_restart="${11}" auto_sync="${12}"
    
    # Remove old entry by ID
    grep -v "^$id|" "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true
    
    # Add new entry
    echo "$id|$name|$local_path|$source_path|$fe_dir|$be_dir|$fe_port|$be_port|$fe_cmd|$be_cmd|$auto_restart|$auto_sync" >> "$CONFIG_FILE"
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

list_projects_table() {
    [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ] && return 1
    
    echo -e "${BOLD}ID     | Status | Name                  | Path${X}"
    echo "---------------------------------------------------------------------"
    
    while IFS='|' read -r id name local_path source_path _; do
        [ -z "$id" ] && continue
        
        local status="${G}✓${X}"
        [ ! -d "$local_path" ] && status="${R}✗${X}"
        
        # Check if running
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
        
        printf "%-6s | %-6s | %-21s | %s%s\n" "$id" "$status" "${name:0:21}" "${local_path:0:40}" "$running"
    done < "$CONFIG_FILE"
    
    return 0
}

# ---------------------------
# Auto-sync function
# ---------------------------
auto_sync_project() {
    local id="$1"
    load_project "$id" || return 1
    
    # Skip if no source path or source = local
    [ -z "$SOURCE_PATH" ] || [ "$SOURCE_PATH" = "$PROJECT_PATH" ] && return 0
    
    # Check if source exists
    [ ! -d "$SOURCE_PATH" ] && {
        msg warn "Source path tidak ditemukan: $SOURCE_PATH"
        return 1
    }
    
    msg info "Auto-sync: $SOURCE_PATH → $PROJECT_PATH"
    
    # Create local directory if not exists
    mkdir -p "$PROJECT_PATH"
    
    # Sync using rsync or cp
    if command -v rsync &>/dev/null; then
        rsync -a --delete "$SOURCE_PATH/" "$PROJECT_PATH/" || {
            msg err "Sync gagal"
            return 1
        }
    else
        cp -rf "$SOURCE_PATH/"* "$PROJECT_PATH/" 2>/dev/null || {
            msg err "Sync gagal"
            return 1
        }
    fi
    
    msg ok "Sync selesai"
    return 0
}

# ---------------------------
# External storage check
# ---------------------------
is_external_storage() {
    [[ "$1" =~ ^/storage/emulated/ ]] || [[ "$1" =~ ^/sdcard/ ]]
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
        msg warn "Missing: ${missing[*]}"
        msg info "Install: pkg install nodejs git net-tools"
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
# Package manager detection
# ---------------------------
detect_pkg_manager() {
    if command -v pnpm &>/dev/null; then echo "pnpm"
    elif command -v yarn &>/dev/null; then echo "yarn"
    else echo "npm"; fi
}

detect_start_command() {
    local pdir="$1"
    [ ! -f "$pdir/package.json" ] && { echo ""; return; }
    
    local has_dev=$(node -e "const p=require('$pdir/package.json'); console.log(!!(p.scripts && p.scripts.dev))" 2>/dev/null || echo "false")
    [ "$has_dev" = "true" ] && { echo "npm run dev"; return; }
    
    local has_start=$(node -e "const p=require('$pdir/package.json'); console.log(!!(p.scripts && p.scripts.start))" 2>/dev/null || echo "false")
    [ "$has_start" = "true" ] && { echo "npm start"; return; }
    
    echo ""
}

# ---------------------------
# Service control
# ---------------------------
start_service() {
    local id="$1" dir="$2" port="$3" cmd="$4" label="$5"
    local pid_file="$LOG_DIR/${id}_${label}.pid"
    local log_file="$LOG_DIR/${id}_${label}.log"
    local port_file="$LOG_DIR/${id}_${label}.port"

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
    [ ! -d "$full_path" ] && { msg err "$label folder not found: $full_path"; return 1; }

    local final_port=$(get_available_port "$port") || { msg err "No port available"; return 1; }
    [ "$final_port" != "$port" ] && msg warn "Port $port in use, using $final_port"

    msg info "Starting $label on port $final_port..."

    (cd "$full_path" || exit 1
        [ -f ".env" ] && set -a && source .env 2>/dev/null && set +a
        PORT="$final_port"
        nohup bash -lc "PORT=$PORT $cmd" > "$log_file" 2>&1 &
        echo $! > "$pid_file"
        echo "$final_port" > "$port_file"
    )

    sleep 1
    local pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        msg ok "$label started (PID: $pid, Port: $final_port)"
        return 0
    else
        msg err "$label failed to start. Check: $log_file"
        rm -f "$pid_file" "$port_file" || true
        return 1
    fi
}

stop_service() {
    local id="$1" label="$2"
    local pid_file="$LOG_DIR/${id}_${label}.pid"
    local port_file="$LOG_DIR/${id}_${label}.port"

    [ ! -f "$pid_file" ] && { msg info "$label not running"; return 0; }

    local pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] && { rm -f "$pid_file" "$port_file"; return 0; }

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
# Project Operations
# ---------------------------
add_project() {
    header
    echo -e "${BOLD}═══ Add New Project ═══${X}\n"
    
    read -rp "Project name: " name
    [ -z "$name" ] && { msg err "Name required"; wait_key; return; }
    
    echo -e "\n${BOLD}Source:${X}"
    echo "1) Clone from GitHub"
    echo "2) Use existing folder (with auto-sync)"
    echo "3) Create new empty project"
    read -rp "Select (1-3): " source_type
    
    local id=$(generate_id)
    local local_path="$PROJECTS_DIR/$name"
    local source_path=""
    local auto_sync=0
    
    case "$source_type" in
        1)
            read -rp "Git URL: " git_url
            [ -z "$git_url" ] && { msg err "URL required"; wait_key; return; }
            msg info "Cloning..."
            git clone "$git_url" "$local_path" || { msg err "Clone failed"; wait_key; return; }
            msg ok "Cloned to: $local_path"
            ;;
        2)
            read -rp "Source folder path: " source_path
            [ -z "$source_path" ] && { msg err "Path required"; wait_key; return; }
            [ ! -d "$source_path" ] && { msg err "Folder not found"; wait_key; return; }
            
            # Auto-move if in external storage
            if is_external_storage "$source_path"; then
                msg warn "Source is in external storage (/storage/emulated/)"
                msg info "Will auto-sync to Termux home for compatibility"
                auto_sync=1
                
                msg info "Initial sync..."
                mkdir -p "$local_path"
                
                if command -v rsync &>/dev/null; then
                    rsync -a "$source_path/" "$local_path/" || { msg err "Sync failed"; wait_key; return; }
                else
                    cp -rf "$source_path/"* "$local_path/" 2>/dev/null || { msg err "Sync failed"; wait_key; return; }
                fi
                msg ok "Synced to: $local_path"
            else
                # If source is in Termux home, use it directly
                local_path="$source_path"
                source_path=""
            fi
            ;;
        3)
            mkdir -p "$local_path/frontend" "$local_path/backend"
            echo '{"name":"frontend","scripts":{"dev":"echo Frontend server"}}' > "$local_path/frontend/package.json"
            echo '{"name":"backend","scripts":{"start":"echo Backend server"}}' > "$local_path/backend/package.json"
            msg ok "Created: $local_path"
            ;;
        *)
            msg err "Invalid choice"; wait_key; return
            ;;
    esac
    
    read -rp "Frontend dir [frontend]: " fe_dir; fe_dir=${fe_dir:-frontend}
    read -rp "Backend dir [backend]: " be_dir; be_dir=${be_dir:-backend}
    read -rp "Frontend port [3000]: " fe_port; fe_port=${fe_port:-3000}
    read -rp "Backend port [8000]: " be_port; be_port=${be_port:-8000}
    
    local fe_cmd=$(detect_start_command "$local_path/$fe_dir" || echo "npm run dev")
    local be_cmd=$(detect_start_command "$local_path/$be_dir" || echo "npm start")
    
    read -rp "Frontend command [$fe_cmd]: " tmp; [ -n "$tmp" ] && fe_cmd="$tmp"
    read -rp "Backend command [$be_cmd]: " tmp; [ -n "$tmp" ] && be_cmd="$tmp"
    
    save_project "$id" "$name" "$local_path" "$source_path" \
                 "$fe_dir" "$be_dir" "$fe_port" "$be_port" \
                 "$fe_cmd" "$be_cmd" "0" "$auto_sync"
    
    msg ok "Project added with ID: $id"
    
    if confirm "Install dependencies now?"; then
        install_deps "$id"
    fi
    
    wait_key
}

install_deps() {
    local id="$1"
    load_project "$id" || { msg err "Project not found"; return 1; }
    
    # Sync if needed
    [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$id"
    
    msg info "Installing dependencies for $PROJECT_NAME..."
    local pkg_mgr=$(detect_pkg_manager)
    
    for spec in "Frontend:$FE_DIR" "Backend:$BE_DIR"; do
        local label=${spec%%:*}
        local dir=${spec#*:}
        local full="$PROJECT_PATH/$dir"
        
        [ ! -d "$full" ] && { msg warn "$label folder not found"; continue; }
        [ ! -f "$full/package.json" ] && { msg warn "$label has no package.json"; continue; }
        
        msg info "Installing $label with $pkg_mgr..."
        
        (cd "$full" && $pkg_mgr install) && msg ok "$label installed" || msg err "$label install failed"
    done
}

run_project() {
    header
    echo -e "${BOLD}═══ Start Project ═══${X}\n"
    
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    
    echo ""
    read -rp "Enter project ID: " id
    [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
    
    load_project "$id" || { msg err "Project not found"; wait_key; return; }
    
    header
    echo -e "${BOLD}═══ Starting: $PROJECT_NAME (ID: $id) ═══${X}\n"
    
    # Sync if enabled
    [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$id"
    
    [ ! -d "$PROJECT_PATH" ] && { msg err "Project path not found"; wait_key; return; }
    
    # Auto-install if needed
    local fe_path="$PROJECT_PATH/$FE_DIR"
    local be_path="$PROJECT_PATH/$BE_DIR"
    
    if [ -d "$fe_path" ] && [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then
        confirm "Frontend deps missing. Install?" && install_deps "$id"
    fi
    
    if [ -d "$be_path" ] && [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then
        confirm "Backend deps missing. Install?" && install_deps "$id"
    fi
    
    # Start services
    start_service "$id" "$FE_DIR" "$FE_PORT" "$FE_CMD" "frontend"
    start_service "$id" "$BE_DIR" "$BE_PORT" "$BE_CMD" "backend"
    
    # Show URLs
    echo -e "\n${BOLD}${G}═══ Access URLs ═══${X}"
    [ -f "$LOG_DIR/${id}_frontend.port" ] && {
        local p=$(cat "$LOG_DIR/${id}_frontend.port")
        echo -e "Frontend: ${C}http://127.0.0.1:$p${X}"
    }
    [ -f "$LOG_DIR/${id}_backend.port" ] && {
        local p=$(cat "$LOG_DIR/${id}_backend.port")
        echo -e "Backend:  ${C}http://127.0.0.1:$p${X}"
    }
    
    wait_key
}

stop_project() {
    header
    echo -e "${BOLD}═══ Stop Project ═══${X}\n"
    
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    
    echo ""
    read -rp "Enter project ID: " id
    [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
    
    load_project "$id" || { msg err "Project not found"; wait_key; return; }
    
    stop_service "$id" "frontend"
    stop_service "$id" "backend"
    
    wait_key
}

delete_project() {
    header
    echo -e "${BOLD}═══ Delete Project ═══${X}\n"
    
    echo "1) Delete single project"
    echo "2) Delete ALL projects"
    read -rp "Select (1/2): " choice
    
    case "$choice" in
        1)
            list_projects_table || { msg warn "No projects"; wait_key; return; }
            echo ""
            read -rp "Enter project ID to delete: " id
            [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
            
            load_project "$id" || { msg err "Project not found"; wait_key; return; }
            
            echo -e "\n${R}${BOLD}WARNING:${X} This will delete:"
            echo "  - Project: $PROJECT_NAME"
            echo "  - Path: $PROJECT_PATH"
            echo "  - Config entry"
            echo ""
            
            confirm "Delete project files?" && {
                stop_service "$id" "frontend"
                stop_service "$id" "backend"
                rm -rf "$PROJECT_PATH"
                msg ok "Files deleted"
            }
            
            confirm "Remove from config?" && {
                grep -v "^$id|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
                mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                msg ok "Config removed"
            }
            ;;
        2)
            echo -e "\n${R}${BOLD}DANGER:${X} This will delete ALL projects!"
            confirm "Are you ABSOLUTELY sure?" || { msg info "Cancelled"; wait_key; return; }
            confirm "Type YES to confirm" || { msg info "Cancelled"; wait_key; return; }
            
            # Stop all
            while IFS='|' read -r id _; do
                [ -z "$id" ] && continue
                stop_service "$id" "frontend"
                stop_service "$id" "backend"
            done < "$CONFIG_FILE"
            
            rm -rf "$PROJECTS_DIR"/*
            > "$CONFIG_FILE"
            msg ok "All projects deleted"
            ;;
        *)
            msg err "Invalid choice"
            ;;
    esac
    
    wait_key
}

sync_project() {
    header
    echo -e "${BOLD}═══ Sync Project ═══${X}\n"
    
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    
    echo ""
    read -rp "Enter project ID: " id
    [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
    
    load_project "$id" || { msg err "Project not found"; wait_key; return; }
    
    [ -z "$SOURCE_PATH" ] && { msg warn "No source path configured"; wait_key; return; }
    
    auto_sync_project "$id"
    
    wait_key
}

view_logs() {
    header
    echo -e "${BOLD}═══ View Logs ═══${X}\n"
    
    list_projects_table || { msg warn "No projects"; wait_key; return; }
    
    echo ""
    read -rp "Enter project ID: " id
    [ -z "$id" ] && { msg err "ID required"; wait_key; return; }
    
    echo "1) Frontend log"
    echo "2) Backend log"
    echo "3) Both (tail -f)"
    read -rp "Select: " choice
    
    case "$choice" in
        1) tail -n 100 "$LOG_DIR/${id}_frontend.log" 2>/dev/null || msg warn "No log" ;;
        2) tail -n 100 "$LOG_DIR/${id}_backend.log" 2>/dev/null || msg warn "No log" ;;
        3) tail -f "$LOG_DIR/${id}_frontend.log" "$LOG_DIR/${id}_backend.log" 2>/dev/null ;;
        *) msg err "Invalid" ;;
    esac
    
    wait_key
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
    echo " 0. 🚪 Exit"
    echo -e "\n${BOLD}═══════════════════════════════════${X}"
    read -rp "Select (0-8): " choice
    
    case "$choice" in
        1) header; list_projects_table || msg warn "No projects"; wait_key ;;
        2) add_project ;;
        3) run_project ;;
        4) stop_project ;;
        5) 
            header
            list_projects_table || { wait_key; return; }
            echo ""
            read -rp "Enter project ID: " id
            [ -n "$id" ] && install_deps "$id"
            wait_key
            ;;
        6) sync_project ;;
        7) view_logs ;;
        8) delete_project ;;
        0) header; msg info "Goodbye!"; exit 0 ;;
        *) msg err "Invalid choice"; wait_key ;;
    esac
}

# ---------------------------
# Main
# ---------------------------
main() {
    check_deps || msg warn "Some dependencies missing"
    
    while true; do
        show_menu
    done
}

main
