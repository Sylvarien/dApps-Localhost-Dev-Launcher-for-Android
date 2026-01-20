#!/data/data/com.termux/files/usr/bin/bash

============================================================================

DApps Localhost Launcher - Professional v3.3.0 (fixed & improved)

- ID project: incremental numeric (1,2,3...)

- Path display: masked ("storage" / "termux") in UI & list; full path available via CLI command

- Run project: otomatis deteksi nama folder frontend/backend (fleksibel)

- Web DB Viewer: sync endpoint tetap, but UI tidak menampilkan full path (hanya type)

- Logging per-sync tetap ada

============================================================================

set -euo pipefail

---------------------------

Configuration

---------------------------

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}" PROJECTS_DIR="$HOME/dapps-projects" CONFIG_FILE="$HOME/.dapps.conf" LOG_DIR="$HOME/.dapps-logs" LAUNCHER_VERSION="3.3.0"

Default viewer location

DB_VIEWER_DIR="${DB_VIEWER_DIR:-$HOME/paxiforge-db-viewer}" DB_VIEWER_PORT="${DB_VIEWER_PORT:-8081}"

PG_DATA="${PG_DATA:-$PREFIX/var/lib/postgresql}" PG_LOG="$HOME/pgsql.log"

GIT_REPO="https://github.com/youruser/dapps-launcher.git"   # <-- ganti jika perlu

Colors

R="[31m"; G="[32m"; Y="[33m"; B="[34m"; C="[36m"; X="[0m"; BOLD="[1m"

Ensure dirs

mkdir -p "$PROJECTS_DIR" "$LOG_DIR" "$DB_VIEWER_DIR" touch "$CONFIG_FILE"

---------------------------

Helpers

---------------------------

msg() { case "$1" in ok)   echo -e "${G}✓${X} $2" ;; err)  echo -e "${R}✗${X} $2" ;; warn) echo -e "${Y}!${X} $2" ;; info) echo -e "${B}i${X} $2" ;; *)    echo -e "$1" ;; esac }

get_device_ip() { local ip ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7; exit}') [ -z "$ip" ] && ip=$(ip -4 addr show scope global | awk '/inet/ && $2 !~ /127/ {split($2,a,"/"); print a[1]; exit}') [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}') echo "${ip:-127.0.0.1}" }

wait_key() { echo -e " ${C}Tekan ENTER untuk kembali...${X}" read -r }

confirm() { read -rp "$1 (y/N): " ans [[ "$ans" =~ ^[Yy]$ ]] }

md5_file() { if command -v md5sum &>/dev/null; then md5sum "$1" 2>/dev/null | awk '{print $1}' elif command -v md5 &>/dev/null; then md5 -q "$1" 2>/dev/null else echo "" fi }

---------------------------

Config format (unchanged):

id|name|local_path|source_path|fe_dir|be_dir|fe_port|be_port|fe_cmd|be_cmd|auto_restart|auto_sync

id is numeric sequential

---------------------------

generate incremental numeric id

generate_id() { if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then echo "1"; return 0 fi local max=0 while IFS='|' read -r id _; do [ -z "$id" ] && continue if [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt "$max" ]; then max=$id; fi done < "$CONFIG_FILE" echo $((max+1)) }

save_project() { local id="$1" name="$2" local_path="$3" source_path="$4" local fe_dir="$5" be_dir="$6" fe_port="$7" be_port="$8" local fe_cmd="$9" be_cmd="${10}" auto_restart="${11}" auto_sync="${12}" # remove old line if exists grep -v "^$id|" "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" 2>/dev/null || true echo "$id|$name|$local_path|$source_path|$fe_dir|$be_dir|$fe_port|$be_port|$fe_cmd|$be_cmd|$auto_restart|$auto_sync" >> "$CONFIG_FILE" }

load_project() { local id="$1" local line line=$(grep "^$id|" "$CONFIG_FILE" 2>/dev/null | head -n1 || true) [ -z "$line" ] && return 1 IFS='|' read -r PROJECT_ID PROJECT_NAME PROJECT_PATH SOURCE_PATH 
FE_DIR BE_DIR FE_PORT BE_PORT FE_CMD BE_CMD 
AUTO_RESTART AUTO_SYNC <<< "$line" return 0 }

---------------------------

Flexible dir detection

- jika FE_DIR atau BE_DIR kosong atau tidak ada, coba deteksi dari nama folder umum

---------------------------

detect_dirs_if_needed() { # expects PROJECT_PATH loaded local p="$PROJECT_PATH" [ -z "$p" ] && return 1 # frontend candidates local f_candidates=("frontend" "client" "web" "ui" "app" "src" "public") local b_candidates=("backend" "server" "api" "app" "srv" "service")

# only set FE_DIR if not exists or not a dir
if [ -z "$FE_DIR" ] || [ ! -d "$p/$FE_DIR" ]; then
    for d in "${f_candidates[@]}"; do
        if [ -d "$p/$d" ]; then FE_DIR="$d"; break; fi
    done
    # fallback: choose any dir with package.json having scripts
    if [ -z "$FE_DIR" ]; then
        for d in "$p"/*/; do
            [ -d "${d%/}" ] || continue
            if [ -f "${d%/}/package.json" ]; then FE_DIR="$(basename "${d%/}")"; break; fi
        done
    fi
fi

if [ -z "$BE_DIR" ] || [ ! -d "$p/$BE_DIR" ]; then
    for d in "${b_candidates[@]}"; do
        if [ -d "$p/$d" ]; then BE_DIR="$d"; break; fi
    done
    if [ -z "$BE_DIR" ]; then
        for d in "$p"/*/; do
            [ -d "${d%/}" ] || continue
            if [ -f "${d%/}/package.json" ]; then
                # if same as FE_DIR skip unless no other
                if [ "$(basename "${d%/}")" != "$FE_DIR" ]; then BE_DIR="$(basename "${d%/}")"; break; fi
            fi
        done
    fi
fi

# if still empty, default to 'frontend'/'backend' but do not create
FE_DIR="${FE_DIR:-frontend}"
BE_DIR="${BE_DIR:-backend}"
return 0

}

---------------------------

Short display for paths: show type instead of full path

---------------------------

path_type() { local p="$1" if [ -z "$p" ]; then echo "(none)"; return; fi if [[ "$p" =~ ^/storage ]] || [[ "$p" =~ ^/sdcard ]] || [[ "$p" =~ ^/mnt/media_rw ]]; then echo "storage" else echo "termux" fi }

short_path() { path_type "$1" }

---------------------------

copy/storage sync helpers (same as before but adapted)

---------------------------

copy_storage_to_termux() { local src="$1" dest="$2" [ -z "$src" ] && { msg err "Sumber kosong"; return 1; } [ -z "$dest" ] && { msg err "Tujuan kosong"; return 1; } if [ ! -d "$src" ]; then msg err "Sumber tidak ditemukan: $src"; return 1; fi mkdir -p "$dest" if command -v rsync &>/dev/null; then msg info "Meng-copy (rsync) dari $src -> $dest" rsync -a --delete --checksum --no-perms --omit-dir-times --out-format='%n|%l' "$src"/ "$dest"/ > "$LOG_DIR/rsync_tmp.out" 2>&1 || { msg err "rsync gagal"; return 1; } local total_bytes=0 files=0 if [ -f "$LOG_DIR/rsync_tmp.out" ]; then while IFS='|' read -r file size; do [[ -z "$file" ]] && continue files=$((files+1)) size=${size:-0} total_bytes=$((total_bytes + size)) done < "$LOG_DIR/rsync_tmp.out" || true mkdir -p "$dest/.dapps" 2>/dev/null || true echo "{"files":$files,"bytes":$total_bytes}" > "$dest/.dapps/sync_summary.json" 2>/dev/null || true mv "$LOG_DIR/rsync_tmp.out" "$LOG_DIR/${PROJECT_ID}_sync.log" 2>/dev/null || true fi else msg warn "rsync tidak tersedia. Menggunakan tar-stream fallback (lebih lambat)." (cd "$src" && tar -cpf - .) | (cd "$dest" && tar -xpf -) || { msg err "tar copy gagal"; return 1; } local cnt; cnt=$(find "$dest" -type f | wc -l 2>/dev/null || echo 0) local bytes; bytes=$(du -sb "$dest" 2>/dev/null | awk '{print $1}' || echo 0) mkdir -p "$dest/.dapps" 2>/dev/null || true echo "{"files":$cnt,"bytes":$bytes}" > "$dest/.dapps/sync_summary.json" 2>/dev/null || true echo "tar fallback: files=$cnt bytes=$bytes" > "$LOG_DIR/${PROJECT_ID}_sync.log" 2>/dev/null || true fi msg ok "Copy selesai: $dest" mkdir -p "$dest/.dapps" date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/.dapps/.last_synced" 2>/dev/null || true return 0 }

---------------------------

Sync functions

---------------------------

sync_project_by_id() { local id="$1" load_project "$id" || { msg err "Project not found"; return 1; } # ensure detection detect_dirs_if_needed || true if [ -z "$SOURCE_PATH" ] || [ ! -d "$SOURCE_PATH" ]; then msg warn "source_path tidak diset atau tidak ada untuk project $PROJECT_NAME" read -rp "Masukkan storage source path untuk project (kosong untuk batalkan): " sp [ -z "$sp" ] && { msg err "Cancelled"; return 1; } SOURCE_PATH="$sp" fi msg info "Sinkronisasi: $(path_type "$SOURCE_PATH") -> $PROJECT_PATH" export PROJECT_ID="$PROJECT_ID" copy_storage_to_termux "$SOURCE_PATH" "$PROJECT_PATH" || { msg err "Sync gagal"; return 1; } msg ok "Sync selesai untuk $PROJECT_NAME" return 0 }

sync_project() { header echo -e "${BOLD}Sync Project${X} " echo "1) Sync by project ID" echo "2) Sync ALL projects that have source_path set" echo "0) Kembali" read -rp "Select: " ch case "$ch" in 1) list_projects_table || { msg warn "No projects"; wait_key; return; } echo "" read -rp "Enter project ID to sync: " id [ -z "$id" ] && { msg err "ID required"; wait_key; return; } sync_project_by_id "$id" wait_key ;; 2) while IFS='|' read -r id name local_path source_path fe_dir be_dir fe_port be_port fe_cmd be_cmd auto_restart auto_sync; do [ -z "$id" ] && continue if [ -n "$source_path" ] && [ -d "$source_path" ]; then msg info "Syncing $name ($id)"; sync_project_by_id "$id" || msg warn "Fail: $name" else msg warn "Skip $name ($id) - no source_path" fi done < "$CONFIG_FILE" wait_key ;; 0) return ;; *) msg err "Invalid"; wait_key ;; esac }

auto sync invoked at start if AUTO_SYNC=1

auto_sync_project() { local id="$1" load_project "$id" || return 1 [ "$AUTO_SYNC" != "1" ] && return 0 if [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ]; then msg info "Auto-sync aktif -> Syncing $PROJECT_NAME" sync_project_by_id "$id" || msg warn "Auto-sync gagal untuk $PROJECT_NAME" else msg warn "Auto-sync: source tidak ada untuk $PROJECT_NAME" fi return 0 }

---------------------------

Listing: show masked path (type) not full path

---------------------------

list_projects_table() { if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then return 1 fi echo -e "${BOLD}ID | Status | Name                  | Source${X}" echo "---------------------------------------------------------------------" while IFS='|' read -r id name local_path source_path _; do [ -z "$id" ] && continue local status="${G}✓${X}" [ ! -d "$local_path" ] && status="${R}✗${X}" local running="" local fe_pid_file="$LOG_DIR/${id}_frontend.pid" local be_pid_file="$LOG_DIR/${id}_backend.pid" if [ -f "$fe_pid_file" ] || [ -f "$be_pid_file" ]; then local fe_pid=$(cat "$fe_pid_file" 2>/dev/null || true) local be_pid=$(cat "$be_pid_file" 2>/dev/null || true) if { [ -n "$fe_pid" ] && kill -0 "$fe_pid" 2>/dev/null; } || 
{ [ -n "$be_pid" ] && kill -0 "$be_pid" 2>/dev/null; }; then running=" ${G}[RUNNING]${X}" fi fi local src_type; src_type=$(path_type "$source_path") printf "%3s | %-6s | %-21s | %s%s " "$id" "$status" "${name:0:21}" "$src_type" "$running" done < "$CONFIG_FILE" echo "" echo "Untuk melihat path asli: ketik => <ID> open path" return 0 }

prompt_open_path_after_list() { echo "" read -rp "Ketik (<ID> open path) atau tekan ENTER: " cmd [ -z "$cmd" ] && return 0 if [[ "$cmd" =~ ^([0-9]+)[[:space:]]+open[[:space:]]+path$ ]]; then local id="${BASH_REMATCH[1]}" load_project "$id" || { msg err "Project not found"; return 1; } echo -e " Full path for $PROJECT_NAME ($id): $PROJECT_PATH SOURCE_PATH: $SOURCE_PATH " wait_key else msg err "Format tidak dikenali" wait_key fi }

---------------------------

PostgreSQL helpers (unchanged)

---------------------------

init_postgres_if_needed() { ... } status_postgres() { ... } start_postgres() { ... } stop_postgres() { ... } create_role_if_needed() { ... } create_db_if_needed() { ... } pg_size_for_db_quiet() { ... } clean_db_schema_public() { ... }

---------------------------

Parse .env for DB config

---------------------------

parse_db_config_from_env() { ... }

---------------------------

DB Viewer creation (server + UI) - updated to hide full path and show type

---------------------------

ensure_db_viewer_files() { mkdir -p "$DB_VIEWER_DIR/public" # package.json if [ ! -f "$DB_VIEWER_DIR/package.json" ]; then cat > "$DB_VIEWER_DIR/package.json" <<'JSON' { "name": "dapps-db-viewer", "version": "0.4.0", "main": "index.js", "dependencies": { "express": "^4.18.2", "pg": "^8.11.0" }, "scripts": { "start": "node index.js" } } JSON fi

# server index.js (with sync endpoints) - returns masked source type instead of full path in /api/projects
cat > "$DB_VIEWER_DIR/index.js" <<'NODE'

const fs = require('fs'); const path = require('path'); const express = require('express'); const { exec } = require('child_process'); const { Client } = require('pg'); const app = express(); app.use(express.json()); const CONFIG_FILE = process.env.CONFIG_FILE || path.join(process.env.HOME, '.dapps.conf'); const PUBLIC_DIR = path.join(__dirname, 'public'); const LOG_DIR = process.env.LOG_DIR || path.join(process.env.HOME, '.dapps-logs');

function parseConfig() { if (!fs.existsSync(CONFIG_FILE)) return []; const lines = fs.readFileSync(CONFIG_FILE,'utf8').split(/ ? /).filter(Boolean); return lines.map(l=>{ const parts = l.split('|'); return { id: parts[0], name: parts[1], path: parts[2], source: parts[3], fe_dir: parts[4], be_dir: parts[5], }; }); } function pathType(p){ if(!p) return '(none)'; if(p.startsWith('/storage')||p.startsWith('/sdcard')||p.startsWith('/mnt/media_rw')) return 'storage'; return 'termux'; } function readEnv(projectPath, be_dir) { const file = path.join(projectPath, be_dir, '.env'); if (!fs.existsSync(file)) return null; const data = fs.readFileSync(file,'utf8').split(/ ? /); const obj = {}; for (const line of data) { if (!line || line.trim().startsWith('#')) continue; const parts = line.split('='); const k = parts.shift(); const v = parts.join('=').replace(/^"/,'').replace(/"$/,''); obj[k] = v; } if (obj.DATABASE_URL && !obj.DB_NAME) { const m = obj.DATABASE_URL.match(/postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+):?([0-9]*)/(.+)/); if (m) { obj.DB_USER = m[1]; obj.DB_PASSWORD = m[2]; obj.DB_HOST = m[3]; obj.DB_PORT = m[4]||'5432'; obj.DB_NAME = m[5]; } } return obj; } function buildPgClientFromEnv(env) { return new Client({ host: env.DB_HOST||'127.0.0.1', port: env.DB_PORT||5432, user: env.DB_USER||process.env.USER, password: env.DB_PASSWORD||undefined, database: env.DB_NAME }); } app.use(express.static(PUBLIC_DIR)); app.get('/api/projects', (req,res)=>{ const projects = parseConfig().map(p=>{ const env = readEnv(p.path, p.be_dir) || {}; return { id: p.id, name: p.name, source_type: pathType(p.source), be_dir: p.be_dir, db: { host: env.DB_HOST||null, port: env.DB_PORT||null, name: env.DB_NAME||null, user: env.DB_USER||null } }; }); res.json(projects); });

// Sync endpoint remains app.post('/api/project/:id/sync', async (req,res)=>{ const projects = parseConfig(); const p = projects.find(x=>x.id===req.params.id); if (!p) return res.status(404).json({error:'project not found'}); const src = p.source || req.body.source; const dest = p.path; if (!src || !fs.existsSync(src)) return res.status(400).json({error:'source path not configured or not exists'}); try { fs.mkdirSync(LOG_DIR, { recursive: true }); } catch(e){} const logFile = path.join(LOG_DIR, ${p.id}_sync.log); const rsyncCmd = rsync -a --delete --checksum --out-format='%n|%l' ${escapeShell(src)}/ ${escapeShell(dest)}/; exec(rsyncCmd, {maxBuffer: 1024102450}, (err, stdout, stderr)=>{ const now = new Date().toISOString(); const header = SYNC ${now} from ${src} -> ${dest} ; fs.appendFileSync(logFile, header+stdout+(stderr?(' ERR: '+stderr):'')+'

'); const lines = stdout.split(/ ? /).filter(Boolean); let files=0, bytes=0; for (const l of lines) { const m = l.split('|'); if (m.length>=2) { files++; bytes += parseInt(m[1]||0,10); } } const summary = { files, bytes }; try { const dappsdir = path.join(dest,'.dapps'); fs.mkdirSync(dappsdir, {recursive:true}); fs.writeFileSync(path.join(dappsdir,'sync_summary.json'), JSON.stringify(summary)); fs.writeFileSync(path.join(dappsdir,'.last_synced'), new Date().toISOString()); } catch(e){} if (err) return res.status(500).json({error: 'rsync failed', details: stderr.slice(0,2000), summary}); return res.json({ok:true, summary, log: header + lines.slice(-200).join(' ')}); }); });

app.get('/api/project/:id/sync/log', (req,res)=>{ const projects = parseConfig(); const p = projects.find(x=>x.id===req.params.id); if (!p) return res.status(404).json({error:'project not found'}); const logFile = path.join(LOG_DIR, ${p.id}_sync.log); if (!fs.existsSync(logFile)) return res.json({ok:false, msg:'no log'}); const txt = fs.readFileSync(logFile,'utf8'); res.json({ok:true, log: txt.slice(-10000)}); });

// Other DB endpoints (unchanged) ... keep existing handlers for /api/db/:id/*

app.get('/api/db/:id/tables', async (req,res)=>{ /* ... / }); app.get('/api/db/:id/table/:table', async (req,res)=>{ / ... / }); app.get('/api/db/:id/info', async (req,res)=>{ / ... / }); app.post('/api/db/:id/clean', async (req,res)=>{ / ... / }); app.post('/api/db/clean-all', async (req,res)=>{ / ... / }); app.post('/api/project/:id/create-env', (req,res)=>{ / ... */ });

app.get('/', (req,res)=> res.sendFile(path.join(PUBLIC_DIR,'index.html'))); const PORT = process.env.PORT || 8081; app.listen(PORT, ()=> { console.log(DApps DB Viewer running on port ${PORT}); });

function escapeShell(s){ return '"'+String(s).replace(/"/g,'\"')+'"'; } NODE

# public/index.html (UI) - hide full path, show source_type only
cat > "$DB_VIEWER_DIR/public/index.html" <<'HTML'

<!doctype html>

<html lang="id">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>DApps DB Viewer + Sync (masked paths)</title>
  <style>/* styling sama seperti sebelumnya */</style>
</head>
<body>
  <header> ... </header>
  <main>
    <div class="panel" style="flex:0 0 360px">
      <h3>Projects</h3>
      <ul id="projects" class="projects"></ul>
    </div>
    <div class="panel" style="flex:0 0 300px">
      <h3>Tabel</h3>
      <div id="selectedProject" class="small"></div>
      <ul id="tables" class="tables"></ul>
    </div>
    <div class="panel" style="flex:1 1 auto">
      <h3>Isi Tabel / Log</h3>
      <div id="tableData"></div>
    </div>
  </main>
  <footer>...</footer>
<script>
(async function(){
  const $ = s=>document.querySelector(s);
  const projectsEl = $('#projects'), tableDataEl = $('#tableData');
  let projects = [], activeProject = null;
  async function fetchProjects(){
    projectsEl.innerHTML = '<li class="small">Memuat...</li>';
    try {
      const res = await fetch('/api/projects'); projects = await res.json(); renderProjects();
    } catch (e) { projectsEl.innerHTML = `<li class="error">Gagal: ${e.message}</li>`; }
  }
  function renderProjects(){
    if (!projects.length){ projectsEl.innerHTML = '<li class="small">Tidak ada project</li>'; return; }
    projectsEl.innerHTML = '';
    projects.forEach(p=>{
      const li = document.createElement('li'); li.textContent = `${p.id} • ${p.name} — [${p.source_type}]`;
      const bSync = document.createElement('button'); bSync.textContent='Sync'; bSync.onclick=()=>doSync(p.id);
      const bLog = document.createElement('button'); bLog.textContent='Sync Log'; bLog.onclick=()=>viewSyncLog(p.id);
      li.appendChild(bSync); li.appendChild(bLog);
      projectsEl.appendChild(li);
    });
  }
  async function doSync(id){ tableDataEl.innerHTML='Syncing...'; const res = await fetch(`/api/project/${id}/sync`, {method:'POST'}); const j=await res.json(); tableDataEl.innerHTML = j.ok? `files:${j.summary.files} bytes:${j.summary.bytes}` : 'Gagal'; }
  async function viewSyncLog(id){ const res = await fetch(`/api/project/${id}/sync/log`); const j = await res.json(); tableDataEl.innerHTML = j.ok? `<pre>${j.log}</pre>` : j.msg; }
  await fetchProjects();
})();
</script>
</body>
</html>
HTMLchmod -R 755 "$DB_VIEWER_DIR"
msg ok "DB Viewer files siap di: $DB_VIEWER_DIR"

}

start_db_viewer() { ensure_db_viewer_files if [ ! -d "$DB_VIEWER_DIR/node_modules" ]; then msg info "Menginstall dependencies untuk DB Viewer..." (cd "$DB_VIEWER_DIR" && npm install --silent) || { msg err "npm install viewer gagal"; return 1; } fi local pidf="$LOG_DIR/db_viewer.pid"; local logf="$LOG_DIR/db_viewer.log" if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then msg info "DB Viewer sudah berjalan (PID: $(cat "$pidf"))" return 0 fi (cd "$DB_VIEWER_DIR" && nohup PORT="$DB_VIEWER_PORT" CONFIG_FILE="$CONFIG_FILE" LOG_DIR="$LOG_DIR" node index.js > "$logf" 2>&1 & echo $! > "$pidf") sleep 1 if kill -0 "$(cat "$pidf")" 2>/dev/null; then msg ok "DB Viewer started (http://0.0.0.0:$DB_VIEWER_PORT)" return 0 else msg err "DB Viewer gagal start. Cek $logf" return 1 fi }

stop_db_viewer() { local pidf="$LOG_DIR/db_viewer.pid" if [ -f "$pidf" ]; then local pid=$(cat "$pidf") kill "$pid" 2>/dev/null || true rm -f "$pidf" msg ok "DB Viewer dihentikan" else msg info "DB Viewer tidak berjalan" fi }

---------------------------

add_project (flexible) - ask storage path or create skeleton

---------------------------

add_project() { header; read -rp "Project name: " name; [ -z "$name" ] && { msg err "Name required"; wait_key; return; } local id=$(generate_id); local local_path="$PROJECTS_DIR/$name"; mkdir -p "$local_path" local source_path="" if confirm "Ambil project dari storage (sdcard /storage/emulated/0)?"; then read -rp "Masukkan path sumber di storage (contoh: /storage/emulated/0/MyProjects/$name): " src [ -z "$src" ] && { msg err "Path sumber kosong"; wait_key; return; } export PROJECT_ID="$id" copy_storage_to_termux "$src" "$local_path" || { msg err "Gagal copy dari storage"; wait_key; return; } source_path="$src" else mkdir -p "$local_path" msg ok "Folder kosong dibuat di $local_path" fi # detect dirs FE_DIR=""; BE_DIR="" PROJECT_ID="$id"; PROJECT_NAME="$name"; PROJECT_PATH="$local_path"; SOURCE_PATH="$source_path" detect_dirs_if_needed save_project "$id" "$name" "$local_path" "$source_path" "$FE_DIR" "$BE_DIR" "3000" "8000" "npx serve ." "npm start" "0" "0" msg ok "Project added with ID: $id" wait_key }

delete_project, export_config_json, etc. (keep as before) - omitted here for brevity but remain in file

delete_project() { ... } export_config_json() { ... } diagnose_and_fix() { ... } self_update() { ... } uninstall_launcher() { ... }

---------------------------

Main menu (uses numeric ids)

---------------------------

show_menu() { header echo -e "${BOLD}MAIN MENU${X} " echo " 1. 📋 List All Projects" echo " 2. ➕ Add New Project" echo " 3. ▶️  Start Project (by ID)" echo " 4. ⏹️  Stop Project (by ID)" echo " 5. 📦 Install Dependencies (by ID)" echo " 6. 🔄 Sync Project (by ID)" echo " 7. 📝 View Logs (by ID)" echo " 8. 🗑️  Delete Project" echo " 9. 🔁 Export Config" echo "10. 🔧 Diagnostic & Fix Tool" echo "11. ⬆️  Update Launcher (self-update)" echo "12. 🗑️  Uninstall Launcher" echo "13. ✏️  Edit backend .env (by ID)" echo "14. 🗄️  PostgreSQL & DB Tools" echo " 0. 🚪 Keluar" echo -e " ${BOLD}═══════════════════════════════════${X}" read -rp "Select (0-14): " choice case "$choice" in 1) header; list_projects_table || msg warn "No projects"; prompt_open_path_after_list || true; wait_key ;; 2) add_project ;; 3) header; list_projects_table || { msg warn "No projects"; wait_key; return; } read -rp "Enter project ID: " id; [ -n "$id" ] && run_project_by_id "$id";; 4) header; list_projects_table || { msg warn "No projects"; wait_key; return; } read -rp "Enter project ID: " id; [ -n "$id" ] && stop_project_by_id "$id";; 5) header; list_projects_table || { msg warn "No projects"; wait_key; return; } echo ""; read -rp "Enter project ID: " id; [ -n "$id" ] && install_deps "$id"; wait_key ;; 6) sync_project ;; 7) view_logs ;; 8) delete_project ;; 9) export_config_json; wait_key ;; 10) diagnose_and_fix ;; 11) self_update ;; 12) uninstall_launcher ;; 13) header; list_projects_table || { wait_key; return; } echo ""; read -rp "Enter project ID: " id; [ -n "$id" ] && edit_env_file "$id" ;; 14) menu_postgres_tools ;; 0) header; msg info "Goodbye!"; exit 0 ;; *) msg err "Invalid choice"; wait_key ;; esac }

run_project_by_id: uses detect_dirs_if_needed to be flexible

run_project_by_id() { local id="$1"; load_project "$id" || { msg err "Project not found"; wait_key; return; } header; echo -e "${BOLD}Starting: $PROJECT_NAME (ID: $id)${X} " ( detect_dirs_if_needed || true [ "$AUTO_SYNC" = "1" ] && auto_sync_project "$id" || true [ ! -d "$PROJECT_PATH" ] && { msg err "Project path not found"; wait_key; return; } local fe_path="$PROJECT_PATH/$FE_DIR"; local be_path="$PROJECT_PATH/$BE_DIR" if [ -d "$fe_path" ] && [ -f "$fe_path/package.json" ] && [ ! -d "$fe_path/node_modules" ]; then confirm "Frontend deps missing. Install?" && install_deps "$id"; fi if [ -d "$be_path" ] && [ -f "$be_path/package.json" ] && [ ! -d "$be_path/node_modules" ]; then confirm "Backend deps missing. Install?" && install_deps "$id"; fi start_service "$id" "$FE_DIR" "$FE_PORT" "$FE_CMD" "frontend" start_service "$id" "$BE_DIR" "$BE_PORT" "$BE_CMD" "backend" if [ -f "$LOG_DIR/${id}_frontend.port" ]; then p=$(cat "$LOG_DIR/${id}_frontend.port"); ip=$(get_device_ip); echo -e "Frontend (device): http://$ip:$p"; fi if [ -f "$LOG_DIR/${id}_backend.port" ]; then p2=$(cat "$LOG_DIR/${id}_backend.port"); ip2=$(get_device_ip); echo -e "Backend (device): http://$ip2:$p2"; fi wait_key ) }

stop_project_by_id() { local id="$1"; load_project "$id" || { msg err "Project not found"; wait_key; return; }; stop_service "$id" "frontend"; stop_service "$id" "backend"; wait_key }

Remaining functions (install_deps, start_service, stop_service, dump/restore, etc.)

Keep implementations from previous full script (not duplicated here for brevity). Ensure they exist in the actual file.

Entrypoint

main() { check_deps || msg warn "Beberapa dependencies mungkin hilang (jalankan pkg install nodejs git postgresql rsync)" while true; do show_menu; done }

check_deps() { ... }

main
