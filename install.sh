#!/bin/bash

set -e

# Kolory dla lepszej czytelności
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
NAME=dynapsys

# Funkcje pomocnicze
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }
warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }

# Funkcja do generowania klucza SSH
generate_ssh_key() {
    local KEY_FILE="$1"
    if [ ! -f "$KEY_FILE" ]; then
        log "Generowanie nowego klucza SSH..."
        ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "$NAME-$(date +%Y%m%d)"
    else
        warning "Używam istniejącego klucza: $KEY_FILE"
    fi
}

# Funkcja do bezpiecznego kopiowania klucza SSH
copy_ssh_key() {
    local SERVER="$1"
    local SSH_USER="$2"
    local SSH_KEY="$3"

    log "Kopiowanie klucza SSH na serwer..."

    # Tworzenie tymczasowego pliku konfiguracji SSH
    local SSH_CONFIG=$(mktemp)
    cat > "$SSH_CONFIG" <<EOF
Host temp-host
    HostName $SERVER
    User $SSH_USER
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

    # Próba skopiowania klucza z użyciem hasła
    if command -v sshpass >/dev/null 2>&1; then
        log "Podaj hasło SSH dla $SSH_USER@$SERVER:"
        read -s SSH_PASS
        echo

        sshpass -p "$SSH_PASS" ssh-copy-id -i "$SSH_KEY.pub" -f -o "IdentitiesOnly=yes" "$SSH_USER@$SERVER"
    else
        # Alternatywna metoda bez sshpass
        log "Kopiowanie klucza ręcznie..."
        local PUB_KEY=$(cat "$SSH_KEY.pub")
        ssh -F "$SSH_CONFIG" temp-host "mkdir -p ~/.ssh && echo '$PUB_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    fi

    # Usunięcie tymczasowego pliku konfiguracji
    rm -f "$SSH_CONFIG"
}

# Funkcja do testowania połączenia SSH
test_ssh_connection() {
    local SERVER="$1"
    local SSH_USER="$2"
    local SSH_KEY="$3"

    log "Testowanie połączenia SSH..."

    # Tworzenie tymczasowego pliku konfiguracji SSH
    local SSH_CONFIG=$(mktemp)
    cat > "$SSH_CONFIG" <<EOF
Host temp-host
    HostName $SERVER
    User $SSH_USER
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    PreferredAuthentications publickey
EOF

    if ssh -F "$SSH_CONFIG" temp-host 'echo "SSH connection successful"'; then
        log "Połączenie SSH działa poprawnie"
        rm -f "$SSH_CONFIG"
        return 0
    else
        error "Nie można nawiązać połączenia SSH"
        rm -f "$SSH_CONFIG"
        return 1
    fi
}

# Funkcja do instalacji na serwerze
run_remote_installation() {
    local SERVER="$1"
    local SSH_USER="$2"
    local SSH_KEY="$3"
    local CLOUDFLARE_TOKEN="$4"
    local DOMAIN="$5"

    # Tworzenie tymczasowego pliku konfiguracji SSH
    local SSH_CONFIG=$(mktemp)
    cat > "$SSH_CONFIG" <<EOF
Host deploy-host
    HostName $SERVER
    User $SSH_USER
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    PreferredAuthentications publickey
    ControlMaster auto
    ControlPath ~/.ssh/control-%r@%h:%p
    ControlPersist 10m
EOF

    # Przygotowanie pliku .env
    log "Przygotowanie konfiguracji..."
    local ENV_FILE=$(mktemp)
    cat > "$ENV_FILE" <<EOF
CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN
DOMAIN_SUFFIX=$DOMAIN
ADMIN_EMAIL=admin@$DOMAIN
LOG_LEVEL=INFO
API_PORT=8000
EOF

    # Kopiowanie plików na serwer
    log "Kopiowanie plików na serwer..."
    scp -F "$SSH_CONFIG" "$ENV_FILE" deploy-host:/tmp/.env

    # Wykonanie instalacji
    log "Uruchamianie instalacji..."
    ssh -F "$SSH_CONFIG" deploy-host << 'ENDSSH'
    # Instalacja wymaganych pakietów
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y curl

    # Pobranie i uruchomienie skryptu instalacyjnego
    curl -fsSL https://raw.githubusercontent.com/dynapsys/install/main/dynapsys.sh -o /tmp/dynapsys.sh
    chmod +x /tmp/dynapsys.sh
    
    # Przeniesienie pliku .env
    sudo mkdir -p /opt/dynapsys
    sudo mv /tmp/.env /opt/dynapsys/.env
    
    # Uruchomienie instalacji dynapsys
    sudo /tmp/dynapsys.sh
    
    # Czyszczenie
    rm -f /tmp/dynapsys.sh
ENDSSH
    
    # Sprzątanie
    rm -f "$SSH_CONFIG" "$ENV_FILE"
}

# Funkcja do weryfikacji instalacji dynapsys
verify_installation() {
    local SERVER="$1"
    local SSH_USER="$2"
    local SSH_KEY="$3"

    log "Weryfikacja instalacji dynapsys..."

    # Sprawdzenie statusu usług
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER" << 'EOF'
    echo "Status usługi dynapsys:"
    sudo systemctl status dynapsys --no-pager

    echo -e "\nStatus Caddy:"
    sudo systemctl status caddy --no-pager

    echo -e "\nSprawdzanie portów:"
    sudo netstat -tulpn | grep -E ':(80|443|8000|2019)'

    echo -e "\nSprawdzanie logów:"
    sudo tail -n 10 /var/log/dynapsys/service.log
EOF
}


# Główny skrypt
main() {
    # Sprawdzenie argumentów
    if [ "$#" -lt 3 ]; then
        echo "Użycie: $0 <server_ip> <ssh_user> <domain> [cloudflare_token]"
        echo "Przykład: $0 192.168.1.100 ubuntu example.com CF_TOKEN_123"
        exit 1
    fi

    SERVER="$1"
    SSH_USER="$2"
    DOMAIN="$3"
    CLOUDFLARE_TOKEN="${4:-$(cat ~/.cloudflare_token 2>/dev/null || echo '')}"

    # Sprawdzenie tokenu Cloudflare
    if [ -z "$CLOUDFLARE_TOKEN" ]; then
        error "Brak tokenu Cloudflare. Podaj jako argument lub zapisz w ~/.cloudflare_token"
    fi

    # Konfiguracja SSH
    SSH_DIR="$HOME/.ssh"
    KEY_FILE="$SSH_DIR/$NAME_$(echo $SERVER | tr '.' '_')"
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Generowanie klucza SSH
    generate_ssh_key "$KEY_FILE"

    # Kopiowanie klucza SSH
    copy_ssh_key "$SERVER" "$SSH_USER" "$KEY_FILE"

    # Test połączenia
    test_ssh_connection "$SERVER" "$SSH_USER" "$KEY_FILE"

    # Instalacja na serwerze
    run_remote_installation "$SERVER" "$SSH_USER" "$KEY_FILE" "$CLOUDFLARE_TOKEN" "$DOMAIN"

    # Konfiguracja serwera
    #setup_server "$SERVER" "$SSH_USER" "$KEY_FILE" "$CLOUDFLARE_TOKEN" "$DOMAIN"

    # Weryfikacja instalacji
    verify_installation "$SERVER" "$SSH_USER" "$KEY_FILE"

    log "Instalacja zakończona pomyślnie!"
    cat << EOF

${GREEN}Instrukcje dostępu do serwera:${NC}

1. Połącz się z serwerem:
   ssh -i $KEY_FILE $SSH_USER@$SERVER

2. Zarządzaj usługą:
   dynapsys status
   dynapsys logs

3. Dodaj nową usługę:
   dynapsys deploy \\
     "https://github.com/user/service" \\
     "api.$DOMAIN" \\
     "my-service"

EOF
}

# Uruchomienie skryptu
main "$@"