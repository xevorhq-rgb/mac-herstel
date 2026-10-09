# Mac Mini herstel

Eén commando om de Xevor Mac Mini vanaf nul terug te bouwen uit de
versleutelde offsite-backup (Cloudflare R2, EU).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xevorhq-rgb/mac-herstel/main/herstel.sh)
```

Benodigd: de drie waarden van de RAMP-KAART uit de wachtwoordmanager
(R2 Access Key ID, R2 Secret Access Key, en het restic-wachtwoord of het
oude backup-wachtwoord).

Twee routes (het script vraagt welke):
- **r = restic (standaard, sinds 09-10-2026)**: incrementele, versleutelde
  snapshots onder `restic-macmini/` in dezelfde bucket, elke nacht 04:30
  (`restic_backup.sh`). Bewaard: 7 dagen, 4 weken, 6 maanden.
- **b = oude totaalbundel**: `macmini-backup/`, 03:45 (`offsite_backup.sh`),
  terugval zolang die nog draait.

Dit repo bevat **geen geheimen** — alleen het herstelscript. De backup zelf
wordt elke nacht om 03:45 gemaakt door `offsite_backup.sh` op de Mac Mini
(versleuteld met AES-256 vóór upload; 7 nachten bewaard).
