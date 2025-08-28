#!/bin/bash

SRC_DIR="$SCRIPT_DIR/sources.list.d"
DEST_DIR="/etc/apt/sources.list.d/"

copie_source_list() {
    cp -r "$SRC_DIR"/* "$DEST_DIR"
}