#!/usr/bin/env bash
#
#* @author     Christopher HAAS,MSc <christopher@itc-haas.at>
#* @copyright  2026 ITC-HAAS.at
#* @license    copyright by Christopher Haas,MSc
#* @version    1.0
#
# ees-doctor.sh — nimmt den Zustand eines Datenloggers auf und bringt ihn in
# Ordnung.
#
# Prueft der Reihe nach Binaries, Dienst, Konfiguration, Deploy-Skripte,
# Release-Schluessel, systemd-Units und die FTP-Zugangsdaten, leitet daraus die
# noetigen Schritte ab und fuehrt sie aus. Was bereits stimmt, bleibt
# unangetastet - ein zweiter Lauf meldet nur noch "in Ordnung".
#
# AUSFUEHRUNG: auf dem Datenlogger, als root.
#
#   sudo ./ees-doctor.sh -n                    # nur der Befund, aendert nichts
#   sudo ./ees-doctor.sh -w v1.9 -e zugang.env # Befund + Behebung
#
# WARUM NICHT ees-onboard.sh: Jenes richtet ein fabrikneues Geraet ein und holt
# dabei Binaries aus dem UNVERSIONIERTEN Verzeichnis. Auf einem Geraet im
# Betrieb ersetzt das einen neueren Stand durch einen aelteren. Dieses Script
# fasst Binaries grundsaetzlich nicht an - das macht allein der Updater.
#
# ZUGANGSDATEN: Dieses Script enthaelt KEIN Passwort und darf keines enthalten -
# es wird ueber das oeffentliche Deploy-Repo verteilt. Die FTP-Zugangsdaten
# kommen ueber -e aus einer Datei (Vorlage: backup.env.example) oder werden
# erfragt. Angelegt wird daraus /etc/ees/backup.env, Mode 600, root-eigen.
#
# Aufruf:  ees-doctor.sh [-w <variante>] [-e <datei>] [-p <port>] [-y] [-n]
#
#   -w  Hardware-Variante v1.8 oder v1.9. Nur noetig, wenn sie noch fehlt.
#   -e  Datei mit FTP_HOST, FTP_USER, FTP_PASS fuer /etc/ees/backup.env.
#       Ohne sie wird gefragt, sofern ein Terminal da ist.
#   -p  Port des app-service   (Vorgabe: 8000)
#   -y  Massnahmen ohne Rueckfrage ausfuehren.
#   -n  Nur pruefen und den Plan zeigen, nichts aendern.
#
set -euo pipefail

VARIANTE=""
ENV_QUELLE=""
SERVICE_PORT="${SERVICE_PORT:-8000}"
JA=false
NUR_PRUEFEN=false
WORKDIR="${EES_WORKDIR:-}"

BACKUP_ENV="${EES_BACKUP_ENV:-/etc/ees/backup.env}"
KEY_DIR="${EES_KEY_DIR:-/etc/ees/keys}"
DEPLOY_RAW="https://raw.githubusercontent.com/cybermailer84/ees-rpi-datalogger-service-deploy/main"

# Die Werksvorgabe aus dtos::AppServiceConfigDto::default(). Steht sie als
# Geraetekennung da, ist die Konfiguration verloren gegangen.
WERKSVORGABE="rpi_bi_gs27_schule"

APP_UNIT="ees-app-service.service"
HC_TIMER="ees-healthcheck.timer"
UPD_TIMER="ees-update.timer"
UPD_UNIT="ees-update.service"

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":w:e:p:ynh" opt; do
    case "$opt" in
        w) VARIANTE="$OPTARG" ;;
        e) ENV_QUELLE="$OPTARG" ;;
        p) SERVICE_PORT="$OPTARG" ;;
        y) JA=true ;;
        n) NUR_PRUEFEN=true ;;
        h) usage 0 ;;
        \?) echo "Unbekannte Option: -$OPTARG" >&2; usage 2 ;;
        :)  echo "Option -$OPTARG benoetigt einen Wert" >&2; usage 2 ;;
    esac
done

die() { echo "FEHLER: $*" >&2; exit 1; }

case "$VARIANTE" in
    v1.8|v1.9|"") ;;
    *) die "Unbekannte Hardware-Variante: '$VARIANTE' (erlaubt: v1.8, v1.9)." ;;
esac

$NUR_PRUEFEN || [[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren:  sudo $0 $*
  Nur der Befund geht auch ohne:  $0 -n"

for tool in curl python3 systemctl; do
    command -v "$tool" >/dev/null || die "$tool ist nicht installiert."
done

# --- Zugangsdaten aus -e sofort pruefen -------------------------------------
#
# Nicht erst kurz vor dem Schreiben: Sonst faellt eine unbrauchbare Datei erst
# auf, nachdem Skripte und Units schon angefasst wurden. So prueft auch der
# Probelauf (-n) die Zugangsdaten mit.
FTP_HOST_V=""; FTP_USER_V=""; FTP_PASS_V=""; FTP_BASE_V=""; FTP_FTPS_V=1

if [[ -n "$ENV_QUELLE" ]]; then
    [[ -r "$ENV_QUELLE" ]] || die "Nicht lesbar: $ENV_QUELLE"

    # In einer Subshell einlesen und nur die Werte zurueckgeben - so landen
    # keine weiteren Variablen aus der Datei im Hauptprozess.
    werte="$(
        set +u
        # shellcheck disable=SC1090
        . "$ENV_QUELLE" 2>/dev/null || exit 1
        printf '%s\n%s\n%s\n%s\n%s\n' "$FTP_HOST" "$FTP_USER" "$FTP_PASS" \
                                      "${FTP_BASE_DIR:-}" "${USE_FTPS:-1}"
    )" || die "$ENV_QUELLE ist nicht als Shell-Datei lesbar."

    FTP_HOST_V="$(sed -n 1p <<<"$werte")"
    FTP_USER_V="$(sed -n 2p <<<"$werte")"
    FTP_PASS_V="$(sed -n 3p <<<"$werte")"
    FTP_BASE_V="$(sed -n 4p <<<"$werte")"
    FTP_FTPS_V="$(sed -n 5p <<<"$werte")"

    [[ -n "$FTP_HOST_V" && -n "$FTP_USER_V" && -n "$FTP_PASS_V" ]] \
        || die "$ENV_QUELLE unvollstaendig - FTP_HOST, FTP_USER und FTP_PASS muessen gesetzt sein."
    [[ "$FTP_USER_V" != HIER_* && "$FTP_PASS_V" != HIER_* ]] \
        || die "$ENV_QUELLE enthaelt noch die Platzhalter der Vorlage."
fi

# --- Arbeitsverzeichnis -----------------------------------------------------

if [[ -z "$WORKDIR" ]]; then
    ziel_user="${SUDO_USER:-$(id -un)}"
    ziel_home="$(getent passwd "$ziel_user" | cut -d: -f6 || true)"
    [[ -n "$ziel_home" ]] || die "Home von '$ziel_user' nicht ermittelbar.
  Aufruf mit EES_WORKDIR=... wiederholen."
    WORKDIR="$ziel_home/WORK/datalogger"
fi
[[ -d "$WORKDIR" ]] || die "Arbeitsverzeichnis nicht gefunden: $WORKDIR"

GERAETE_USER="$(stat -c '%U' "$WORKDIR")"

# --- Befund sammeln ---------------------------------------------------------

MASSNAHMEN=()
fehlt=0
warnungen=0

ok()    { printf '  ok     %-30s %s\n' "$1" "${2:-}"; }
mangel(){ printf '  FEHLT  %-30s %s\n' "$1" "${2:-}"; fehlt=$(( fehlt + 1 )); }
warnung(){ printf '  hm     %-30s %s\n' "$1" "${2:-}"; warnungen=$(( warnungen + 1 )); }
# Doppelt eingeplant wird schnell: die Units fehlen sowohl, wenn keine Unit da
# ist, als auch, wenn der Schluessel fehlt - beides behebt install-services.sh.
plane() {
    local s
    for s in ${MASSNAHMEN[@]+"${MASSNAHMEN[@]}"}; do [[ "$s" == "$1" ]] && return 0; done
    MASSNAHMEN+=("$1")
}

# Feste Reihenfolge der Ausfuehrung, unabhaengig davon, in welcher Reihenfolge
# die Maengel auffallen: ohne die Skripte gibt es kein ees-set-variant.sh, und
# ohne die Units keinen Updater.
REIHENFOLGE=(skripte units variante env envrechte)

echo "================================================================"
echo " Befund   $(hostname -s)   $(date '+%d.%m.%Y %H:%M')"
echo "================================================================"
echo
echo "Arbeitsverzeichnis: $WORKDIR  (Benutzer $GERAETE_USER)"
echo

# 1. Binaries -----------------------------------------------------------------

lies_version() {
    [[ -r "$1" ]] || return 1
    grep -ao '20[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]+[0-9a-f]\{7\}\(-dirty\)\?' "$1" | head -1
}

echo "-- Binaries --"
VERSION=""
if [[ -x "$WORKDIR/app-service" ]]; then
    VERSION="$(lies_version "$WORKDIR/app-service" || true)"
    ok "app-service" "${VERSION:-Version nicht lesbar}"
else
    mangel "app-service" "fehlt unter $WORKDIR"
fi
[[ -x "$WORKDIR/app-tui" ]] && ok "app-tui" "$(lies_version "$WORKDIR/app-tui" || echo '-')" \
                            || warnung "app-tui" "fehlt (nur die Bedienung, nicht der Dienst)"

# 2. Dienst und Konfiguration -------------------------------------------------

echo
echo "-- Dienst --"
GESUND=false
if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:$SERVICE_PORT/health" || true)" == "200" ]]; then
    GESUND=true
    ok "/health" "antwortet auf Port $SERVICE_PORT"
else
    mangel "/health" "keine Antwort auf Port $SERVICE_PORT"
fi

KENNUNG=""; IST_VARIANTE=""; HEARTBEAT=""
if $GESUND; then
    CONFIG="$(curl -fsS --max-time 10 "http://127.0.0.1:$SERVICE_PORT/config/" || true)"
    if [[ -n "$CONFIG" ]]; then
        felder="$(python3 -c '
import json, sys
c = json.load(sys.stdin) or {}
print(c.get("piDataLoggerId") or "")
print(c.get("hardwareVariant") or "")
print(c.get("heartbeatUrl") or "")
' <<<"$CONFIG" 2>/dev/null || true)"
        KENNUNG="$(sed -n 1p <<<"$felder")"
        IST_VARIANTE="$(sed -n 2p <<<"$felder")"
        HEARTBEAT="$(sed -n 3p <<<"$felder")"
    fi
fi

if [[ -z "$KENNUNG" ]]; then
    mangel "Geraetekennung" "nicht lesbar - Dienst laeuft nicht?"
elif [[ "$KENNUNG" == "$WERKSVORGABE" ]]; then
    mangel "Geraetekennung" "$KENNUNG  <- WERKSVORGABE, Konfiguration verloren"
else
    ok "Geraetekennung" "$KENNUNG"
fi

if [[ -n "$IST_VARIANTE" ]]; then
    ok "Hardware-Variante" "$IST_VARIANTE"
    [[ -n "$VARIANTE" && "$VARIANTE" != "$IST_VARIANTE" ]] \
        && warnung "Variante abweichend" "gesetzt $IST_VARIANTE, angefordert $VARIANTE (nur mit ees-set-variant.sh -f)"
elif [[ -n "$KENNUNG" && "$KENNUNG" != "$WERKSVORGABE" ]]; then
    mangel "Hardware-Variante" "nicht gesetzt - der Updater bricht damit ab"
    [[ -n "$VARIANTE" ]] && plane "variante" \
                         || warnung "Variante unbekannt" "mit -w v1.8 bzw. -w v1.9 aufrufen"
fi

[[ -n "$HEARTBEAT" ]] && ok "Heartbeat-URL" "$HEARTBEAT" \
                      || { [[ -n "$KENNUNG" ]] && mangel "Heartbeat-URL" "fehlt - das Geraet meldet sich nicht"; }

# 3. Deploy-Skripte -----------------------------------------------------------

echo
echo "-- Deploy-Skripte --"
BENOETIGT=(ees-update.sh ees-set-variant.sh install-services.sh install-update.sh download_install_scripts.sh)
skripte_fehlen=false
for s in "${BENOETIGT[@]}"; do
    [[ -f "$WORKDIR/$s" ]] && ok "$s" || { mangel "$s" "fehlt"; skripte_fehlen=true; }
done

# Ein vorhandenes, aber altes ees-update.sh nennt ees-set-variant.sh noch nicht.
if [[ -f "$WORKDIR/ees-update.sh" ]] && ! grep -q 'ees-set-variant.sh' "$WORKDIR/ees-update.sh"; then
    warnung "ees-update.sh" "alter Stand"
    skripte_fehlen=true
fi
$skripte_fehlen && plane "skripte"

# 4. Release-Schluessel -------------------------------------------------------

echo
echo "-- Release-Schluessel --"
if compgen -G "$KEY_DIR/*.pub" >/dev/null 2>&1; then
    for k in "$KEY_DIR"/*.pub; do
        ok "$(basename "$k")" "SHA-256 $(openssl pkey -pubin -in "$k" -outform DER 2>/dev/null | sha256sum | cut -c1-16)"
    done
else
    mangel "$KEY_DIR" "kein oeffentlicher Schluessel - der Updater kann nichts pruefen"
    plane "units"
fi

# 5. systemd-Units ------------------------------------------------------------

echo
echo "-- systemd --"
units_fehlen=false
for u in "$APP_UNIT" "$HC_TIMER" "$UPD_TIMER"; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl cat "$u" >/dev/null 2>&1; then
        zustand="$(systemctl is-active "$u" 2>/dev/null || true)"
        [[ "$zustand" == "active" ]] && ok "$u" "$zustand" || warnung "$u" "$zustand"
    else
        mangel "$u" "nicht eingerichtet"
        units_fehlen=true
    fi
done
$units_fehlen && plane "units"

# Ein von Hand gestarteter Dienst haelt den Port und laesst die Unit scheitern.
if ! systemctl is-active "$APP_UNIT" >/dev/null 2>&1 && pgrep -f "$WORKDIR/app-service" >/dev/null 2>&1; then
    warnung "app-service" "laeuft ausserhalb von systemd - haelt Port $SERVICE_PORT"
fi

# 6. FTP-Zugangsdaten ---------------------------------------------------------

echo
echo "-- FTP-Sicherung --"
env_noetig=false
if [[ ! -e "$BACKUP_ENV" ]]; then
    mangel "$BACKUP_ENV" "fehlt - Sicherungen werden nicht hochgeladen"
    env_noetig=true
else
    rechte="$(stat -c '%a %U:%G' "$BACKUP_ENV")"
    [[ "$rechte" == "600 root:root" ]] && ok "$BACKUP_ENV" "$rechte" \
                                       || { warnung "$BACKUP_ENV" "$rechte, erwartet 600 root:root"; plane "envrechte"; }

    # In einer Subshell lesen, damit die Werte nicht im Hauptprozess landen.
    unvollstaendig="$(
        set +u
        # shellcheck disable=SC1090
        . "$BACKUP_ENV" 2>/dev/null || true
        [[ -z "$FTP_HOST" || -z "$FTP_USER" || -z "$FTP_PASS" ]] && echo "leer"
        [[ "$FTP_USER" == HIER_* || "$FTP_PASS" == HIER_* ]] && echo "vorlage"
        true
    )"
    case "$unvollstaendig" in
        *leer*)    mangel "$BACKUP_ENV" "FTP_HOST/FTP_USER/FTP_PASS unvollstaendig"; env_noetig=true ;;
        *vorlage*) mangel "$BACKUP_ENV" "enthaelt noch die Platzhalter der Vorlage"; env_noetig=true ;;
        *)         ok "Zugangsdaten" "vollstaendig" ;;
    esac
fi
$env_noetig && plane "env"

# --- Plan --------------------------------------------------------------------

echo
echo "================================================================"
if (( fehlt == 0 && warnungen == 0 )); then
    echo " Alles in Ordnung - nichts zu tun."
    echo "================================================================"
    exit 0
fi
printf ' %d Mangel, %d Auffaelligkeit(en)\n' "$fehlt" "$warnungen"
echo "================================================================"
echo
echo "Vorgesehene Massnahmen:"

beschreibe() {
    case "$1" in
        skripte)   echo "  - Deploy-Skripte erneuern (Bootstrap + download_install_scripts.sh)" ;;
        units)     echo "  - systemd-Units, Schluessel und Updater einrichten (install-services.sh)" ;;
        variante)  echo "  - Hardware-Variante '$VARIANTE' setzen (ees-set-variant.sh)" ;;
        env)       echo "  - $BACKUP_ENV anlegen (FTP-Zugangsdaten)" ;;
        envrechte) echo "  - Rechte von $BACKUP_ENV auf 600 root:root setzen" ;;
    esac
}

if (( ${#MASSNAHMEN[@]} == 0 )); then
    echo "  keine - die Beanstandungen oben sind von Hand zu klaeren."
    exit 1
fi

hat() { local s; for s in "${MASSNAHMEN[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

# In der Reihenfolge anzeigen, in der auch gearbeitet wird - sonst liest sich
# der Plan, als wuerde die Variante vor den Skripten gesetzt, die sie braucht.
for m in "${REIHENFOLGE[@]}"; do hat "$m" && beschreibe "$m"; done

echo
if $NUR_PRUEFEN; then
    echo "Probelauf - es wurde nichts geaendert."
    exit 0
fi

if ! $JA; then
    read -rp "Ausfuehren? [j/N] " antwort
    [[ "$antwort" == [jJyY] ]] || { echo "Abgebrochen."; exit 0; }
fi

# --- Massnahmen --------------------------------------------------------------

if hat skripte; then
    echo
    echo "=== Deploy-Skripte erneuern ==="
    # Das Bootstrap-Skript holt sich selbst NICHT mit - dieses Script ist eine
    # andere Datei und darf es deshalb gefahrlos ersetzen.
    curl -fsSL --max-time 30 -o "$WORKDIR/download_install_scripts.sh.neu" \
        "$DEPLOY_RAW/download_install_scripts.sh" \
        || die "Bootstrap-Skript nicht ladbar von $DEPLOY_RAW"
    mv "$WORKDIR/download_install_scripts.sh.neu" "$WORKDIR/download_install_scripts.sh"
    chmod 755 "$WORKDIR/download_install_scripts.sh"
    chown "$GERAETE_USER:$GERAETE_USER" "$WORKDIR/download_install_scripts.sh"

    sudo -u "$GERAETE_USER" bash "$WORKDIR/download_install_scripts.sh" \
        || die "download_install_scripts.sh fehlgeschlagen."

    [[ -f "$WORKDIR/ees-set-variant.sh" ]] \
        || die "ees-set-variant.sh fehlt auch nach dem Holen - steht es in der
  SCRIPTS-Liste des Bootstrap-Skripts und im oeffentlichen Deploy-Repo?"
fi

if hat units; then
    echo
    echo "=== systemd-Units einrichten ==="
    SERVICE_PORT="$SERVICE_PORT" bash "$WORKDIR/install-services.sh" \
        || die "install-services.sh fehlgeschlagen."
fi

if hat variante; then
    echo
    echo "=== Hardware-Variante setzen ==="
    bash "$WORKDIR/ees-set-variant.sh" -w "$VARIANTE" -p "$SERVICE_PORT" \
        || die "ees-set-variant.sh fehlgeschlagen."
fi

if hat env; then
    echo
    echo "=== FTP-Zugangsdaten ablegen ==="
    ftp_host="$FTP_HOST_V"; ftp_user="$FTP_USER_V"; ftp_pass="$FTP_PASS_V"
    ftp_base="$FTP_BASE_V"; ftp_ftps="$FTP_FTPS_V"

    if [[ -n "$ENV_QUELLE" ]]; then
        : # bereits oben eingelesen und geprueft
    elif [[ -t 0 ]]; then
        read -rp   "  FTP_HOST     : " ftp_host
        read -rp   "  FTP_USER     : " ftp_user
        read -rsp  "  FTP_PASS     : " ftp_pass; echo
        read -rp   "  FTP_BASE_DIR : " ftp_base
    else
        die "Keine Zugangsdaten: weder -e <datei> noch ein Terminal zum Fragen.
  Vorlage: deploy/backup.env.example"
    fi

    [[ -n "$ftp_host" && -n "$ftp_user" && -n "$ftp_pass" ]] \
        || die "FTP_HOST, FTP_USER und FTP_PASS muessen alle gesetzt sein."
    [[ "$ftp_user" != HIER_* && "$ftp_pass" != HIER_* ]] \
        || die "Die Platzhalter aus der Vorlage stehen noch drin."

    install -d -m 755 -o root -g root "$(dirname "$BACKUP_ENV")"
    # Erst die Rechte, dann der Inhalt: waere es umgekehrt, laege das Passwort
    # einen Wimpernschlag lang lesbar da.
    install -m 600 -o root -g root /dev/null "$BACKUP_ENV"
    cat > "$BACKUP_ENV" <<EOF
# Angelegt von ees-doctor.sh am $(date '+%Y-%m-%d %H:%M:%S')
FTP_HOST="$ftp_host"
FTP_USER="$ftp_user"
FTP_PASS="$ftp_pass"
FTP_BASE_DIR="$ftp_base"
USE_FTPS="$ftp_ftps"
EOF
    echo "  $BACKUP_ENV angelegt ($(stat -c '%a %U:%G' "$BACKUP_ENV"))"

    # Gegenprobe am echten Ziel: ein Verzeichnislisting beweist, dass die
    # Anmeldung geht - ohne etwas zu schreiben.
    fern="${ftp_base%/}/"; fern="${fern#/}"
    curl_opts=(--silent --show-error --fail --connect-timeout 20 --max-time 60
               --user "$ftp_user:$ftp_pass" --list-only)
    [[ "$ftp_ftps" == "1" ]] && curl_opts+=(--ssl-reqd)
    if curl "${curl_opts[@]}" "ftp://$ftp_host/$fern" >/dev/null 2>&1; then
        echo "  Anmeldung am FTP geprueft: ftp://$ftp_host/$fern"
    else
        echo "  ACHTUNG: Anmeldung am FTP fehlgeschlagen - Datei liegt, Zugang pruefen." >&2
    fi
fi

if hat envrechte && ! hat env; then
    echo
    echo "=== Rechte an $BACKUP_ENV ==="
    chown root:root "$BACKUP_ENV"
    chmod 600 "$BACKUP_ENV"
    echo "  jetzt $(stat -c '%a %U:%G' "$BACKUP_ENV")"
fi

# --- Abschluss ---------------------------------------------------------------

echo
echo "================================================================"
echo " Fertig. Gegenprobe:"
echo "   $0 -n"
echo
echo " Fehlt noch der Sollstand im Dashboard. Danach:"
echo "   sudo systemctl start $UPD_UNIT"
echo "   journalctl -u $UPD_UNIT -n 40 --no-pager"
echo "================================================================"
