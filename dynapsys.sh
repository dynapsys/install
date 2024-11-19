#!/bin/bash
set -e

# Kolory dla lepszej czytelności
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Konfiguracja
INSTALL_DIR="/opt/dynapsys"
REPO_URL="https://github.com/dynapsys/install"
SERVICE_USER="dynapsys"

# Funkcja logowania
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Sprawdzenie czy skrypt jest uruchomiony jako root
if [ "$EUID" -ne 0 ]; then 
    error "Ten skrypt musi być uruchomiony jako root"
fi

# Sprawdzenie systemu operacyjnego
if [ ! -f /etc/os-release ]; then
    error "Nie można określić systemu operacyjnego"
fi
. /etc/os-release

case $ID in
    ubuntu|debian)
        log "Wykryto system: $PRETTY_NAME"
        PKG_MANAGER="apt-get"
        PKG_UPDATE="$PKG_MANAGER update"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PACKAGES="python3 python3-pip git curl certbot python3-certbot-nginx protobuf-compiler golang-go nginx"
        ;;
    centos|rhel|fedora)
        log "Wykryto system: $PRETTY_NAME"
        PKG_MANAGER="dnf"
        PKG_UPDATE="$PKG_MANAGER update -y"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PACKAGES="python3 python3-pip git curl certbot python3-certbot-nginx protobuf-compiler golang nginx"
        ;;
    *)
        error "Niewspierany system operacyjny: $PRETTY_NAME"
        ;;
esac

# Instalacja zależności
log "Aktualizacja listy pakietów..."
$PKG_UPDATE

log "Instalacja wymaganych pakietów..."
$PKG_INSTALL $PACKAGES

# Instalacja Caddy
log "Instalacja Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/setup.deb.sh' | bash
$PKG_INSTALL caddy

# Tworzenie użytkownika systemowego
log "Tworzenie użytkownika systemowego..."
useradd -r -s /bin/false $SERVICE_USER || warning "Użytkownik już istnieje"

# Tworzenie katalogów
log "Tworzenie struktury katalogów..."
mkdir -p $INSTALL_DIR/{services,ssl,logs}
mkdir -p /var/log/dynapsys

# Instalacja Go protoc plugins
log "Instalacja Go protoc plugins..."
export PATH=$PATH:/usr/local/go/bin
export GOPATH=/root/go
export PATH=$PATH:$GOPATH/bin

go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Pobieranie i instalacja aplikacji
log "Pobieranie aplikacji..."
if [ -d "$INSTALL_DIR" ]; then
    cd $INSTALL_DIR
    if [ -d ".git" ]; then
        git pull
    else
        git clone $REPO_URL .
    fi
else
    git clone $REPO_URL $INSTALL_DIR
fi

# Konfiguracja środowiska Python
log "Instalacja zależności Python..."
cd $INSTALL_DIR
python3 -m pip install -r requirements.txt

# Tworzenie pliku .env jeśli nie istnieje
if [ ! -f "$INSTALL_DIR/.env" ]; then
    log "Tworzenie pliku konfiguracyjnego .env..."
    cat > $INSTALL_DIR/.env <<EOF
# Konfiguracja Cloudflare
CLOUDFLARE_TOKEN=your-token-here
DOMAIN_SUFFIX=example.com

# Konfiguracja Email
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASS=your-app-specific-password
FROM_EMAIL=noreply@example.com

# Konfiguracja aplikacji
ADMIN_EMAIL=admin@example.com
LOG_LEVEL=INFO
API_PORT=8000
EOF
    warning "Proszę uzupełnić dane w pliku $INSTALL_DIR/.env"
fi

# Konfiguracja Caddy
log "Konfiguracja Caddy..."
cat > /etc/caddy/Caddyfile <<EOF
{
    email {$ADMIN_EMAIL}
    admin 0.0.0.0:2019
}

import $INSTALL_DIR/services/*/Caddyfile
EOF

# Tworzenie pliku systemd dla głównej usługi
log "Konfiguracja systemd..."
cat > /etc/systemd/system/dynapsys.service <<EOF
[Unit]
Description=Dynapsys - gRPC Service Manager
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=/usr/bin/python3 $INSTALL_DIR/dynapsys.py
Restart=always
StandardOutput=append:/var/log/dynapsys/service.log
StandardError=append:/var/log/dynapsys/error.log

[Install]
WantedBy=multi-user.target
EOF

# Ustawienie uprawnień
log "Ustawianie uprawnień..."
chown -R $SERVICE_USER:$SERVICE_USER $INSTALL_DIR
chown -R $SERVICE_USER:$SERVICE_USER /var/log/dynapsys
chmod 755 $INSTALL_DIR/dynapsys.py

# Konfiguracja logrotate
log "Konfiguracja logrotate..."
cat > /etc/logrotate.d/dynapsys <<EOF
/var/log/dynapsys/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 $SERVICE_USER $SERVICE_USER
}
EOF

# Tworzenie skryptu pomocniczego
log "Tworzenie skryptu pomocniczego..."
cat > /usr/local/bin/dynapsys <<EOF
#!/bin/bash

case "\$1" in
    start)
        systemctl start dynapsys
        ;;
    stop)
        systemctl stop dynapsys
        ;;
    restart)
        systemctl restart dynapsys
        ;;
    status)
        systemctl status dynapsys
        ;;
    logs)
        journalctl -u dynapsys -f
        ;;
    deploy)
        if [ -z "\$2" ] || [ -z "\$3" ] || [ -z "\$4" ]; then
            echo "Usage: dynapsys deploy <git_repo> <domain> <service_name>"
            exit 1
        fi
        curl -X POST "http://localhost:8000/deploy" \
            -H "Content-Type: application/json" \
            -d "{
                \"git_repo\": \"\$2\",
                \"domain\": \"\$3\",
                \"service_name\": \"\$4\"
            }"
        ;;
    *)
        echo "Usage: dynapsys {start|stop|restart|status|logs|deploy}"
        exit 1
        ;;
esac
EOF

chmod +x /usr/local/bin/dynapsys

# Uruchomienie usług
log "Uruchamianie usług..."
systemctl daemon-reload
systemctl enable caddy
systemctl enable dynapsys
systemctl start caddy
systemctl start dynapsys

log "Instalacja zakończona pomyślnie!"
log "Proszę uzupełnić dane w pliku $INSTALL_DIR/.env"
log "Aby zarządzać usługą, użyj: dynapsys {start|stop|restart|status|logs|deploy}"

# Wyświetl przykład użycia
cat <<EOF

${GREEN}Przykład użycia:${NC}

1. Edytuj plik konfiguracyjny:
   nano $INSTALL_DIR/.env

2. Zrestartuj usługę:
   dynapsys restart

3. Deploy nowej usługi:
   dynapsys deploy \\
     "https://github.com/user/service" \\
     "api.example.com" \\
     "my-service"

4. Sprawdź logi:
   dynapsys logs

EOF