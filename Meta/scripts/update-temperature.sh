#!/bin/bash
# update-temperature.sh
# Ebbinghaus-inspired note temperature tracking
# Scans all Canon entries and assigns a temperature based on recency and frequency
# Temperature levels: hot | warm | cool | cold | frozen
#
# Logic:
#   - Count incoming wikilinks (how many other notes reference this one)
#   - Check last updated date
#   - Check mentions in recent inbox notes (last 30 days)
#   - Combine into temperature score
#
# Run weekly or after major vault changes

set -uo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DATE=$(date +%Y-%m-%d)
THIRTY_DAYS_AGO=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "2026-02-16")

echo "Updating note temperatures..."

# Count how many notes link TO a given note name
count_incoming_links() {
    local name="$1"
    # Search for [[Name]] across all vault files
    grep -rl "\[\[${name}\]\]" "$VAULT_DIR" --include="*.md" 2>/dev/null | wc -l | tr -d ' '
}

# Check if note was mentioned in recent inbox notes
count_recent_mentions() {
    local name="$1"
    grep -rl "\[\[${name}\]\]" "$VAULT_DIR/Inbox/" --include="*.md" 2>/dev/null | wc -l | tr -d ' '
}

# Process all Canon entries
process_folder() {
    local folder="$1"
    for f in "$folder"/*.md; do
        [ -f "$f" ] || continue
        local name=$(basename "$f" .md)

        # Get current updated date from frontmatter
        local updated=$(grep "^updated:" "$f" 2>/dev/null | head -1 | sed 's/updated: *//')

        # Count links
        local incoming=$(count_incoming_links "$name")
        local recent=$(count_recent_mentions "$name")

        # Calculate temperature
        # hot: 5+ incoming links AND mentioned in recent inbox
        # warm: 3+ incoming links OR mentioned in recent inbox
        # cool: 1-2 incoming links, not recent
        # cold: 0 incoming links
        # frozen: 0 links AND updated > 30 days ago

        local temp="cool"
        if [ "$incoming" -ge 5 ] && [ "$recent" -gt 0 ]; then
            temp="hot"
        elif [ "$incoming" -ge 3 ] || [ "$recent" -gt 0 ]; then
            temp="warm"
        elif [ "$incoming" -ge 1 ]; then
            temp="cool"
        elif [ -n "$updated" ] && [[ "$updated" < "$THIRTY_DAYS_AGO" ]]; then
            temp="frozen"
        else
            temp="cold"
        fi

        # Update frontmatter if temperature field exists, otherwise add it
        if grep -q "^temperature:" "$f" 2>/dev/null; then
            # Only update if changed
            local current=$(grep "^temperature:" "$f" | head -1 | sed 's/temperature: *//')
            if [ "$current" != "$temp" ]; then
                sed -i'' "s/^temperature: .*/temperature: $temp/" "$f"
                echo "  $name: $current → $temp (links: $incoming, recent: $recent)"
            fi
        else
            # Add temperature after the last frontmatter field (before closing ---)
            sed -i'' "/^---$/,/^---$/{
                /^---$/{
                    x
                    /^$/!{
                        x
                        i\\
temperature: $temp
                        b
                    }
                    x
                }
            }" "$f"
            # Simpler approach: just add before closing ---
            # Only do this for files that have frontmatter
            if grep -c "^---$" "$f" | grep -q "2"; then
                echo "  $name: NEW → $temp (links: $incoming, recent: $recent)"
            fi
        fi
    done
}

for folder in Canon/People Canon/Events Canon/Concepts Canon/Decisions Canon/Projects Canon/Actions; do
    [ -d "$VAULT_DIR/$folder" ] && process_folder "$VAULT_DIR/$folder"
done

echo "Temperature update complete: $DATE"
