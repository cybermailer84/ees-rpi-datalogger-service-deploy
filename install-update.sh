#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# install-update.sh — aktualisiert die Binaries (app-service, app-tui) des EES Data Loggers.
#
# - fragt die Hardware-Version ab (nur ganze Zahlen)
#     Version 1–8 -> hardware_v1.8
#     Version 9   -> hardware_v1.9
# - lädt app-service und app-tui nach ~/WORK/datalogger und macht sie ausführbar (chmod a+x)
# - sind die Dateien bereits vorhanden, wird zuvor ees-app-service.service gestoppt und nach
#   erfolgreichem Download wieder gestartet
#
# Aufruf:  sudo ./install-update.sh
#          sudo HARDWARE_VERSION=9 ./install-update.sh    (ohne Rueckfrage)
#
set -euo pipefail

APP_UNIT="ees-app-service.service"
BASE_ROOT="https://ees.itc-haas.at/update/BACKUP/services"
FILES=(app-service app-tui)

# --- muss als root laufen (systemctl stop/start des Dienstes) ---
if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen:  sudo $0" >&2
  exit 1
fi

command -v curl >/dev/null || { echo "curl ist nicht installiert." >&2; exit 1; }

# --- aufrufenden (Nicht-root-)Benutzer und dessen Home ermitteln ---
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "${TARGET_HOME:-}" ]]; then
  echo "Konnte das Home-Verzeichnis von '$TARGET_USER' nicht ermitteln." >&2
  exit 1
fi
WORKDIR="$TARGET_HOME/WORK/datalogger"

# --- Hardware-Version abfragen (nur ganze Zahlen) ---
#
# Ueber HARDWARE_VERSION laesst sich die Abfrage ueberspringen - das braucht
# ees-onboard.sh, das dieses Script ohne Terminal aufruft. Ohne die Variable
# bleibt alles wie bisher.
HW_DIR=""
while true; do
  if [[ -n "${HARDWARE_VERSION:-}" ]]; then
    hw="$HARDWARE_VERSION"
    echo "Hardware-Version aus HARDWARE_VERSION: $hw"
  else
    read -rp "Welche Hardware-Version verwenden Sie? (ganze Zahl): " hw
  fi
  if [[ ! "$hw" =~ ^[0-9]+$ ]]; then
    echo "  Ungültige Eingabe — bitte nur eine ganze Zahl eingeben."
    [[ -n "${HARDWARE_VERSION:-}" ]] && { echo "HARDWARE_VERSION ist ungültig: $hw" >&2; exit 2; }
    continue
  fi
  hw=$((10#$hw))   # führende Nullen sicher entfernen (keine Oktal-Interpretation)
  if (( hw >= 1 && hw <= 8 )); then
    HW_DIR="hardware_v1.8"; break
  elif (( hw == 9 )); then
    HW_DIR="hardware_v1.9"; break
  else
    echo "  Version $hw wird nicht unterstützt (gültig: 1–9)."
    [[ -n "${HARDWARE_VERSION:-}" ]] && exit 2
  fi
done

BASE_URL="$BASE_ROOT/$HW_DIR"
echo
echo "Hardware-Version:   $hw  ->  $HW_DIR"
echo "Zielbenutzer:       $TARGET_USER"
echo "Arbeitsverzeichnis: $WORKDIR"
echo "Quelle:             $BASE_URL"
echo

mkdir -p "$WORKDIR"

# --- Dienst stoppen, falls die Dateien bereits existieren ---
restart_needed=false
if [[ -e "$WORKDIR/app-service" || -e "$WORKDIR/app-tui" ]]; then
  echo "Bestehende Dateien gefunden."
  if systemctl cat "$APP_UNIT" &>/dev/null; then
    echo "Stoppe $APP_UNIT ..."
    systemctl stop "$APP_UNIT" || true
    restart_needed=true
  fi
fi

# --- bei Fehler: temporäre Dateien entfernen und Dienst ggf. wieder starten ---
cleanup_fail() {
  for f in "${FILES[@]}"; do rm -f "$WORKDIR/$f.new"; done
  if $restart_needed; then
    echo "Starte $APP_UNIT nach Fehler wieder ..."
    systemctl start "$APP_UNIT" || true
  fi
}

# --- Download in temporäre Dateien (alte Binaries bleiben bei Fehler erhalten) ---
for f in "${FILES[@]}"; do
  echo "Lade $f von $BASE_URL/$f"
  if ! curl -fSL --retry 3 -o "$WORKDIR/$f.new" "$BASE_URL/$f"; then
    echo "FEHLER: Download von $f fehlgeschlagen." >&2
    cleanup_fail
    exit 1
  fi
done

# --- alle Downloads erfolgreich -> in Position bringen ---
for f in "${FILES[@]}"; do
  mv -f "$WORKDIR/$f.new" "$WORKDIR/$f"
  chmod a+x "$WORKDIR/$f"
  chown "$TARGET_USER":"$TARGET_USER" "$WORKDIR/$f"
done
echo "Dateien aktualisiert und ausführbar gesetzt."

# --- Dienst wieder starten, falls er zuvor gestoppt wurde ---
if $restart_needed; then
  echo "Starte $APP_UNIT ..."
  systemctl start "$APP_UNIT"
  echo "  $APP_UNIT läuft wieder."
fi

echo
echo "Fertig."
