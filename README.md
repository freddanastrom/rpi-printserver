# RPi Printserver

Konfigurera en Raspberry Pi som nätverksprintserver med CUPS, Samba och Avahi (Bonjour/AirPrint).
Primärt testat med Zebra-etikettskrivare (GK420, GXxxx) anslutna via USB.

## Förutsättningar

- Raspberry Pi med **Raspberry Pi OS Lite** (Bookworm, rekommenderas)
- SSH aktiverat (skapa tom fil `ssh` på boot-partitionen, eller via `raspi-config`)
- WiFi konfigurerat eller Ethernet tillgängligt för initial SSH-anslutning
- Internetåtkomst från RPi (för paketinstallation)

## OS-rekommendation

| Modell        | Arkitektur | 64-bit OS | 32-bit OS | Rekommenderat OS              |
|--------------|------------|-----------|-----------|-------------------------------|
| RPi 4 / 5    | ARMv8      | ✅        | ✅        | RPi OS Lite 64-bit (Bookworm) |
| RPi Zero 2W  | ARMv8      | ✅        | ✅        | RPi OS Lite 64-bit/32-bit     |
| RPi 2 v1.1   | ARMv7      | ❌        | ✅        | RPi OS Lite 32-bit            |

Scriptet är arkitekturoberoende (bash + apt) och fungerar på alla ovanstående modeller.

## Snabbstart

```bash
# 1. Klona repot (eller kopiera filerna) till din lokala dator
git clone <repo-url>
cd rpi-printserver

# 2. Kopiera konfigurationsmallen och fyll i dina värden
cp config.env.template config.env
nano config.env        # Redigera WIFI_SSID, STATIC_IP, etc.

# 3. Kopiera filerna till RPi via scp (anpassa användarnamn/IP)
scp -r . pi@raspberrypi.local:~/rpi-printserver/

# 4. SSH in på RPi
ssh pi@raspberrypi.local

# 5. Kör deploy – scriptet startar automatiskt inuti tmux
cd ~/rpi-printserver
sudo bash deploy.sh

# 6. Om SSH tappar under deploy – reconnecta på den nya IP:n och återanslut tmux:
ssh pi@<STATIC_IP>
tmux attach -t deploy

# 7. Lägg till Zebra-skrivare (efter deploy)
sudo bash scripts/add-zebra-printer.sh
```

## Paket som installeras

| Paket                              | Funktion                                    |
|------------------------------------|---------------------------------------------|
| `cups`, `cups-client`, `cups-bsd`, `cups-filters` | Utskriftsserver (CUPS) + `lpr`/`lpq`-kommandon |
| `avahi-daemon`, `libnss-mdns`      | Bonjour/AirPrint – automatisk nätverksupptäckt |
| `samba`, `smbclient`               | Windows-kompatibel utskriftsdelning         |
| `openprinting-ppds`, `foomatic-db-compressed-ppds` | Drivrutinsdatabas           |
| `ufw`                              | Brandvägg                                   |
| `tmux`                             | Terminalfönster som överlever SSH-avbrott   |
| `hplip` *(valfri)*                 | HP-skrivardrivrutiner                       |
| `printer-driver-gutenprint` *(valfri)* | Bred drivrutinstäckning (Canon, Epson m.fl.) |
| `printer-driver-escpr` *(valfri)*  | Epson ESCPR-drivrutiner                     |

## Zebra-skrivare

### ZPL och EPL – kort förklaring

Zebra-skrivare kommunicerar via ett av två skrivarspråk:

- **ZPL2** (Zebra Programming Language): Modern standard. Stöds av GK420d, GX420d m.fl.
- **EPL2** (Eltron Programming Language): Äldre standard. Stöds av GK420t och äldre modeller.
- Vissa modeller stöder **båda** och auto-detekterar, eller kan växlas via frontknappar (se skrivarmanual).

### Raw-kö – hur det fungerar

CUPS konfigureras som en **raw-kö** som passerar data oförändrad till skrivaren:

```
Applikation → ZPL/EPL-data → CUPS raw-kö → USB → Zebra-skrivare
                                (ingen konvertering)
```

Applikationen (t.ex. etikettprogram) ansvarar för att skicka korrekt ZPL- eller EPL-kod.
En raw-kö hanterar båda protokollen utan extra konfiguration.

### Lägg till Zebra-skrivare

Eftersom skrivare-URI inkluderar ett unikt serienummer kan skrivare inte läggas till helt
automatiskt. Kör hjälpscriptet efter deploy:

```bash
sudo bash scripts/add-zebra-printer.sh
```

Scriptet listar anslutna Zebra-enheter och guidar dig genom konfigurationen.

Alternativt via CUPS webbgränssnitt:
1. Öppna `http://<STATIC_IP>:631` i webbläsaren
2. Gå till **Administration → Add Printer**
3. Välj din USB-skrivare
4. Välj **Raw** som drivrutin (under "Generic" eller "Raw Queue")

### Testa utskrift

```bash
# ZPL2-test (GK420d och de flesta moderna Zebra)
printf '^XA^FO50,50^ADN,36,20^FDTest ZPL^FS^XZ' | lpr -P <SKRIVARNAMN>

# EPL2-test (äldre modeller, t.ex. GK420t)
printf 'N\nA50,50,0,3,1,1,N,"Test EPL"\nP1\n' | lpr -P <SKRIVARNAMN>
```

## Konfiguration

### config.env – viktigaste variabler

| Variabel           | Beskrivning                                    | Exempel              |
|--------------------|------------------------------------------------|----------------------|
| `WIFI_SSID`        | Nätverksnamn                                   | `"MinaNat"`          |
| `WIFI_PASSWORD`    | WiFi-lösenord                                  | `"hemligtkod"`       |
| `STATIC_IP`        | Fast IP-adress för printservern                | `"192.168.1.100"`    |
| `GATEWAY`          | Nätverkets gateway (router)                    | `"192.168.1.1"`      |
| `HOSTNAME`         | Hostname på RPi                                | `"printserver"`      |
| `CUPS_ADMIN_USER`  | Användare med CUPS-adminrätt                   | `"pi"`               |

### CUPS webgränssnitt

Åtkomst: `http://<STATIC_IP>:631`

Logga in med den Linux-användare som angavs i `CUPS_ADMIN_USER` (standard: `pi`).

### Windows-anslutning

1. Öppna **Utforskaren**
2. Skriv `\\<STATIC_IP>` i adressfältet
3. Skrivarerna listas automatiskt

`cups options = raw` i smb.conf säkerställer att ZPL/EPL-data passerar oförändrad via Samba.

### Mac och iOS

Skrivare upptäcks automatiskt via Bonjour (Avahi). Välj skrivare i systempreferenser som vanligt.

## Uppdatera inställningar

`deploy.sh` är idempotent och kan köras om utan att orsaka dubbelkonfiguration.
Tjänsterna `cups`, `smbd` och `nmbd` startas alltid om vid slutet av scriptet,
så konfigurationsändringar träder i kraft direkt.

### Ändra WiFi, IP eller hostname

1. Redigera `config.env` lokalt
2. Kopiera filen till RPi:
   ```bash
   scp config.env pi@<STATIC_IP>:~/rpi-printserver/
   ```
3. Kör om deploy:
   ```bash
   ssh pi@<STATIC_IP>
   cd ~/rpi-printserver
   sudo bash deploy.sh
   ```

> **Obs:** Ändras `STATIC_IP` eller `HOSTNAME` tappar SSH-sessionen. Vänta 30 sekunder
> och anslut sedan till den nya adressen. tmux-sessionen (`tmux attach -t deploy`)
> visar logg och slutstatus.

### Ändra CUPS- eller Samba-konfiguration

Redigera mallfilerna i `config/` lokalt, kopiera och kör om deploy på samma sätt som ovan.
deploy.sh skriver alltid de genererade konfigfilerna till disk och startar om berörda tjänster.

## Hårdvarukompatibilitet

Scriptet är arkitekturoberoende och fungerar på alla RPi-modeller med Raspberry Pi OS.
Se OS-rekommendationstabellen ovan för val av 32- eller 64-bitars OS.

## Felsökning

### CUPS startar inte

```bash
sudo systemctl status cups
sudo journalctl -u cups -n 50
```

### Skrivaren syns inte i lpinfo

```bash
lpinfo -v
# Kontrollera USB-anslutning och att skrivaren är påslagen
# Kontrollera USB-behörighet:
ls -la /dev/usb/
```

### Samba-fel

```bash
testparm -s                     # Validera smb.conf
sudo systemctl status smbd nmbd
sudo journalctl -u smbd -n 50
```

### Nätverket tappades under deploy

Om SSH-anslutningen tappade under nätverkskonfigurationen är det normalt.
Vänta 30 sekunder och anslut sedan till den nya statiska IP-adressen:

```bash
ssh pi@<STATIC_IP>
```

### Kontrollera brandväggsregler

```bash
sudo ufw status numbered
```

### Visa deploy-logg

```bash
cat /var/log/printserver-deploy.log
```

## Verifiering efter deploy

```bash
# 1. Tjänster uppe?
sudo systemctl status cups avahi-daemon smbd

# 2. CUPS lyssnar på nätverket?
ss -tlnp | grep 631

# 3. Anslutna USB-skrivare synliga?
lpinfo -v | grep -i "usb\|zebra"

# 4. Brandväggsregler korrekta?
sudo ufw status numbered

# 5. Lägg till Zebra-skrivare
sudo bash scripts/add-zebra-printer.sh

# 6. Testa CUPS webbgränssnitt
curl http://<STATIC_IP>:631/

# 7. Windows: Öppna \\<STATIC_IP> i Utforskaren
# 8. Mac/iOS: Skrivaren syns automatiskt via Bonjour
```
