# EES Data Logger — Deploy-Skripte

Bootstrap-Skripte für den EES Data Logger (Raspberry Pi). Öffentlich, damit ein
frisches Gerät sie ohne Zugangsdaten holen kann.

## Ein Gerät einrichten

```bash
curl -fsSLO https://raw.githubusercontent.com/cybermailer84/ees-rpi-datalogger-service-deploy/main/download_install_scripts.sh
chmod +x download_install_scripts.sh
./download_install_scripts.sh

sudo ~/WORK/datalogger/ees-onboard.sh -w v1.9      # oder -w v1.8
```

Danach meldet das Gerät seinen Versionsstand an das Dashboard und holt sich den
dort hinterlegten Sollstand selbst.

## Was hier liegt

| Datei | Zweck |
|---|---|
| `download_install_scripts.sh` | holt die übrigen Skripte und den öffentlichen Schlüssel |
| `ees-onboard.sh` | richtet ein **fabrikneues** Gerät in einem Aufruf ein |
| `ees-doctor.sh` | nimmt den Zustand eines **laufenden** Geräts auf und ergänzt, was fehlt |
| `ees-set-variant.sh` | trägt die Hardware-Variante nach, ohne Binaries anzufassen |
| `ees-set-identity.sh` | gibt einem **geklonten** Gerät seine eigene Kennung (Hostname, ID, VPN) |
| `install-services.sh` | systemd-Units, Schlüssel, Updater |
| `install-update.sh` | Binaries von Hand aktualisieren |
| `ees-update.sh` | automatisches Update, per Timer |
| `install-testadapter.sh` | Dummy-Adapter für Testaufbauten |
| `keys/release-key.pub` | öffentlicher Schlüssel, gegen den Releases geprüft werden |

`keys/release-key.pub` ist der **öffentliche** Teil — er gehört hierher. Der
private Teil liegt ausschließlich beim Betreiber und niemals auf einem Gerät.

Fingerabdruck prüfen:

```bash
openssl pkey -pubin -in keys/release-key.pub -outform DER | sha256sum
```

## Woher diese Dateien kommen

Quelle ist das (private) Hauptrepo `ees-rpi-datalogger-service`, Verzeichnisse
`deploy/` und `keys/`. Gespiegelt wird mit `scripts/publish-deploy.sh`.

**Änderungen bitte dort vornehmen** — was hier direkt bearbeitet wird, ist beim
nächsten Spiegeln überschrieben.
