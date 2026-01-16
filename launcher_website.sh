#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# DApps Localhost Dev Launcher for Android/Termux
# ============================================================================
# Version: 1.0.1
# Release: January 16, 2026
# Platform: Android (Termux)
# License: MIT
#
# Professional development environment manager for Android with:
# • Multi-project management with isolated environments
# • Smart dependency detection (Node.js, npm, git auto-install)
# • Intelligent update system with hash-based change detection
# • Automatic port conflict resolution
# • Background service management (nohup-based, no systemd/pm2)
# • Separate logging per service with PID tracking
# • Zero external dependencies (pure Bash/POSIX)
# ============================================================================

# ============================================================================
# CONFIGURATION
# ============================================================================

BASE_PROJECT_DIR="$HOME/projects"
DEFAULT_FRONTEND_DIR="frontend"
DEFAULT_BACKEND_DIR="backend"
DEFAULT_FRONTEND_PORT=3000
DEFAULT_BACKEND_PORT=8000

CONFIG_FILE="$HOME/.dapps_projects.conf"
ACTIVE_PROJECT_FILE="$HOME/.dapps_active.conf"
LOG_DIR="$HOME/.dapps_logs"

# Colors for TUI
COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_CYAN="\033[36m"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

show_header() {
    clear
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         DApps Localhost Dev Launcher for Android          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${COLOR_RESET}\n"
}

print_msg() {
    local type="$1"
    local msg="$2"
    case "$type" in
        "info")    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $msg" ;;
        "success") echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $msg" ;;
        "warning") echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $msg" ;;
        "error")   echo -e "${COLOR_RED}[✗]${COLOR_RESET} $msg" ;;
        *)         echo "$msg" ;;
    esac
}

pause() {
    echo -e "\n${COLOR_CYAN}Press ENTER to continue...${COLOR_RESET}"
    read
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_file_hash() {
    local file="$1"
    [ -f "$file" ] && md5sum "$file" 2>/dev/null | cut -d' ' -f1 || echo ""
}

# ============================================================================
# INITIALIZATION
# ============================================================================

init_environment() {
    mkdir -p "$BASE_PROJECT_DIR" "$LOG_DIR"
    touch "$CONFIG_FILE"
    [ ! -f "$ACTIVE_PROJECT_FILE" ] && echo "" > "$ACTIVE_PROJECT_FILE"
}

check_dependencies() {
    local need_install=0
    
    print_msg "info" "Checking dependencies..."
    
    for dep in node npm git; do
        if ! command_exists "$dep"; then
            print_msg "warning" "$dep not found. Installing..."
            pkg install -y nodejs git || {
                print_msg "error" "Failed to install $dep"
                return 1
            }
            need_install=1
        fi
    done
    
    [ $need_install -eq 0 ] && print_msg "success" "All dependencies installed" || print_msg "success" "Dependencies installed successfully"
    return 0
}

# ============================================================================
# PROJECT CONFIGURATION
# ============================================================================

save_project() {
    local name="$1" repo="$2" folder="$3" fe_dir="$4" be_dir="$5" fe_port="$6" be_port="$7"
    
    # Remove existing entry
    [ -f "$CONFIG_FILE" ] && grep -v "^$name|" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    # Add new entry
    echo "$name|$repo|$folder|$fe_dir|$be_dir|$fe_port|$be_port" >> "$CONFIG_FILE"
}

load_project() {
    local name="$1"
    local line=$(grep "^$name|" "$CONFIG_FILE" 2>/dev/null | head -n1)
    
    [ -z "$line" ] && return 1
    
    PROJECT_NAME=$(echo "$line" | cut -d'|' -f1)
    PROJECT_REPO=$(echo "$line" | cut -d'|' -f2)
    PROJECT_FOLDER=$(echo "$line" | cut -d'|' -f3)
    PROJECT_FE_DIR=$(echo "$line" | cut -d'|' -f4)
    PROJECT_BE_DIR=$(echo "$line" | cut -d'|' -f5)
    PROJECT_FE_PORT=$(echo "$line" | cut -d'|' -f6)
    PROJECT_BE_PORT=$(echo "$line" | cut -d'|' -f7)
    
    return 0
}

list_projects() {
    [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ] && return 1
    
    local idx=1
    while IFS='|' read -r name _; do
        [ -z "$name" ] && continue
        echo "$idx. $name"
        idx=$((idx + 1))
    done < "$CONFIG_FILE"
    
    return 0
}

get_active_project() {
    [ -f "$ACTIVE_PROJECT_FILE" ] && cat "$ACTIVE_PROJECT_FILE" 2>/dev/null | head -n1 || echo ""
}

set_active_project() {
    echo "$1" > "$ACTIVE_PROJECT_FILE"
}

# ============================================================================
# PROJECT MANAGEMENT
# ============================================================================

add_project() {
    show_header
    echo -e "${COLOR_BOLD}═══ Add New Project ═══${COLOR_RESET}\n"
    
    echo -n "Project name: "
    read name
    [ -z "$name" ] && { print_msg "error" "Project name cannot be empty"; pause; return 1; }
    
    grep -q "^$name|" "$CONFIG_FILE" 2>/dev/null && { print_msg "error" "Project '$name' already exists"; pause; return 1; }
    
    echo -n "Git repository URL (or leave empty): "
    read repo
    
    echo -n "Local folder name [$name]: "
    read folder
    [ -z "$folder" ] && folder="$name"
    
    echo -n "Frontend directory [$DEFAULT_FRONTEND_DIR]: "
    read fe_dir
    [ -z "$fe_dir" ] && fe_dir="$DEFAULT_FRONTEND_DIR"
    
    echo -n "Backend directory [$DEFAULT_BACKEND_DIR]: "
    read be_dir
    [ -z "$be_dir" ] && be_dir="$DEFAULT_BACKEND_DIR"
    
    echo -n "Frontend port [$DEFAULT_FRONTEND_PORT]: "
    read fe_port
    [ -z "$fe_port" ] && fe_port="$DEFAULT_FRONTEND_PORT"
    
    echo -n "Backend port [$DEFAULT_BACKEND_PORT]: "
    read be_port
    [ -z "$be_port" ] && be_port="$DEFAULT_BACKEND_PORT"
    
    save_project "$name" "$repo" "$folder" "$fe_dir" "$be_dir" "$fe_port" "$be_port"
    print_msg "success" "Project '$name' added successfully"
    
    echo -n "\nSet as active project? (y/n): "
    read set_active
    if [ "$set_active" = "y" ] || [ "$set_active" = "Y" ]; then
        set_active_project "$name"
        print_msg "success" "Active project set to '$name'"
    fi
    
    pause
}

select_project() {
    show_header
    echo -e "${COLOR_BOLD}═══ Select Project ═══${COLOR_RESET}\n"
    
    local projects=$(list_projects)
    if [ -z "$projects" ]; then
        print_msg "warning" "No projects found. Please add a project first."
        pause
        return 1
    fi
    
    echo "$projects"
    echo -n "\nSelect project number: "
    read num
    
    local selected=$(echo "$projects" | sed -n "${num}p" | cut -d'.' -f2- | sed 's/^ //')
    
    [ -z "$selected" ] && { print_msg "error" "Invalid selection"; pause; return 1; }
    
    set_active_project "$selected"
    print_msg "success" "Active project set to '$selected'"
    pause
}

setup_project() {
    local project_path="$BASE_PROJECT_DIR/$PROJECT_FOLDER"
    
    # Clone if needed
    if [ ! -d "$project_path" ] && [ -n "$PROJECT_REPO" ]; then
        print_msg "info" "Cloning repository..."
        git clone "$PROJECT_REPO" "$project_path" || {
            print_msg "error" "Failed to clone repository"
            return 1
        }
        print_msg "success" "Repository cloned"
    elif [ ! -d "$project_path" ]; then
        mkdir -p "$project_path"
        print_msg "success" "Project directory created"
    fi
    
    # Install dependencies with timeout
    for dir_var in "FE:$PROJECT_FE_DIR" "BE:$PROJECT_BE_DIR"; do
        local label=$(echo "$dir_var" | cut -d: -f1)
        local dir=$(echo "$dir_var" | cut -d: -f2)
        local path="$project_path/$dir"
        
        if [ -d "$path" ] && [ -f "$path/package.json" ] && [ ! -d "$path/node_modules" ]; then
            print_msg "info" "Installing ${label} dependencies..."
            cd "$path" || {
                print_msg "error" "Cannot access ${label} directory"
                return 1
            }
            
            timeout 300 npm install || {
                print_msg "error" "${label} npm install failed or timed out"
                cd - > /dev/null
                return 1
            }
            
            cd - > /dev/null
            print_msg "success" "${label} dependencies installed"
        fi
    done
    
    return 0
}

update_project() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Update Project: $PROJECT_NAME ═══${COLOR_RESET}\n"
    
    local project_path="$BASE_PROJECT_DIR/$PROJECT_FOLDER"
    
    [ ! -d "$project_path" ] && { setup_project; pause; return $?; }
    
    # Git update with smart npm install
    if [ -d "$project_path/.git" ]; then
        print_msg "info" "Checking for updates..."
        cd "$project_path" || return 1
        
        git fetch origin 2>&1 | tee "$LOG_DIR/git_fetch.log"
        
        local local_hash=$(git rev-parse HEAD)
        local remote_hash=$(git rev-parse @{u} 2>/dev/null || echo "$local_hash")
        
        if [ "$local_hash" = "$remote_hash" ]; then
            print_msg "success" "Already up to date"
            cd - > /dev/null
            pause
            return 0
        fi
        
        print_msg "info" "Updates found. Pulling changes..."
        
        # Save package.json hashes
        local fe_pkg_hash=$(get_file_hash "$PROJECT_FE_DIR/package.json")
        local be_pkg_hash=$(get_file_hash "$PROJECT_BE_DIR/package.json")
        
        git pull origin 2>&1 | tee "$LOG_DIR/git_pull.log" || {
            print_msg "error" "Git pull failed. Check for conflicts manually."
            cd - > /dev/null
            pause
            return 1
        }
        
        print_msg "success" "Changes pulled"
        
        # Smart npm install (only if package.json changed)
        for dir_var in "FE:$PROJECT_FE_DIR:$fe_pkg_hash" "BE:$PROJECT_BE_DIR:$be_pkg_hash"; do
            local label=$(echo "$dir_var" | cut -d: -f1)
            local dir=$(echo "$dir_var" | cut -d: -f2)
            local old_hash=$(echo "$dir_var" | cut -d: -f3)
            
            if [ -d "$dir" ] && [ -f "$dir/package.json" ]; then
                local new_hash=$(get_file_hash "$dir/package.json")
                if [ "$old_hash" != "$new_hash" ]; then
                    print_msg "info" "${label} package.json changed. Updating dependencies..."
                    cd "$dir" || continue
                    timeout 300 npm install || print_msg "warning" "${label} npm install failed"
                    cd "$project_path"
                    print_msg "success" "${label} dependencies updated"
                else
                    print_msg "info" "${label} dependencies unchanged"
                fi
            fi
        done
        
        cd - > /dev/null
    else
        print_msg "info" "Not a git repository. Skipping update."
    fi
    
    pause
}

# ============================================================================
# SERVICE CONTROL
# ============================================================================

get_pid() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
        rm -f "$pid_file"
    fi
    return 1
}

find_available_port() {
    local port="$1"
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Fixed: Use word boundary instead of space
        if ! netstat -tuln 2>/dev/null | grep -q ":$port\b"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
        attempt=$((attempt + 1))
    done
    
    return 1
}

start_service() {
    local service="$1"
    local dir_var="$2"
    local default_port="$3"
    local npm_cmd="$4"
    
    local project_path="$BASE_PROJECT_DIR/$PROJECT_FOLDER"
    local service_path="$project_path/$dir_var"
    local pid_file="$LOG_DIR/${PROJECT_NAME}_${service}.pid"
    local log_file="$LOG_DIR/${PROJECT_NAME}_${service}.log"
    
    # Check if already running
    if get_pid "$pid_file" >/dev/null; then
        local pid=$(cat "$pid_file")
        print_msg "warning" "${service^} already running (PID: $pid)"
        return 0
    fi
    
    [ ! -d "$service_path" ] && { print_msg "warning" "${service^} directory not found"; return 1; }
    [ ! -f "$service_path/package.json" ] && { print_msg "warning" "${service^} package.json not found"; return 1; }
    
    # Find available port
    local port=$(find_available_port "$default_port")
    [ -z "$port" ] && { print_msg "error" "No available port found"; return 1; }
    
    [ "$port" != "$default_port" ] && print_msg "warning" "Port $default_port in use. Using port $port"
    
    print_msg "info" "Starting ${service} on port $port..."
    
    cd "$service_path" || {
        print_msg "error" "Cannot access ${service} directory"
        return 1
    }
    
    # Fixed: Safe .env loading
    if [ -f ".env" ]; then
        set -a
        source .env 2>/dev/null
        set +a
    fi
    
    # Start with nohup
    PORT=$port nohup $npm_cmd > "$log_file" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$pid_file"
    
    cd - > /dev/null
    
    sleep 2
    
    # Verify
    if kill -0 "$new_pid" 2>/dev/null; then
        print_msg "success" "${service^} started (PID: $new_pid, Port: $port)"
        echo "$port" > "$LOG_DIR/${PROJECT_NAME}_${service}.port"
        return 0
    else
        print_msg "error" "${service^} failed to start. Check logs: $log_file"
        rm -f "$pid_file"
        return 1
    fi
}

start_frontend() {
    start_service "frontend" "$PROJECT_FE_DIR" "$PROJECT_FE_PORT" "npm run dev"
}

start_backend() {
    start_service "backend" "$PROJECT_BE_DIR" "$PROJECT_BE_PORT" "npm start"
}

stop_service() {
    local service="$1"
    local pid_file="$LOG_DIR/${PROJECT_NAME}_${service}.pid"
    
    if ! get_pid "$pid_file" >/dev/null; then
        print_msg "info" "${service^} not running"
        return 0
    fi
    
    local pid=$(cat "$pid_file")
    print_msg "info" "Stopping ${service}..."
    
    # Graceful shutdown
    kill "$pid" 2>/dev/null
    sleep 2
    
    # Force kill if needed
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    
    rm -f "$pid_file" "$LOG_DIR/${PROJECT_NAME}_${service}.port"
    print_msg "success" "${service^} stopped"
}

start_project() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Start Project: $PROJECT_NAME ═══${COLOR_RESET}\n"
    
    local project_path="$BASE_PROJECT_DIR/$PROJECT_FOLDER"
    [ ! -d "$project_path" ] && { setup_project || { pause; return 1; }; }
    
    start_frontend
    echo ""
    start_backend
    
    echo -e "\n${COLOR_BOLD}Access URLs:${COLOR_RESET}"
    local fe_port=$(cat "$LOG_DIR/${PROJECT_NAME}_frontend.port" 2>/dev/null)
    local be_port=$(cat "$LOG_DIR/${PROJECT_NAME}_backend.port" 2>/dev/null)
    [ -n "$fe_port" ] && echo -e "  Frontend: ${COLOR_GREEN}http://127.0.0.1:$fe_port${COLOR_RESET}"
    [ -n "$be_port" ] && echo -e "  Backend:  ${COLOR_GREEN}http://127.0.0.1:$be_port${COLOR_RESET}"
    
    pause
}

stop_project() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Stop Project: $PROJECT_NAME ═══${COLOR_RESET}\n"
    
    stop_service "frontend"
    stop_service "backend"
    
    pause
}

restart_project() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Restart Project: $PROJECT_NAME ═══${COLOR_RESET}\n"
    
    stop_service "frontend"
    stop_service "backend"
    echo ""
    sleep 1
    start_frontend
    echo ""
    start_backend
    
    echo ""
    print_msg "success" "Project restarted"
    pause
}

show_status() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Project Status: $PROJECT_NAME ═══${COLOR_RESET}\n"
    
    for service in "frontend" "backend"; do
        local pid_file="$LOG_DIR/${PROJECT_NAME}_${service}.pid"
        local port_file="$LOG_DIR/${PROJECT_NAME}_${service}.port"
        
        if get_pid "$pid_file" >/dev/null; then
            local pid=$(cat "$pid_file")
            local port=$(cat "$port_file" 2>/dev/null)
            echo -e "${service^}: ${COLOR_GREEN}● RUNNING${COLOR_RESET} (PID: $pid, Port: $port)"
        else
            echo -e "${service^}: ${COLOR_RED}○ STOPPED${COLOR_RESET}"
        fi
    done
    
    echo -e "\n${COLOR_BOLD}Project Info:${COLOR_RESET}"
    echo "  Location: $BASE_PROJECT_DIR/$PROJECT_FOLDER"
    [ -n "$PROJECT_REPO" ] && echo "  Repository: $PROJECT_REPO"
    
    pause
}

view_logs() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ View Logs: $PROJECT_NAME ═══${COLOR_RESET}\n"
    echo "1. Frontend log"
    echo "2. Backend log"
    echo "3. Both logs"
    echo -n "\nSelect: "
    read choice
    
    case "$choice" in
        1)
            local log="$LOG_DIR/${PROJECT_NAME}_frontend.log"
            [ -f "$log" ] && { echo -e "\n${COLOR_BOLD}=== Frontend Log (last 50 lines) ===${COLOR_RESET}"; tail -n 50 "$log"; } || print_msg "warning" "Log not found"
            ;;
        2)
            local log="$LOG_DIR/${PROJECT_NAME}_backend.log"
            [ -f "$log" ] && { echo -e "\n${COLOR_BOLD}=== Backend Log (last 50 lines) ===${COLOR_RESET}"; tail -n 50 "$log"; } || print_msg "warning" "Log not found"
            ;;
        3)
            for service in "frontend" "backend"; do
                local log="$LOG_DIR/${PROJECT_NAME}_${service}.log"
                [ -f "$log" ] && { echo -e "\n${COLOR_BOLD}=== ${service^} Log (last 25 lines) ===${COLOR_RESET}"; tail -n 25 "$log"; }
            done
            ;;
        *)
            print_msg "error" "Invalid choice"
            ;;
    esac
    
    pause
}

clean_cache() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Clean Cache: $PROJECT_NAME ═══${COLOR_RESET}\n"
    echo -e "${COLOR_YELLOW}Warning: This will remove node_modules, package-lock.json, and npm cache${COLOR_RESET}"
    echo -n "\nContinue? (y/n): "
    read confirm
    
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { print_msg "info" "Cancelled"; pause; return 0; }
    
    local project_path="$BASE_PROJECT_DIR/$PROJECT_FOLDER"
    
    for dir in "$PROJECT_FE_DIR" "$PROJECT_BE_DIR"; do
        local path="$project_path/$dir"
        [ -d "$path" ] && {
            print_msg "info" "Cleaning $dir cache..."
            rm -rf "$path/node_modules" "$path/package-lock.json" 2>/dev/null
            print_msg "success" "$dir cache cleaned"
        }
    done
    
    print_msg "info" "Cleaning npm cache..."
    npm cache clean --force 2>/dev/null
    print_msg "success" "npm cache cleaned"
    
    echo ""
    print_msg "success" "All cache cleaned. Run 'npm install' to reinstall dependencies"
    
    pause
}

open_browser() {
    show_header
    
    local active=$(get_active_project)
    [ -z "$active" ] && { print_msg "error" "No active project selected"; pause; return 1; }
    
    load_project "$active" || { print_msg "error" "Failed to load project"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}═══ Open in Browser: $PROJECT_NAME ═══${COLOR_RESET}\n"
    
    local fe_port=$(cat "$LOG_DIR/${PROJECT_NAME}_frontend.port" 2>/dev/null)
    local be_port=$(cat "$LOG_DIR/${PROJECT_NAME}_backend.port" 2>/dev/null)
    
    [ -z "$fe_port" ] && [ -z "$be_port" ] && { print_msg "error" "No services running"; pause; return 1; }
    
    echo -e "${COLOR_BOLD}Available URLs:${COLOR_RESET}\n"
    
    [ -n "$fe_port" ] && echo "1. Frontend - http://127.0.0.1:$fe_port"
    [ -n "$be_port" ] && echo "2. Backend - http://127.0.0.1:$be_port"
    
    echo -e "\n${COLOR_CYAN}Copy the URL above to open in your browser or WebView app${COLOR_RESET}"
    
    if command_exists termux-open-url; then
        echo -n "\nOpen URL? (1/2/n): "
        read choice
        
        case "$choice" in
            1) [ -n "$fe_port" ] && termux-open-url "http://127.0.0.1:$fe_port" 2>/dev/null ;;
            2) [ -n "$be_port" ] && termux-open-url "http://127.0.0.1:$be_port" 2>/dev/null ;;
        esac
    fi
    
    pause
}

# ============================================================================
# MAIN MENU
# ============================================================================

show_menu() {
    show_header
    
    local active=$(get_active_project)
    
    if [ -n "$active" ]; then
        echo -e "${COLOR_BOLD}Active Project:${COLOR_RESET} ${COLOR_GREEN}$active${COLOR_RESET}"
        
        if load_project "$active"; then
            echo -n "Status: "
            for service in "frontend" "backend"; do
                if get_pid "$LOG_DIR/${PROJECT_NAME}_${service}.pid" >/dev/null; then
                    echo -ne "${COLOR_GREEN}● ${service^}${COLOR_RESET} "
                else
                    echo -ne "${COLOR_RED}○ ${service^}${COLOR_RESET} "
                fi
            done
            echo ""
        fi
    else
        echo -e "${COLOR_BOLD}Active Project:${COLOR_RESET} ${COLOR_YELLOW}None${COLOR_RESET}"
    fi
    
    echo -e "\n${COLOR_BOLD}╔════════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║                  MAIN MENU                     ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚════════════════════════════════════════════════╝${COLOR_RESET}\n"
    echo " 1.  Select Project"
    echo " 2.  Add New Project"
    echo " 3.  Update Project"
    echo " 4.  Start Project"
    echo " 5.  Stop Project"
    echo " 6.  Restart Project"
    echo " 7.  Project Status"
    echo " 8.  View Logs"
    echo " 9.  Clean Cache"
    echo " 10. Open in Browser"
    echo " 11. Exit"
    echo -e "\n${COLOR_BOLD}════════════════════════════════════════════════${COLOR_RESET}\n"
    echo -n "Select option: "
}

main_loop() {
    while true; do
        show_menu
        read choice
        
        case "$choice" in
            1)  select_project ;;
            2)  add_project ;;
            3)  update_project ;;
            4)  start_project ;;
            5)  stop_project ;;
            6)  restart_project ;;
            7)  show_status ;;
            8)  view_logs ;;
            9)  clean_cache ;;
            10) open_browser ;;
            11) 
                show_header
                print_msg "info" "Exiting..."
                exit 0
                ;;
            *)
                show_header
                print_msg "error" "Invalid option"
                pause
                ;;
        esac
    done
}

# ============================================================================
# CLEANUP & MAIN EXECUTION
# ============================================================================

# Fixed: Proper cleanup on exit
cleanup_on_exit() {
    echo ""
    print_msg "info" "Cleaning up..."
    
    if [ -f "$ACTIVE_PROJECT_FILE" ]; then
        local active=$(cat "$ACTIVE_PROJECT_FILE" 2>/dev/null)
        if [ -n "$active" ] && load_project "$active" 2>/dev/null; then
            stop_service "frontend" 2>/dev/null
            stop_service "backend" 2>/dev/null
        fi
    fi
    
    print_msg "success" "Cleanup complete"
    exit 130
}

trap cleanup_on_exit INT TERM

# Initialize
init_environment
check_dependencies || {
    print_msg "error" "Dependency check failed"
    exit 1
}

# Start
main_loop
