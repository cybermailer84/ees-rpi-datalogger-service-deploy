#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# ees-onboard.sh — bereitet einen Datenlogger fuer automatische Updates vor.
#
# Fasst die drei Schritte zusammen, die bisher von Hand zu machen waren:
#
#   1. Binaries holen             (install-update.sh)
#   2. systemd-Units, oeffentliche Schluessel und Updater  (install-services.sh)
#   3. Hardware-Variante setzen   (ueber den Konfigurations-Endpunkt)
#
# Danach traegt das Geraet seinen Versionsstand an das Dashboard und holt sich
# den dort hinterlegten Sollstand selbst. Es muss danach nicht mehr angefasst
# werden.
#
# AUSFUEHRUNG: auf dem Datenlogger, als root.
#
#   ./download_install_scripts.sh        # holt dieses Script und die Schluessel
#   sudo ./ees-onboard.sh -w v1.9
#
# Wiederholbar: Ein zweiter Lauf aktualisiert die Binaries, legt die Units neu
# an und setzt die Variante erneut - er richtet keinen Schaden an.
#
# Aufruf:  ees-onboard.sh -w <variante> [-p <port>] [-n]
#
#   -w  Hardware-Variante: v1.8 oder v1.9. Bestimmt, welche Binaries fuer
#       dieses Geraet gelten - ohne sie kann der Updater nicht arbeiten.
#   -p  Port des app-service   (Vorgabe: 8000)
#   -n  Probelauf: nur pruefen und anzeigen, nichts installieren.
#
set -euo pipefail

VARIANT=""
SERVICE_PORT="${SERVICE_PORT:-8000}"
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_UNIT="ees-app-service.service"
UPD_TIMER="ees-update.timer"
HC_TIMER="ees-healthcheck.timer"

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":w:p:nh" opt; do
    case "$opt" in
        w) VARIANT="$OPTARG" ;;
        p) SERVICE_PORT="$OPTARG" ;;
        n) DRY_RUN=true ;;
        h) usage 0 ;;
        \?) echo "Unbekannte Option: -$OPTARG" >&2; usage 2 ;;
        :)  echo "Option -$OPTARG benoetigt einen Wert" >&2; usage 2 ;;
    esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; echo "=== $* ==="; }
die()  { echo "FEHLER: $*" >&2; exit 1; }

# --- Vorbedingungen ---------------------------------------------------------

case "$VARIANT" in
    v1.8) HW_NUMBER=8 ;;
    v1.9) HW_NUMBER=9 ;;
    "")   die "Keine Hardware-Variante angegeben (-w v1.9)." ;;
    *)    die "Unbekannte Hardware-Variante: '$VARIANT' (erlaubt: v1.8, v1.9)." ;;
esac

$DRY_RUN || [[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren:  sudo $0 -w $VARIANT"

for tool in curl python3 systemctl; do
    command -v "$tool" >/dev/null || die "$tool ist nicht installiert."
done

# Die Geschwisterscripte kommen ueber download_install_scripts.sh mit. Dieses
# Script ruft es bewusst NICHT selbst auf: Es wuerde dabei die gerade laufende
# Datei ueberschreiben, und bash liest ein Script haeppchenweise waehrend der
# Ausfuehrung - das Ergebnis waere nicht vorhersagbar.
for helper in install-update.sh install-services.sh; do
    [[ -f "$SCRIPT_DIR/$helper" ]] \
        || die "$helper fehlt neben diesem Script ($SCRIPT_DIR).
  Zuerst ./download_install_scripts.sh ausfuehren."
done

# Ohne oeffentlichen Schluessel kann der Updater spaeter kein Release pruefen.
# Lieber hier auffallen als beim ersten Update.
if ! compgen -G "$SCRIPT_DIR/keys/*.pub" >/dev/null 2>&1 \
   && ! compgen -G "/etc/ees/keys/*.pub" >/dev/null 2>&1; then
    die "Kein oeffentlicher Release-Schluessel gefunden.
  Erwartet in $SCRIPT_DIR/keys/ oder /etc/ees/keys/.
  ./download_install_scripts.sh holt ihn mit."
fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Home-Verzeichnis von '$TARGET_USER' nicht ermittelbar."
WORKDIR="$TARGET_HOME/WORK/datalogger"

echo "----------------------------------------------------------------"
printf 'Hardware-Variante  : %s\n' "$VARIANT"
printf 'Zielbenutzer       : %s\n' "$TARGET_USER"
printf 'Arbeitsverzeichnis : %s\n' "$WORKDIR"
printf 'Port               : %s\n' "$SERVICE_PORT"
echo "----------------------------------------------------------------"

if $DRY_RUN; then
    echo
    log "Probelauf - es wird nichts installiert. Ausgefuehrt wuerden:"
    echo "  1. HARDWARE_VERSION=$HW_NUMBER $SCRIPT_DIR/install-update.sh"
    echo "  2. SERVICE_PORT=$SERVICE_PORT $SCRIPT_DIR/install-services.sh"
    echo "  3. Hardware-Variante '$VARIANT' ueber http://127.0.0.1:$SERVICE_PORT/config/update setzen"
    exit 0
fi

# --- 1. Binaries ------------------------------------------------------------

step "1/3  Binaries holen"
HARDWARE_VERSION="$HW_NUMBER" bash "$SCRIPT_DIR/install-update.sh" \
    || die "install-update.sh fehlgeschlagen."

# --- 2. Units, Schluessel, Updater -----------------------------------------

# Vor dem Setzen der Variante, nicht danach: Auf einem frischen Geraet gibt es
# noch keine Unit, der Dienst laeuft also nicht - und ohne laufenden Dienst
# gibt es keinen Konfigurations-Endpunkt, ueber den sich etwas setzen liesse.
step "2/3  systemd-Units, Schluessel und Updater einrichten"
SERVICE_PORT="$SERVICE_PORT" bash "$SCRIPT_DIR/install-services.sh" \
    || die "install-services.sh fehlgeschlagen."

# --- 3. Hardware-Variante ---------------------------------------------------

step "3/3  Hardware-Variante setzen"

log "Warte darauf, dass der Dienst antwortet ..."
healthy=false
for _ in $(seq 40); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
             "http://127.0.0.1:$SERVICE_PORT/health" 2>/dev/null)" == "200" ]]; then
        healthy=true
        break
    fi
    sleep 1
done
# Kommt der Dienst nicht hoch, ist die haeufigste Ursache eine Bibliothek, die
# auf dem Build-Rechner vorhanden war und auf diesem Geraet fehlt. Das gleich
# hier zeigen, statt den Benutzer erst durch journalctl schicken zu muessen -
# die eigentliche Meldung steht sonst drei Schritte weiter hinten.
if ! $healthy; then
    echo
    echo "--- Der Dienst kam nicht hoch. Was das Geraet dazu sagt: -------------"

    echo
    echo "Fehlende Bibliotheken (ldd):"
    if command -v ldd >/dev/null; then
        fehlende="$(ldd "$WORKDIR/app-service" 2>/dev/null | grep -i 'not found' || true)"
        if [[ -n "$fehlende" ]]; then
            sed 's/^/  /' <<<"$fehlende"
            echo
            echo "  Das Binary wurde auf einem Rechner gebaut, auf dem es diese"
            echo "  Bibliotheken gibt - auf diesem Geraet fehlen sie. Entweder hier"
            echo "  nachinstallieren, oder auf einem Geraet bauen, das dem hier"
            echo "  entspricht (gleiche Betriebssystemfassung)."
        else
            echo "  keine - daran liegt es nicht."
        fi
    else
        echo "  ldd nicht vorhanden."
    fi

    echo
    echo "Direkter Startversuch:"
    # In einem Wegwerf-Verzeichnis und als Zielbenutzer, nicht als root: Kommt
    # das Binary weit genug, legt es eine Datenbank an - die gehoerte sonst
    # root und waere fuer den eigentlichen Dienst nicht mehr beschreibbar.
    # Mit Zeitgrenze, weil ein erfolgreicher Start nicht von selbst endet.
    probe_dir="$(mktemp -d)"
    chown "$TARGET_USER":"$TARGET_USER" "$probe_dir" 2>/dev/null || true
    if command -v setpriv >/dev/null; then
        probe_cmd=(setpriv --reuid="$TARGET_USER" --regid="$TARGET_USER" --clear-groups)
    elif command -v runuser >/dev/null; then
        probe_cmd=(runuser -u "$TARGET_USER" --)
    else
        probe_cmd=()   # dann eben als root - die Zeitgrenze und das
                       # Wegwerf-Verzeichnis begrenzen den Schaden trotzdem
    fi
    ( cd "$probe_dir" && timeout 5 ${probe_cmd[@]+"${probe_cmd[@]}"} \
        "$WORKDIR/app-service" --service-port 0 ) 2>&1 \
        | head -5 | sed 's/^/  /' || true
    rm -rf "$probe_dir"

    echo
    echo "Letzte Zeilen aus dem Journal:"
    journalctl -u "$APP_UNIT" -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || true
    echo "----------------------------------------------------------------------"
    echo

    die "Der app-service antwortet nicht auf Port $SERVICE_PORT - siehe oben.
  Die Hardware-Variante wurde noch nicht gesetzt. Nach der Behebung dieses
  Script einfach erneut aufrufen, es ist wiederholbar."
fi

# Die Konfiguration wird als Ganzes ersetzt - also erst lesen, ergaenzen,
# zurueckschreiben. Nur das eine Feld zu senden wuerde alles andere loeschen.
config="$(curl -fsS --max-time 10 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null)" \
    || die "Konfiguration nicht lesbar."

patched="$(python3 -c '
import json, sys
cfg = json.load(sys.stdin)
if not cfg:
    sys.exit("Konfiguration ist leer")
cfg["hardwareVariant"] = sys.argv[1]
print(json.dumps(cfg))
' "$VARIANT" <<<"$config")" || die "Konfiguration nicht veraenderbar."

curl -fsS -o /dev/null --max-time 10 -X POST \
    "http://127.0.0.1:$SERVICE_PORT/config/update" \
    -H 'Content-Type: application/json' --data @- <<<"$patched" \
    || die "Hardware-Variante konnte nicht gesetzt werden."

log "Hardware-Variante '$VARIANT' gesetzt."

# --- Abschliessende Pruefung ------------------------------------------------

step "Pruefung"

fehler=0
pruefe() { # beschreibung erwartet ist
    if [[ "$2" == "$3" ]]; then
        printf '  ok    %-34s %s\n' "$1" "$3"
    else
        printf '  FEHLT %-34s erwartet "%s", ist "%s"\n' "$1" "$2" "$3"
        fehler=$(( fehler + 1 ))
    fi
}

variant_now="$(curl -fsS --max-time 5 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hardwareVariant") or "")' 2>/dev/null || true)"
pruefe "Hardware-Variante" "$VARIANT" "$variant_now"

sensor_id="$(curl -fsS --max-time 5 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("piDataLoggerId") or "")' 2>/dev/null || true)"
printf '  ok    %-34s %s\n' "Geraetekennung" "${sensor_id:-unbekannt}"

version="$(grep -ao '20[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]+[0-9a-f]\{7\}\(-dirty\)\?' \
    "$WORKDIR/app-service" 2>/dev/null | head -1 || true)"
if [[ -n "$version" ]]; then
    printf '  ok    %-34s %s\n' "Versionsstand" "$version"
else
    printf '  FEHLT %-34s %s\n' "Versionsstand" "keiner im Binary - zu alter Build?"
    fehler=$(( fehler + 1 ))
fi

for unit in "$APP_UNIT" "$HC_TIMER" "$UPD_TIMER"; do
    pruefe "$unit" "active" "$(systemctl is-active "$unit" 2>/dev/null || echo inaktiv)"
done

keys="$(ls /etc/ees/keys/*.pub 2>/dev/null | wc -l)"
if (( keys > 0 )); then
    printf '  ok    %-34s %s\n' "Release-Schluessel" "$keys in /etc/ees/keys"
else
    printf '  FEHLT %-34s %s\n' "Release-Schluessel" "keiner in /etc/ees/keys"
    fehler=$(( fehler + 1 ))
fi

echo
if (( fehler > 0 )); then
    die "$fehler Punkt(e) offen - siehe oben."
fi

log "Geraet ist vorbereitet."
echo
echo "Abschlussprobe (aendert nichts):"
echo "  sudo $WORKDIR/ees-update.sh --dry-run"
echo
echo "Danach im Dashboard unter Administration -> Datenlogger die Soll-Version"
echo "setzen. Das Geraet holt sie sich von allein, spaetestens nach 25 Minuten."
