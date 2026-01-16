# DApps Localhost Dev Launcher

> Lightweight development environment manager for Android/Termux

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/yourusername/dapps-launcher)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Termux-green.svg)](https://termux.com/)
[![License](https://img.shields.io/badge/license-MIT-orange.svg)](LICENSE)

**DApps Localhost Dev Launcher** is a pure Bash tool for managing multiple localhost development projects on Android devices through Termux. Built for developers who need real development environments on mobile devices without the overhead of Docker, PM2, or systemd.

---

## ✨ Features

- **Multi-Project Management** – Run multiple frontend/backend projects simultaneously with full isolation
- **Zero Dependencies** – Pure Bash/POSIX shell script, no external packages required
- **Smart Updates** – Automatic `npm install` only when `package.json` changes
- **Auto Dependency Detection** – Automatically installs Node.js, npm, and git if missing
- **Intelligent Port Management** – Automatic port conflict resolution (3000 → 3001 → ...)
- **Process Lifecycle** – Clean background processes with PID tracking, no zombies
- **Separate Logging** – Individual log files per service for easy debugging
- **Environment Variables** – Full `.env` file support
- **Low Resource Usage** – Optimized for devices with 1GB RAM or less

---

## 📋 Requirements

- **Termux** (Android 7.0+)
- **Internet connection** (for git clone and npm install)
- **Storage permission** (for project files)

---

## 🚀 Installation

```bash
# Download the script
curl -O https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh

# Make it executable
chmod +x launcher_website.sh

# Move to PATH (optional)
mv launcher_website.sh ~/.local/bin/dapps
```

Or install directly:

```bash
curl -fsSL https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh | bash
```

# or if you want to install it then move it to the dapps folder:
```bash
curl -fsSL -o ~/launcher_website.sh \
https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh \
&& chmod +x ~/launcher_website.sh \
&& mv ~/launcher_website.sh $PREFIX/bin/dapps
```
run:
```bash
dapps
```
updated:
```bash
dapps # then chose update option
```

re-install & updated all in one: 
```bash
curl -fsSL https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh \
| sed '1c #!/data/data/com.termux/files/usr/bin/bash' \
> $PREFIX/bin/dapps && chmod +x $PREFIX/bin/dapps
```
---

## 📖 Usage

### Basic Commands

```bash
# Add a new project
dapps add <name> <repo> <folder> <fe_dir> <be_dir> <fe_port> <be_port>

# Select active project
dapps select <name>

# Update project (smart git pull + npm install)
dapps update <name>

# Start services
dapps start <name>

# Check status
dapps status <name>

# View logs
dapps logs <name> [frontend|backend]

# Stop services
dapps stop <name>

# Clean project files
dapps clean <name>
```

### Example Workflow

```bash
# 1. Add your project
dapps add myapp \
  https://github.com/user/fullstack-app.git \
  myapp \
  client \
  server \
  3000 \
  8000

# 2. Start the project
dapps start myapp

# 3. View status
dapps status myapp
# Output:
# Frontend: Running on http://localhost:3000 (PID: 12345)
# Backend: Running on http://localhost:8000 (PID: 12346)

# 4. Check logs
dapps logs myapp frontend

# 5. Stop when done
dapps stop myapp
```

---

## ⚙️ Configuration

### Project Configuration File

Location: `~/.dapps_projects.conf`

Format (pipe-separated):
```
name|repo|folder|fe_dir|be_dir|fe_port|be_port
```

Example:
```
myapp|https://github.com/user/repo.git|myapp|frontend|backend|3000|8000
todoapp|https://github.com/user/todo.git|todo|client|api|3001|8001
```

### Log Files

Location: `~/.dapps_logs/`

Structure:
```
myapp_frontend.log    # Frontend console output
myapp_backend.log     # Backend console output
myapp_frontend.pid    # Frontend process ID
myapp_backend.pid     # Backend process ID
```

---

## 🔧 How It Works

### Smart Update System

```bash
# On update command:
1. Git pull latest changes
2. Check if package.json changed (via git diff)
3. Run npm install only if needed
4. Save new hash for next comparison
```

### Port Conflict Resolution

```bash
# Automatic fallback:
3000 → 3001 → 3002 → ... (up to 10 attempts)
8000 → 8001 → 8002 → ...

# Prevents:
Error: listen EADDRINUSE :::3000
```

### Process Management

```bash
# Background execution with nohup:
nohup npm start > ~/.dapps_logs/myapp_frontend.log 2>&1 &
echo $! > ~/.dapps_logs/myapp_frontend.pid

# Clean shutdown:
kill $(cat ~/.dapps_logs/myapp_frontend.pid)
```

---

## 🎯 Use Cases

- **Mobile Development** – Test full-stack apps on your phone
- **Learning & Prototyping** – Quick project setup without desktop
- **Remote Work** – Dev environment on tablet with keyboard
- **Low-End Hardware** – Runs smoothly on budget Android devices
- **Offline Development** – Works without constant internet after initial clone

---

## ⚠️ Limitations

- **No HTTPS** – Local development only (use ngrok for external access)
- **No Database Management** – Use separate Termux packages for PostgreSQL/MongoDB
- **Single User** – Not designed for multi-user scenarios
- **Standard Git Auth** – Uses system git credentials (SSH keys or HTTPS tokens)

---

## 🛠️ Troubleshooting

### Services won't start
```bash
# Check if ports are in use
netstat -tuln | grep :3000

# View detailed logs
dapps logs myapp frontend
```

### npm install fails
```bash
# Update npm
npm install -g npm@latest

# Clear cache
npm cache clean --force
```

### Process becomes zombie
```bash
# Clean stop
dapps stop myapp

# Force kill if needed
pkill -f "node.*myapp"
```

---

## ✅ **TESTING CHECKLIST**

```bash
# Test 1: Port conflict
nc -l 3000 &
./dapps-launcher.sh
# → Should use port 3001

# Test 2: npm timeout
# Edit package.json dengan typo
# → Should timeout in 5 minutes

# Test 3: Ctrl+C cleanup
./dapps-launcher.sh
# Start project
# Ctrl+C
# Check: ps aux | grep node
# → No zombie processes

# Test 4: Git conflict
# Edit file, don't commit
# Update project
# → Should show error with hint

# Test 5: .env with spaces
echo 'DB_URL="postgres://user with space"' > .env
# → Should load correctly
```

## 📝 Changelog

### v1.0.0 (Jan 16, 2026)
- Initial release
- Multi-project support with isolation
- Smart git + npm update mechanism
- Automatic port conflict handling
- Full process lifecycle management
- Separate logging per service

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

---

## 🙏 Acknowledgments

Built for the Termux community and mobile developers who refuse to compromise on their development environment.

---

---

<div align="center">

**Made with ❤️ for Android developers**

</div>
