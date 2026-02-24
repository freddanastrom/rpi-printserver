#!/usr/bin/env bash
# scripts/add-zebra-printer.sh
# Kör EFTER deploy.sh för att lägga till en Zebra-skrivare som raw-kö i CUPS.
#
# Användning: sudo bash scripts/add-zebra-printer.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Det här scriptet måste köras som root (sudo)."
    exit 1
fi

echo "Söker efter anslutna Zebra-skrivare..."
ZEBRA_DEVICES=$(lpinfo -v 2>/dev/null | grep -i "zebra\|ZTC\|ZPL\|EPL" || true)

if [[ -z "$ZEBRA_DEVICES" ]]; then
    echo ""
    echo "Inga Zebra-skrivare hittades. Kontrollera:"
    echo "  1. Att skrivaren är påslagen och ansluten via USB"
    echo "  2. Att CUPS-tjänsten körs: systemctl status cups"
    echo "  3. Alla anslutna enheter: lpinfo -v"
    exit 1
fi

echo ""
echo "Hittade enheter:"
echo "$ZEBRA_DEVICES"
echo ""

read -rp "Kopiera device URI från listan ovan: " DEVICE_URI
if [[ -z "$DEVICE_URI" ]]; then
    echo "Inget device URI angivet. Avbryter."
    exit 1
fi

read -rp "Skrivarnamn (utan mellanslag, t.ex. Zebra-GK420): " PRINTER_NAME
if [[ -z "$PRINTER_NAME" ]]; then
    echo "Inget skrivarnamn angivet. Avbryter."
    exit 1
fi

read -rp "Beskrivning (t.ex. 'Zebra GK420d - ZPL'): " DESCRIPTION
DESCRIPTION="${DESCRIPTION:-Zebra skrivare}"

read -rp "Skrivarspråk? [ZPL/EPL, enter för ZPL]: " LANG_CHOICE
LANG_CHOICE="${LANG_CHOICE:-ZPL}"

echo ""
echo "Lägger till skrivare..."
lpadmin -p "$PRINTER_NAME" -E \
    -v "$DEVICE_URI" \
    -m raw \
    -o printer-is-shared=true \
    -D "$DESCRIPTION"

echo ""
echo "Skrivare '$PRINTER_NAME' tillagd med raw-kö (${LANG_CHOICE}-kompatibel)."
echo ""
echo "Testa utskrift:"
if [[ "${LANG_CHOICE^^}" == "EPL" ]]; then
    echo "  EPL2: printf 'N\\nA50,50,0,3,1,1,N,\"Test EPL\"\\nP1\\n' | lpr -P $PRINTER_NAME"
else
    echo "  ZPL2: printf '^XA^FO50,50^ADN,36,20^FDTest ZPL^FS^XZ' | lpr -P $PRINTER_NAME"
fi
echo ""
echo "Visa alla skrivare: lpstat -p -d"
