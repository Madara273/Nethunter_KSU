#!/bin/bash

# === Configure ===
SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=true
LATESTARTSERVICE=false

# === Variables ===
[ -z "$TMPDIR" ] && TMPDIR=/dev/tmp
[ ! -z "$ZIP" ] && { ZIPFILE="$ZIP"; unset ZIP; }
[ -z "$ZIPFILE" ] && ZIPFILE="$3"
DIR=$(dirname "$ZIPFILE")
TMP="$TMPDIR/$MODID"

# === Functions ===
file_getprop() {
	grep "^$2" "$1" | head -n1 | cut -d= -f2-
}

set_perm() {
	chown "$2:$3" "$1" || return 1
	chmod "$4" "$1" || return 1
	chcon "${5:-u:object_r:system_file:s0}" "$1" || return 1
}

set_perm_recursive() {
	find "$1" -type d 2>/dev/null | while read -r dir; do
		set_perm "$dir" "$2" "$3" "$4" "$6"
	done
	find "$1" -type f -o -type l 2>/dev/null | while read -r file; do
		set_perm "$file" "$2" "$3" "$5" "$6"
	done
}

symlink() {
	ln -sf "$1" "$2" 2>/dev/null
	chmod 755 "$2" 2>/dev/null
}

set_wallpaper() {
	[ -d "$TMP/wallpaper" ] || return 1
	ui_print "Installing NetHunter wallpaper"

	local wp="/data/system/users/0/wallpaper"
	local wpinfo="${wp}_info.xml"

	local res res_w res_h
	res=$(wm size 2>/dev/null | grep "Physical size:" | cut -d' ' -f3)
	res_w=$(echo "$res" | cut -dx -f1)
	res_h=$(echo "$res" | cut -dx -f2)

	if [ -z "$res_w" ] || [ -z "$res_h" ]; then
		res_w=$(cat /sys/class/drm/*/modes | head -n1 | cut -dx -f1)
		res_h=$(cat /sys/class/drm/*/modes | head -n1 | cut -dx -f2)
		res="${res_w}x${res_h}"
	fi

	if [ -z "$res" ]; then
		ui_print "Can't get screen resolution of device. Skipping..."
		return 1
	fi

	ui_print "Found screen resolution: $res"

	local wallpaper_path="$TMP/wallpaper/$res.png"
	[ ! -f "$wallpaper_path" ] && {
		ui_print "No wallpaper found for your screen resolution. Skipping..."
		return 1
	}

	local setup_wp=0
	[ ! -f "$wp" ] || [ ! -f "$wpinfo" ] && setup_wp=1

	cat "$wallpaper_path" > "$wp"
	echo "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" > "$wpinfo"
	echo "<wp width=\"$res_w\" height=\"$res_h\" name=\"nethunter.png\" />" >> "$wpinfo"

	if [ "$setup_wp" = 1 ]; then
		chown system:system "$wp" "$wpinfo"
		chmod 600 "$wp" "$wpinfo"
		chcon "u:object_r:wallpaper_file:s0" "$wp"
		chcon "u:object_r:system_data_file:s0" "$wpinfo"
	fi

	ui_print "NetHunter wallpaper applied successfully"
}

f_kill_pids() {
	local pids
	pids=$(lsof 2>/dev/null | grep "$PRECHROOT" | awk '{print $2}' | sort -u)
	[ -n "$pids" ] && kill -9 $pids 2>/dev/null
}

f_restore_setup() {
	sysctl -w kernel.shmmax=134217728 2>/dev/null
	rm -rf "$PRECHROOT"/tmp/.X11* "$PRECHROOT"/tmp/.X*-lock "$PRECHROOT"/root/.vnc/.pid "$PRECHROOT"/root/.vnc/.log 2>/dev/null
}

f_umount_fs() {
	local path="$PRECHROOT/$1"
	local isAllunmounted=0

	if mountpoint -q "$path"; then
		umount -f "$path" || isAllunmounted=1
		[ "$1" != "dev/pts" ] && [ "$1" != "dev/shm" ] && rm -rf "$path"
	else
		[ -d "$path" ] && rm -rf "$path"
	fi
}

f_dir_umount() {
	sync
	ui_print "Killing all running processes..."
	f_kill_pids
	f_restore_setup
	ui_print "Removing all filesystem mounts..."
	for i in dev/pts dev/shm dev proc sys system; do
		f_umount_fs "$i"
	done
	umount -l "$PRECHROOT/sdcard" && rm -rf "$PRECHROOT/sdcard"
}

f_is_mntpoint() {
	[ -d "$PRECHROOT" ] && mountpoint -q "$PRECHROOT"
}

do_umount() {
	if ! f_is_mntpoint; then
		f_dir_umount
	fi

	if ! grep -q "$PRECHROOT" /proc/mounts; then
		ui_print "All mount points unmounted."
		return 0
	else
		ui_print "Some mount points were not unmounted."
		return 1
	fi
}

verify_fs() {
	case "$FS_ARCH" in armhf|arm64|i386|amd64) ;; *) return 1 ;; esac
	case "$FS_SIZE" in full|minimal|nano) ;; *) return 1 ;; esac
	return 0
}

# === Fix roofs installation ===
do_chroot() {
	NHSYS=/data/local/nhsystem

	[ -f "$ZIPFILE" ] || {
		ui_print "ZIP archive not found: $ZIPFILE"
		return 0
	}

	KALIFS=$(unzip -lqq "$ZIPFILE" | awk '$4 ~ /^kalifs-/ { print $4; exit }')

	if [ -z "$KALIFS" ]; then
		ui_print "No Kali rootfs found in archive. Skipping rootfs installation..."
		return 0
	fi

	FS_SIZE=$(echo "$KALIFS" | awk -F[-.] '{print $2}')
	FS_ARCH=$(echo "$KALIFS" | awk -F[-.] '{print $3}')

	if verify_fs; then
		do_install
	else
		ui_print "Invalid rootfs (size: $FS_SIZE, arch: $FS_ARCH). Skipping installation..."
		return 0
	fi
}

do_install() {
	ui_print "📦 Installing Kali rootfs..."

	mkdir -p "$NHSYS"

	if ! unzip -j "$ZIPFILE" "$KALIFS" -d "$TMP"; then
		ui_print "Failed to extract $KALIFS from archive. Aborting..."
		return 1
	fi

	if ! tar -xJf "$TMP/$KALIFS" -C "$NHSYS"; then
		ui_print "Failed to extract tarball. Aborting..."
		return 1
	fi

	ui_print "✅ Kali rootfs installed to $NHSYS"
}

# === Setup ===
UMASK=$(umask)
umask 022
mkdir -p "$TMPDIR"
cd "$TMPDIR"
unzip -jo "$ZIPFILE" module.prop -d "$TMPDIR" >&2
MODID=$(file_getprop module.prop id)

ui_print "------------------------------------------------"
ui_print "        Kali NetHunter KernelSu Installer       "
ui_print "------------------------------------------------"

ui_print "Unpacking the installer..."
mkdir -p "$TMP"
cd "$TMP"
unzip -qq "$ZIPFILE" -x "kalifs-*"

getenforce | grep -q "Enforcing" && ENFORCE=true || ENFORCE=false
$ENFORCE && setenforce 0
VERIFY=$(settings get global verifier_verify_adb_installs)
settings put global verifier_verify_adb_installs 0

ui_print "Removing previous NetHunter apps..."
rm -rf /sdcard/nh_files
for pkg in com.offsec.nethunter com.offsec.nethunter.kex com.offsec.nhterm com.offsec.nethunter.store; do
	pm uninstall "$pkg" &>/dev/null
done

ui_print "Installing apps..."
for apk in NetHunter NetHunterTerminal NetHunterKeX; do
	ui_print "- Installing ${apk}.apk"
	pm install "$TMP/data/app/${apk}.apk" &>/dev/null
done
ui_print "- Installing NetHunter Store and Privileged Extension"
pm install -g "$TMP/data/app/NetHunterStore.apk" &>/dev/null
pm install -g "$TMP/data/app/NetHunterStorePrivilegedExtension.apk" &>/dev/null

ui_print "Done installing apps."

ui_print "Setting up busybox to automatically mount at startup"

ui_print "Extracting firmware files"
unzip -o "$ZIPFILE" 'system/*' -d "$MODPATH" >&2

ui_print "Granting permissions to NetHunter app"
for perm in \
	android.permission.INTERNET \
	android.permission.ACCESS_WIFI_STATE \
	android.permission.CHANGE_WIFI_STATE \
	android.permission.READ_EXTERNAL_STORAGE \
	android.permission.WRITE_EXTERNAL_STORAGE \
	android.permission.RECEIVE_BOOT_COMPLETED \
	android.permission.WAKE_LOCK \
	android.permission.VIBRATE \
	android.permission.FOREGROUND_SERVICE \
	com.offsec.nhterm.permission.RUN_SCRIPT \
	com.offsec.nhterm.permission.RUN_SCRIPT_SU \
	com.offsec.nhterm.permission.RUN_SCRIPT_NH \
	com.offsec.nhterm.permission.RUN_SCRIPT_NH_LOGIN
do
	pm grant -g com.offsec.nethunter "$perm"
done

do_chroot

settings put global verifier_verify_adb_installs "$VERIFY"
$ENFORCE && setenforce 1

for TARGET in $REPLACE; do
	ui_print "- Replace target: $TARGET"
	mktouch "$MODPATH$TARGET/.replace"
done

umask "$UMASK"

ui_print "------------------------------------------------"
ui_print "        Kali NetHunter is now installed!        "
ui_print "================================================"
ui_print "    Please update the NetHunter app via the     "
ui_print "    NetHunter Store to fix Android permission   "
ui_print "    issues and finish the setup!                "
ui_print "------------------------------------------------"

set_permissions() {
	set_perm_recursive "$MODPATH" 0 0 0755 0644
}
