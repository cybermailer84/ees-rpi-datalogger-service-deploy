#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# ees-update.sh — holt den vom Dashboard vorgegebenen Softwarestand.
#
# Fragt das Dashboard nach der Soll-Version, laedt bei Abweichung das passende
# Release, prueft Signatur und Pruefsummen, tauscht die Binaries und meldet das
# Ergebnis zurueck. Schlaegt etwas fehl, wird der vorherige Stand
# wiederhergestellt.
#
# Enthaelt das Release ein postinstall.sh, laeuft es danach als root - aber erst,
# wenn der neue Stand nachweislich gesund ist. Was es anrichtet, laesst sich
# nicht zuruecknehmen; scheitert es, bleiben die neuen Binaries trotzdem aktiv
# und der Lauf wird als fehlgeschlagen gemeldet.
#
# AUSFUEHRUNG: automatisch durch ees-update.timer (alle 15 Minuten, zufaellig
# verzoegert). Von Hand zum Nachsehen:
#
#   sudo systemctl start ees-update.service     # einmal jetzt laufen lassen
#   journalctl -u ees-update.service -n 50      # Ergebnis ansehen
#   sudo /home/<user>/WORK/datalogger/ees-update.sh --dry-run
#
# Muss als root laufen: der Dienst wird gestoppt und gestartet.
#
# Optionen:
#   --dry-run   Nur pruefen und anzeigen, nichts installieren und nichts melden.
#   --force     Auch dann installieren, wenn Soll- und Ist-Stand gleich sind,
#               und eine vorherige Fehlschlag-Sperre uebergehen.
#
set -euo pipefail

APP_UNIT="ees-app-service.service"
HC_TIMER="ees-healthcheck.timer"
BINARIES=(app-service app-tui)

# Optionales Skript im Release, das nach einem erfolgreichen Update als root
# laeuft. Fuer kleinere Anpassungen, die viele Geraete betreffen und sich nicht
# im Programm selbst erledigen lassen.
POSTINSTALL="postinstall.sh"
POSTINSTALL_TIMEOUT="${EES_POSTINSTALL_TIMEOUT:-300}"

# Sicherung der Geraetekonfiguration vor jedem Update. Unter /var/lib, nicht im
# Arbeitsverzeichnis: Dort liegen die Dateien, die ein Update austauscht.
CONFIG_BACKUP_DIR="${EES_CONFIG_BACKUP_DIR:-/var/lib/ees/config}"
CONFIG_BACKUP_KEEP="${EES_CONFIG_BACKUP_KEEP:-10}"

# Werksvorgabe aus dtos::AppServiceConfigDto::default(). Eine Sicherung, die
# diese Kennung traegt, ist keine - sie wuerde eine brauchbare ueberschreiben.
WERKSVORGABE="rpi_bi_gs27_schule"

UPDATE_ROOT="${EES_UPDATE_ROOT:-https://ees.itc-haas.at/update/BACKUP/services}"
KEY_DIR="${EES_KEY_DIR:-/etc/ees/keys}"
SERVICE_PORT="${EES_SERVICE_PORT:-8000}"
WORKDIR="${EES_WORKDIR:-}"

# Wie lange nach dem Start auf ein gesundes /health gewartet wird, bevor der
# Stand als kaputt gilt. Ein Pi der ersten Generation braucht spuerbar laenger
# als eine Sekunde, ein wirklich defektes Binary kommt auch in einer Minute
# nicht hoch.
HEALTH_TIMEOUT="${EES_HEALTH_TIMEOUT:-60}"

# Wie lange ein fehlgeschlagener Stand nicht erneut versucht wird. Ohne das
# wuerde ein kaputtes Release ueber Nacht von jedem Geraet viertelstuendlich
# neu geladen - bei ueber 100 Geraeten belastet das den Server und macht das
# Log unlesbar. Eine geaenderte Soll-Version hebt die Sperre sofort auf.
RETRY_AFTER="${EES_RETRY_AFTER:-21600}"   # 6 Stunden

DRY_RUN=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FEHLER: $*"; exit 1; }

$DRY_RUN || [[ $EUID -eq 0 ]] || die "Muss als root laufen (stoppt und startet $APP_UNIT)."

for tool in curl openssl sha256sum python3; do
    command -v "$tool" >/dev/null || die "$tool ist nicht installiert."
done

# --- Nur eine Instanz -------------------------------------------------------
#
# Der Timer koennte erneut ausloesen, waehrend noch ein Download laeuft. Zwei
# Laeufe, die gleichzeitig Binaries tauschen, wuerden sich gegenseitig den
# Boden wegziehen.
LOCK_FILE=/run/ees-update.lock
[[ -w /run ]] || LOCK_FILE="${TMPDIR:-/tmp}/ees-update.lock"   # Probelauf ohne root
exec 9>"$LOCK_FILE"
flock -n 9 || { log "Ein Update-Lauf laeuft bereits - beendet."; exit 0; }

# --- Arbeitsverzeichnis -----------------------------------------------------

if [[ -z "$WORKDIR" ]]; then
    # Unter systemd ist HOME=/root, deshalb setzt die Unit EES_WORKDIR. Der
    # Fallback greift nur beim Aufruf von Hand.
    fallback_user="${SUDO_USER:-$(id -un)}"
    fallback_home="$(getent passwd "$fallback_user" | cut -d: -f6)"
    [[ -n "$fallback_home" ]] || die "EES_WORKDIR ist nicht gesetzt und das Home von
  '$fallback_user' ist nicht ermittelbar. Aufruf mit EES_WORKDIR=... wiederholen."
    WORKDIR="$fallback_home/WORK/datalogger"
fi
[[ -d "$WORKDIR" ]] || die "Arbeitsverzeichnis nicht gefunden: $WORKDIR
  Erwartet in EES_WORKDIR (setzt die systemd-Unit)."

# --- Konfiguration lesen ----------------------------------------------------
#
# Zuerst ueber den laufenden Dienst - das ist der Stand, den er tatsaechlich
# fuehrt. Faellt er aus, direkt aus seiner Datenbank: gerade dann willst du ein
# Update ausspielen koennen, und ein toter Dienst darf das nicht verhindern.
# Die vollstaendige Konfiguration, wie die app-tui sie als data_logger.config
# exportiert. Bewusst hier oben und nicht in einer Funktion geholt: In einer
# Kommandoersetzung - CONFIG="$(...)" - liefe die Zuweisung in einer Subshell
# und waere danach wieder leer.
RAW_CONFIG="$(curl -fsS --max-time 10 "http://127.0.0.1:$SERVICE_PORT/config" 2>/dev/null || true)"

parse_config() {   # wertet RAW_CONFIG aus
    [[ -n "$RAW_CONFIG" ]] || return 1
    python3 -c '
import json, sys
c = json.load(sys.stdin)
if not c:
    sys.exit(1)
print(c.get("piDataLoggerId") or "")
print(c.get("hardwareVariant") or "")
print(c.get("heartbeatUrl") or "")
' <<<"$RAW_CONFIG" 2>/dev/null || return 1
}

read_config_sqlite() {
    command -v sqlite3 >/dev/null || return 1
    local db="$WORKDIR/app-service-database.sqlite"
    [[ -r "$db" ]] || return 1
    # Nur lesen: eine schreibende Verbindung koennte dem laufenden Dienst in
    # die Quere kommen.
    sqlite3 -readonly -separator $'\n' "$db" \
        "SELECT pi_data_logger_id, COALESCE(hardware_variant,''), heartbeat_url
         FROM config ORDER BY id LIMIT 1;" 2>/dev/null
}

CONFIG="$(parse_config || true)"
CONFIG_SOURCE="Dienst"
if [[ -z "$CONFIG" ]]; then
    RAW_CONFIG=""      # unbrauchbar - keine Sicherung daraus schreiben
    log "Dienst nicht erreichbar - lese die Konfiguration aus der Datenbank."
    CONFIG="$(read_config_sqlite || true)"
    CONFIG_SOURCE="Datenbank"
fi
if [[ -z "$CONFIG" ]]; then
    # Fehlt beides, hat der Dienst hier vermutlich noch nie gelaufen - die
    # Datenbank legt er beim ersten Start selbst an. Das ist die eigentliche
    # Ursache, und ohne diesen Hinweis sucht man an der falschen Stelle.
    hinweis=""
    if [[ ! -e "$WORKDIR/app-service-database.sqlite" ]]; then
        hinweis="
  Die Datenbank existiert gar nicht. Der app-service legt sie beim ersten
  erfolgreichen Start an - er ist hier also vermutlich noch nie gelaufen.
  Nachsehen mit:  systemctl status $APP_UNIT ; journalctl -u $APP_UNIT -n 30
  Haeufigste Ursache ist eine fehlende Bibliothek:  ldd $WORKDIR/app-service | grep 'not found'"
    fi
    die "Konfiguration nicht lesbar - weder ueber
  http://127.0.0.1:$SERVICE_PORT/config noch aus $WORKDIR/app-service-database.sqlite.$hinweis"
fi

SENSOR_ID="$(sed -n 1p <<<"$CONFIG")"
HARDWARE_VARIANT="$(sed -n 2p <<<"$CONFIG")"
HEARTBEAT_URL="$(sed -n 3p <<<"$CONFIG")"

[[ -n "$SENSOR_ID" ]] || die "Keine pi_data_logger_id in der Konfiguration."
[[ -n "$HARDWARE_VARIANT" ]] || die "Keine Hardware-Variante in der Konfiguration.
  Ohne sie ist nicht bestimmbar, welche Binaries fuer dieses Geraet gelten.
  Setzen ueber den Konfigurations-Endpunkt (die app-tui zeigt sie nur an):
    sudo $WORKDIR/ees-onboard.sh -w v1.9"
[[ -n "$HEARTBEAT_URL" ]] || die "Keine heartbeat_url in der Konfiguration."

# Die Update-Endpunkte liegen neben dem Heartbeat. Sie daraus abzuleiten statt
# sie erneut zu konfigurieren heisst: ein Geraet, das seinen Heartbeat los
# wird, erreicht auch den Update-Kanal.
API_BASE="${HEARTBEAT_URL%/heartbeat}"
[[ "$API_BASE" != "$HEARTBEAT_URL" ]] \
    || die "heartbeat_url endet nicht auf /heartbeat: $HEARTBEAT_URL"
STATE_URL="$API_BASE/update/state"
REPORT_URL="$API_BASE/update/report"

# --- Ist-Stand aus dem Binary lesen -----------------------------------------
#
# Nicht aus der Konfiguration: eine dort gespeicherte Version kann veralten und
# wuerde dann etwas anderes behaupten als das, was laeuft.
read_version() {
    grep -ao '20[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]+[0-9a-f]\{7\}\(-dirty\)\?' \
        "$1" 2>/dev/null | head -1 || true
}

CURRENT_VERSION="$(read_version "$WORKDIR/app-service")"
[[ -n "$CURRENT_VERSION" ]] || CURRENT_VERSION="unbekannt"

log "Geraet:     $SENSOR_ID ($HARDWARE_VARIANT), Konfiguration aus: $CONFIG_SOURCE"
log "Ist-Stand:  $CURRENT_VERSION"

# --- Soll-Stand erfragen ----------------------------------------------------

request_state() {
    curl -fsS --max-time 20 --retry 2 -H 'Content-Type: application/json' \
        -d "$(python3 -c '
import json, sys
print(json.dumps({"operation":"","service":"","data":{"sensor_id":sys.argv[1]}}))
' "$SENSOR_ID")" "$STATE_URL"
}

STATE_BODY="$(request_state)" || die "Dashboard nicht erreichbar: $STATE_URL"

TARGET_VERSION="$(python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("target_release") or "")
except Exception:
    sys.exit(1)
' <<<"$STATE_BODY")" || die "Unerwartete Antwort vom Dashboard: $STATE_BODY"

if [[ -z "$TARGET_VERSION" ]]; then
    log "Keine Soll-Version gesetzt - nichts zu tun."
    exit 0
fi

log "Soll-Stand: $TARGET_VERSION"

if [[ "$TARGET_VERSION" == "$CURRENT_VERSION" ]] && ! $FORCE; then
    log "Stand ist aktuell - nichts zu tun."
    exit 0
fi

# --- Sperre nach Fehlschlag -------------------------------------------------

FAIL_MARKER="$WORKDIR/.update-failed"
if [[ -r "$FAIL_MARKER" ]] && ! $FORCE; then
    failed_version="$(sed -n 1p "$FAIL_MARKER")"
    failed_at="$(sed -n 2p "$FAIL_MARKER")"
    if [[ "$failed_version" == "$TARGET_VERSION" ]] \
       && (( $(date +%s) - ${failed_at:-0} < RETRY_AFTER )); then
        log "Stand $TARGET_VERSION ist hier schon gescheitert; naechster Versuch"
        log "  fruehestens $(date -d "@$(( failed_at + RETRY_AFTER ))" '+%Y-%m-%d %H:%M') (--force uebergeht das)."
        exit 0
    fi
fi

# --- Konfiguration sichern --------------------------------------------------
#
# Vor jedem Update-Versuch, und zwar bevor irgendetwas geladen oder angefasst
# wird. Inhaltlich dasselbe, was die app-tui als data_logger.config exportiert -
# damit laesst sich ein Geraet notfalls von Hand wieder herrichten.
#
# Nicht bei jedem Lauf: Der Timer schaut alle 15 Minuten nach, das gaebe 96
# gleiche Dateien am Tag. Nur wenn wirklich aktualisiert wird.
sichere_konfiguration() {
    if [[ -z "$RAW_CONFIG" ]]; then
        # Kam die Konfiguration aus der Datenbank, liegen nur die drei Felder
        # vor, die der Updater braucht - kein vollstaendiger Export. Dann lieber
        # nichts schreiben, als eine aeltere vollstaendige Sicherung durch eine
        # unvollstaendige zu ersetzen.
        log "WARNUNG: Kein vollstaendiger Konfigurationsexport moeglich (Quelle: $CONFIG_SOURCE)."
        log "  Vorhandene Sicherungen unter $CONFIG_BACKUP_DIR bleiben unveraendert."
        return 0
    fi

    if [[ "$SENSOR_ID" == "$WERKSVORGABE" ]]; then
        log "WARNUNG: Der Dienst meldet die Werksvorgabe als Geraetekennung."
        log "  Das ist keine gueltige Konfiguration - es wird nichts gesichert,"
        log "  damit eine brauchbare Sicherung erhalten bleibt."
        return 0
    fi

    mkdir -p "$CONFIG_BACKUP_DIR" || { log "WARNUNG: $CONFIG_BACKUP_DIR nicht anlegbar."; return 0; }

    local zeit ziel
    zeit="$(date '+%Y%m%d-%H%M%S')"
    ziel="$CONFIG_BACKUP_DIR/data_logger-$zeit.config"

    # Erst pruefen und formatieren, dann schreiben. Eine halb geschriebene oder
    # ungueltige Sicherung waere schlimmer als keine - man verlaesst sich im
    # Ernstfall darauf.
    if ! python3 -c '
import json, sys
cfg = json.load(sys.stdin)
if not cfg:
    sys.exit(1)
sys.stdout.write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
' <<<"$RAW_CONFIG" > "$ziel.neu" 2>/dev/null; then
        rm -f "$ziel.neu"
        log "WARNUNG: Konfiguration nicht auswertbar - keine Sicherung geschrieben."
        return 0
    fi

    chmod 600 "$ziel.neu"
    mv -f "$ziel.neu" "$ziel"
    # Stabiler Name fuer den Ernstfall: den sucht niemand unter Zeitstempeln.
    cp -p "$ziel" "$CONFIG_BACKUP_DIR/data_logger.config"

    log "Konfiguration gesichert: $ziel ($(stat -c %s "$ziel") Bytes)"

    # Alte Staende begrenzen - eine SD-Karte ist klein.
    local ueberzaehlig
    ueberzaehlig="$(ls -1t "$CONFIG_BACKUP_DIR"/data_logger-*.config 2>/dev/null | tail -n +$(( CONFIG_BACKUP_KEEP + 1 )))"
    if [[ -n "$ueberzaehlig" ]]; then
        xargs -r rm -f <<<"$ueberzaehlig"
        log "  aeltere Staende entfernt, $CONFIG_BACKUP_KEEP behalten."
    fi
}

$DRY_RUN || sichere_konfiguration

# --- Herunterladen ----------------------------------------------------------

RELEASE_URL="$UPDATE_ROOT/hardware_$HARDWARE_VARIANT/$TARGET_VERSION"
log "Quelle:     $RELEASE_URL"

# Bewusst im Arbeitsverzeichnis und nicht in /tmp: gleiche Partition, damit der
# Tausch ein Verschieben ist und nicht ein Kopieren, das auf halber Strecke am
# vollen Dateisystem scheitern kann.
TMP_DIR="$WORKDIR/.update-tmp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

report() {
    $DRY_RUN && return 0
    local status="$1" message="${2:-}"
    curl -fsS --max-time 20 --retry 2 -o /dev/null -H 'Content-Type: application/json' \
        -d "$(python3 -c '
import json, sys
sensor, status = sys.argv[1], sys.argv[2]
msg = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
body = {"sensor_id": sensor, "status": status}
if msg:
    body["message"] = msg
print(json.dumps({"operation":"","service":"","data":body}))
' "$SENSOR_ID" "$status" "$message")" "$REPORT_URL" \
        || log "WARNUNG: Rueckmeldung '$status' konnte nicht zugestellt werden."
}

# Ab hier ist der Lauf sichtbar: bricht das Geraet mittendrin weg, steht im
# Dashboard "running" und nicht faelschlich "erfolgreich".
$DRY_RUN || report running "Update $CURRENT_VERSION -> $TARGET_VERSION gestartet"

fail() {
    local reason="$1"
    log "FEHLER: $reason"
    if ! $DRY_RUN; then
        printf '%s\n%s\n' "$TARGET_VERSION" "$(date +%s)" > "$FAIL_MARKER"
        report failed "$reason"
    fi
    rm -rf "$TMP_DIR"
    exit 1
}

# Zuerst nur Manifest und Signatur. Welche Dateien zu einem Release gehoeren,
# bestimmt das signierte Manifest - nicht eine hier fest verdrahtete Liste. So
# kostet eine zusaetzliche Datei im Release keine Aenderung auf den Geraeten.
for f in manifest.txt manifest.sig; do
    curl -fsSL --max-time 60 --retry 3 -o "$TMP_DIR/$f" "$RELEASE_URL/$f" \
        || fail "Download von $f fehlgeschlagen ($RELEASE_URL/$f)."
done

# --- Signatur pruefen -------------------------------------------------------
#
# Vor den Pruefsummen: ein Angreifer, der die Dateien austauscht, kann das
# Manifest gleich mit anpassen. Erst die Signatur macht das Manifest
# vertrauenswuerdig, danach schuetzen dessen Pruefsummen die Binaries.
#
# Gegen jeden hinterlegten Schluessel, nicht nur gegen einen: waehrend eines
# Schluesselwechsels liegen zwei im Verzeichnis, und Releases beider
# Generationen muessen durchgehen.
shopt -s nullglob
KEYS=("$KEY_DIR"/*.pub)
shopt -u nullglob
(( ${#KEYS[@]} > 0 )) || fail "Keine oeffentlichen Schluessel unter $KEY_DIR - Release nicht pruefbar."

signature_ok=false
for key in "${KEYS[@]}"; do
    if openssl pkeyutl -verify -pubin -inkey "$key" \
        -rawin -in "$TMP_DIR/manifest.txt" -sigfile "$TMP_DIR/manifest.sig" >/dev/null 2>&1; then
        log "Signatur gueltig (Schluessel: $(basename "$key"))."
        signature_ok=true
        break
    fi
done
$signature_ok || fail "Signatur ungueltig - zu keinem Schluessel unter $KEY_DIR passend. Release verworfen."

# --- Dateiliste aus dem nun vertrauenswuerdigen Manifest ------------------
mapfile -t RELEASE_FILES < <(sed -E 's/^[0-9a-fA-F]+[[:space:]]+\*?//' "$TMP_DIR/manifest.txt")
(( ${#RELEASE_FILES[@]} > 0 )) || fail "Manifest nennt keine Dateien."

for f in "${RELEASE_FILES[@]}"; do
    # Nur einfache Dateinamen zulassen. Ohne das waere ein Eintrag wie
    # ../../etc/cron.d/x ein Schreibzugriff an beliebiger Stelle im
    # Dateisystem. Das Manifest ist zwar signiert - aber ein Vertipper beim
    # Schnueren genuegt fuer den Schaden, und der laege dann auf 100 Geraeten.
    [[ "$f" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || fail "Unzulaessiger Dateiname im Manifest: '$f'. Release verworfen."
done

# Ein Release ohne die Binaries waere unvollstaendig - lieber hier abbrechen
# als nach dem Stoppen des Dienstes.
for b in "${BINARIES[@]}"; do
    printf '%s\n' "${RELEASE_FILES[@]}" | grep -qxF "$b" \
        || fail "Manifest fuehrt $b nicht auf - unvollstaendiges Release."
done

for f in "${RELEASE_FILES[@]}"; do
    curl -fsSL --max-time 300 --retry 3 -o "$TMP_DIR/$f" "$RELEASE_URL/$f" \
        || fail "Download von $f fehlgeschlagen ($RELEASE_URL/$f)."
done

( cd "$TMP_DIR" && sha256sum -c manifest.txt --quiet ) \
    || fail "Pruefsummen stimmen nicht mit dem Manifest ueberein. Release verworfen."

# Das Binary muss den Stand tragen, der draufsteht. Faengt ein Verzeichnis auf
# dem Update-Server ab, das falsch benannt wurde - signiert und unverfaelscht
# waere es trotzdem, nur eben der falsche Stand.
DOWNLOADED_VERSION="$(read_version "$TMP_DIR/app-service")"
[[ "$DOWNLOADED_VERSION" == "$TARGET_VERSION" ]] \
    || fail "Geladenes Binary meldet '$DOWNLOADED_VERSION', erwartet war '$TARGET_VERSION'. Release verworfen."


# --- Laeuft dieses Binary auf diesem Geraet ueberhaupt? ---------------------
#
# Ein auf neuerem Betriebssystem gebautes Binary verlangt eine neuere glibc.
# Die laesst sich nicht nachinstallieren, und die Vertraeglichkeit geht nur in
# eine Richtung: alt gebaut laeuft auf neu, nie umgekehrt. Ohne diese Pruefung
# wird ein laufender Dienst durch einen ersetzt, der nicht startet.
#
# Bewusst nur mit grep und sort statt readelf: binutils ist auf einem Geraet
# nicht vorausgesetzt. Die benoetigten Fassungen stehen als Zeichenketten im
# Binary, das Ergebnis stimmt mit readelf ueberein.
benoetigte_glibc() {
    grep -ao 'GLIBC_[0-9]\+\.[0-9]\+' "$1" 2>/dev/null \
        | sed 's/GLIBC_//' | sort -uV | tail -1
}

glibc_reicht() { # $1 Binary; setzt GLIBC_NOETIG und GLIBC_LOKAL
    GLIBC_NOETIG="$(benoetigte_glibc "$1")"
    GLIBC_LOKAL="$(ldd --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+$')"

    # Statisch gebunden oder nicht ermittelbar - dann nicht im Weg stehen.
    [[ -n "$GLIBC_NOETIG" && -n "$GLIBC_LOKAL" ]] || return 0

    [[ "$(printf '%s\n%s\n' "$GLIBC_NOETIG" "$GLIBC_LOKAL" | sort -V | tail -1)" == "$GLIBC_LOKAL" ]]
}

for b in "${BINARIES[@]}"; do
    glibc_reicht "$TMP_DIR/$b" || fail "$b braucht glibc $GLIBC_NOETIG, dieses Geraet hat $GLIBC_LOKAL.
  Das Binary wurde auf einem neueren Betriebssystem gebaut. glibc laesst sich
  nicht nachinstallieren - das Release muss auf einem Geraet gebaut werden, das
  hoechstens so neu ist wie dieses hier.
  Der Dienst wurde nicht angetastet und laeuft unveraendert weiter."
done

log "Signatur, Pruefsummen und Version geprueft."
log "Vertraeglichkeit geprueft: braucht glibc $GLIBC_NOETIG, vorhanden $GLIBC_LOKAL."

if $DRY_RUN; then
    [[ -f "$TMP_DIR/$POSTINSTALL" ]] \
        && log "Das Release enthaelt $POSTINSTALL - es wuerde nach dem Tausch als root laufen."
    log "Probelauf - es wurde nichts installiert."
    rm -rf "$TMP_DIR"
    exit 0
fi

# --- Tauschen ---------------------------------------------------------------
#
# Der Health-Check startet den Dienst neu, sobald /health nicht antwortet. Genau
# das wuerde er waehrend des Tauschs tun und dabei ein halb ersetztes Binary
# starten. Also Timer anhalten - und in jedem Ausgang wieder anschalten, sonst
# bleibt das Geraet ohne seine Selbstheilung zurueck.
HC_WAS_ACTIVE=false
systemctl is-active --quiet "$HC_TIMER" && HC_WAS_ACTIVE=true
restore_healthcheck() {
    $HC_WAS_ACTIVE && systemctl start "$HC_TIMER" >/dev/null 2>&1 || true
}
trap restore_healthcheck EXIT

$HC_WAS_ACTIVE && { log "Halte $HC_TIMER an."; systemctl stop "$HC_TIMER"; }

BACKUP_DIR="$WORKDIR/.update-backup"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for f in "${BINARIES[@]}"; do
    [[ -f "$WORKDIR/$f" ]] && cp -p "$WORKDIR/$f" "$BACKUP_DIR/$f"
done

OWNER="$(stat -c '%U:%G' "$WORKDIR")"

log "Stoppe $APP_UNIT."
systemctl stop "$APP_UNIT" || true

swap_in() {
    local from="$1"
    for f in "${BINARIES[@]}"; do
        [[ -f "$from/$f" ]] || continue
        mv -f "$from/$f" "$WORKDIR/$f"
        chmod 755 "$WORKDIR/$f"
        chown "$OWNER" "$WORKDIR/$f"
    done
}

swap_in "$TMP_DIR"
log "Binaries getauscht."

log "Starte $APP_UNIT."
systemctl start "$APP_UNIT" || true

# --- Nachsehen, ob er wirklich hochkommt ------------------------------------

healthy=false
for (( waited = 0; waited < HEALTH_TIMEOUT; waited += 3 )); do
    sleep 3
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:$SERVICE_PORT/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then healthy=true; break; fi
done

if ! $healthy; then
    log "Neuer Stand antwortet nicht auf /health - nehme den alten zurueck."
    systemctl stop "$APP_UNIT" || true
    swap_in "$BACKUP_DIR"
    systemctl start "$APP_UNIT" || true
    fail "Stand $TARGET_VERSION kam nicht hoch (kein /health innerhalb ${HEALTH_TIMEOUT}s). Auf $CURRENT_VERSION zurueckgesetzt."
fi

# Der Dienst laeuft - traegt er auch den erwarteten Stand?
INSTALLED_VERSION="$(read_version "$WORKDIR/app-service")"

# --- Nachlauf-Skript -------------------------------------------------------
#
# Erst hier, weil der neue Stand nachweislich gesund sein soll, bevor etwas am
# System geaendert wird. Es laeuft als root und liegt noch im temporaeren
# Verzeichnis - es wird nicht dauerhaft abgelegt, damit kein alter Stand
# spaeter versehentlich erneut laeuft.
if [[ -f "$TMP_DIR/$POSTINSTALL" ]]; then
    log "Fuehre $POSTINSTALL aus (Abbruch nach ${POSTINSTALL_TIMEOUT}s) ..."

    set +e
    script_output="$(cd "$WORKDIR" && \
        EES_WORKDIR="$WORKDIR" \
        EES_SENSOR_ID="$SENSOR_ID" \
        EES_HARDWARE_VARIANT="$HARDWARE_VARIANT" \
        EES_VERSION="$INSTALLED_VERSION" \
        EES_PREVIOUS_VERSION="$CURRENT_VERSION" \
        EES_RELEASE_DIR="$TMP_DIR" \
        timeout "$POSTINSTALL_TIMEOUT" bash "$TMP_DIR/$POSTINSTALL" 2>&1)"
    script_rc=$?
    set -e

    # Vollstaendig ins Journal - dort ist Platz, in der Rueckmeldung an das
    # Dashboard nicht.
    [[ -n "$script_output" ]] && sed 's/^/    /' <<<"$script_output"

    if (( script_rc != 0 )); then
        if (( script_rc == 124 )); then
            reason="$POSTINSTALL nach ${POSTINSTALL_TIMEOUT}s abgebrochen"
        else
            reason="$POSTINSTALL fehlgeschlagen (Exit-Code $script_rc)"
        fi

        # Die Binaries bleiben. Sie sind gesund hochgekommen, und ein Fehler im
        # Skript soll ein gutes Update nicht kippen - rueckgaengig machen liesse
        # sich die Wirkung des Skripts ohnehin nicht.
        log "FEHLER: $reason"
        log "  Programmstand $INSTALLED_VERSION laeuft und bleibt aktiv."
        rm -rf "$TMP_DIR" "$BACKUP_DIR"
        rm -f "$FAIL_MARKER"
        report failed "$reason. Das Update auf $INSTALLED_VERSION selbst lief durch, das Programm laeuft. Ausgabe: $(tail -c 2000 <<<"$script_output")"
        exit 1
    fi

    log "$POSTINSTALL erfolgreich."
fi

rm -rf "$TMP_DIR" "$BACKUP_DIR" "$FAIL_MARKER"

log "Update erfolgreich: $CURRENT_VERSION -> $INSTALLED_VERSION"
report success "Update $CURRENT_VERSION -> $INSTALLED_VERSION erfolgreich"
