Skrypt do inicjalizacji połączenia SSH i zdalnej instalacji na serwerze.


Użycie skryptu:

```bash
# 1. Pobierz skrypt
curl -O https://raw.githubusercontent.com/user/grpc-manager/main/install.sh
chmod +x install.sh

# 2. Uruchom instalację
./install.sh 192.168.1.100 root example.com CF_TOKEN_123

# Lub z tokenem w pliku
echo "your-cloudflare-token" > ~/.cloudflare_token
./install.sh 192.168.1.100 root example.com
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
    sudo mkdir -p /opt/grpc-manager/backups
    echo "0 3 * * * root /opt/grpc-manager/scripts/backup.sh" | sudo tee /etc/cron.d/grpc-backup
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