#!/usr/bin/env bash
# One-time setup for nightly CI on a cluster node (CoreOS).
# Run this on the node or via SSH: ssh core@virtlab725 < setup-node.sh
set -euo pipefail

echo "=== Setting up nightly CI on $(hostname) ==="

# --- bats-core ---
if ! command -v bats &>/dev/null; then
    echo "Installing bats-core..."
    curl -sL https://github.com/bats-core/bats-core/archive/refs/tags/v1.12.0.tar.gz | sudo tar xz -C /opt
    sudo /opt/bats-core-1.12.0/install.sh /usr/local
    echo "bats $(bats --version) installed"
else
    echo "bats already installed: $(bats --version)"
fi

# --- openshell CLI ---
if ! command -v openshell &>/dev/null; then
    echo "openshell CLI not found."
    echo "Install manually: download from OpenShell releases, extract to /usr/local/bin/openshell"
else
    echo "openshell already installed: $(openshell --version 2>&1 | head -1)"
fi

# --- CI directories ---
sudo mkdir -p /opt/ci /tmp/ci-results /etc/ci
sudo chown core:core /opt/ci /tmp/ci-results

# --- Slack config ---
if [[ ! -f /etc/ci/slack-env ]]; then
    echo "Creating /etc/ci/slack-env template..."
    sudo tee /etc/ci/slack-env > /dev/null << 'SLACK_EOF'
# Slack notification config for nightly CI.
# Option A: Incoming webhook (posts to a channel)
# SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T.../B.../...

# Option B: Bot token (can send DMs)
# SLACK_BOT_TOKEN=xoxb-...
# SLACK_CHANNEL=U01ABCDEF  # your Slack user ID for DMs
SLACK_EOF
    sudo chmod 600 /etc/ci/slack-env
    echo "Edit /etc/ci/slack-env with your Slack credentials."
else
    echo "Slack config already exists at /etc/ci/slack-env"
fi

# --- Copy test scripts ---
echo ""
echo "=== Next steps ==="
echo "1. Copy the downstream/ directory to /opt/ci/ on this node:"
echo "   scp -r downstream/ core@$(hostname):/opt/ci/downstream/"
echo ""
echo "2. If using upstream Rust e2e tests, pre-compile the binary on your Mac:"
echo "   cd /path/to/OpenShell/e2e/rust"
echo "   cargo test --features e2e-kubernetes --no-run"
echo "   scp target/debug/deps/smoke-* core@$(hostname):/opt/ci/openshell-e2e"
echo ""
echo "3. Edit /etc/ci/slack-env with your Slack credentials"
echo ""
echo "4. Set up the cron job:"
echo "   sudo crontab -e"
echo "   # Regression (Mon-Fri at 02:00 UTC):"
echo "   0 2 * * 1-5 /opt/ci/downstream/scripts/run-nightly.sh regression >> /var/log/ci-nightly.log 2>&1"
echo "   # Integration (Sat at 02:00 UTC):"
echo "   0 2 * * 6 /opt/ci/downstream/scripts/run-nightly.sh integration >> /var/log/ci-nightly.log 2>&1"
echo ""
echo "5. Test manually:"
echo "   /opt/ci/downstream/scripts/run-nightly.sh regression"
echo ""
echo "=== Setup complete ==="
