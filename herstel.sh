#!/bin/bash
# ============================================================================
# herstel.sh — één-commando-herstel van de Xevor Mac Mini
#
# Gebruik op een kale (nieuwe) Mac, ingelogd als je eigen gebruiker:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/xevorhq-rgb/mac-herstel/main/herstel.sh)
#
# Het script vraagt om 3 waarden uit de RAMP-KAART in je wachtwoordmanager:
#   1. R2 Access Key ID          2. R2 Secret Access Key
#   3. Restic-wachtwoord (route r, standaard sinds 09-10-2026) of Backup-wachtwoord (route b)
# Twee routes:
#   r = restic (incrementele back-up onder R2-prefix restic-macmini, elke nacht 04:30) — STANDAARD
#   b = oude totaalbundel (openssl-tar onder macmini-backup, 03:45) — terugval, zolang die nog draait
#
# Dit bestand bevat GEEN geheimen en mag publiek staan.
# ============================================================================
set -uo pipefail

R2_ENDPOINT="https://94958e0e4802ce140e03d0c2330f6a6d.eu.r2.cloudflarestorage.com"
R2_BUCKET="gerustbewaard-kluis"
R2_PREFIX="macmini-backup"
STAGING="$HOME/herstel-uitgepakt"

WARN_AANTAL=0
WARN_LIJST=""
kop()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ⚠ %s\033[0m\n' "$*"; WARN_AANTAL=$((WARN_AANTAL+1)); WARN_LIJST="${WARN_LIJST}
  ⚠ $*"; }
fout() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*"; exit 1; }

kop "Xevor Mac Mini herstel"
echo "  Pak de RAMP-KAART uit je wachtwoordmanager erbij."
read -r -p "  R2 Access Key ID: " R2_ACCESS_KEY_ID < /dev/tty
read -r -s -p "  R2 Secret Access Key: " R2_SECRET_ACCESS_KEY < /dev/tty; echo
read -r -p "  Route: [r]estic (standaard) of [b]undel (oud): " HERSTEL_ROUTE < /dev/tty
HERSTEL_ROUTE="${HERSTEL_ROUTE:-r}"
if [[ "$HERSTEL_ROUTE" == "b" ]]; then
  read -r -s -p "  Backup-wachtwoord: " BACKUP_WW < /dev/tty; echo
else
  HERSTEL_ROUTE="r"
  read -r -s -p "  Restic-wachtwoord: " BACKUP_WW < /dev/tty; echo
fi
export R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY BACKUP_WW
[[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" && -n "$BACKUP_WW" ]] || fout "lege invoer"

# --- 1. Xcode Command Line Tools (nodig voor git/brew) ---
kop "1/9 Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  echo "  Er verschijnt een macOS-venster — klik 'Installeer' en wacht (max 30 min)."
  POGING=0
  until xcode-select -p >/dev/null 2>&1; do
    sleep 15
    POGING=$((POGING+1))
    (( POGING >= 120 )) && fout "CLT niet geïnstalleerd na 30 min. Installeer handmatig: Systeeminstellingen → Algemeen → Software-update, of 'softwareupdate --list' in een tweede Terminal, en draai dit script opnieuw."
  done
fi
ok "aanwezig"

# --- 2. Homebrew ---
kop "2/9 Homebrew"
if [[ ! -x /opt/homebrew/bin/brew ]]; then
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || fout "brew-installatie faalde"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
ok "aanwezig"

# --- 3. Basisgereedschap (hard gecontroleerd — hierop leunt al het vervolg) ---
kop "3/9 Basisgereedschap (python, git, gh, node)"
brew install -q python git gh node >/dev/null 2>&1 || true
for gereedschap in python3 git gh node npm; do
  command -v "$gereedschap" >/dev/null 2>&1 \
    || fout "$gereedschap ontbreekt na brew install — draai 'brew install python git gh node' handmatig en start dit script opnieuw"
done
ok "geïnstalleerd en gecontroleerd"

if [[ "$HERSTEL_ROUTE" == "r" ]]; then
# --- 4+5 (restic). Haalt de nieuwste snapshot rechtstreeks van R2; geen bundel-download. ---
kop "4/9 restic installeren"
brew install -q restic >/dev/null 2>&1 || true
command -v restic >/dev/null 2>&1 || fout "restic ontbreekt na brew install"
ok "restic $(restic version | awk '{print $2}')"
kop "5/9 Nieuwste snapshot terugzetten uit R2 (restic)"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto
export RESTIC_REPOSITORY="s3:$R2_ENDPOINT/$R2_BUCKET/restic-macmini" RESTIC_PASSWORD="$BACKUP_WW"
restic snapshots --host xevor-macmini --latest 3 || fout "repo niet leesbaar (kloppen de R2-sleutels en het restic-wachtwoord?)"
RESTIC_DOEL="$HOME/herstel-restic"
restic restore latest --host xevor-macmini --target "$RESTIC_DOEL" || fout "restic restore faalde"
# restic zet absolute paden terug (bv. herstel-restic/Users/xevor/...): zoek de oude home-map
EXTRA_DIR=$(find "$RESTIC_DOEL" -maxdepth 4 -type d -name .restic-extra | head -1)
[[ -n "$EXTRA_DIR" ]] || fout "snapshot incompleet (.restic-extra mist)"
STAGING="$(dirname "$EXTRA_DIR")"
cp -R "$EXTRA_DIR/." "$STAGING/"      # Brewfile, repos.txt, LaunchAgents, gh-token, crontab
[[ -f "$STAGING/.openclaw/workspace/SOUL_CORE.md" ]] || fout "snapshot incompleet (sentinel mist)"
ok "teruggezet in $STAGING"
else
# --- 4. Nieuwste backup-bundel ophalen van R2 ---
kop "4/9 Backup-bundel downloaden van R2"
VENV="$(mktemp -d)/venv"
python3 -m venv "$VENV" && "$VENV/bin/pip" -q install boto3 || fout "boto3-installatie faalde"
BUNDEL="$HOME/herstel-bundel.tar.gz.enc"
export HERSTEL_ENDPOINT="$R2_ENDPOINT" HERSTEL_BUCKET="$R2_BUCKET" HERSTEL_PREFIX="$R2_PREFIX"
"$VENV/bin/python" - "$BUNDEL" <<'PYEOF' || fout "download faalde (kloppen de R2-sleutels?)"
import os, sys, boto3
s3 = boto3.client("s3",
    endpoint_url=os.environ["HERSTEL_ENDPOINT"],
    aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
    region_name="auto")
bucket, prefix = os.environ["HERSTEL_BUCKET"], os.environ["HERSTEL_PREFIX"]
objs, token = [], None
while True:
    kw = {"Bucket": bucket, "Prefix": prefix + "/", "MaxKeys": 1000}
    if token: kw["ContinuationToken"] = token
    r = s3.list_objects_v2(**kw)
    objs += [o["Key"] for o in r.get("Contents", [])]
    if not r.get("IsTruncated"): break
    token = r.get("NextContinuationToken")
if not objs: sys.exit("geen backups gevonden onder " + prefix)
nieuwste = sorted(objs)[-1]
print(f"  nieuwste: {nieuwste}")
s3.download_file(bucket, nieuwste, sys.argv[1])
PYEOF
[[ -s "$BUNDEL" ]] || fout "bundel niet gedownload"
ok "gedownload: $(du -h "$BUNDEL" | cut -f1)"

# --- 5. Ontsleutelen en uitpakken ---
kop "5/9 Ontsleutelen en uitpakken"
mkdir -p "$STAGING"
/usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$BUNDEL" -pass env:BACKUP_WW | tar xzf - -C "$STAGING" \
  || fout "ontsleutelen faalde (klopt het backup-wachtwoord?)"
[[ -f "$STAGING/.openclaw/workspace/SOUL_CORE.md" ]] || fout "bundel incompleet (sentinel mist)"
ok "uitgepakt in $STAGING"
fi

# --- 6. Bestanden terugzetten (Projects komt uit de bundel, mét niet-gecommit werk) ---
kop "6/9 Bestanden terugzetten"
for item in .openclaw .claude vault Projects .ssh .gitconfig .zshrc .zprofile \
            .claude.json raad-van-advies.md sync-soul.sh SignaalRadar .config \
            WoningArchief Archief backups; do
  if [[ -e "$STAGING/$item" ]]; then
    if [[ "$item" == ".config" ]]; then
      mkdir -p "$HOME/.config" && cp -R "$STAGING/.config/." "$HOME/.config/"
    else
      [[ -e "$HOME/$item" ]] && mv "$HOME/$item" "$HOME/${item}.pre-herstel" 2>/dev/null
      cp -R "$STAGING/$item" "$HOME/$item"
    fi
    ok "$item"
  fi
done
[[ -d "$HOME/.ssh" ]] && chmod 700 "$HOME/.ssh" && chmod 600 "$HOME/.ssh"/* 2>/dev/null || true

# --- 7. GitHub + eventueel ontbrekende repos ---
kop "7/9 GitHub-koppeling en repo-controle"
if [[ -s "$STAGING/gh-token.txt" ]]; then
  gh auth login --with-token < "$STAGING/gh-token.txt" 2>/dev/null || true
fi
if gh auth status >/dev/null 2>&1; then
  ok "gh ingelogd"
else
  warn "GitHub niet ingelogd (token verlopen?) — draai straks: gh auth login. Repos komen uit de bundel, dus dit blokkeert het herstel niet; pushen/pullen werkt pas na inloggen."
fi
gh auth setup-git 2>/dev/null || true
mkdir -p "$HOME/Projects"
while read -r naam url; do
  [[ -z "$naam" || "$url" == "-" ]] && continue
  if [[ ! -d "$HOME/Projects/$naam" ]]; then
    git clone -q "$url" "$HOME/Projects/$naam" && ok "gecloned (ontbrak in bundel): $naam" || warn "clonen faalde: $naam ($url)"
  fi
done < "$STAGING/repos.txt"
# .env's alleen terugzetten in repos die echt bestaan (geen fantoom-mappen maken)
if [[ -d "$STAGING/env-files/Projects" ]]; then
  for envdir in "$STAGING/env-files/Projects"/*/; do
    naam=$(basename "$envdir")
    if [[ -d "$HOME/Projects/$naam" ]]; then
      cp -R "$envdir." "$HOME/Projects/$naam/"
    else
      warn ".env voor '$naam' niet teruggezet: repo-map ontbreekt"
    fi
  done
  ok ".env-bestanden teruggezet"
fi

# --- 8. Software en automatisering ---
kop "8/9 Software (Brewfile, npm, venvs) en LaunchAgents"
[[ -f "$STAGING/Brewfile" ]] && { brew bundle --file "$STAGING/Brewfile" >/dev/null 2>&1 && ok "Brewfile" || warn "deel van Brewfile faalde (App Store-apps vergen inloggen) — check: brew bundle --file $STAGING/Brewfile"; }
if [[ -f "$STAGING/npm-global.txt" ]]; then
  : > /tmp/herstel-npm-fouten.txt
  grep -oE '[@a-zA-Z0-9/._-]+@[0-9][0-9a-zA-Z.-]*' "$STAGING/npm-global.txt" | grep -v '^corepack' | while read -r pkg; do
    npm install -g -q "$pkg" >/dev/null 2>&1 || echo "  npm-pakket faalde: $pkg" >> /tmp/herstel-npm-fouten.txt
  done
  if [[ -s /tmp/herstel-npm-fouten.txt ]]; then warn "npm-pakketten gefaald: $(tr '\n' ' ' < /tmp/herstel-npm-fouten.txt)"; else ok "npm-globals (o.a. claude-code)"; fi
fi
for repo in "$HOME"/Projects/*/; do
  if [[ -f "$repo/requirements.txt" && ! -d "$repo/.venv" ]]; then
    (cd "$repo" && python3 -m venv .venv && .venv/bin/pip -q install -r requirements.txt && .venv/bin/pip -q install boto3) \
      && ok "venv: $(basename "$repo")" || warn "venv faalde: $(basename "$repo")"
  fi
done
if [[ -d "$STAGING/LaunchAgents" ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$STAGING/LaunchAgents/"*.plist "$HOME/Library/LaunchAgents/"
  GELADEN=0
  for p in "$HOME/Library/LaunchAgents/"*.plist; do
    if launchctl load "$p" 2>/dev/null; then GELADEN=$((GELADEN+1)); else warn "LaunchAgent laadde niet: $(basename "$p") (hoort erbij als de bijbehorende app nog niet is geïnstalleerd, bv. Grass)"; fi
  done
  ok "LaunchAgents geladen: $GELADEN"
fi
[[ -s "$STAGING/crontab.txt" ]] && crontab "$STAGING/crontab.txt" 2>/dev/null || true

# --- 9. Resultaat + wat nog handwerk is ---
kop "9/9 Resultaat"
cat <<'CHECKLIST'
  Handmatige stappen (in deze volgorde):
  □ Systeeminstellingen → Apple-ID: log in bij iCloud (voor de iCloud-backup-map)
  □ Systeeminstellingen → Privacy → Volledige schijftoegang: zet Terminal AAN
  □ claude → opnieuw inloggen met 'claude' (de login zat in de Keychain en gaat niet mee)
  □ gh auth login — alleen als hierboven een GitHub-waarschuwing stond
  □ Telegram Desktop: log in (Xevors meldingen)
  □ Grass.app + andere App Store-apps: installeer/log in
  □ OpenClaw-browser: diensten opnieuw inloggen (browserprofiel zit bewust niet in de backup)
  □ Ollama-modellen opnieuw binnenhalen als je lokale AI gebruikt: ollama pull <model> (~GB's)
  □ Energiestand: Systeeminstellingen → nooit sluimeren (headless!)
  □ Test: launchctl list | grep -E "xevor|gerustgekocht"   (alles moet er staan)
  □ Test: claude → vraag "wie ben ik en waar waren we mee bezig?"
  □ Ruim op: rm -rf ~/herstel-uitgepakt ~/herstel-restic ~/herstel-bundel.tar.gz.enc ~/*.pre-herstel
CHECKLIST
echo
if (( WARN_AANTAL > 0 )); then
  printf '\033[1;33m  Herstel afgerond MET %d waarschuwing(en):%s\033[0m\n' "$WARN_AANTAL" "$WARN_LIJST"
  echo "  Loop deze na vóór je ervan uitgaat dat alles draait."
  exit 1
fi
ok "Herstel volledig afgerond, zonder waarschuwingen. Welkom terug."
