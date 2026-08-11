#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# ees-set-variant.sh — traegt die Hardware-Variante nach und rollt das Update aus.
#
# Fuer Geraete, die bereits laufen, aber keine Hardware-Variante in der
# Konfiguration haben. Ohne sie ist nicht bestimmbar, welche Binaries fuer das
# Geraet gelten, und ees-update.sh bricht mit genau dieser Meldung ab:
#
#   "Keine Hardware-Variante in der Konfiguration."
#
# Abgrenzung zu ees-onboard.sh: Jenes richtet ein fabrikneues Geraet komplett
# ein - Binaries, systemd-Units, Schluessel, Variante. Dieses Script setzt nur
# die Variante und stoesst den Update-Lauf an. Es fasst weder Binaries noch
# Units an und eignet sich damit fuer ein Geraet im Betrieb.
#
# AUSFUEHRUNG: auf dem Datenlogger, als root.
#
#   sudo ./ees-set-variant.sh -w v1.9 -u
#
# Wiederholbar: Steht die Variante bereits richtig, meldet das Script das und
# aendert nichts. Eine abweichende Variante wird nur mit -f ueberschrieben -
# eine falsche Variante zieht die Binaries einer fremden Hardware.
#
# Aufruf:  ees-set-variant.sh -w <variante> [-p <port>] [-u] [-f] [-n]
#
#   -w  Hardware-Variante: v1.8 oder v1.9.
#   -p  Port des app-service   (Vorgabe: 8000)
#   -u  Nach dem Setzen sofort einen Update-Lauf ausloesen, statt bis zu
#       25 Minuten auf den Timer zu warten.
#   -f  Eine bereits gesetzte, abweichende Variante ueberschreiben.
#   -n  Probelauf: nur lesen und anzeigen, nichts schreiben.
#
set -euo pipefail

VARIANT=""
SERVICE_PORT="${SERVICE_PORT:-8000}"
RUN_UPDATE=false
FORCE=false
DRY_RUN=false
WORKDIR="${EES_WORKDIR:-}"

# Die Werksvorgabe aus dtos::AppServiceConfigDto::default(). Steht sie als
# Geraetekennung da, hat der Dienst seine Konfiguration nicht lesen koennen -
# ein Zurueckschreiben wuerde den Verlust festschreiben.
WERKSVORGABE="rpi_bi_gs27_schule"

APP_UNIT="ees-app-service.service"
UPD_UNIT="ees-update.service"

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":w:p:ufnh" opt; do
    case "$opt" in
        w) VARIANT="$OPTARG" ;;
        p) SERVICE_PORT="$OPTARG" ;;
        u) RUN_UPDATE=true ;;
        f) FORCE=true ;;
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
    v1.8|v1.9) ;;
    "")   die "Keine Hardware-Variante angegeben (-w v1.9)." ;;
    *)    die "Unbekannte Hardware-Variante: '$VARIANT' (erlaubt: v1.8, v1.9)." ;;
esac

$DRY_RUN || [[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren:  sudo $0 -w $VARIANT"

for tool in curl python3 systemctl; do
    command -v "$tool" >/dev/null || die "$tool ist nicht installiert."
done

# Dieselbe Aufloesung wie in ees-update.sh: unter systemd ist HOME=/root, von
# Hand aufgerufen zaehlt das Home des aufrufenden Benutzers. Gebraucht wird das
# Verzeichnis nur, um die laufende Version aus dem Binary zu lesen - fehlt es,
# ist das kein Grund abzubrechen.
if [[ -z "$WORKDIR" ]]; then
    fallback_user="${SUDO_USER:-$(id -un)}"
    fallback_home="$(getent passwd "$fallback_user" | cut -d: -f6 || true)"
    [[ -n "$fallback_home" ]] && WORKDIR="$fallback_home/WORK/datalogger"
fi

lies_version() {
    [[ -n "$WORKDIR" && -r "$WORKDIR/app-service" ]] || return 1
    grep -ao '20[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]+[0-9a-f]\{7\}\(-dirty\)\?' \
        "$WORKDIR/app-service" | head -1
}

# --- Konfiguration lesen ----------------------------------------------------

step "1/3  Konfiguration lesen"

# Bewusst nur ueber den Dienst, nicht ersatzweise aus der Datenbank: Zurueck
# geschrieben wird die *vollstaendige* Konfiguration. Aus der Datenbank lagen
# nur einzelne Felder vor - daraus einen Vollersatz zu bauen hiesse, Sensoren
# und Adapter zu loeschen.
CONFIG="$(curl -fsS --max-time 10 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null || true)"

[[ -n "$CONFIG" ]] || die "Dienst antwortet nicht auf http://127.0.0.1:$SERVICE_PORT/config/
  Ohne ihn liegt die vollstaendige Konfiguration nicht vor, und dieses Script
  wuerde beim Zurueckschreiben Sensoren und Adapter verlieren.
  Nachsehen mit:  systemctl status $APP_UNIT ; journalctl -u $APP_UNIT -n 30"

# Zeilenweise statt durch Leerzeichen getrennt: eine Kennung mit Leerzeichen
# wuerde sonst still in zwei Felder zerfallen.
FELDER="$(python3 -c '
import json, sys
cfg = json.load(sys.stdin) or {}
print(cfg.get("piDataLoggerId") or "")
print(cfg.get("hardwareVariant") or "")
' <<<"$CONFIG" 2>/dev/null || true)"

KENNUNG="$(sed -n 1p <<<"$FELDER")"
IST_VARIANTE="$(sed -n 2p <<<"$FELDER")"

[[ -n "$KENNUNG" ]] || die "Keine Geraetekennung in der Konfiguration."

# Dieselbe Sperre wie in ees-onboard.sh: Die Werksvorgabe bedeutet, dass der
# Dienst seine Konfiguration nicht lesen konnte. Zurueckschreiben wuerde den
# Verlust festschreiben.
[[ "$KENNUNG" != "$WERKSVORGABE" ]] || die "Der Dienst meldet die Geraetekennung '$KENNUNG'.
  Das ist die Werksvorgabe, nicht die dieses Geraetes - die Konfiguration ist
  also verloren gegangen. Dieses Script bricht ab, damit es das nicht
  festschreibt.

  Letzte Sicherung ansehen:  ls -l /var/lib/ees/config/
  Einspielen:                curl -sS -X POST http://127.0.0.1:$SERVICE_PORT/config/update \\
                               -H 'content-type: application/json' \\
                               --data @/var/lib/ees/config/data_logger.config"

VERSION_IST="$(lies_version || true)"

echo "----------------------------------------------------------------"
printf 'Geraetekennung     : %s\n' "$KENNUNG"
printf 'Variante ist       : %s\n' "${IST_VARIANTE:-nicht gesetzt}"
printf 'Variante soll      : %s\n' "$VARIANT"
printf 'Laufende Version   : %s\n' "${VERSION_IST:-unbekannt}"
echo "----------------------------------------------------------------"

# --- Entscheiden ------------------------------------------------------------

if [[ "$IST_VARIANTE" == "$VARIANT" ]]; then
    log "Variante steht bereits auf '$VARIANT' - nichts zu aendern."
    SCHREIBEN=false
elif [[ -n "$IST_VARIANTE" ]] && ! $FORCE; then
    die "Es steht bereits die Variante '$IST_VARIANTE' in der Konfiguration.
  Eine falsche Variante zieht die Binaries einer fremden Hardware.
  Wenn '$VARIANT' wirklich richtig ist:  $0 -w $VARIANT -f"
else
    SCHREIBEN=true
fi

if $DRY_RUN; then
    echo
    log "Probelauf - es wird nichts geschrieben. Ausgefuehrt wuerden:"
    $SCHREIBEN && echo "  1. hardwareVariant='$VARIANT' ueber /config/update setzen" \
               || echo "  1. (nichts - Variante steht schon richtig)"
    $RUN_UPDATE && echo "  2. systemctl start $UPD_UNIT"
    exit 0
fi

# --- Variante setzen --------------------------------------------------------

step "2/3  Hardware-Variante setzen"

if $SCHREIBEN; then
    # Der Konfigurations-Endpunkt ersetzt vollstaendig - also die gelesene
    # Konfiguration ergaenzen und komplett zurueckschreiben, nicht nur das Feld.
    PATCHED="$(python3 -c '
import json, sys
cfg = json.load(sys.stdin)
if not cfg:
    sys.exit("Konfiguration ist leer")
cfg["hardwareVariant"] = sys.argv[1]
print(json.dumps(cfg))
' "$VARIANT" <<<"$CONFIG")" || die "Konfiguration nicht veraenderbar."

    curl -fsS -o /dev/null --max-time 10 -X POST \
        "http://127.0.0.1:$SERVICE_PORT/config/update" \
        -H 'Content-Type: application/json' --data @- <<<"$PATCHED" \
        || die "Hardware-Variante konnte nicht gesetzt werden."

    # Gegenprobe am Dienst, nicht am eigenen Wunsch: Der POST kann mit 200
    # antworten und die Persistenz trotzdem scheitern.
    JETZT="$(curl -fsS --max-time 5 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hardwareVariant") or "")' \
        2>/dev/null || true)"

    [[ "$JETZT" == "$VARIANT" ]] \
        || die "Variante steht nach dem Schreiben auf '${JETZT:-leer}', erwartet '$VARIANT'."

    log "Hardware-Variante '$VARIANT' gesetzt und geprueft."
else
    log "Uebersprungen."
fi

# --- Update ausloesen -------------------------------------------------------

step "3/3  Update"

if ! $RUN_UPDATE; then
    echo "  Nicht ausgeloest (-u nicht angegeben)."
    echo "  Der Timer greift von selbst, hoechstens 25 Minuten:"
    echo "    systemctl list-timers ees-update.timer"
    echo "  Sofort ausloesen:"
    echo "    sudo systemctl start $UPD_UNIT"
    exit 0
fi

echo "  Soll-Version muss im Dashboard gesetzt sein - sonst passiert nichts."
echo

systemctl start "$UPD_UNIT" || true
journalctl -u "$UPD_UNIT" -n 40 --no-pager

echo
printf 'Version vorher : %s\n' "${VERSION_IST:-unbekannt}"
printf 'Version jetzt  : %s\n' "$(lies_version || echo 'nicht lesbar')"
