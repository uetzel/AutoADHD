#!/bin/bash
# build-canvas.sh
# Auto-generates an Obsidian Canvas file from vault wikilinks
# Creates a visual knowledge graph you can open in Obsidian
#
# Usage: ./build-canvas.sh [focus]
#   No args: full vault overview
#   focus: "people" | "actions" | "concepts" | a specific note name

set -uo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FOCUS="${1:-overview}"
DATE=$(date +%Y-%m-%d)

# Color coding by type
# 1=red, 2=orange, 3=yellow, 4=green, 5=cyan, 6=purple
color_for_type() {
    case "$1" in
        person) echo "5" ;;    # cyan
        event) echo "2" ;;     # orange
        concept) echo "6" ;;   # purple
        decision) echo "3" ;;  # yellow
        project) echo "4" ;;   # green
        action) echo "1" ;;    # red
        *) echo "" ;;
    esac
}

# Generate unique hex IDs
next_id() {
    printf '%016x' $((RANDOM * RANDOM * RANDOM + $1))
}

export VAULT_DIR FOCUS

echo "Building Canvas: $FOCUS"

# Collect all Canon notes
NODES_JSON="[]"
EDGES_JSON="[]"
NODE_MAP="" # name -> id mapping

node_count=0
edge_count=0

# Helper: add a node
add_node() {
    local id="$1" type="$2" name="$3" file="$4" x="$5" y="$6" color="$7"
    local width=250 height=60
    [ "$type" = "group" ] && width=400 && height=300

    NODES_JSON=$(echo "$NODES_JSON" | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
node = {
    'id': '$id',
    'type': 'file',
    'file': '$file',
    'x': $x,
    'y': $y,
    'width': $width,
    'height': $height
}
if '$color':
    node['color'] = '$color'
nodes.append(node)
json.dump(nodes, sys.stdout)
")
}

# Build the canvas using Python for proper JSON handling
python3 << 'PYEOF'
import json
import os
import re
import math
import random

vault = os.environ.get("VAULT_DIR", ".")
focus = os.environ.get("FOCUS", "overview")

nodes = []
edges = []
node_ids = {}  # filename (no ext) -> node id
id_counter = [0]

def make_id():
    id_counter[0] += 1
    return f"{id_counter[0]:016x}"

def get_type(filepath):
    """Extract type from frontmatter"""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        m = re.search(r'^type:\s*(\S+)', content, re.MULTILINE)
        if m:
            return m.group(1)
    except:
        pass
    return "unknown"

def get_status(filepath):
    """Extract status from frontmatter"""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        m = re.search(r'^status:\s*(\S+)', content, re.MULTILINE)
        if m:
            return m.group(1)
    except:
        pass
    return ""

def get_wikilinks(filepath):
    """Extract all [[wikilinks]] from a file"""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        return re.findall(r'\[\[([^\]|]+?)(?:\|[^\]]+?)?\]\]', content)
    except:
        return []

def color_for_type(t):
    colors = {
        'person': '5',    # cyan
        'event': '2',     # orange
        'concept': '6',   # purple
        'decision': '3',  # yellow
        'project': '4',   # green
        'action': '1',    # red
        'ai-reflection': '6',
    }
    return colors.get(t, '')

# Collect all Canon entries
canon_files = {}
for root, dirs, files in os.walk(os.path.join(vault, 'Canon')):
    for f in files:
        if f.endswith('.md'):
            name = f[:-3]
            path = os.path.join(root, f)
            rel_path = os.path.relpath(path, vault)
            note_type = get_type(path)
            status = get_status(path)
            canon_files[name] = {
                'path': rel_path,
                'type': note_type,
                'status': status,
                'links': get_wikilinks(path)
            }

# Filter based on focus
if focus == "actions":
    focus_names = [n for n, d in canon_files.items() if d['type'] == 'action']
    # Also include linked notes
    extras = set()
    for name in focus_names:
        for link in canon_files[name]['links']:
            if link in canon_files:
                extras.add(link)
    focus_names = list(set(focus_names) | extras)
elif focus == "people":
    focus_names = [n for n, d in canon_files.items() if d['type'] == 'person']
elif focus == "concepts":
    focus_names = [n for n, d in canon_files.items() if d['type'] == 'concept']
    extras = set()
    for name in focus_names:
        for link in canon_files[name]['links']:
            if link in canon_files:
                extras.add(link)
    focus_names = list(set(focus_names) | extras)
else:
    # Overview: include everything but limit to most connected
    # Count incoming links
    incoming = {name: 0 for name in canon_files}
    for name, data in canon_files.items():
        for link in data['links']:
            if link in incoming:
                incoming[link] += 1

    # Take top 50 most connected + all actions
    sorted_by_links = sorted(incoming.items(), key=lambda x: -x[1])
    focus_names = [n for n, _ in sorted_by_links[:50]]
    # Always include open actions
    for name, data in canon_files.items():
        if data['type'] == 'action' and data.get('status') in ('open', 'in-progress', ''):
            if name not in focus_names:
                focus_names.append(name)

# Layout: arrange by type in clusters
type_positions = {
    'person': (0, 0),
    'event': (800, 0),
    'concept': (0, 600),
    'decision': (800, 600),
    'project': (400, 300),
    'action': (1200, 300),
}

type_counts = {}

for name in focus_names:
    if name not in canon_files:
        continue
    data = canon_files[name]
    nid = make_id()
    node_ids[name] = nid

    note_type = data['type']
    base_x, base_y = type_positions.get(note_type, (400, 0))

    # Offset within cluster
    count = type_counts.get(note_type, 0)
    type_counts[note_type] = count + 1

    cols = 3
    row = count // cols
    col = count % cols
    x = base_x + col * 280
    y = base_y + row * 100

    node = {
        'id': nid,
        'type': 'file',
        'file': data['path'],
        'x': x,
        'y': y,
        'width': 250,
        'height': 60,
    }

    color = color_for_type(note_type)
    if color:
        node['color'] = color

    # Red border for open actions
    if note_type == 'action' and data.get('status') == 'open':
        node['color'] = '1'

    nodes.append(node)

# Add type group labels
for note_type, (bx, by) in type_positions.items():
    count = type_counts.get(note_type, 0)
    if count == 0:
        continue
    cols = 3
    rows = (count + cols - 1) // cols
    gid = make_id()
    nodes.append({
        'id': gid,
        'type': 'group',
        'x': bx - 20,
        'y': by - 50,
        'width': min(count, cols) * 280 + 40,
        'height': rows * 100 + 70,
        'label': note_type.upper() + 'S',
    })

# Build edges from wikilinks
for name in focus_names:
    if name not in canon_files or name not in node_ids:
        continue
    for link in canon_files[name]['links']:
        if link in node_ids and link != name:
            eid = make_id()
            edges.append({
                'id': eid,
                'fromNode': node_ids[name],
                'toNode': node_ids[link],
                'toEnd': 'arrow',
            })

# Write canvas file
canvas = {'nodes': nodes, 'edges': edges}

if focus == "overview":
    outpath = os.path.join(vault, 'Vault Overview.canvas')
elif focus in ('actions', 'people', 'concepts'):
    outpath = os.path.join(vault, f'{focus.title()} Map.canvas')
else:
    outpath = os.path.join(vault, f'{focus} Map.canvas')

with open(outpath, 'w') as f:
    json.dump(canvas, f, indent=2)

print(f"Canvas written: {os.path.basename(outpath)}")
print(f"  Nodes: {len(nodes)}")
print(f"  Edges: {len(edges)}")
PYEOF
