#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# install-testadapter.sh — richtet die Test-/Dummy-Adapter für den EES Data Logger ein.
#
# - legt ~/WORK/datalogger/adapter/dummy an (falls noch nicht vorhanden)
# - lädt die drei Dummy-Adapter-Skripte dorthin und macht sie ausführbar (chmod a+x):
#     mbus1_heatmeter, mbus2_heatmeter, mbus3_heatmeter
# - lädt data_logger.config nach ~/WORK/datalogger
#
# Kein root nötig (schreibt nur ins Home des Benutzers). Wird das Skript dennoch mit
# sudo aufgerufen, landen die Dateien im Home des aufrufenden Benutzers.
#
# Aufruf:  ./install-testadapter.sh
#
set -euo pipefail

# --- aufrufenden Benutzer und dessen Home ermitteln (auch unter sudo korrekt) ---
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "${TARGET_HOME:-}" ]]; then
  echo "Konnte das Home-Verzeichnis von '$TARGET_USER' nicht ermitteln." >&2
  exit 1
fi

WORKDIR="$TARGET_HOME/WORK/datalogger"
DUMMY_DIR="$WORKDIR/adapter/dummy"
BASE_URL="https://ees.itc-haas.at/update/BACKUP/TEST/WORK/datalogger"
ADAPTERS=(mbus1_heatmeter mbus2_heatmeter mbus3_heatmeter)

command -v curl >/dev/null || { echo "curl ist nicht installiert." >&2; exit 1; }

echo "Zielbenutzer:       $TARGET_USER"
echo "Arbeitsverzeichnis: $WORKDIR"
echo

# --- Dummy-Ordner anlegen (falls nicht vorhanden) ---
if [[ -d "$DUMMY_DIR" ]]; then
  echo "Ordner existiert bereits: $DUMMY_DIR"
else
  echo "Erstelle Ordner: $DUMMY_DIR"
  mkdir -p "$DUMMY_DIR"
fi

# --- Dummy-Adapter herunterladen + ausführbar machen ---
for a in "${ADAPTERS[@]}"; do
  dest="$DUMMY_DIR/$a"
  echo "Lade $a -> $dest"
  curl -fSL --retry 3 -o "$dest" "$BASE_URL/adapter/dummy/$a"
  chmod a+x "$dest"
done

# --- data_logger.config herunterladen ---
echo "Lade data_logger.config -> $WORKDIR/"
curl -fSL --retry 3 -o "$WORKDIR/data_logger.config" "$BASE_URL/data_logger.config"

# --- falls als root ausgeführt: Besitzrechte an den Zielbenutzer zurückgeben ---
if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
  chown -R "$TARGET_USER":"$TARGET_USER" "$WORKDIR/adapter" "$WORKDIR/data_logger.config"
fi

echo
echo "Fertig. Abgelegt:"
for a in "${ADAPTERS[@]}"; do echo "  $DUMMY_DIR/$a (ausführbar)"; done
echo "  $WORKDIR/data_logger.config"
