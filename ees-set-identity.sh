#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# ees-set-identity.sh — gibt einem geklonten Datenlogger seine eigene Kennung.
#
# Fuer eine NVMe, die von einem fertig eingerichteten Geraet kopiert wurde. Der
# Klon traegt noch Hostname, Datenlogger-ID, VPN-Zertifikat und Systemkennungen
# der Vorlage. Dieses Script stellt all das auf die neue Kennung um:
#
#   1. Konfiguration des app-service: piDataLoggerId und jedes Vorkommen der
#      alten Kennung (ueber den Dienst, nicht in der Datenbank)
#   2. Hostname:  /etc/hostname, /etc/hosts
#   3. Crontab (Geraetebenutzer und root) und /etc/default/openvpn
#   4. VPN-Zertifikat der neuen Kennung holen und einsetzen
#   5. Klon-Kennungen erneuern: machine-id, DHCP-DUID, SSH-Hostschluessel;
#      Konfigurationssicherungen der Vorlage beiseitelegen
#   6. Zeichensatz auf UTF-8 stellen, falls er es nicht ist
#   7. Pruefen, dass das Dashboard Softwarestand und Hardware-Variante unter
#      der neuen Kennung fuehrt
#
# Den Softwarestand meldet der app-service selbst: Sein Heartbeat traegt
# Version und Hardware-Variante, und nach dem Setzen der Konfiguration sendet
# er sofort. Dieses Script sieht nur nach, ob es angekommen ist.
#
# AUSFUEHRUNG: auf dem geklonten Datenlogger, als root. Klone nacheinander in
# Betrieb nehmen - bis zum Neustart teilen sie sich Hostname und machine-id,
# und damit im selben Netz auch die DHCP-Adresse.
#
#   sudo ./ees-set-identity.sh -k rpi-de69test -n    # Probelauf
#   sudo ./ees-set-identity.sh -k rpi-de69test -r    # umstellen, neu starten
#
# Die neue Kennung muss im Dashboard angelegt sein, sonst lehnt es den
# Heartbeat ab. Das Script stellt das Geraet trotzdem um und sagt es am Ende.
#
# Wiederholbar: Was bereits auf der neuen Kennung steht, bleibt unangetastet.
#
# Aufruf:  ees-set-identity.sh -k <kennung> [-w <variante>] [-u <url>]
#                              [-p <port>] [-l] [-V] [-Z] [-r] [-y] [-n]
#
#   -k  Neue Kennung, z.B. rpi-de69test (rpi_de69test geht auch).
#       Hostname wird rpi-de69test, Datenlogger-ID rpi_de69test.
#   -w  Hardware-Variante mitsetzen: v1.8 oder v1.9 (sonst bleibt sie).
#   -u  Heartbeat-URL setzen (sonst bleibt sie).
#   -p  Port des app-service   (Vorgabe: 8000)
#   -l  Mitgebrachte Messwerte und das Fehlerprotokoll der Vorlage loeschen.
#   -V  Kein VPN-Zertifikat holen.
#   -Z  Zeichensatz nicht anfassen.
#   -r  Am Ende neu starten. Noetig ist der Neustart in jedem Fall - erst
#       danach gelten Hostname, machine-id und das neue VPN-Zertifikat.
#   -y  Ohne Rueckfrage ausfuehren.
#   -n  Probelauf: nur lesen und anzeigen, nichts aendern.
#
set -euo pipefail

NEU_EINGABE=""
VARIANTE=""
NEUE_URL=""
SERVICE_PORT="${SERVICE_PORT:-8000}"
MESSWERTE_LOESCHEN=false
MIT_VPN=true
MIT_ZEICHENSATZ=true
NEUSTART=false
JA=false
PROBELAUF=false
WORKDIR="${EES_WORKDIR:-}"

# Nur fuer den Test: legt /etc und /var unter ein anderes Verzeichnis.
ROOT="${EES_ROOT:-}"
STATE_DIR="$ROOT/var/lib/ees"
VPN_BASE="${EES_VPN_BASE:-https://ees.itc-haas.at/smartnode/ressources/vpn/vpncert/rpi}"
DASHBOARD_HOST="dashboard.ees-austria.at"
# Wie lange auf die Meldung im Dashboard gewartet wird. Der Dienst sendet
# sofort nach dem Setzen der Konfiguration; laenger als ein paar Sekunden
# dauert es nur, wenn etwas nicht stimmt.
MELDUNG_TIMEOUT="${EES_MELDUNG_TIMEOUT:-45}"

# Die Werksvorgabe aus dtos::AppServiceConfigDto::default(). Steht sie als
# Geraetekennung da, hat der Dienst seine Konfiguration nicht lesen koennen -
# ein Zurueckschreiben wuerde den Verlust festschreiben.
WERKSVORGABE="rpi_bi_gs27_schule"

APP_UNIT="ees-app-service.service"

usage() { sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":k:w:u:p:lVZrynh" opt; do
    case "$opt" in
        k) NEU_EINGABE="$OPTARG" ;;
        w) VARIANTE="$OPTARG" ;;
        u) NEUE_URL="$OPTARG" ;;
        p) SERVICE_PORT="$OPTARG" ;;
        l) MESSWERTE_LOESCHEN=true ;;
        V) MIT_VPN=false ;;
        Z) MIT_ZEICHENSATZ=false ;;
        r) NEUSTART=true ;;
        y) JA=true ;;
        n) PROBELAUF=true ;;
        h) usage 0 ;;
        \?) echo "Unbekannte Option: -$OPTARG" >&2; usage 2 ;;
        :)  echo "Option -$OPTARG benoetigt einen Wert" >&2; usage 2 ;;
    esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; echo "=== $* ==="; }
die()  { echo "FEHLER: $*" >&2; exit 1; }

# --- Vorbedingungen ---------------------------------------------------------

[[ -n "$NEU_EINGABE" ]] || die "Keine neue Kennung angegeben (-k rpi-de69test)."

# Beide Schreibweisen annehmen, denn beide sind im Umlauf: der Hostname mit
# Bindestrich, die Datenlogger-ID mit Unterstrich.
kern="${NEU_EINGABE#rpi-}"; kern="${kern#rpi_}"
[[ "$kern" != "$NEU_EINGABE" ]] || die "Die Kennung muss mit rpi- beginnen: '$NEU_EINGABE'"
# Nur Kleinbuchstaben und Ziffern: Der Hostname vertraegt keinen Unterstrich,
# die ID keinen Bindestrich - alles andere zerfiele in einer der beiden Formen.
[[ "$kern" =~ ^[a-z0-9]+$ ]] || die "Ungueltige Kennung '$NEU_EINGABE' - nach rpi- nur Kleinbuchstaben und Ziffern."
NEU_HOST="rpi-$kern"
NEU_ID="rpi_$kern"

case "$VARIANTE" in
    v1.8|v1.9|"") ;;
    *) die "Unbekannte Hardware-Variante: '$VARIANTE' (erlaubt: v1.8, v1.9)." ;;
esac

if [[ -n "$NEUE_URL" ]]; then
    [[ "$NEUE_URL" == https://*/heartbeat || "$NEUE_URL" == http://*/heartbeat ]] \
        || die "Die Heartbeat-URL muss auf /heartbeat enden: $NEUE_URL"
fi

$PROBELAUF || [[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren:  sudo $0 -k $NEU_HOST
  Nur ansehen geht auch ohne:  $0 -k $NEU_HOST -n"

for tool in curl python3 systemctl crontab; do
    command -v "$tool" >/dev/null || die "$tool ist nicht installiert."
done
$MIT_VPN && { command -v tar >/dev/null || die "tar ist nicht installiert (oder -V fuer ohne VPN)."; }
$MESSWERTE_LOESCHEN && { command -v sqlite3 >/dev/null || die "-l braucht sqlite3:  sudo apt install sqlite3"; }

if [[ -z "$WORKDIR" ]]; then
    ziel_user="${SUDO_USER:-$(id -un)}"
    ziel_home="$(getent passwd "$ziel_user" | cut -d: -f6 || true)"
    [[ -n "$ziel_home" ]] || die "Home von '$ziel_user' nicht ermittelbar.
  Aufruf mit EES_WORKDIR=... wiederholen."
    WORKDIR="$ziel_home/WORK/datalogger"
fi
[[ -d "$WORKDIR" ]] || die "Arbeitsverzeichnis nicht gefunden: $WORKDIR"
GERAETE_USER="$(stat -c '%U' "$WORKDIR")"
DB="$WORKDIR/app-service-database.sqlite"

lies_version() {
    grep -ao '20[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]+[0-9a-f]\{7\}\(-dirty\)\?' \
        "$WORKDIR/app-service" 2>/dev/null | head -1 || true
}

# Ersetzt in einer Datei jede alte Kennung durch die neue, aber nur als
# ganzes Wort: rpi_ab darf nicht in rpi_abc hineingreifen. rpi_ab_1 wird zu
# rpi_neu_1 - so hat es auch das alte sed-Script gehalten.
# Schreibt nur, wenn sich etwas aendert, und in dieselbe Datei (Rechte und
# Eigentuemer bleiben). Gibt die Zahl der Ersetzungen aus.
ersetze() { # datei alt neu [alt neu ...]
    python3 - "$@" <<'PY'
import re, sys
pfad, paare = sys.argv[1], sys.argv[2:]
with open(pfad, encoding="utf-8", errors="surrogateescape") as fh:
    text = fh.read()
neu, anzahl = text, 0
for alt, ersatz in zip(paare[0::2], paare[1::2]):
    muster = r"(?<![A-Za-z0-9])" + re.escape(alt) + r"(?![A-Za-z0-9])"
    neu, n = re.subn(muster, lambda _m: ersatz, neu)
    anzahl += n
if anzahl:
    with open(pfad, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(neu)
print(anzahl)
PY
}

warte_auf_dienst() {
    local _
    for _ in $(seq 40); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
             "http://127.0.0.1:$SERVICE_PORT/health" 2>/dev/null)" == "200" ]] && return 0
        sleep 1
    done
    return 1
}

# --- 1. Bestand aufnehmen ---------------------------------------------------

step "Bestand"

# Bewusst nur ueber den Dienst, nicht aus der Datenbank: Zurueckgeschrieben
# wird die vollstaendige Konfiguration, und die liefert nur der Dienst.
CONFIG="$(curl -fsS --max-time 10 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null || true)"
[[ -n "$CONFIG" && "$CONFIG" != "null" ]] || die "Dienst antwortet nicht auf http://127.0.0.1:$SERVICE_PORT/config/
  Ohne ihn liegt die vollstaendige Konfiguration nicht vor.
  Nachsehen mit:  systemctl status $APP_UNIT ; journalctl -u $APP_UNIT -n 30"

ALT_ID="$(python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("piDataLoggerId") or "")' <<<"$CONFIG")"
[[ -n "$ALT_ID" ]] || die "Keine Geraetekennung in der Konfiguration."
[[ "$ALT_ID" != "$WERKSVORGABE" ]] || die "Der Dienst meldet die Werksvorgabe '$ALT_ID' als Kennung.
  Die Konfiguration der Vorlage ist nicht angekommen oder verloren gegangen -
  dieses Script schreibt sie zurueck und wuerde den Verlust festschreiben.
  Zuerst eine Konfiguration einspielen (app-tui oder /config/update)."

if [[ -n "$ROOT" ]]; then
    ALT_HOST="$(tr -d '[:space:]' < "$ROOT/etc/hostname")"
else
    ALT_HOST="$(hostname -s)"
fi

# Welche Zeichenketten als "alte Kennung" gelten. Die ID aus der
# Konfiguration immer; die aus dem Hostnamen abgeleitete nur, wenn der
# Hostname dem Schema folgt - ein "raspberrypi" in der Crontab zu ersetzen
# waere sonst ein Blindgaenger.
ID_PAARE=("$ALT_ID" "$NEU_ID")
HOST_PAARE=("$ALT_HOST" "$NEU_HOST")
if [[ "$ALT_HOST" == rpi-* && "${ALT_HOST//-/_}" != "$ALT_ID" ]]; then
    ID_PAARE+=("${ALT_HOST//-/_}" "$NEU_ID")
fi
if [[ "$ALT_ID" == rpi_* && "${ALT_ID//_/-}" != "$ALT_HOST" ]]; then
    HOST_PAARE+=("${ALT_ID//_/-}" "$NEU_HOST")
fi

# Die neue Konfiguration schon hier bauen, damit der Probelauf genau zeigt,
# welche Felder sich aendern.
PATCH="$(python3 -c '
import json, re, sys
neu_id, variante, url = sys.argv[1:4]
paare = list(zip(sys.argv[4::2], sys.argv[5::2]))
cfg = json.load(sys.stdin)
if not cfg:
    sys.exit("Konfiguration ist leer")
aenderungen = []

def ersetze(wert):
    for alt, neu in paare:
        muster = r"(?<![A-Za-z0-9])" + re.escape(alt) + r"(?![A-Za-z0-9])"
        wert = re.sub(muster, lambda _m: neu, wert)
    return wert

def laufe(knoten, pfad):
    if isinstance(knoten, dict):
        return {k: laufe(v, pfad + "." + k if pfad else k) for k, v in knoten.items()}
    if isinstance(knoten, list):
        return [laufe(v, "%s[%d]" % (pfad, i)) for i, v in enumerate(knoten)]
    if isinstance(knoten, str):
        neu = ersetze(knoten)
        if neu != knoten:
            aenderungen.append((pfad, knoten, neu))
        return neu
    return knoten

cfg = laufe(cfg, "")

def setze(feld, wert):
    if wert and cfg.get(feld) != wert:
        aenderungen.append((feld, cfg.get(feld), wert))
        cfg[feld] = wert

# Die ID ausdruecklich setzen, auch wenn die Ersetzung sie schon traf -
# so steht sie auch bei einer ungewoehnlich geschriebenen alten Kennung.
if cfg.get("piDataLoggerId") != neu_id:
    setze("piDataLoggerId", neu_id)
setze("hardwareVariant", variante)
setze("heartbeatUrl", url)

# Doppelte Eintraege (Ersetzung und setze() auf demselben Feld) nur einmal zeigen.
gesehen, zeilen = set(), []
for pfad, alt, neu in aenderungen:
    if pfad not in gesehen:
        gesehen.add(pfad)
        zeilen.append("%s: %s -> %s" % (pfad, alt, neu))

aktiv = []
for s in cfg.get("sensors") or []:
    if not s.get("isEnabled"):
        continue
    kennungen = sorted({a.get("valueAuthorizationId") or "" for a in s.get("adapter") or []} - {""})
    aktiv.append("%s%s" % (s.get("sensorId") or "(ohne sensorId)",
                          " -> " + ", ".join(kennungen) if kennungen else ""))

print(json.dumps({
    "config": cfg,
    "aenderungen": zeilen,
    "sensoren": aktiv,
    "variante": cfg.get("hardwareVariant") or "",
    "url": cfg.get("heartbeatUrl") or "",
    "aktiv": bool(cfg.get("isAppServiceActive")),
    "intervall": cfg.get("heartbeatInterval") or 60,
}))
' "$NEU_ID" "$VARIANTE" "$NEUE_URL" "${ID_PAARE[@]}" <<<"$CONFIG")" \
    || die "Konfiguration nicht auswertbar."

feld() { python3 -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print("\n".join(v) if isinstance(v,list) else ("true" if v is True else "false" if v is False else v))' "$1" <<<"$PATCH"; }

AENDERUNGEN="$(feld aenderungen)"
SENSOREN="$(feld sensoren)"
SOLL_VARIANTE="$(feld variante)"
SOLL_URL="$(feld url)"
DIENST_AKTIV="$(feld aktiv)"
INTERVALL="$(feld intervall)"
VERSION="$(lies_version)"

# Identitaet gilt als neu, solange die Klon-Kennungen nicht fuer diese ID
# erneuert wurden. Die Marke der Vorlage reist mit der NVMe mit, traegt aber
# deren Kennung - deshalb der Vergleich und nicht nur "gibt es sie".
MARKE="$STATE_DIR/identitaet"
KLON_ERNEUERN=true
[[ -r "$MARKE" && "$(cat "$MARKE")" == "$NEU_ID" ]] && KLON_ERNEUERN=false

# Der Zeichensatz der Anmeldesitzung. Gelesen wird die Datei, nicht die eigene
# Umgebung: sudo reicht LANG durch, und dann stuende hier der Zeichensatz des
# Aufrufenden statt der, den das Geraet am Bildschirm verwendet.
#
# LC_ALL wird mitgelesen, weil es jede andere Einstellung uebersteuert - ein
# LANG=de_AT.UTF-8 neben LC_ALL=de_AT bleibt wirkungslos.
LOCALE_DATEI="$ROOT/etc/default/locale"
LOCALE_GEN="$ROOT/etc/locale.gen"

lies_locale() { # variable
    [[ -r "$LOCALE_DATEI" ]] || return 0
    sed -n "s/^[[:space:]]*$1=\\?\"\\?\([^\"]*\)\"\\?[[:space:]]*$/\1/p" "$LOCALE_DATEI" | tail -1
}

ist_utf8() { [[ "${1,,}" == *.utf-8 || "${1,,}" == *.utf8 ]]; }

LANG_IST="$(lies_locale LANG)"
LCALL_IST="$(lies_locale LC_ALL)"

# Ziel: dieselbe Sprache, nur mit Zeichensatz. Steht gar nichts oder C/POSIX
# da, ist C.UTF-8 richtig - das gibt es auf jedem Debian ohne locale-gen.
basis="${LANG_IST%%.*}"
case "${basis:-C}" in
    C|POSIX|"") LOCALE_SOLL="C.UTF-8" ;;
    *)          LOCALE_SOLL="$basis.UTF-8" ;;
esac

ZEICHENSATZ_OK=false
if ist_utf8 "$LANG_IST" && { [[ -z "$LCALL_IST" ]] || ist_utf8 "$LCALL_IST"; }; then
    ZEICHENSATZ_OK=true
fi
$MIT_ZEICHENSATZ || ZEICHENSATZ_OK=true   # -Z: als erledigt behandeln

VPN_DA=false
for d in "$ROOT/etc/openvpn/$NEU_ID.conf" "$ROOT/etc/openvpn/$NEU_ID.ovpn"; do
    [[ -f "$d" ]] && VPN_DA=true
done

UNGESENDET=""
if command -v sqlite3 >/dev/null && [[ -r "$DB" ]]; then
    UNGESENDET="$(sqlite3 -readonly "$DB" "
        SELECT (SELECT COUNT(*) FROM ees_sensor_values WHERE send_at IS NULL)
             + (SELECT COUNT(*) FROM big_sensor_values WHERE send_at IS NULL);" 2>/dev/null || true)"
fi

echo "----------------------------------------------------------------"
printf 'Hostname           : %s -> %s\n' "$ALT_HOST" "$NEU_HOST"
printf 'Datenlogger-ID     : %s -> %s\n' "$ALT_ID" "$NEU_ID"
printf 'Hardware-Variante  : %s\n' "${SOLL_VARIANTE:-NICHT GESETZT}"
printf 'Softwarestand      : %s\n' "${VERSION:-unbekannt}"
printf 'Heartbeat-URL      : %s\n' "$SOLL_URL"
printf 'Zeichensatz        : %s\n' "$(if $ZEICHENSATZ_OK; then echo "${LANG_IST:-nicht gesetzt}"; else echo "${LANG_IST:-nicht gesetzt}${LCALL_IST:+, LC_ALL=$LCALL_IST}  ->  $LOCALE_SOLL"; fi)"
printf 'Arbeitsverzeichnis : %s  (Benutzer %s)\n' "$WORKDIR" "$GERAETE_USER"
echo "----------------------------------------------------------------"

echo
echo "Aenderungen in der Konfiguration:"
if [[ -n "$AENDERUNGEN" ]]; then sed 's/^/  /' <<<"$AENDERUNGEN"; else echo "  keine"; fi

# Sichtbar machen, was jeder Klon senden wird: Eine Testkonfiguration der
# Vorlage mit echten Sensor-Kennungen liesse sonst alle Klone auf dieselben
# Sensoren im Dashboard schreiben.
echo
echo "Aktive Sensoren (sensorId -> valueAuthorizationId):"
if [[ -n "$SENSOREN" ]]; then sed 's/^/  /' <<<"$SENSOREN"; else echo "  keine"; fi

echo
warnungen=0
hinweis() { echo "  ACHTUNG: $*"; warnungen=$(( warnungen + 1 )); }
[[ -n "$SOLL_VARIANTE" ]] || hinweis "keine Hardware-Variante - mit -w v1.8 bzw. -w v1.9 mitsetzen, sonst bricht der Updater ab."
[[ "$DIENST_AKTIV" == "true" ]] || hinweis "isAppServiceActive ist aus - der Dienst sendet dann gar keinen Heartbeat."
[[ -n "$VERSION" ]] || hinweis "keine Versionsangabe im Binary - zu alt, um sie zu melden (install-update.sh)."
[[ "$SOLL_URL" == *"://$DASHBOARD_HOST/"* ]] || hinweis "Heartbeat-URL zeigt nicht auf $DASHBOARD_HOST (mit -u aendern)."
[[ -n "$SENSOREN" ]] && hinweis "Sensoren aktiv - jeder Klon sendet fuer die oben genannten Kennungen."
if [[ "${UNGESENDET:-0}" =~ ^[0-9]+$ ]] && (( ${UNGESENDET:-0} > 0 )) && ! $MESSWERTE_LOESCHEN; then
    hinweis "$UNGESENDET ungesendete Messwerte der Vorlage in der Datenbank (mit -l loeschen)."
fi
(( warnungen == 0 )) && echo "  keine Auffaelligkeiten"

echo
echo "Vorgesehen:"
n=0
plan() { n=$(( n + 1 )); echo "  $n. $*"; }
$MESSWERTE_LOESCHEN && plan "Messwerte und Fehlerprotokoll loeschen (Dienst kurz gestoppt)"
[[ -n "$AENDERUNGEN" ]] && plan "Konfiguration ueber /config/update schreiben"
[[ "$ALT_HOST" != "$NEU_HOST" ]] && plan "Hostname setzen, /etc/hosts anpassen"
plan "Crontab und /etc/default/openvpn auf $NEU_ID umstellen (soweit noetig)"
if $MIT_VPN; then
    $VPN_DA && plan "VPN: $NEU_ID liegt schon in /etc/openvpn - nichts zu holen" \
            || plan "VPN-Zertifikat $NEU_ID holen und einsetzen"
fi
$KLON_ERNEUERN && plan "machine-id, DHCP-DUID und SSH-Hostschluessel erneuern; Sicherungen der Vorlage beiseitelegen"
$ZEICHENSATZ_OK || plan "Zeichensatz auf $LOCALE_SOLL stellen (erzeugen und setzen)"
plan "Meldung im Dashboard pruefen"
$NEUSTART && plan "Neu starten"

if $PROBELAUF; then
    echo
    log "Probelauf - es wurde nichts geaendert."
    exit 0
fi

if ! $JA; then
    echo
    read -rp "Ausfuehren? [j/N] " antwort
    [[ "$antwort" == [jJyY] ]] || { echo "Abgebrochen."; exit 0; }
fi

ZEIT="$(date '+%Y%m%d-%H%M%S')"
ABLAGE="$STATE_DIR/identitaet-$ZEIT-vorher-$ALT_ID"
mkdir -p "$ABLAGE"
log "Bisherige Dateien werden abgelegt unter $ABLAGE"

# --- 2. Messwerte der Vorlage -----------------------------------------------

if $MESSWERTE_LOESCHEN; then
    step "Messwerte der Vorlage loeschen"
    # Bei laufendem Dienst wuerde er waehrend des Loeschens weiterschreiben -
    # und eine zweite schreibende Verbindung ist genau das, was er nicht
    # erwartet (siehe DOKUMENTATION.md, Datenbank ohne WAL).
    systemctl stop "$APP_UNIT"
    cp -p "$DB" "$ABLAGE/" 2>/dev/null || true
    for t in ees_sensor_values big_sensor_values data_logger_errors; do
        sqlite3 "$DB" "DELETE FROM $t;" 2>/dev/null && log "  $t geleert" || log "  $t: nicht vorhanden"
    done
    systemctl start "$APP_UNIT"
    warte_auf_dienst || die "Dienst kam nach dem Loeschen nicht wieder hoch - journalctl -u $APP_UNIT -n 30
  Die Datenbank vor dem Loeschen liegt unter $ABLAGE."
fi

# --- 3. Konfiguration -------------------------------------------------------

step "Konfiguration"

if [[ -n "$AENDERUNGEN" ]]; then
    printf '%s\n' "$CONFIG" > "$ABLAGE/data_logger.config"

    NEUE_CONFIG="$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["config"]))' <<<"$PATCH")"
    curl -fsS -o /dev/null --max-time 10 -X POST \
        "http://127.0.0.1:$SERVICE_PORT/config/update" \
        -H 'Content-Type: application/json' --data @- <<<"$NEUE_CONFIG" \
        || die "Konfiguration konnte nicht geschrieben werden. Es wurde sonst noch nichts geaendert."

    # Gegenprobe am Dienst, nicht am eigenen Wunsch: Der POST kann mit 200
    # antworten und die Persistenz trotzdem scheitern.
    jetzt="$(curl -fsS --max-time 5 "http://127.0.0.1:$SERVICE_PORT/config/" 2>/dev/null \
        | python3 -c 'import json,sys; c=json.load(sys.stdin) or {}; print(c.get("piDataLoggerId") or ""); print(c.get("hardwareVariant") or "")' \
        2>/dev/null || true)"
    [[ "$(sed -n 1p <<<"$jetzt")" == "$NEU_ID" ]] \
        || die "Nach dem Schreiben meldet der Dienst die Kennung '$(sed -n 1p <<<"$jetzt")', erwartet '$NEU_ID'."
    [[ -z "$SOLL_VARIANTE" || "$(sed -n 2p <<<"$jetzt")" == "$SOLL_VARIANTE" ]] \
        || die "Variante steht nach dem Schreiben auf '$(sed -n 2p <<<"$jetzt")', erwartet '$SOLL_VARIANTE'.
  Ist das Binary aelter als das Feld hardwareVariant? ees-doctor.sh -n zeigt es."
    log "Konfiguration geschrieben und geprueft: $NEU_ID"
else
    log "Steht bereits auf $NEU_ID - unveraendert."
fi

# Die alte Konfigurationsdatei im Arbeitsverzeichnis, falls es sie noch gibt.
# Der Dienst liest sie nicht, aber wer sie einspielt, bekaeme sonst die alte ID.
if [[ -f "$WORKDIR/data_logger.config" ]]; then
    cp -p "$WORKDIR/data_logger.config" "$ABLAGE/data_logger.config.arbeitsverzeichnis"
    log "  data_logger.config im Arbeitsverzeichnis: $(ersetze "$WORKDIR/data_logger.config" "${ID_PAARE[@]}") Ersetzung(en)"
fi

# --- 4. Hostname -------------------------------------------------------------

step "Hostname"

if [[ "$ALT_HOST" != "$NEU_HOST" ]]; then
    cp -p "$ROOT/etc/hostname" "$ROOT/etc/hosts" "$ABLAGE/"
    if [[ -z "$ROOT" ]] && command -v hostnamectl >/dev/null; then
        hostnamectl set-hostname "$NEU_HOST"
    else
        echo "$NEU_HOST" > "$ROOT/etc/hostname"
        [[ -z "$ROOT" ]] && hostname "$NEU_HOST"
    fi
    log "  /etc/hostname: $NEU_HOST"
fi

anzahl="$(ersetze "$ROOT/etc/hosts" "${HOST_PAARE[@]}")"
# Fehlt die Zeile ganz, loest sudo den eigenen Namen nicht auf und meldet das
# bei jedem Aufruf - lieber gleich ergaenzen.
if ! grep -qE "(^|[[:space:]])$NEU_HOST([[:space:]]|$)" "$ROOT/etc/hosts"; then
    echo "127.0.1.1	$NEU_HOST" >> "$ROOT/etc/hosts"
    anzahl=$(( anzahl + 1 ))
fi
log "  /etc/hosts: $anzahl Aenderung(en)"

# --- 5. Crontab und OpenVPN-Autostart ---------------------------------------

step "Crontab und OpenVPN-Autostart"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Beide, weil nicht sicher ist, unter wem die Eintraege angelegt wurden.
for user in "$GERAETE_USER" root; do
    crontab -u "$user" -l > "$tmp" 2>/dev/null || continue
    cp "$tmp" "$ABLAGE/crontab-$user"
    anzahl="$(ersetze "$tmp" "${ID_PAARE[@]}")"
    if (( anzahl > 0 )); then
        crontab -u "$user" "$tmp"
    fi
    log "  crontab $user: $anzahl Ersetzung(en)"
done

if [[ -f "$ROOT/etc/default/openvpn" ]]; then
    cp -p "$ROOT/etc/default/openvpn" "$ABLAGE/default-openvpn"
    log "  /etc/default/openvpn: $(ersetze "$ROOT/etc/default/openvpn" "${ID_PAARE[@]}") Ersetzung(en)"
fi

# --- 6. VPN-Zertifikat -------------------------------------------------------

step "VPN-Zertifikat"

if ! $MIT_VPN; then
    log "Uebersprungen (-V)."
elif $VPN_DA; then
    log "$NEU_ID liegt bereits in /etc/openvpn - nichts zu holen."
else
    vpn_tmp="$(mktemp -d)"
    trap 'rm -f "$tmp"; rm -rf "$vpn_tmp"' EXIT
    url="$VPN_BASE/$NEU_ID.tar.gz"
    log "Lade $url"
    curl -fsSL --retry 3 --max-time 60 -o "$vpn_tmp/vpn.tar.gz" "$url" \
        || die "VPN-Zertifikat nicht ladbar: $url
  Liegt es fuer $NEU_ID schon auf dem Server? Ohne VPN weiter:  -V
  Konfiguration, Hostname und Crontab sind bereits umgestellt; ein erneuter
  Aufruf setzt hier fort."
    tar -xzf "$vpn_tmp/vpn.tar.gz" -C "$vpn_tmp" --no-same-owner \
        || die "VPN-Archiv nicht entpackbar."

    quelle="$vpn_tmp/$NEU_ID"
    # Erst pruefen, dann die alten entfernen: Ein leeres oder fremdes Archiv
    # darf das Geraet nicht ohne VPN-Konfiguration zuruecklassen.
    [[ -f "$quelle/$NEU_ID.conf" || -f "$quelle/$NEU_ID.ovpn" ]] \
        || die "Im Archiv fehlt $NEU_ID/$NEU_ID.conf bzw. .ovpn - die alte VPN-Konfiguration bleibt.
  Inhalt: $(cd "$vpn_tmp" && find . -maxdepth 2 | grep -v vpn.tar.gz | tr '\n' ' ')"

    mkdir -p "$ABLAGE/etc-openvpn"
    shopt -s nullglob
    for alt in "$ROOT"/etc/openvpn/rpi_*; do
        mv "$alt" "$ABLAGE/etc-openvpn/"
    done
    shopt -u nullglob

    cp -r "$quelle/." "$ROOT/etc/openvpn/"
    chown -R root:root "$ROOT/etc/openvpn/" 2>/dev/null || true
    chmod 600 "$ROOT"/etc/openvpn/*.key 2>/dev/null || true

    # Denselben Loglevel wie der Rest der Flotte (2026-08-06-wartung.sh). Das
    # Archiv vom Server kann noch den alten tragen, und das Nachlauf-Skript
    # laeuft auf diesem Klon nicht mehr - seine Marke kam mit der NVMe mit.
    for d in "$ROOT/etc/openvpn/$NEU_ID.conf" "$ROOT/etc/openvpn/$NEU_ID.ovpn"; do
        [[ -f "$d" ]] && sed -i -E 's/^([[:space:]]*)verb[[:space:]]+[0-9]+[[:space:]]*$/\1verb 3/' "$d"
    done
    log "VPN-Konfiguration $NEU_ID eingesetzt; die bisherige liegt unter $ABLAGE/etc-openvpn."
    log "  OpenVPN wird hier nicht neu gestartet - womoeglich laeuft gerade diese Sitzung darueber."
fi

# --- 7. Klon-Kennungen -------------------------------------------------------

step "Klon-Kennungen"

if ! $KLON_ERNEUERN; then
    log "Fuer $NEU_ID bereits erneuert - unveraendert."
else
    # machine-id: Aus ihr leiten DHCP-Client und NetworkManager die Kennung ab,
    # mit der sie eine Adresse anfragen. Gleiche machine-id heisst im selben
    # Netz gleiche IP fuer alle Klone.
    cp -p "$ROOT/etc/machine-id" "$ABLAGE/" 2>/dev/null || true
    rm -f "$ROOT/etc/machine-id"
    if [[ -n "$ROOT" ]]; then
        systemd-machine-id-setup --root="$ROOT" >/dev/null 2>&1 \
            || python3 -c 'import uuid; print(uuid.uuid4().hex)' > "$ROOT/etc/machine-id"
    else
        systemd-machine-id-setup >/dev/null
    fi
    if [[ -f "$ROOT/var/lib/dbus/machine-id" && ! -L "$ROOT/var/lib/dbus/machine-id" ]]; then
        ln -sf /etc/machine-id "$ROOT/var/lib/dbus/machine-id"
    fi
    log "  machine-id erneuert"

    # dhcpcd haelt seine DUID getrennt davon fest; NetworkManager einen
    # Schluessel fuer stabile Adressen. Beide entstehen beim Start neu.
    for f in "$ROOT/var/lib/dhcpcd/duid" "$ROOT/etc/dhcpcd.duid" \
             "$ROOT/var/lib/NetworkManager/secret_key"; do
        [[ -e "$f" ]] && { mv "$f" "$ABLAGE/"; log "  $(basename "$f") entfernt (entsteht neu)"; }
    done

    # SSH-Hostschluessel: Alle Klone mit demselben Schluessel lassen sich nicht
    # auseinanderhalten, und wer einen besitzt, kann sich als jeder ausgeben.
    # Erst beiseitelegen, dann erzeugen, und bei einem Fehlschlag zuruecklegen -
    # ohne Hostschluessel startet sshd nach dem Neustart nicht.
    mkdir -p "$ABLAGE/ssh"
    shopt -s nullglob
    alte_schluessel=("$ROOT"/etc/ssh/ssh_host_*)
    shopt -u nullglob
    if (( ${#alte_schluessel[@]} > 0 )); then
        mv "${alte_schluessel[@]}" "$ABLAGE/ssh/"
        if ssh-keygen -A ${ROOT:+-f "$ROOT"} >/dev/null 2>&1 \
           && [[ -s "$ROOT/etc/ssh/ssh_host_ed25519_key" ]]; then
            log "  SSH-Hostschluessel erneuert - der naechste ssh-Login warnt einmal (known_hosts)"
        else
            cp -p "$ABLAGE"/ssh/ssh_host_* "$ROOT/etc/ssh/"
            echo "  ACHTUNG: SSH-Hostschluessel nicht erzeugbar - die bisherigen bleiben." >&2
        fi
    fi

    # Konfigurationssicherungen der Vorlage tragen deren Kennung. Wer im
    # Ernstfall "die letzte Sicherung" einspielt, gaebe diesem Geraet sonst
    # die Identitaet der Vorlage zurueck.
    for d in "$STATE_DIR/config" "$STATE_DIR/geraetesicherung"; do
        if [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
            mv "$d" "$ABLAGE/"
            log "  $(basename "$d")/ der Vorlage beiseitegelegt"
        fi
    done
    rm -f "$WORKDIR/.update-failed"

    echo "$NEU_ID" > "$MARKE"
fi

# --- 8. Zeichensatz ----------------------------------------------------------

step "Zeichensatz"

if $ZEICHENSATZ_OK; then
    $MIT_ZEICHENSATZ && log "Steht auf ${LANG_IST:-nicht gesetzt} - nichts zu tun." \
                     || log "Uebersprungen (-Z)."
else
    # Warum das hier steht: Ohne UTF-8 zeichnet die app-tui am angesteckten
    # Bildschirm Kaestchen und "â" statt Rahmen - sie malt Unicode-Striche
    # (U+2500 ff.), und ein Terminal ohne UTF-8 liest die drei Bytes einzeln
    # als Latin-1. Ueber SSH faellt es nicht auf: Dort gilt der Zeichensatz
    # des Clients, den der Client mitschickt.
    cp -p "$LOCALE_DATEI" "$ABLAGE/locale" 2>/dev/null || true
    cp -p "$LOCALE_GEN" "$ABLAGE/locale.gen" 2>/dev/null || true

    # C.UTF-8 gibt es immer; jedes andere Gebietsschema muss erst erzeugt
    # werden, und erzeugt wird nur, was in /etc/locale.gen unkommentiert steht.
    if [[ "$LOCALE_SOLL" != "C.UTF-8" && -f "$LOCALE_GEN" ]]; then
        if grep -qE "^[[:space:]]*#[[:space:]]*$LOCALE_SOLL[[:space:]]+UTF-8" "$LOCALE_GEN"; then
            sed -i -E "s/^[[:space:]]*#[[:space:]]*($LOCALE_SOLL[[:space:]]+UTF-8)/\1/" "$LOCALE_GEN"
            log "  $LOCALE_SOLL in $(basename "$LOCALE_GEN") freigeschaltet"
        elif ! grep -qE "^[[:space:]]*$LOCALE_SOLL[[:space:]]+UTF-8" "$LOCALE_GEN"; then
            echo "$LOCALE_SOLL UTF-8" >> "$LOCALE_GEN"
            log "  $LOCALE_SOLL in $(basename "$LOCALE_GEN") ergaenzt"
        fi
        locale-gen >/dev/null 2>&1 || true

        # Gegenprobe: Ein Tippfehler im Gebietsschema faellt sonst erst am
        # Bildschirm auf - und bis dahin steht ein LANG da, das es nicht gibt.
        if ! locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$(tr 'A-Z' 'a-z' <<<"${LOCALE_SOLL/.UTF-8/.utf8}")"; then
            log "  $LOCALE_SOLL liess sich nicht erzeugen - weiche auf C.UTF-8 aus."
            LOCALE_SOLL="C.UTF-8"
        fi
    fi

    # LC_ALL wird geleert, nicht mitgesetzt: Es uebersteuert jede einzelne
    # Kategorie, und genau daran scheitert sonst das neue LANG.
    update-locale LANG="$LOCALE_SOLL" LC_ALL= >/dev/null 2>&1 || true

    # Nicht auf update-locale verlassen - bei alten Fassungen bleibt die
    # LC_ALL-Zeile stehen, und dann war alles umsonst.
    if [[ -f "$LOCALE_DATEI" ]]; then
        sed -i -E '/^[[:space:]]*LC_ALL=/d' "$LOCALE_DATEI"
        grep -qE "^[[:space:]]*LANG=" "$LOCALE_DATEI" \
            || echo "LANG=$LOCALE_SOLL" >> "$LOCALE_DATEI"
        sed -i -E "s|^[[:space:]]*LANG=.*|LANG=$LOCALE_SOLL|" "$LOCALE_DATEI"
    else
        echo "LANG=$LOCALE_SOLL" > "$LOCALE_DATEI"
    fi

    log "Zeichensatz steht auf $LOCALE_SOLL (gilt ab der naechsten Anmeldung)."

    # Eine eigene Zeile in den Profildateien uebersteuert die Systemeinstellung
    # wieder. Nur melden, nicht aendern: Was jemand dort von Hand eingetragen
    # hat, gehoert ihm.
    GERAETE_HOME="$(getent passwd "$GERAETE_USER" | cut -d: -f6 || true)"
    eigene="$(grep -lE '^[[:space:]]*(export[[:space:]]+)?(LC_ALL|LANG)=' \
        ${GERAETE_HOME:+"$GERAETE_HOME/.bashrc" "$GERAETE_HOME/.profile"} \
        "$ROOT/etc/environment" 2>/dev/null || true)"
    if [[ -n "$eigene" ]]; then
        echo "  ACHTUNG: LANG oder LC_ALL steht auch hier und uebersteuert die Systemeinstellung:"
        sed 's/^/    /' <<<"$eigene"
    fi
fi

# --- 9. Meldung im Dashboard -------------------------------------------------

step "Meldung im Dashboard"

# Der Dienst meldet Version und Variante mit seinem Heartbeat - nach dem
# Setzen der Konfiguration sofort, danach alle heartbeatInterval Sekunden.
# Nachgesehen wird ueber den Update-Endpunkt: Er gibt den zuletzt gemeldeten
# Stand zurueck, also genau das, was der Heartbeat hinterlassen hat.
API_BASE="${SOLL_URL%/heartbeat}"
STATE_URL="$API_BASE/update/state"

gemeldet() {
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        -d "{\"operation\":\"\",\"service\":\"\",\"data\":{\"sensor_id\":\"$NEU_ID\"}}" \
        "$STATE_URL" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("current_release") or "")' 2>/dev/null \
        || true
}

meldung_ok=false
if [[ -n "$VERSION" ]]; then
    for (( gewartet = 0; gewartet < MELDUNG_TIMEOUT; gewartet += 3 )); do
        [[ "$(gemeldet)" == "$VERSION" ]] && { meldung_ok=true; break; }
        sleep 3
    done
fi

if $meldung_ok; then
    log "Dashboard fuehrt $NEU_ID mit Softwarestand $VERSION (Variante $SOLL_VARIANTE)."
else
    # Selbst nachfragen, um den Grund zu erfahren: Derselbe Heartbeat, den
    # der Dienst schickt. Nur das Dashboard kann sagen, ob es die Kennung kennt.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c '
import json, sys, time
d = {"sensor_id": sys.argv[1], "timestamp": int(time.time() * 1000)}
if sys.argv[2]: d["app_version"] = sys.argv[2]
if sys.argv[3]: d["hardware_variant"] = sys.argv[3]
print(json.dumps({"operation": "", "service": "", "data": d}))
' "$NEU_ID" "$VERSION" "$SOLL_VARIANTE")" "$SOLL_URL" || true)"
    case "$code" in
        200) echo "  Das Dashboard nimmt die Kennung an; der Dienst selbst hat sich aber nicht"
             echo "  gemeldet. isAppServiceActive und  journalctl -u $APP_UNIT -n 30  pruefen." ;;
        400) echo "  Das Dashboard kennt $NEU_ID nicht (HTTP 400)."
             echo "  Im Dashboard anlegen - danach meldet sich das Geraet innerhalb von"
             echo "  ${INTERVALL}s von selbst, an diesem Geraet ist nichts mehr zu tun." ;;
        *)   echo "  Dashboard nicht erreichbar (HTTP ${code:-keine Antwort}): $SOLL_URL" ;;
    esac
fi

# --- Abschluss ---------------------------------------------------------------

echo
echo "================================================================"
echo " $NEU_HOST ist eingerichtet.  Abgelegt: $ABLAGE"
echo "================================================================"

if $NEUSTART; then
    log "Neustart in 5 Sekunden ..."
    sleep 5
    if [[ -z "$ROOT" ]]; then systemctl reboot; fi
else
    echo " Neustart noetig - erst danach gelten Hostname, machine-id und VPN:"
    echo "   sudo systemctl reboot"
fi
