# Shared by the sunairies-* tools (sourced, not run). SunairiesOS keeps its
# root filesystem as read-only versions on the data partition:
#
#   $STORE/layers/<sha256>.erofs   one read-only image per OCI layer, shared
#   $STORE/versions/<id>/          one bootable system:
#       layers         its layers, bottom first
#       vmlinuz initrd.img
#       image          where it came from (registry reference, or "local")
#       image-id       its podman image ID
#       base-image-id  the image ID it was fetched as (layered versions keep
#                      their base's), so an update knows when nothing changed
#   $STORE/grubenv     current=, staged=, tried= : the only state GRUB reads
#   $STORE/grub.cfg    the boot menu
#
# Version IDs are dates: 2026.10.27, then 2026.10.27.2, ...

SUNAIRIES_DATA=${SUNAIRIES_DATA:-/run/sunairies/data}
STORE=$SUNAIRIES_DATA/sunairies
LAYERS=$STORE/layers
VERSIONS=$STORE/versions
GRUBENV=$STORE/grubenv
REPO=localhost/sunairiesos       # podman tag of each version: $REPO:<id>
LIB=${SUNAIRIES_LIB:-/usr/lib/sunairies}
ETC=${SUNAIRIES_ETC:-/etc/sunairies}

prog=${0##*/}
die() { echo "$prog: $*" >&2; exit 1; }
say() { [ -z "${QUIET:-}" ] && echo "$prog: $*" >&2; return 0; }

env_get() { grub-editenv "$GRUBENV" list 2>/dev/null | sed -n "s/^$1=//p"; }
env_set() { grub-editenv "$GRUBENV" set "$@"; }
env_unset() { grub-editenv "$GRUBENV" unset "$@"; }

booted() { sed -n 's/.*sunairies\.version=\([^ ]*\).*/\1/p' /proc/cmdline; }
current() { env_get current; }
staged() { env_get staged; }

versions() { ls "$VERSIONS" 2>/dev/null | grep -v '\.part$' | sort -V; }

# A new version ID: today's date, numbered when there already was one today.
# IDs are never reused, even after their version is removed.
new_version_id() {
  d=$(date -u +%Y.%m.%d) last=$(cat "$STORE/last-version" 2>/dev/null || true) n=1
  case "$last" in "$d") n=2 ;; "$d".*) n=$((${last##*.} + 1)) ;; esac
  id=$d; [ "$n" -gt 1 ] && id=$d.$n
  while [ -e "$VERSIONS/$id" ] || [ -e "$VERSIONS/$id.part" ]; do n=$((n + 1)) id=$d.$n; done
  echo "$id" > "$STORE/last-version"
  echo "$id"
}

# Mount VERSION_DIR's layers at DIR/0, DIR/1, ... and set $lower to the
# overlayfs lowerdir for them, relative to DIR (top first): the kernel takes
# at most 256 bytes per mount option, which full paths of many layers exceed.
mount_layers() { # VERSION_DIR DIR
  lower="" i=0
  while read -r id; do
    [ -n "$id" ] || continue
    mkdir -p "$2/$i"
    mount -t erofs -o ro "$LAYERS/$id.erofs" "$2/$i" 2>/dev/null \
      || mount -t erofs -o ro,loop "$LAYERS/$id.erofs" "$2/$i" || return 1
    lower="$i${lower:+:$lower}" i=$((i + 1))
  done < "$1/layers"
}

# Mount VERSION_DIR's root, read-only, at DIR/root; unmount with
# umount_version DIR.
mount_version() { # VERSION_DIR DIR
  mount_layers "$1" "$2" || return 1
  mkdir -p "$2/root"
  if [ "$i" -eq 1 ]; then mount --bind "$2/0" "$2/root"
  else (cd "$2" && mount -t overlay -o ro,lowerdir="$lower" sunairies-version "$2/root"); fi
}
umount_version() { # DIR
  umount "$1/root" 2>/dev/null
  for d in "$1"/[0-9]*; do umount "$d" 2>/dev/null; done
  rm -rf "$1"
}

# save_layer FROM W ORIGIN: W/upper (the writable layer over FROM's layers,
# mounted at W/root) as a new version on top of FROM; prints its ID. ORIGIN
# goes in its image file.
save_layer() {
  rm -rf "$2/upper/run" "$2/upper/tmp"
  _v=$(new_version_id)
  _part=$VERSIONS/$_v.part
  mkdir -p "$_part"
  _tmp=$LAYERS/layer.erofs.part
  mkfs.erofs --quiet -zlz4 "$_tmp" "$2/upper" || return 1
  _l=$(sha256sum "$_tmp" | cut -c1-64)
  mv "$_tmp" "$LAYERS/$_l.erofs"
  cat "$VERSIONS/$1/layers" > "$_part/layers"
  echo "$_l" >> "$_part/layers"
  # A kernel upgrade changes /boot: take the new version's kernel.
  _k=$(ls "$2/root"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
  if [ -n "$_k" ] && [ -e "$2/root/boot/initrd.img-${_k##*/vmlinuz-}" ]; then
    cp "$_k" "$_part/vmlinuz"
    cp "$2/root/boot/initrd.img-${_k##*/vmlinuz-}" "$_part/initrd.img"
  else
    cp "$VERSIONS/$1/vmlinuz" "$VERSIONS/$1/initrd.img" "$_part/"
  fi
  echo "$3" > "$_part/image"
  cp "$VERSIONS/$1/base-image-id" "$_part/" 2>/dev/null || true
  mv "$_part" "$VERSIONS/$_v"
  echo "$_v"
}

# Accounts: /etc/passwd, group, shadow, gshadow. This machine's /etc holds its
# own copy (its users), which hides each version's: so the accounts a
# version's packages made (sddm, colord, ...) are added to the machine's, and
# package changes run with the machine's accounts, so that packages find the
# users and groups the machine has, with their IDs, and new ones get free IDs.
ACCOUNTS="passwd group shadow gshadow"

# accounts_merge NEW BEFORE FILE: FILE, with NEW's line for every name whose
# line NEW changed from BEFORE, and NEW's names that BEFORE lacks added.
accounts_merge() {
  awk -F: '
    FILENAME == ARGV[1] { n[$1] = $0; order[++k] = $1; next }
    FILENAME == ARGV[2] { b[$1] = $0; next }
    { if (($1 in n) && ($1 in b) && n[$1] != b[$1]) print n[$1]; else print; seen[$1] }
    END { for (j = 1; j <= k; j++) { x = order[j]; if (!(x in b) && !(x in seen)) print n[x] } }
  ' "$1" "$2" "$3"
}

# accounts_add ROOT: the accounts of ROOT (a version) this machine lacks,
# added to it.
accounts_add() {
  _none=$(mktemp)   # (0600, as the copies of shadow made here)
  for _f in $ACCOUNTS; do
    [ -f "$1/etc/$_f" ] && [ -f "/etc/$_f" ] || continue
    accounts_merge "$1/etc/$_f" "$_none" "/etc/$_f" > "$_none.new"
    cmp -s "$_none.new" "/etc/$_f" || cat "$_none.new" > "/etc/$_f"
  done
  rm -f "$_none" "$_none.new"
}

# accounts_in ROOT STATE: ROOT (a version's root, about to change) gets this
# machine's accounts, and its own the machine lacks. STATE keeps what it had.
accounts_in() {
  mkdir -p "$2" && chmod 700 "$2"
  _none=$(mktemp)
  for _f in $ACCOUNTS; do
    [ -f "$1/etc/$_f" ] && [ -f "/etc/$_f" ] || continue
    cp -p "$1/etc/$_f" "$2/$_f"
    accounts_merge "$2/$_f" "$_none" "/etc/$_f" > "$2/$_f.in"
    cat "$2/$_f.in" > "$1/etc/$_f"
  done
  rm -f "$_none"
}

# accounts_out ROOT STATE: what the change did to the accounts, kept in ROOT
# (its own accounts, not the machine's users) and given to this machine.
accounts_out() {
  for _f in $ACCOUNTS; do
    [ -f "$2/$_f" ] || continue
    accounts_merge "$1/etc/$_f" "$2/$_f.in" "/etc/$_f" > "$2/$_f.machine"
    cmp -s "$2/$_f.machine" "/etc/$_f" || cat "$2/$_f.machine" > "/etc/$_f"
    accounts_merge "$1/etc/$_f" "$2/$_f.in" "$2/$_f" > "$2/$_f.out"
    cat "$2/$_f.out" > "$1/etc/$_f"
  done
  accounts_add "$1"
}

# The store's boot menu. GRUB boots `staged` once (setting `tried`), and
# `current` otherwise; a staged version that never got committed falls back.
write_grub_cfg() {
  cat > "$STORE/grub.cfg.part" <<'EOF'
# SunairiesOS. Written by sunairies-*; the state is in grubenv.
load_env -f $sg/grubenv
set version="$current"
set timeout=0
if [ -n "$staged" ]; then
  if [ -z "$tried" ]; then
    set tried=1
    save_env -f $sg/grubenv tried
    set version="$staged"
  else
    # It booted once and was never committed: back to the current version.
    set staged=
    set tried=
    save_env -f $sg/grubenv staged tried
    set timeout=5
  fi
fi
# Hold Shift (or Esc) while starting to see the menu.
if [ "$timeout" = 0 ]; then
  if keystatus --shift; then set timeout=-1; fi
fi
function sunairies_boot {
  echo "SunairiesOS $1"
  linux $sg/versions/$1/vmlinuz boot=sunairies sunairies.version=$1 init=/usr/bin/dinit $cmdline
  initrd $sg/versions/$1/initrd.img
}
menuentry "SunairiesOS $version" { sunairies_boot "$version" }
if [ "$version" != "$current" ]; then
  menuentry "SunairiesOS $current (current)" { sunairies_boot "$current" }
fi
EOF
  mv "$STORE/grub.cfg.part" "$STORE/grub.cfg"
}

init_store() {
  mkdir -p "$LAYERS" "$VERSIONS" "$SUNAIRIES_DATA/etc" "$SUNAIRIES_DATA/var" \
    "$SUNAIRIES_DATA/home" "$SUNAIRIES_DATA/root" "$SUNAIRIES_DATA/containers"
  [ -f "$GRUBENV" ] || grub-editenv "$GRUBENV" create
  write_grub_cfg
}

# The empty mount points a root needs, and the image's own /etc/hostname and
# /etc/hosts (a container build cannot write those).
prepare_root() { # DIR
  for d in proc sys dev run tmp mnt media home root var/tmp; do mkdir -p "$1/$d"; done
  chmod 1777 "$1/tmp" "$1/var/tmp"
  [ -d "$1/usr/share/sunairies/etc" ] && cp -a "$1/usr/share/sunairies/etc/." "$1/etc/"
  return 0
}

# Mount version VERSION of the store on DATA at DIR/root as it boots: its
# layers read-only, /etc and /var with their writable layers from DATA, /home
# and /root from DATA. Undo with umount_installed DIR.
mount_installed() { # DATA VERSION DIR
  LAYERS=$1/sunairies/layers    # (this store's layers, for mount_version)
  mount_version "$1/sunairies/versions/$2" "$3" || return 1
  for d in etc var; do
    mkdir -p "$1/$d/upper" "$1/$d/work"
    mount -t overlay -o lowerdir="$3/root/$d",upperdir="$1/$d/upper",workdir="$1/$d/work" \
      "sunairies-$d" "$3/root/$d" || return 1
  done
  for d in home root; do
    mkdir -p "$1/$d"; mount --bind "$1/$d" "$3/root/$d" || return 1
  done
}
umount_installed() { # DIR
  for d in home root var etc; do umount "$1/root/$d" 2>/dev/null; done
  umount_version "$1"
}

# GRUB for the EFI system partition: finds the partition labelled
# sunairies-data and its boot menu (sunairies/grub.cfg).
write_efi_binary() { # GRUB_TARGET OUT
  stub=$(mktemp)
  cat > "$stub" <<'EOS'
search --no-floppy --label sunairies-data --set=root
set sg=($root)/sunairies
export root
export sg
configfile $sg/grub.cfg
EOS
  grub-mkstandalone -O "$1" -o "$2" \
    --modules="part_gpt part_msdos ext2 fat iso9660 search search_label search_fs_file configfile loadenv normal linux test echo gzio all_video keystatus" \
    --locales= --fonts= --themes= "boot/grub/grub.cfg=$stub"
  rm -f "$stub"
}
