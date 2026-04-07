#!/usr/bin/env bash
# This script is meant to be run on Ubuntu/Debian
cd "$(dirname "$0")"
sudo apt update
sudo apt -y install ffmpeg jq python3-pip python3-venv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
