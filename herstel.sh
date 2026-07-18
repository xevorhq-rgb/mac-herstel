#!/bin/bash
# ============================================================================
# herstel.sh — één-commando-herstel van de Xevor Mac Mini
#
# Gebruik op een kale (nieuwe) Mac, ingelogd als je eigen gebruiker:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/xevorhq-rgb/mac-herstel/main/herstel.sh)
#
# Het script vraagt om 3 waarden uit de RAMP-KAART in je wachtwoordmanager:
#   1. R2 Access Key ID          2. R2 Secret Access Key          3. Backup-wachtwoord
#
# Dit bestand bevat GEEN geheimen en mag publiek staan.
# ============================================================================
set -uo pipefail

R2_ENDPOINT="https://94958e0e4802ce140e03d0c2330f6a6d.eu.r2.cloudflarestorage.com"
R2_BUCKET="gerustbewaard-kluis"
R2_PREFIX="macmini-backup"
STAGING="$HOME/herstel-uitgepakt"

kop()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ⚠ %s\033[0m\n' "$*"; }
fout() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*"; exit 1; }

kop "Xevor Mac Mini herstel"
echo "  Pak de RAMP-KAART uit je wachtwoordmanager erbij."
read -r -p "  R2 Access Key ID: " R2_ACCESS_KEY_ID < /dev/tty
read -r -s -p "  R2 Secret Access Key: " R2_SECRET_ACCESS_KEY < /dev/tty; echo
read -r -s -p "  Backup-wachtwoord: " BACKUP_WW < /dev/tty; echo
export R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY BACKUP_WW
[[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" && -n "$BACKUP_WW" ]] || fout "lege invoer"

# --- 1. Xcode Command Line Tools (nodig voor git/brew) ---
kop "1/9 Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  echo "  Er verschijnt een macOS-venster — klik 'Installeer' en wacht."
  until xcode-select -p >/dev/null 2>&1; do sleep 15; done
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

# --- 3. Basisgereedschap ---
kop "3/9 Basisgereedschap (python, git, gh, node)"
brew install -q python git gh node >/dev/null 2>&1 || warn "brew install gaf een waarschuwing (meestal onschuldig)"
ok "geïnstalleerd"

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

# --- 6. Bestanden terugzetten ---
kop "6/9 Bestanden terugzetten"
for item in .openclaw .claude vault .ssh .gitconfig .zshrc .zprofile raad-van-advies.md .config; do
  if [[ -e "$STAGING/$item" ]]; then
    if [[ -e "$HOME/$item" && "$item" != ".config" ]]; then
      mv "$HOME/$item" "$HOME/${item}.pre-herstel" 2>/dev/null || true
    fi
    if [[ "$item" == ".config" ]]; then
      mkdir -p "$HOME/.config" && cp -R "$STAGING/.config/." "$HOME/.config/"
    else
      cp -R "$STAGING/$item" "$HOME/$item"
    fi
    ok "$item"
  fi
done
[[ -d "$HOME/.ssh" ]] && chmod 700 "$HOME/.ssh" && chmod 600 "$HOME/.ssh"/* 2>/dev/null || true

# --- 7. GitHub + repos + .env's ---
kop "7/9 GitHub-repos clonen"
if [[ -s "$STAGING/gh-token.txt" ]]; then
  gh auth login --with-token < "$STAGING/gh-token.txt" 2>/dev/null \
    && ok "gh ingelogd met bewaard token" \
    || warn "bewaard gh-token werkt niet meer — draai straks: gh auth login"
else
  warn "geen gh-token in bundel — draai straks: gh auth login"
fi
gh auth setup-git 2>/dev/null || true
mkdir -p "$HOME/Projects"
while read -r naam url; do
  [[ -z "$naam" || "$url" == "-" ]] && continue
  if [[ ! -d "$HOME/Projects/$naam" ]]; then
    git clone -q "$url" "$HOME/Projects/$naam" && ok "gecloned: $naam" || warn "clonen faalde: $naam ($url)"
  fi
done < "$STAGING/repos.txt"
if [[ -d "$STAGING/env-files/Projects" ]]; then
  cp -R "$STAGING/env-files/Projects/." "$HOME/Projects/"
  ok ".env-bestanden teruggezet"
fi

# --- 8. Software en automatisering ---
kop "8/9 Software (Brewfile, npm, venvs) en LaunchAgents"
[[ -f "$STAGING/Brewfile" ]] && { brew bundle --file "$STAGING/Brewfile" >/dev/null 2>&1 && ok "Brewfile" || warn "deel van Brewfile faalde (App Store-apps vergen inloggen)"; }
if [[ -f "$STAGING/npm-global.txt" ]]; then
  grep -oE '[@a-zA-Z0-9/._-]+@[0-9][0-9a-zA-Z.-]*' "$STAGING/npm-global.txt" | grep -v '^corepack' | while read -r pkg; do
    npm install -g -q "$pkg" >/dev/null 2>&1 || warn "npm-pakket faalde: $pkg"
  done
  ok "npm-globals (o.a. claude-code)"
fi
for repo in "$HOME"/Projects/*/; do
  if [[ -f "$repo/requirements.txt" && ! -d "$repo/.venv" ]]; then
    (cd "$repo" && python3 -m venv .venv && .venv/bin/pip -q install -r requirements.txt) \
      && ok "venv: $(basename "$repo")" || warn "venv faalde: $(basename "$repo")"
  fi
done
if [[ -d "$STAGING/LaunchAgents" ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$STAGING/LaunchAgents/"*.plist "$HOME/Library/LaunchAgents/"
  for p in "$HOME/Library/LaunchAgents/"*.plist; do launchctl load "$p" 2>/dev/null || true; done
  ok "LaunchAgents geladen"
fi
[[ -s "$STAGING/crontab.txt" ]] && crontab "$STAGING/crontab.txt" 2>/dev/null || true

# --- 9. Wat nog handwerk is ---
kop "9/9 KLAAR — nog een paar handmatige stappen"
cat <<'CHECKLIST'
  □ Systeeminstellingen → Apple-ID: log in bij iCloud (voor de iCloud-backup-map)
  □ Systeeminstellingen → Privacy → Volledige schijftoegang: zet Terminal AAN
  □ Telegram Desktop: log in (Xevors meldingen)
  □ Grass.app + andere App Store-apps: installeer/log in
  □ Energiestand: Systeeminstellingen → nooit sluimeren (headless!)
  □ Test: launchctl list | grep -E "xevor|gerustgekocht"   (alles moet er staan)
  □ Test: claude  →  en vraag "wie ben ik en waar waren we mee bezig?"
  □ Ruim op: rm -rf ~/herstel-uitgepakt ~/herstel-bundel.tar.gz.enc ~/*.pre-herstel
CHECKLIST
echo
ok "Herstel afgerond. Welkom terug."
