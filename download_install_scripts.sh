#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# download_install_scripts.sh — holt die Deploy-Skripte direkt von GitHub.
#
# Lädt install-services.sh, install-testadapter.sh, install-update.sh,
# ees-update.sh und ees-onboard.sh nach ~/WORK/datalogger und macht sie
# ausführbar (chmod a+x).
#
# Danach richtet ees-onboard.sh das Gerät in einem Aufruf fertig ein — §9.15.
#
# Kein root nötig (schreibt nur ins Home des Benutzers). Wird das Skript dennoch mit
# sudo aufgerufen, landen die Dateien im Home des aufrufenden Benutzers.
#
# Bezugsquellen, in dieser Reihenfolge:
#
#   1. EES_BOOTSTRAP_BASE, falls gesetzt
#   2. ees-rpi-datalogger-service-deploy auf GitHub - oeffentlich, ohne Token
#   3. der Update-Server, als Ausweichweg
#
# Die Deploy-Skripte liegen in einem eigenen oeffentlichen Repo. Das Repo mit
# dem Programmcode bleibt privat; raw.githubusercontent.com antwortete dort
# ohne Token mit 404 (nicht 403), und ein Token auf ueber 100 Geraeten
# einzutippen ist keine Loesung.
#
# Token nur noetig, falls das Deploy-Repo doch einmal privat gestellt wird:
#   GITHUB_TOKEN=ghp_xxx ./download_install_scripts.sh
#
# Aufruf:  ./download_install_scripts.sh
#
set -euo pipefail

GITHUB_OWNER="cybermailer84"
GITHUB_REPO="ees-rpi-datalogger-service-deploy"
GITHUB_BRANCH="main"
# Im Deploy-Repo liegen die Skripte im Wurzelverzeichnis, die Schluessel in keys/.
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_OWNER/$GITHUB_REPO/$GITHUB_BRANCH"
UPDATE_SERVER="${EES_UPDATE_SERVER:-https://ees.itc-haas.at/update/BACKUP/services/bootstrap}"

SCRIPTS=(install-services.sh install-testadapter.sh install-update.sh ees-update.sh ees-onboard.sh)
KEYS=(release-key.pub)

command -v curl >/dev/null || { echo "curl ist nicht installiert." >&2; exit 1; }

# --- aufrufenden Benutzer und dessen Home ermitteln (auch unter sudo korrekt) ---
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "${TARGET_HOME:-}" ]]; then
  echo "Konnte das Home-Verzeichnis von '$TARGET_USER' nicht ermitteln." >&2
  exit 1
fi
WORKDIR="$TARGET_HOME/WORK/datalogger"

# --- Quelle bestimmen -------------------------------------------------------
#
# Einmal festlegen und dann alles von dort holen. Quellen zu mischen hiesse,
# Skripte verschiedener Staende nebeneinanderzulegen.
SCRIPT_BASE=""
KEY_BASE=""
QUELLE_NAME=""
auth=()

probiere() { # $1 Skript-Basis, $2 Schluessel-Basis, $3 Name, $4.. curl-Argumente
    local skripte="$1" schluessel="$2" name="$3"; shift 3
    if curl -fsS --max-time 15 "$@" -o /dev/null "$skripte/install-services.sh" 2>/dev/null; then
        SCRIPT_BASE="$skripte"; KEY_BASE="$schluessel"; QUELLE_NAME="$name"
        auth=("$@")
        return 0
    fi
    return 1
}

if [[ -n "${EES_BOOTSTRAP_BASE:-}" ]]; then
    probiere "$EES_BOOTSTRAP_BASE" "$EES_BOOTSTRAP_BASE/keys" "EES_BOOTSTRAP_BASE" \
        || { echo "FEHLER: EES_BOOTSTRAP_BASE gesetzt, aber dort liegt kein install-services.sh:" >&2
             echo "  $EES_BOOTSTRAP_BASE" >&2; exit 1; }
fi

# Der Token geht ausschliesslich an GitHub. Ihn an einen anderen Server zu
# schicken hiesse, ein Geheimnis dorthin zu geben, wo es nicht hingehoert.
if [[ -z "$SCRIPT_BASE" ]]; then
    github_auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && github_auth=(-H "Authorization: token $GITHUB_TOKEN")
    probiere "$GITHUB_RAW" "$GITHUB_RAW/keys" "GitHub ($GITHUB_REPO)" \
        ${github_auth[@]+"${github_auth[@]}"} || true
fi

if [[ -z "$SCRIPT_BASE" ]]; then
    probiere "$UPDATE_SERVER" "$UPDATE_SERVER/keys" "Update-Server" || true
fi

if [[ -z "$SCRIPT_BASE" ]]; then
    echo "FEHLER: Keine erreichbare Bezugsquelle." >&2
    echo "  Versucht:" >&2
    echo "    $GITHUB_RAW" >&2
    echo "    $UPDATE_SERVER" >&2
    echo >&2
    echo "  Besteht ueberhaupt eine Internetverbindung?  curl -I https://github.com" >&2
    exit 1
fi

echo "Zielbenutzer:       $TARGET_USER"
echo "Arbeitsverzeichnis: $WORKDIR"
echo "Quelle:             $QUELLE_NAME"
echo "                    $SCRIPT_BASE"
echo

mkdir -p "$WORKDIR"

# --- Skripte herunterladen + ausführbar machen ---
for s in "${SCRIPTS[@]}"; do
  echo "Lade $s -> $WORKDIR/$s"
  if ! curl -fSL --retry 3 ${auth[@]+"${auth[@]}"} -o "$WORKDIR/$s" "$SCRIPT_BASE/$s"; then
    echo "FEHLER: Download von $s fehlgeschlagen." >&2
    exit 1
  fi
  chmod a+x "$WORKDIR/$s"
  [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]] && chown "$TARGET_USER":"$TARGET_USER" "$WORKDIR/$s"
done

# --- oeffentliche Release-Schluessel mitholen ---
#
# Sie gehoeren zum Bootstrap: install-services.sh legt sie nach /etc/ees/keys,
# und ohne sie kann der Updater kein Release pruefen. Der erste Schluessel
# laesst sich nicht ueber den Update-Mechanismus verteilen, den er absichert.
mkdir -p "$WORKDIR/keys"
for k in "${KEYS[@]}"; do
  echo "Lade $k -> $WORKDIR/keys/$k"
  if ! curl -fSL --retry 3 ${auth[@]+"${auth[@]}"} -o "$WORKDIR/keys/$k" "$KEY_BASE/$k"; then
    echo "WARNUNG: Download von $k fehlgeschlagen - Updates lassen sich ohne" >&2
    echo "  oeffentlichen Schluessel nicht pruefen." >&2
  fi
done
[[ $EUID -eq 0 && "$TARGET_USER" != "root" ]] && chown -R "$TARGET_USER":"$TARGET_USER" "$WORKDIR/keys"

echo
echo "Fertig. Abgelegt in $WORKDIR:"
for s in "${SCRIPTS[@]}"; do echo "  $s (ausführbar)"; done
