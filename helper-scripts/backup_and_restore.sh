#!/usr/bin/env bash

# ===========================================
# Konfiguration
# ===========================================
# Discord Webhook URL für Benachrichtigungen
DISCORD_WEBHOOK_URL="YOUR_WEBHOOK_URL_HERE"

# Standard Backup-Verzeichnis
DEFAULT_BACKUP_LOCATION="/home/backup/mailcow"

# Backup Aufbewahrungszeit in Tagen (0 = unbegrenzt)
BACKUP_RETENTION_DAYS=30

# Docker Image für Backups
DEBIAN_DOCKER_IMAGE="mailcow/backup:latest"

# Docker Container Präfix
CONTAINER_PREFIX="mailcowdockerized"

# ===========================================
# Hilfsfunktionen
# ===========================================

# Formatierte Ausgabe
log_info() {
    echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}

# Discord Webhook Funktion
send_discord_notification() {
    local status=$1
    local message=$2
    local color
    local backup_size

    case $status in
        "success") color=65280 ;; # Grün
        "error") color=16711680 ;; # Rot
        *) color=39423 ;; # Blau
    esac

    # Berechne Backup-Größe wenn vorhanden
    if [ -d "${BACKUP_LOCATION}" ]; then
        backup_size=$(du -sh "${BACKUP_LOCATION}/mailcow-${DATE}" 2>/dev/null | cut -f1)
    fi

    # Erstelle einen formatierten Embed
    local json_data=$(cat <<EOF
{
  "embeds": [{
    "title": "Mailcow Backup Status",
    "description": "$message",
    "color": $color,
    "fields": [
      {
        "name": "Backup Location",
        "value": "\`$BACKUP_LOCATION/mailcow-${DATE}\`",
        "inline": true
      },
      {
        "name": "Timestamp",
        "value": "$(date '+%Y-%m-%d %H:%M:%S')",
        "inline": true
      },
      {
        "name": "Backup Size",
        "value": "${backup_size:-Unknown}",
        "inline": true
      }
    ],
    "footer": {
      "text": "Mailcow Backup System"
    }
  }]
}
EOF
)

    # Sende Webhook
    if [ -n "$DISCORD_WEBHOOK_URL" ] && [ "$DISCORD_WEBHOOK_URL" != "YOUR_WEBHOOK_URL_HERE" ]; then
        curl -H "Content-Type: application/json" -X POST -d "$json_data" "$DISCORD_WEBHOOK_URL" &>/dev/null
    fi
}

# ===========================================
# Backup Funktion
# ===========================================

backup() {
    local start_time=$(date +%s)
    DATE=$(date +"%Y-%m-%d-%H-%M-%S")
    local backup_dir="${BACKUP_LOCATION}/mailcow-${DATE}"
    local success=true
    local backup_components=()
    local THREADS=${THREADS:-1}
    local ARCH=$(uname -m)

    log_info "🚀 Starte Mailcow Backup nach ${backup_dir}"
    send_discord_notification "info" "🚀 Backup wird gestartet..."

    # Erstelle Backup-Verzeichnis
    mkdir -p "${backup_dir}"
    chmod 755 "${backup_dir}"
    
    # Setze Architektur-Signatur
    touch "${backup_dir}/.$ARCH"

    # Speichere Docker-Compose Konfiguration
    if [ -f "/opt/mailcow-dockerized/docker-compose.yml" ]; then
        cp "/opt/mailcow-dockerized/docker-compose.yml" "${backup_dir}/docker-compose.yml"
        backup_components+=("Docker Compose Konfiguration")
    fi

    # Speichere Mailcow Konfiguration
    if [ -f "/opt/mailcow-dockerized/mailcow.conf" ]; then
        cp "/opt/mailcow-dockerized/mailcow.conf" "${backup_dir}/mailcow.conf"
        backup_components+=("Mailcow Konfiguration")
    fi

    # Backup Mail-Verzeichnis (vmail)
    log_info "📧 Backup Mail-Verzeichnis..."
    local VMAIL_VOL=$(docker volume ls -qf name=${CONTAINER_PREFIX}_vmail-vol-1)
    if [ -z "$VMAIL_VOL" ]; then
        log_error "Mail-Volume nicht gefunden"
        success=false
    else
        if docker run --rm \
            -v ${backup_dir}:/backup:z \
            -v ${VMAIL_VOL}:/vmail:ro,z \
            ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_vmail.tar.gz /vmail; then
            backup_components+=("Mail-Verzeichnis")
            log_success "✅ Mail-Verzeichnis gesichert"
        else
            log_error "❌ Fehler beim Backup des Mail-Verzeichnisses"
            success=false
        fi
    fi

    # Backup Dovecot-Daten (crypt)
    log_info "🔒 Backup Verschlüsselungsdaten..."
    local CRYPT_VOL=$(docker volume ls -qf name=${CONTAINER_PREFIX}_crypt-vol-1)
    if [ -z "$CRYPT_VOL" ]; then
        log_error "Crypt-Volume nicht gefunden"
        success=false
    else
        if docker run --rm \
            -v ${backup_dir}:/backup:z \
            -v ${CRYPT_VOL}:/crypt:ro,z \
            ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_crypt.tar.gz /crypt; then
            backup_components+=("Verschlüsselungsdaten")
            log_success "✅ Verschlüsselungsdaten gesichert"
        else
            log_error "❌ Fehler beim Backup der Verschlüsselungsdaten"
            success=false
        fi
    fi

    # Backup Postfix-Queue und Konfiguration
    log_info "📨 Backup Postfix-Daten..."
    local POSTFIX_VOL=$(docker volume ls -qf name=${CONTAINER_PREFIX}_postfix-vol-1)
    if [ -z "$POSTFIX_VOL" ]; then
        log_error "Postfix-Volume nicht gefunden"
        success=false
    else
        if docker run --rm \
            -v ${backup_dir}:/backup:z \
            -v ${POSTFIX_VOL}:/postfix:ro,z \
            ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_postfix.tar.gz /postfix; then
            backup_components+=("Postfix-Daten")
            log_success "✅ Postfix-Daten gesichert"
        else
            log_error "❌ Fehler beim Backup von Postfix"
            success=false
        fi
    fi

    # Backup Redis (wichtige Caches und temporäre Daten)
    log_info "📦 Backup Redis-Daten..."
    local REDIS_CONTAINER=$(docker ps -qf name=redis-mailcow)
    local REDIS_VOL=$(docker volume ls -qf name=${CONTAINER_PREFIX}_redis-vol-1)
    
    if [ -z "$REDIS_CONTAINER" ] || [ -z "$REDIS_VOL" ]; then
        log_error "Redis Container oder Volume nicht gefunden"
        success=false
    else
        if docker exec ${REDIS_CONTAINER} redis-cli save && \
            docker run --rm \
            -v ${backup_dir}:/backup:z \
            -v ${REDIS_VOL}:/redis:ro,z \
            ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_redis.tar.gz /redis; then
            backup_components+=("Redis-Daten")
            log_success "✅ Redis-Daten gesichert"
        else
            log_error "❌ Fehler beim Backup von Redis"
            success=false
        fi
    fi

    # Backup rspamd (Spam-Filter Konfiguration und Daten)
    log_info "🛡️ Backup RSpamd-Daten..."
    local RSPAMD_VOL=$(docker volume ls -qf name=${CONTAINER_PREFIX}_rspamd-vol-1)
    if [ -z "$RSPAMD_VOL" ]; then
        log_error "RSpamd-Volume nicht gefunden"
        success=false
    else
        if docker run --rm \
            -v ${backup_dir}:/backup:z \
            -v ${RSPAMD_VOL}:/rspamd:ro,z \
            ${DEBIAN_DOCKER_IMAGE} /bin/tar --warning='no-file-ignored' --warning='no-file-changed' --use-compress-program="pigz --rsyncable -p ${THREADS}" -Pcvpf /backup/backup_rspamd.tar.gz /rspamd; then
            backup_components+=("RSpamd-Daten")
            log_success "✅ RSpamd-Daten gesichert"
        else
            log_error "❌ Fehler beim Backup von RSpamd"
            success=false
        fi
    fi

    # Erstelle README mit Backup-Informationen
    cat > "${backup_dir}/README.txt" << EOF
Mailcow Backup vom $(date '+%Y-%m-%d %H:%M:%S')
===============================================

Dieses Backup enthält folgende Komponenten:
$(printf '%s\n' "${backup_components[@]}" | sed 's/^/- /')

Architektur: ${ARCH}
Backup-Pfad: ${backup_dir}

Restore-Anweisungen:
1. Stelle sicher, dass Mailcow installiert ist
2. Kopiere die mailcow.conf und docker-compose.yml in dein Mailcow-Verzeichnis
3. Stoppe Mailcow: cd /opt/mailcow-dockerized && docker compose down
4. Entpacke die Backup-Archive:
   tar xzvf backup_vmail.tar.gz
   tar xzvf backup_crypt.tar.gz
   tar xzvf backup_postfix.tar.gz
   tar xzvf backup_redis.tar.gz
   tar xzvf backup_rspamd.tar.gz
5. Starte Mailcow: docker compose up -d
EOF

    # Cleanup alte Backups
    if [ $BACKUP_RETENTION_DAYS -gt 0 ]; then
        log_info "🧹 Lösche Backups älter als ${BACKUP_RETENTION_DAYS} Tage..."
        find ${BACKUP_LOCATION}/mailcow-* -maxdepth 0 -mtime +${BACKUP_RETENTION_DAYS} -exec rm -rf {} \;
    fi

    # Berechne Backup-Dauer
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_formatted=$(date -u -d @${duration} +"%H:%M:%S")

    # Backup-Größe ermitteln
    local backup_size=$(du -sh "${backup_dir}" | cut -f1)

    # Sende Discord Benachrichtigung
    if [ "$success" = true ]; then
        local components_str=$(IFS=", "; echo "${backup_components[*]}")
        send_discord_notification "success" "✅ Backup erfolgreich abgeschlossen!\n\n**Komponenten:**\n${components_str}\n\n**Größe:** ${backup_size}\n**Dauer:** ${duration_formatted}\n\nDas Backup wurde optimiert für einfaches Restore!"
        log_success "Backup erfolgreich abgeschlossen! Größe: ${backup_size}, Dauer: ${duration_formatted}"
    else
        send_discord_notification "error" "❌ Backup teilweise fehlgeschlagen!\n\n**Erfolgreich gesichert:**\n${components_str}\n\n**Größe:** ${backup_size}\n**Dauer:** ${duration_formatted}\n\nBitte prüfen Sie die Logs für Details."
        log_error "Backup teilweise fehlgeschlagen! Größe: ${backup_size}, Dauer: ${duration_formatted}"
        exit 1
    fi
}

# ===========================================
# Hauptprogramm
# ===========================================

# Prüfe Abhängigkeiten
for bin in docker curl date; do
    if [[ -z $(which ${bin}) ]]; then
        log_error "Benötigte Software nicht gefunden: ${bin}"
        exit 1
    fi
done

# Setze Backup-Location
if [[ ! -z ${MAILCOW_BACKUP_LOCATION} ]]; then
    BACKUP_LOCATION="${MAILCOW_BACKUP_LOCATION}"
else
    BACKUP_LOCATION="${DEFAULT_BACKUP_LOCATION}"
fi

# Prüfe Backup-Verzeichnis
if [[ ! ${BACKUP_LOCATION} =~ ^/ ]]; then
    log_error "Backup-Verzeichnis muss ein absoluter Pfad sein (beginnt mit /)."
    send_discord_notification "error" "Backup fehlgeschlagen: Ungültiger Backup-Pfad"
    exit 1
fi

if [[ -f ${BACKUP_LOCATION} ]]; then
    log_error "${BACKUP_LOCATION} ist eine Datei!"
    send_discord_notification "error" "Backup fehlgeschlagen: Backup-Pfad ist eine Datei"
    exit 1
fi

# Erstelle Backup-Verzeichnis falls nicht vorhanden
if [[ ! -d ${BACKUP_LOCATION} ]]; then
    log_info "Erstelle Backup-Verzeichnis ${BACKUP_LOCATION}"
    mkdir -p ${BACKUP_LOCATION}
    chmod 755 ${BACKUP_LOCATION}
fi

# Prüfe Parameter
if [[ ! ${1} == "backup" ]]; then
    log_error "Parameter muss 'backup' sein"
    echo "Verwendung: $0 backup"
    exit 1
fi

# Starte Backup
backup
