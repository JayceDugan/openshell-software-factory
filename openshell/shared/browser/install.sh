#!/bin/sh
# Headless browser layer for web-dev personas (any harness). Run as root during image build:
#   COPY shared/browser/install.sh /tmp/browser-install.sh
#   RUN sh /tmp/browser-install.sh <agent-dir> && rm /tmp/browser-install.sh
# The persona Containerfile must also set the ENV block from personas/pi-web-dev/Containerfile
# (PLAYWRIGHT_BROWSERS_PATH, AGENT_BROWSER_*), since a script can't set image ENV.
#
# Why not `agent-browser install --with-deps`: it downloads Chrome for Testing, which has no
# linux-arm64 build, and Ubuntu 24.04's chromium apt package is a snap stub. Playwright ships
# its own Chromium for both amd64 and arm64, and `--with-deps` pulls the apt libs + fonts.
set -eu

AGENT_DIR="${1:?usage: install.sh <agent-dir>}"
AGENT_BROWSER_VERSION=0.27.0
PLAYWRIGHT_VERSION=1.56.1
: "${PLAYWRIGHT_BROWSERS_PATH:?set PLAYWRIGHT_BROWSERS_PATH (under /usr: policies grant /usr, not /opt)}"

npm install -g --ignore-scripts "agent-browser@${AGENT_BROWSER_VERSION}"
npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium
rm -rf /var/lib/apt/lists/* /root/.npm

CHROME="$(ls -d "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux*/chrome | head -1)"
test -x "$CHROME"
ln -sf "$CHROME" /usr/local/bin/chromium
agent-browser --version

# agent-browser's own version-matched skill. It is named "core"; rename so the frontmatter
# name matches the directory both pi and omp load it from.
mkdir -p "$AGENT_DIR/skills"
cp -R "$(agent-browser skills path core)" "$AGENT_DIR/skills/agent-browser"
sed -i '0,/^name: core$/s//name: agent-browser/' "$AGENT_DIR/skills/agent-browser/SKILL.md"
