#!/bin/bash
# Cleanup script for orphaned Longhorn VolumeSnapshots
# Generated: 2025-12-21
# These snapshots reference non-existent PVCs and are safe to delete

export KUBECONFIG="${KUBECONFIG:-./kubeconfig}"
KUBECTL="/home/linuxbrew/.linuxbrew/bin/kubectl"

echo "=== Longhorn Orphaned Snapshots Cleanup ==="
echo "This script will delete 96 orphaned VolumeSnapshots"
echo ""

# Download namespace (16 snapshots)
echo "Deleting download namespace snapshots..."
$KUBECTL delete volumesnapshot -n download \
  volsync-autobrr-dst-local-dest-20251219205828 \
  volsync-autobrr-dst-r2-dest-20251219205841 \
  volsync-autobrr-local-src \
  volsync-autobrr-r2-src \
  volsync-cross-seed-dst-local-dest-20251219205828 \
  volsync-cross-seed-dst-r2-dest-20251219205906 \
  volsync-cross-seed-local-src \
  volsync-cross-seed-r2-src \
  volsync-qbittorrent-dst-local-dest-20251219205832 \
  volsync-qbittorrent-dst-r2-dest-20251219205840 \
  volsync-qbittorrent-local-src \
  volsync-qbittorrent-r2-src \
  volsync-sabnzbd-dst-local-dest-20251219205828 \
  volsync-sabnzbd-dst-r2-dest-20251219205839 \
  volsync-sabnzbd-local-src \
  volsync-sabnzbd-r2-src --ignore-not-found=true

# Games namespace (8 snapshots)
echo "Deleting games namespace snapshots..."
$KUBECTL delete volumesnapshot -n games \
  volsync-satisfactory-dst-local-dest-20251219205803 \
  volsync-satisfactory-dst-r2-dest-20251219205647 \
  volsync-satisfactory-local-src \
  volsync-satisfactory-r2-src \
  volsync-valheim-dst-local-dest-20251219205852 \
  volsync-valheim-dst-r2-dest-20251217033734 \
  volsync-valheim-local-src \
  volsync-valheim-r2-src --ignore-not-found=true

# Infrastructure namespace (8 snapshots)
echo "Deleting infrastructure namespace snapshots..."
$KUBECTL delete volumesnapshot -n infrastructure \
  volsync-mosquitto-dst-local-dest-20251219205647 \
  volsync-mosquitto-dst-r2-dest-20251219205712 \
  volsync-mosquitto-local-src \
  volsync-mosquitto-r2-src --ignore-not-found=true

# Media namespace (64 snapshots)
echo "Deleting media namespace snapshots..."
$KUBECTL delete volumesnapshot -n media \
  volsync-audiobookshelf-dst-local-dest-20251219205713 \
  volsync-audiobookshelf-dst-r2-dest-20251219205733 \
  volsync-audiobookshelf-local-src \
  volsync-audiobookshelf-r2-src \
  volsync-bazarr-dst-local-dest-20251219205818 \
  volsync-bazarr-dst-r2-dest-20251219205834 \
  volsync-bazarr-local-src \
  volsync-bazarr-r2-src \
  volsync-calibre-web-dst-local-dest-20251219205647 \
  volsync-calibre-web-dst-r2-dest-20251219205647 \
  volsync-jellyfin-dst-local-dest-20251219205828 \
  volsync-jellyfin-dst-r2-dest-20251219205839 \
  volsync-jellyfin-local-src \
  volsync-jellyfin-r2-src \
  volsync-jellyseerr-dst-local-dest-20251219205828 \
  volsync-jellyseerr-dst-r2-dest-20251219205836 \
  volsync-jellyseerr-local-src \
  volsync-jellyseerr-r2-src \
  volsync-lidarr-dst-local-dest-20251219205748 \
  volsync-lidarr-dst-r2-dest-20251219205836 \
  volsync-lidarr-local-src \
  volsync-lidarr-r2-src \
  volsync-notifiarr-dst-local-dest-20251219205648 \
  volsync-notifiarr-dst-r2-dest-20251219205802 \
  volsync-notifiarr-local-src \
  volsync-notifiarr-r2-src \
  volsync-plex-dst-local-dest-20251219211328 \
  volsync-plex-dst-r2-dest-20251219211337 \
  volsync-plex-local-src \
  volsync-plex-r2-src \
  volsync-prowlarr-dst-local-dest-20251219205812 \
  volsync-prowlarr-dst-r2-dest-20251219205657 \
  volsync-prowlarr-local-src \
  volsync-prowlarr-r2-src \
  volsync-radarr-dst-local-dest-20251219205742 \
  volsync-radarr-dst-r2-dest-20251219205802 \
  volsync-radarr-local-src \
  volsync-radarr-r2-src \
  volsync-readarr-audiobooks-dst-local-dest-20251219205813 \
  volsync-readarr-audiobooks-dst-r2-dest-20251219205838 \
  volsync-readarr-audiobooks-local-src \
  volsync-readarr-audiobooks-r2-src \
  volsync-readarr-ebooks-dst-local-dest-20251219205818 \
  volsync-readarr-ebooks-dst-r2-dest-20251219205736 \
  volsync-readarr-ebooks-local-src \
  volsync-readarr-ebooks-r2-src \
  volsync-recyclarr-dst-local-dest-20251219205901 \
  volsync-recyclarr-dst-r2-dest-20251219205837 \
  volsync-recyclarr-local-src \
  volsync-recyclarr-r2-src \
  volsync-sonarr-dst-local-dest-20251219205804 \
  volsync-sonarr-dst-r2-dest-20251219205838 \
  volsync-sonarr-local-src \
  volsync-sonarr-r2-src \
  volsync-tautulli-dst-local-dest-20251219205735 \
  volsync-tautulli-dst-r2-dest-20251219205835 \
  volsync-tautulli-local-src \
  volsync-tautulli-r2-src \
  volsync-tdarr-dst-local-dest-20251219205653 \
  volsync-tdarr-dst-r2-dest-20251219205735 \
  volsync-tdarr-local-src \
  volsync-tdarr-r2-src --ignore-not-found=true

echo ""
echo "=== Cleanup Complete ==="
echo "Deleted 96 orphaned VolumeSnapshots"

