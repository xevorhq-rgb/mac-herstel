# Mac Mini herstel

Eén commando om de Xevor Mac Mini vanaf nul terug te bouwen uit de
versleutelde offsite-backup (Cloudflare R2, EU).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xevorhq-rgb/mac-herstel/main/herstel.sh)
```

Benodigd: de drie waarden van de RAMP-KAART uit de wachtwoordmanager
(R2 Access Key ID, R2 Secret Access Key, backup-wachtwoord).

Dit repo bevat **geen geheimen** — alleen het herstelscript. De backup zelf
wordt elke nacht om 03:45 gemaakt door `offsite_backup.sh` op de Mac Mini
(versleuteld met AES-256 vóór upload; 7 nachten bewaard).
