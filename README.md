USAGE: ./autorip.sh

This script automatically detects the optical disc in `disc:0`, rips long titles directly to MKV using MakeMKV (skipping full-disc backups), selects the largest title as the main feature, and optionally encodes it with HandBrakeCLI. It can also transfer the file to a remote host and trigger a simple HTTP notification.

Requirements:
- makemkvcon
- HandBrakeCLI
- awk, sed, grep
- Optional: blkid (for filesystem label lookup), curl (for notification), scp (for remote transfer)

Environment variables (optional):
- TMPDIR: Base working directory (default `/mnt/backup/tmp`)
- DEST_DIR: Output destination directory (default `TMPDIR`)
- REMOTE_DEST: If set, scp destination like `host:/path`
- SSH_KEY: Path to ssh key for scp (default `~/.ssh/utility`)
- TITLE_MINLENGTH: Minimum title length in seconds for ripping (default `1800`)
- HB_QUALITY: HandBrake constant quality, lower = better (default `20`)
- HB_SUBS_ARGS: HandBrake subtitle args (default `--subtitle 1`; examples: `--all-subtitles`)
- SKIP_ENCODE: If `1`, skip HandBrake and keep MakeMKV MKV (default `0`)
- NOTIFY_URL: If set, will GET `${NOTIFY_URL}/<message>` when done

Examples:
```bash
# Simple local rip + encode
./autorip.sh

# Faster path: keep MakeMKV main title without re-encode
SKIP_ENCODE=1 ./autorip.sh

# Custom paths and remote transfer
DEST_DIR=/media/videos REMOTE_DEST=mythbackend:/var/lib/mythtv/videos ./autorip.sh

# Higher quality encode with all subtitles
HB_QUALITY=18 HB_SUBS_ARGS="--all-subtitles" ./autorip.sh
```
