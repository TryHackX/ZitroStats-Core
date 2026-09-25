#!/bin/sh
# Builds zitrostats_dll.so for the 32-bit Soldat server on Linux.
# Compiler output stays in build/i386-linux; only the finished library is copied to the
# script folder (one level up), which is where main.pas loads it from.
#
# It needs Free Pascal 3.2.2 for i386-linux with all its packages, the linker and the 32-bit C
# library files. On a 64-bit Debian or Ubuntu, the official release has everything:
#   sudo apt-get install binutils libc6-dev-i386
#   wget https://downloads.sourceforge.net/project/freepascal/Linux/3.2.2/fpc-3.2.2.i386-linux.tar
#   tar xf fpc-3.2.2.i386-linux.tar && cd fpc-3.2.2.i386-linux && sudo ./install.sh
#
#   sh build.sh          the library for the server
#   sh build.sh debug    with range, overflow and object checks and line numbers (slower)
#   FPCUNITS=/usr/local/lib/fpc/3.2.2/units/i386-linux sh build.sh
#                        reads the packages from that folder, whatever fpc.cfg says
#
# Without FPCUNITS the packages are taken from beside the compiler itself: a Free Pascal of a
# distribution (Debian, Ubuntu) often has an fpc.cfg that names only its own 64-bit folders,
# and ppc386 from the official release then finds its RTL but none of its packages.
set -e
cd "$(dirname "$0")"

FPC=${FPC:-fpc}
# the packages of the compiler that will run: <prefix>/lib/fpc/<version>/ppc386 has them in
# <prefix>/lib/fpc/<version>/units/i386-linux
if [ -z "$FPCUNITS" ]; then
  ppc=$("$FPC" -Pi386 -PB 2>/dev/null | head -n 1) || ppc=
  case $ppc in
    /*) ;;
    ?*) ppc=$(command -v "$ppc" 2>/dev/null) || ppc= ;;
  esac
  if [ -n "$ppc" ]; then
    ppc=$(readlink -f "$ppc" 2>/dev/null) || ppc=
    if [ -n "$ppc" ] && [ -d "${ppc%/*}/units/i386-linux/rtl-objpas" ]; then
      FPCUNITS=${ppc%/*}/units/i386-linux
      echo "build.sh: packages from $FPCUNITS"
    fi
  fi
fi
UNITPATH=${FPCUNITS:+-Fu$FPCUNITS/*}
OPTS="-O2 -Xs -XX -CX"
if [ "$1" = "debug" ]; then
  OPTS="-O1 -gl -gw -Cr -Co -Ci -CX"
fi
OUT=build/i386-linux
mkdir -p "$OUT"

# A tiny library with the same units first: a missing package is named here, with the way to
# get it, instead of stopping the real build halfway.
probe=build/probe.$$
mkdir -p "$probe"
printf 'library probe;\nuses cthreads, BaseUnix, Unix, %s;\nbegin\nend.\n' \
  'SysUtils, Classes, Math, StrUtils, process, base64, sockets, ssockets, sha1' > "$probe/probe.pas"
if ! log=$("$FPC" -Pi386 -Tlinux ${UNITPATH:+"$UNITPATH"} -FU"$probe" -FE"$probe" "$probe/probe.pas" 2>&1); then
  rm -rf "$probe"
  printf '%s\n' "$log" | grep -E 'Fatal:|Error:|cannot find' | head -n 3
  case $log in
    *"Can't find unit"*)
      echo "build.sh: Free Pascal does not find the i386-linux package of the unit named above."
      echo "  Install the whole fpc-3.2.2.i386-linux.tar (see the top of this file), or tell"
      echo "  build.sh where its units are: FPCUNITS=/usr/local/lib/fpc/3.2.2/units/i386-linux sh build.sh" ;;
    *"cannot find"*|*"Error while linking"*)
      echo "build.sh: linking failed: sudo apt-get install binutils libc6-dev-i386" ;;
    *) echo "build.sh: '$FPC -Pi386' failed: are ppc386 and ld (binutils) installed?" ;;
  esac
  exit 1
fi
rm -rf "$probe"

# the MySQL mirror is always part of the library and needs nothing else on the server
"$FPC" -B -Pi386 -Tlinux -Mobjfpc -Sh $OPTS ${UNITPATH:+"$UNITPATH"} -FU"$OUT" -FE"$OUT" -ozitrostats_dll.so zs_main.pas
cp -f "$OUT/zitrostats_dll.so" ../zitrostats_dll.so
chmod 755 ../zitrostats_dll.so
echo "Built ../zitrostats_dll.so"
