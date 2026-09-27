#!/bin/sh
# Auto-executed on Lyrion Docker container startup (/config/custom-init.sh).
# Applies mai-artist-names.patch to the Music & Artist Information (MAI) plugin, so artists
# tagged "Family, Given" (eg. composers) get the same picture as "Given Family" (performers).
#
# Safe to run on every start:
#   - patch already applied          -> nothing to do
#   - plugin updated, patch fits     -> re-applied
#   - plugin changed, patch no fit   -> NOT applied (no partial patching), logged
#
# Regenerate the patch from the fork (github.com/arigit/MusicArtistInfo):
#   git diff upstream/master artist-name-normalization -- '*.pm' > docker/mai-artist-names.patch
#
# Check the result:
#   docker logs lyrion 2>&1 | grep -i 'MAI patch'

if [ -f "/.dockerenv" ]; then
    # running inside the Docker container
    MAI="/config/cache/InstalledPlugins/Plugins/MusicArtistInfo"
    PATCH="/config/mai-artist-names.patch"
else
    # running on the host directly
    MAI="/home/homeassistant/lyrion/cache/InstalledPlugins/Plugins/MusicArtistInfo"
    PATCH="/home/homeassistant/lyrion/mai-artist-names.patch"
fi

log() { echo "MAI patch: $*"; }

if [ ! -d "$MAI" ]; then
    log "plugin not installed at $MAI - skipping"
elif [ ! -f "$PATCH" ]; then
    log "patch file $PATCH not found - skipping"
else
    VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$MAI/install.xml" 2>/dev/null)

    # if the patch can be reversed cleanly, it's already in place
    if patch -p1 -R --dry-run --force -s -d "$MAI" < "$PATCH" >/dev/null 2>&1; then
        log "already applied to MAI $VERSION"
    # only apply if every hunk fits - never leave the plugin half-patched
    elif OUT=$(patch -p1 --forward --dry-run --force -d "$MAI" < "$PATCH" 2>&1); then
        patch -p1 --forward --force --no-backup-if-mismatch -r - -d "$MAI" < "$PATCH" | sed 's/^/MAI patch: /'
        # patch re-creates the files as root - hand them back to the server user
        chown --reference="$MAI" "$MAI"/*.pm 2>/dev/null
        log "applied to MAI $VERSION"
    else
        log "does NOT fit MAI $VERSION - plugin left unpatched. Patch needs updating:"
        echo "$OUT" | sed 's/^/MAI patch:   /'
    fi
fi

# never block the server startup
exit 0
