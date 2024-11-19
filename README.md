Skrypt do inicjalizacji połączenia SSH i zdalnej instalacji na serwerze.


Użycie skryptu:

```bash
# 1. Pobierz skrypt
curl -O https://raw.githubusercontent.com/dynapsys/install/main/install.sh
chmod +x install.sh

# 2. Uruchom instalację
./install.sh 192.168.1.100 root dynapsys.com CF_TOKEN_123

# Lub z tokenem w pliku
echo "your-cloudflare-token" > ~/.cloudflare_token
./install.sh 192.168.1.100 root dynapsys.com
```

Skrypt wykonuje:

1. **Przygotowanie SSH**:
    - Generuje klucz SSH jeśli nie istnieje
    - Kopiuje klucz na serwer
    - Testuje połączenie

2. **Konfiguracja serwera**:
    - Aktualizuje system
    - Przygotowuje plik `.env`
    - Pobiera i uruchamia skrypt instalacyjny

3. **Weryfikacja**:
    - Sprawdza status usług
    - Weryfikuje otwarte porty
    - Sprawdza logi

4. **Dokumentacja**:
    - Wyświetla instrukcje dostępu
    - Pokazuje przykłady użycia

Bezpieczeństwo:
- Używa dedykowanego klucza SSH
- Bezpiecznie przechowuje token Cloudflare
- Automatycznie czyści wrażliwe dane

Dodatkowe funkcje:
1. **Automatyczny backup**:
```bash
# Dodaj do skryptu
setup_backup() {
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER" << 'EOF'
    # Konfiguracja automatycznego backupu
    sudo mkdir -p /opt/dynapsys/backups
    echo "0 3 * * * root /opt/dynapsys/scripts/backup.sh" | sudo tee /etc/cron.d/grpc-backup
EOF
}
```

2. **Monitoring**:
```bash
# Dodaj do skryptu
setup_monitoring() {
    ssh -i "$SSH_KEY" "$SSH_USER@$SERVER" << 'EOF'
    # Instalacja monitoringu
    sudo apt-get install -y prometheus node-exporter
    
    # Konfiguracja eksportera metryk
    cat > /etc/prometheus/grpc_exporter.yml << 'CONF'
    metrics:
      - name: grpc_services_total
        type: gauge
        help: Number of running gRPC services
    CONF
EOF
}
```





1. Token Cloudflare jest pobierany z `.env`:
```bash
CLOUDFLARE_TOKEN=your-cloudflare-token
DOMAIN_SUFFIX=dynapsys.com
```

2. Uproszczone polecenie curl (bez tokenu):
```bash
curl -X POST "http://localhost:8000/deploy" \
    -H "Content-Type: application/json" \
    -d '{
        "git_repo": "https://github.com/dynapsys/grpc-service",
        "domain": "api",
        "service_name": "example-service"
    }'
```

3. Rozszerzony status zawiera teraz:
- Stan usługi systemd
- Stan rekordów DNS
- Konfigurację usługi
- Czas ostatniego deploymentu

4. Dodatkowe funkcje:
- Automatyczne dodawanie domeny suffix
- Sprawdzanie i aktualizacja istniejących rekordów DNS
- Pełniejsze informacje o statusie DNS

5. Przykład odpowiedzi status:
```json
{
    "status": "success",
    "service": {
        "name": "example-service",
        "systemd_status": "active",
        "dns_status": {
            "status": "active",
            "records": [
                {
                    "type": "CNAME",
                    "content": "dynapsys.com"
                },
                {
                    "type": "TXT",
                    "content": "service=example-service;port=50051"
                }
            ]
        },
        "last_deployment": "Wed Nov 19 14:30:22 2024",
        "config": {
            "version": "1.0",
            "domain": "api.dynapsys.com",
            "port": 50051
        }
    }
}
```

Teraz wystarczy:
1. Utworzyć plik `.env` z tokenem Cloudflare
2. Uruchomić serwer
3. Używać prostych poleceń curl bez podawania tokenu



Oto przykład jak poprawnie używać zmiennych w curl z JSON-em:

```bash
# Metoda 1 - używając zmiennej i podstawienia
CLOUDFLARE_TOKEN="your-token-here"
curl -X POST "http://localhost:8000/deploy" \
  -H "Content-Type: application/json" \
  -d "{
    \"git_repo\": \"https://github.com/dynapsys/grpc-service\",
    \"domain\": \"grpc.dynapsys.com\",
    \"service_name\": \"example-service\",
    \"cloudflare_token\": \"${CLOUDFLARE_TOKEN}\"
  }"

# Metoda 2 - używając heredoc
CLOUDFLARE_TOKEN="your-token-here"
curl -X POST "http://localhost:8000/deploy" \
  -H "Content-Type: application/json" \
  -d @- << EOF
{
  "git_repo": "https://github.com/dynapsys/grpc-service",
  "domain": "grpc.dynapsys.com",
  "service_name": "example-service",
  "cloudflare_token": "${CLOUDFLARE_TOKEN}"
}
EOF

# Metoda 3 - używając jq (zalecana)
CLOUDFLARE_TOKEN="your-token-here"
jq -n \
  --arg token "$CLOUDFLARE_TOKEN" \
  '{
    git_repo: "https://github.com/dynapsys/grpc-service",
    domain: "grpc.dynapsys.com",
    service_name: "example-service",
    cloudflare_token: $token
  }' | curl -X POST "http://localhost:8000/deploy" \
    -H "Content-Type: application/json" \
    -d @-

# Metoda 4 - skrypt deploy.sh
#!/bin/bash
set -e

# Wczytaj zmienne z .env
if [ -f .env ]; then
    export $(cat .env | grep -v '#' | xargs)
fi

# Funkcja do deploymentu
deploy_service() {
    local GIT_REPO=$1
    local DOMAIN=$2
    local SERVICE_NAME=$3

    curl -X POST "http://localhost:8000/deploy" \
        -H "Content-Type: application/json" \
        -d "{
            \"git_repo\": \"${GIT_REPO}\",
            \"domain\": \"${DOMAIN}\",
            \"service_name\": \"${SERVICE_NAME}\",
            \"cloudflare_token\": \"${CLOUDFLARE_TOKEN}\"
        }"
}

# Użycie
deploy_service \
    "https://github.com/dynapsys/grpc-service" \
    "grpc.dynapsys.com" \
    "example-service"
```

Możesz też stworzyć bardziej zaawansowany skrypt pomocniczy:

```bash
#!/bin/bash
set -e

# Konfiguracja
CONFIG_FILE=".env"
API_URL="http://localhost:8000"

# Wczytaj konfigurację
if [ -f "$CONFIG_FILE" ]; then
    export $(cat "$CONFIG_FILE" | grep -v '#' | xargs)
else
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

# Sprawdź wymagane zmienne
check_required_vars() {
    local required_vars=("CLOUDFLARE_TOKEN")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo "Error: Missing required variables: ${missing_vars[*]}"
        exit 1
    fi
}

# Funkcja do deploymentu
deploy_service() {
    if [ $# -ne 3 ]; then
        echo "Usage: $0 deploy <git_repo> <domain> <service_name>"
        exit 1
    fi

    local GIT_REPO=$1
    local DOMAIN=$2
    local SERVICE_NAME=$3

    echo "Deploying service..."
    echo "Git repo: $GIT_REPO"
    echo "Domain: $DOMAIN"
    echo "Service name: $SERVICE_NAME"

    # Wykonaj request
    local response=$(curl -s -X POST "$API_URL/deploy" \
        -H "Content-Type: application/json" \
        -d "{
            \"git_repo\": \"${GIT_REPO}\",
            \"domain\": \"${DOMAIN}\",
            \"service_name\": \"${SERVICE_NAME}\",
            \"cloudflare_token\": \"${CLOUDFLARE_TOKEN}\"
        }")

    # Wyświetl odpowiedź w ładnym formacie
    echo "Response:"
    echo "$response" | python3 -m json.tool

    # Sprawdź status
    if echo "$response" | grep -q '"status":"success"'; then
        echo "Deployment successful!"
        
        # Sprawdź status usługi
        echo "Checking service status..."
        curl -s "$API_URL/services/$SERVICE_NAME/status" | python3 -m json.tool
    else
        echo "Deployment failed!"
        exit 1
    fi
}

# Sprawdź wymagane zmienne
check_required_vars

# Parsuj argumenty
case "$1" in
    deploy)
        shift
        deploy_service "$@"
        ;;
    *)
        echo "Usage: $0 deploy <git_repo> <domain> <service_name>"
        exit 1
        ;;
esac
```

Użycie skryptu:

```bash
# Najpierw utwórz .env z tokenem
echo "CLOUDFLARE_TOKEN=your-token-here" > .env

# Następnie uruchom deployment
./deploy.sh deploy \
    "https://github.com/dynapsys/grpc-service" \
    "grpc.dynapsys.com" \
    "example-service"
```

Ten skrypt:
1. Wczytuje token z pliku .env
2. Sprawdza czy wszystkie wymagane zmienne są ustawione
3. Wykonuje deployment
4. Sprawdza status deploymentu
5. Wyświetla status usługi
6. Formatuje JSON-owe odpowiedzi dla lepszej czytelności

Metoda 4 (skrypt) jest najbardziej kompletna i bezpieczna w użyciu.