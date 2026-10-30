#!/bin/sh
# Regenerate the test fixture debs (requires dpkg-deb).
# Fixtures contain only placeholder files, never real build output; --root-owner-group keeps the local user name out of tar headers.
set -eu

cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# build <output file> <data compression> <control contents> [rootless]
build() {
  out=$1 compression=$2 control=$3 prefix=${4:+/var/jb}
  root="$work/$out"
  mkdir -p "$root/DEBIAN" "$root$prefix/Library/MobileSubstrate/DynamicLibraries"
  printf '%s\n' "$control" > "$root/DEBIAN/control"
  echo placeholder > "$root$prefix/Library/MobileSubstrate/DynamicLibraries/Placeholder.txt"
  dpkg-deb --root-owner-group -Z"$compression" -b "$root" "$out" > /dev/null
}

dockpages() {
  cat <<EOF
Package: to.define.dockpages
Name: DockPages
Version: $1
Architecture: iphoneos-arm64e
Description: Paged, swipeable dock with 8 icons (2 pages x 4).
Maintainer: Sion
Author: Sion
Section: Tweaks
Depends: mobilesubstrate (>= 0.9.5000)
EOF
}

sample='Package: com.example.sample
Name: Sample
Version: 1:2.0~beta1-3
Architecture: iphoneos-arm64
Maintainer: Example <dev@example.com>
Author: Example
Section: Tweaks
Description: Sample rootless package
 Long description line one.
 .
 Line after blank.'

build dockpages-roothide.deb gzip "$(dockpages 0.1.0)"
build dockpages-debug.deb gzip "$(dockpages 0.1.0-1+debug)"
build sample-rootless.deb gzip "$sample" rootless
build sample-xz.deb xz "$sample" rootless
