#!/bin/python
import os
import sys
import json
import subprocess
from pathlib import Path
import yaml
from flask import Flask, request, jsonify
import CloudFlare
import requests
from dataclasses import dataclass
from typing import Optional
import time
from dotenv import load_dotenv

# Wczytanie zmiennych środowiskowych
load_dotenv()

@dataclass
class ServiceConfig:
    git_repo: str
    domain: str
    service_name: str
    grpc_port: Optional[int] = None

class DomainManager:
    def __init__(self):
        self.caddy_api_url = os.getenv('CADDY_API_URL', 'http://localhost:2019')
        self.cloudflare_token = os.getenv('CLOUDFLARE_TOKEN')
        if not self.cloudflare_token:
            raise ValueError("CLOUDFLARE_TOKEN must be set in .env file")
        self.cf = CloudFlare.CloudFlare(token=self.cloudflare_token)

    def update_cloudflare(self, config: ServiceConfig) -> dict:
        try:
            domain_parts = config.domain.split('.')
            zone_name = '.'.join(domain_parts[-2:])
            zones = self.cf.zones.get(params={'name': zone_name})

            if not zones:
                return {"status": "error", "message": f"Zone not found for domain: {zone_name}"}

            zone_id = zones[0]['id']

            # Dodaj/zaktualizuj wpis CNAME
            dns_records = self.cf.zones.dns_records.get(zone_id, params={'name': config.domain})
            if dns_records:
                # Aktualizuj istniejący rekord
                record_id = dns_records[0]['id']
                self.cf.zones.dns_records.put(zone_id, record_id, data={
                    'name': config.domain,
                    'type': 'CNAME',
                    'content': zone_name,
                    'proxied': True
                })
            else:
                # Dodaj nowy rekord
                self.cf.zones.dns_records.post(zone_id, data={
                    'name': config.domain,
                    'type': 'CNAME',
                    'content': zone_name,
                    'proxied': True
                })

            # Dodaj/zaktualizuj wpis TXT
            txt_domain = f'_grpc.{config.domain}'
            dns_records = self.cf.zones.dns_records.get(zone_id, params={'name': txt_domain})
            txt_content = f'service={config.service_name};port={config.grpc_port}'

            if dns_records:
                record_id = dns_records[0]['id']
                self.cf.zones.dns_records.put(zone_id, record_id, data={
                    'name': txt_domain,
                    'type': 'TXT',
                    'content': txt_content
                })
            else:
                self.cf.zones.dns_records.post(zone_id, data={
                    'name': txt_domain,
                    'type': 'TXT',
                    'content': txt_content
                })

            return {"status": "success", "message": "DNS records updated successfully"}

        except Exception as e:
            return {"status": "error", "message": str(e)}

class ServiceManager:
    def __init__(self):
        self.services_dir = Path(os.getenv('SERVICES_DIR', '/opt/dynapsys/services'))
        self.services_dir.mkdir(exist_ok=True)
        self.domain_manager = DomainManager()
        self.domain_suffix = os.getenv('DOMAIN_SUFFIX', 'example.com')

    async def deploy_service(self, config: ServiceConfig) -> dict:
        try:
            if not config.domain.endswith(self.domain_suffix):
                config.domain = f"{config.domain}.{self.domain_suffix}"

            service_dir = self.services_dir / config.service_name

            # Klonowanie/aktualizacja repozytorium
            if service_dir.exists():
                subprocess.run(['git', 'pull'], cwd=service_dir, check=True)
            else:
                subprocess.run(['git', 'clone', config.git_repo, str(service_dir)], check=True)

            # Ustawienie portu
            if not config.grpc_port:
                config.grpc_port = self._get_free_port()

            # Aktualizacja DNS w Cloudflare
            cloudflare_result = self.domain_manager.update_cloudflare(config)
            if cloudflare_result["status"] == "error":
                return cloudflare_result

            # Aktualizacja konfiguracji Caddy
            caddy_result = self.domain_manager.update_caddy(config)
            if caddy_result["status"] == "error":
                return caddy_result

            # Generowanie i deployment usługi
            self._deploy_service(config)

            return {
                "status": "success",
                "service": {
                    "name": config.service_name,
                    "domain": config.domain,
                    "port": config.grpc_port,
                    "git_repo": config.git_repo,
                    "urls": {
                        "grpc": f"grpc://{config.domain}",
                        "status": f"http://localhost:8000/services/{config.service_name}/status"
                    }
                }
            }

        except Exception as e:
            return {"status": "error", "message": str(e)}

    def get_service_status(self, service_name: str) -> dict:
        try:
            service_dir = self.services_dir / service_name
            if not service_dir.exists():
                return {"status": "error", "message": "Service not found"}

            # Status usługi systemd
            systemd_status = subprocess.run(
                ["systemctl", "is-active", f"grpc-{service_name}"],
                capture_output=True,
                text=True
            ).stdout.strip()

            # Konfiguracja DNS
            config_file = service_dir / "service.yaml"
            if config_file.exists():
                with config_file.open() as f:
                    config = yaml.safe_load(f)
                    domain = config.get('domain')
                    if domain:
                        dns_status = self._check_dns_status(domain)
                    else:
                        dns_status = {"status": "unknown"}
            else:
                dns_status = {"status": "unknown"}

            return {
                "status": "success",
                "service": {
                    "name": service_name,
                    "systemd_status": systemd_status,
                    "dns_status": dns_status,
                    "last_deployment": time.ctime(service_dir.stat().st_mtime),
                    "config": config if 'config' in locals() else None
                }
            }

        except Exception as e:
            return {"status": "error", "message": str(e)}

    def _check_dns_status(self, domain: str) -> dict:
        try:
            domain_parts = domain.split('.')
            zone_name = '.'.join(domain_parts[-2:])
            zones = self.domain_manager.cf.zones.get(params={'name': zone_name})

            if not zones:
                return {"status": "error", "zone": "not found"}

            zone_id = zones[0]['id']
            records = self.domain_manager.cf.zones.dns_records.get(
                zone_id,
                params={'name': domain}
            )

            return {
                "status": "active" if records else "not_configured",
                "records": [
                    {"type": r['type'], "content": r['content']}
                    for r in records
                ] if records else []
            }
        except Exception as e:
            return {"status": "error", "message": str(e)}

app = Flask(__name__)

@app.route('/deploy', methods=['POST'])
def deploy_service():
    try:
        data = request.get_json()
        config = ServiceConfig(**data)
        return jsonify(app.loop.run_until_complete(
            service_manager.deploy_service(config)
        ))
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/services/<service_name>/status', methods=['GET'])
def get_service_status(service_name):
    return jsonify(service_manager.get_service_status(service_name))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)