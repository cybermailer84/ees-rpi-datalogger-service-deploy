#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# install-services.sh — legt die systemd-Units des EES Data Loggers an (oder neu an):
#   - ees-app-service.service   (Logger-Daemon, Autostart + Auto-Restart)
#   - ees-healthcheck.service    (oneshot Health-Check)
#   - ees-healthcheck.timer      (führt den Health-Check alle 2 Minuten aus)
#   - ees-update.service         (oneshot Software-Update)
#   - ees-update.timer           (prüft alle 15 Minuten auf einen neuen Sollstand)
#
# Wiederholbar: existiert eine dieser Units bereits, wird sie zuerst gestoppt,
# deaktiviert und entfernt, danach werden alle neu angelegt. Zusätzlich werden
# Alt-Units aus früheren Setups entfernt (siehe LEGACY_UNITS, z.B. datalogger-app-service).
#
# Arbeitsverzeichnis: ~/WORK/datalogger des aufrufenden Benutzers.
# Dort wird auch healthcheck.sh abgelegt; das Binary "app-service" muss dort liegen.
#
# Aufruf:  sudo ./install-services.sh          (Port 8000)
#          sudo SERVICE_PORT=8001 ./install-services.sh
#
set -euo pipefail

# --- muss als root laufen (schreibt nach /etc/systemd/system, ruft systemctl) ---
if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen:  sudo $0" >&2
  exit 1
fi

# --- aufrufenden (Nicht-root-)Benutzer und dessen Home ermitteln ---
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "${TARGET_HOME:-}" ]]; then
  echo "Konnte das Home-Verzeichnis von '$TARGET_USER' nicht ermitteln." >&2
  exit 1
fi

WORKDIR="$TARGET_HOME/WORK/datalogger"      # absoluter Pfad — systemd expandiert kein ~
SERVICE_PORT="${SERVICE_PORT:-8000}"
BINARY="$WORKDIR/app-service"
HEALTHCHECK="$WORKDIR/healthcheck.sh"

APP_UNIT="ees-app-service.service"
HC_UNIT="ees-healthcheck.service"
HC_TIMER="ees-healthcheck.timer"
UPD_UNIT="ees-update.service"
UPD_TIMER="ees-update.timer"
UPDATER="$WORKDIR/ees-update.sh"
UNIT_DIR="/etc/systemd/system"

# Oeffentliche Schluessel, gegen die der Updater Releases prueft. Bewusst ein
# Verzeichnis und nicht eine einzelne Datei: So laesst sich ein zweiter
# Schluessel ausrollen, spaeter damit signieren und der alte danach entfernen,
# ohne dass die Flotte zwischendurch stillsteht.
KEY_DIR="${EES_KEY_DIR:-/etc/ees/keys}"

# Alt-Units aus früheren Setups, die ebenfalls entfernt werden sollen (falls vorhanden)
LEGACY_UNITS=("datalogger-app-service.service")

echo "Zielbenutzer:       $TARGET_USER"
echo "Arbeitsverzeichnis: $WORKDIR"
echo "Port:               $SERVICE_PORT"
echo

# --- bestehende Unit entfernen (falls vorhanden) ---
remove_unit() {
  local unit="$1"
  if [[ -f "$UNIT_DIR/$unit" ]] || systemctl cat "$unit" &>/dev/null; then
    echo "  entferne bestehende Unit: $unit"
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f "$UNIT_DIR/$unit"
  fi
}

echo "Prüfe/entferne bestehende Units ..."
remove_unit "$UPD_TIMER"    # Timer zuerst (stoppt die Auslösung)
remove_unit "$UPD_UNIT"
remove_unit "$HC_TIMER"
remove_unit "$HC_UNIT"
remove_unit "$APP_UNIT"
for legacy in "${LEGACY_UNITS[@]}"; do   # Alt-Dienste aus früheren Setups
  remove_unit "$legacy"
done
systemctl daemon-reload
echo

# --- Arbeitsverzeichnis anlegen ---
echo "Lege Arbeitsverzeichnis an: $WORKDIR"
mkdir -p "$WORKDIR"
chown -R "$TARGET_USER":"$TARGET_USER" "$WORKDIR"

# --- Oeffentliche Release-Schluessel ablegen ---
#
# Henne-Ei: Der erste Schluessel kann nicht ueber den Update-Mechanismus
# verteilt werden, den er absichern soll - er kommt daher hier mit. Danach wird
# er nur noch bei einem Schluesselwechsel angefasst.
#
# Die Schluessel liegen unter /etc (root-eigen, 644): Der Updater muss sie
# lesen, aber niemand ausser root darf sie austauschen - sonst waere die
# Signaturpruefung wertlos.
# Zwei Fundorte, weil das Script auf zwei Wegen laeuft: aus einem git-Checkout
# heraus (dann liegen die Schluessel in ../keys) oder nach dem Bootstrap ueber
# download_install_scripts.sh in ~/WORK/datalogger (dann daneben in keys/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_KEY_DIR=""
for candidate in "$SCRIPT_DIR/../keys" "$SCRIPT_DIR/keys"; do
  if compgen -G "$candidate/*.pub" >/dev/null 2>&1; then
    REPO_KEY_DIR="$(cd "$candidate" && pwd)"
    break
  fi
done

if [[ -n "$REPO_KEY_DIR" ]]; then
  echo "Lege oeffentliche Release-Schluessel ab: $KEY_DIR"
  install -d -m 755 -o root -g root "$KEY_DIR"
  for key in "$REPO_KEY_DIR"/*.pub; do
    install -m 644 -o root -g root "$key" "$KEY_DIR/"
    echo "    $(basename "$key")  (SHA-256 $(openssl pkey -pubin -in "$key" -outform DER 2>/dev/null | sha256sum | cut -c1-16))"
  done
else
  echo "HINWEIS: Keine oeffentlichen Schluessel gefunden (gesucht in" >&2
  echo "  $SCRIPT_DIR/../keys und $SCRIPT_DIR/keys)." >&2
  echo "  Der Updater kann Releases dann nicht pruefen." >&2
fi

# --- healthcheck.sh im Arbeitsverzeichnis ablegen ---
echo "Schreibe $HEALTHCHECK"
cat > "$HEALTHCHECK" <<EOF
#!/bin/bash
# Prüft /health des app-service; bei != 200 wird der Dienst neu gestartet.
code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$SERVICE_PORT/health)
if [ "\$code" != "200" ]; then
  echo "Health check failed (HTTP \$code) – restarting $APP_UNIT"
  systemctl restart $APP_UNIT
fi
EOF
chmod +x "$HEALTHCHECK"
chown "$TARGET_USER":"$TARGET_USER" "$HEALTHCHECK"

# --- ees-app-service.service ---
echo "Schreibe $UNIT_DIR/$APP_UNIT"
cat > "$UNIT_DIR/$APP_UNIT" <<EOF
[Unit]
Description=EES Data Logger – App Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$WORKDIR
ExecStart=$BINARY --service-port $SERVICE_PORT
Restart=always
RestartSec=5
StartLimitIntervalSec=0
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ees-app-service

[Install]
WantedBy=multi-user.target
EOF

# --- ees-healthcheck.service (oneshot, läuft als root → darf den Dienst neu starten) ---
echo "Schreibe $UNIT_DIR/$HC_UNIT"
cat > "$UNIT_DIR/$HC_UNIT" <<EOF
[Unit]
Description=EES App Service health check

[Service]
Type=oneshot
ExecStart=$HEALTHCHECK
EOF

# --- ees-healthcheck.timer ---
echo "Schreibe $UNIT_DIR/$HC_TIMER"
cat > "$UNIT_DIR/$HC_TIMER" <<EOF
[Unit]
Description=Run EES health check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

# --- ees-update.sh im Arbeitsverzeichnis ablegen ---
#
# Liegt im git-Checkout neben diesem Script, nach dem Bootstrap ueber
# download_install_scripts.sh bereits im Arbeitsverzeichnis selbst - dann ist
# nichts zu kopieren.
if [[ -f "$SCRIPT_DIR/ees-update.sh" ]]; then
  if [[ "$SCRIPT_DIR/ees-update.sh" -ef "$UPDATER" ]]; then
    echo "Updater liegt bereits an Ort und Stelle: $UPDATER"
    chmod 755 "$UPDATER"
  else
    echo "Schreibe $UPDATER"
    install -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/ees-update.sh" "$UPDATER"
  fi
else
  echo "HINWEIS: ees-update.sh nicht gefunden - automatische Updates bleiben aus." >&2
fi

# --- ees-update.service (oneshot, als root -> darf den Dienst tauschen) ---
if [[ -x "$UPDATER" ]]; then
echo "Schreibe $UNIT_DIR/$UPD_UNIT"
cat > "$UNIT_DIR/$UPD_UNIT" <<EOF
[Unit]
Description=EES Data Logger software update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=EES_WORKDIR=$WORKDIR
Environment=EES_SERVICE_PORT=$SERVICE_PORT
ExecStart=$UPDATER
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ees-update
EOF

# --- ees-update.timer ---
#
# RandomizedDelaySec ist hier das Wesentliche: ohne sie wuerden ueber 100
# Datenlogger im selben Moment dasselbe Release ziehen. Die Streuung verteilt
# das ueber zehn Minuten.
echo "Schreibe $UNIT_DIR/$UPD_TIMER"
cat > "$UNIT_DIR/$UPD_TIMER" <<EOF
[Unit]
Description=Check for EES software updates every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF
fi

# --- aktivieren ---
echo
echo "Aktiviere Units ..."
systemctl daemon-reload
systemctl enable "$APP_UNIT" >/dev/null
systemctl enable --now "$HC_TIMER" >/dev/null
[[ -f "$UNIT_DIR/$UPD_TIMER" ]] && systemctl enable --now "$UPD_TIMER" >/dev/null

if [[ -x "$BINARY" ]]; then
  systemctl restart "$APP_UNIT"
  echo "  $APP_UNIT gestartet."
else
  echo
  echo "HINWEIS: Binary fehlt unter $BINARY."
  echo "  Der Dienst ist aktiviert (Autostart), wird aber erst laufen, sobald das Binary vorliegt:"
  echo "    cargo build --release --bin app-service"
  echo "    cp target/release/app-service \"$WORKDIR/\""
  echo "    sudo systemctl start $APP_UNIT"
  echo "  (Nur bei BIG/MQTT: mqtt-big.crt ebenfalls nach $WORKDIR/ kopieren.)"
fi

echo
echo "Fertig. Status/Logs:"
echo "  systemctl status $APP_UNIT $HC_TIMER $UPD_TIMER"
echo "  journalctl -u $APP_UNIT -f"
echo "  systemctl list-timers $HC_TIMER $UPD_TIMER"
echo
echo "Software-Update von Hand pruefen:"
echo "  sudo $UPDATER --dry-run"
echo "  journalctl -u $UPD_UNIT -n 50"
