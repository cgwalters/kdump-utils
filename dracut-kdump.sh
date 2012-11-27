#!/bin/sh

. /lib/dracut-lib.sh

set -x
KDUMP_PATH="/var/crash"
CORE_COLLECTOR=""
DEFAULT_CORE_COLLECTOR="makedumpfile -c --message-level 1 -d 31"
DEFAULT_ACTION="dump_rootfs"
DATEDIR=`date +%d.%m.%y-%T`
DUMP_INSTRUCTION=""
SSH_KEY_LOCATION="/root/.ssh/kdump_id_rsa"
KDUMP_SCRIPT_DIR="/kdumpscripts"
DD_BLKSIZE=512
FINAL_ACTION="reboot -f"
DUMP_RETVAL=0
conf_file="/etc/kdump.conf"
KDUMP_PRE=""
KDUMP_POST=""

export PATH=$PATH:$KDUMP_SCRIPT_DIR

# we use manual setup nics in udev rules,
# so we need to test network is really ok
wait_for_net_ok() {
    local ip=$(getarg ip)
    local iface=`echo $ip|cut -d':' -f1`
    return $(wait_for_route_ok $iface)
}

do_default_action()
{
    wait_for_loginit
    $DEFAULT_ACTION
}

do_kdump_pre()
{
    if [ -n "$KDUMP_PRE" ]; then
        "$KDUMP_PRE"
    fi
}

do_kdump_post()
{
    if [ -n "$KDUMP_POST" ]; then
        "$KDUMP_POST" "$1"
    fi
}

add_dump_code()
{
    DUMP_INSTRUCTION=$1
}

dump_fs()
{
    local _mp=$(findmnt -k -f -n -r -o TARGET $1)

    if [ -z "$_mp" ]; then
        echo "kdump: error: Dump target $1 is not mounted."
        return 1
    fi
    if [ "$_mp" = "$NEWROOT/" ] || [ "$_mp" = "$NEWROOT" ]
    then
        mount -o remount,rw $_mp || return 1
    fi
    mkdir -p $_mp/$KDUMP_PATH/$DATEDIR || return 1
    $CORE_COLLECTOR /proc/vmcore $_mp/$KDUMP_PATH/$DATEDIR/vmcore || return 1
    umount $_mp || return 1
    return 0
}

dump_raw()
{
    [ -b "$1" ] || return 1

    echo "Saving to raw disk $1"
    if $(echo -n $CORE_COLLECTOR|grep -q makedumpfile); then
        _src_size_mb="Unknown"
    else
        _src_size=`ls -l /proc/vmcore | cut -d' ' -f5`
        _src_size_mb=$(($_src_size / 1048576))
    fi

    monitor_dd_progress $_src_size_mb &

    $CORE_COLLECTOR /proc/vmcore | dd of=$1 bs=$DD_BLKSIZE >> /tmp/dd_progress_file 2>&1 || return 1
    return ${PIPESTATUS[0]}
}

dump_rootfs()
{
    mount -o remount,rw $NEWROOT/ || return 1
    mkdir -p $NEWROOT/$KDUMP_PATH/$DATEDIR
    $CORE_COLLECTOR /proc/vmcore $NEWROOT/$KDUMP_PATH/$DATEDIR/vmcore || return 1
    sync
}

dump_ssh()
{
    local _opt="-i $1 -o BatchMode=yes -o StrictHostKeyChecking=yes"
    local _dir="$KDUMP_PATH/$DATEDIR"

    cat /var/lib/random-seed > /dev/urandom
    ssh -q $_opt $2 mkdir -p $_dir || return 1

    if [ "${CORE_COLLECTOR%% *}" = "scp" ]; then
        scp -q $_opt /proc/vmcore "$2:$_dir/vmcore-incomplete" || return 1
        ssh $_opt $2 "mv $_dir/vmcore-incomplete $_dir/vmcore" || return 1
    else
        $CORE_COLLECTOR /proc/vmcore | ssh $_opt $2 "dd bs=512 of=$_dir/vmcore-incomplete" || return 1
        ssh $_opt $2 "mv $_dir/vmcore-incomplete $_dir/vmcore.flat" || return 1
    fi
}

is_ssh_dump_target()
{
    grep -q "^ssh[[:blank:]].*@" $conf_file
}

is_raw_dump_target()
{
    grep -q "^raw" $conf_file
}

read_kdump_conf()
{
    if [ ! -f "$conf_file" ]; then
        echo "$conf_file not found"
        return
    fi

    # first get the necessary variables
    while read config_opt config_val;
    do
        case "$config_opt" in
        path)
        KDUMP_PATH="$config_val"
            ;;
        core_collector)
            [ -n "$config_val" ] && CORE_COLLECTOR="$config_val"
            ;;
        sshkey)
            if [ -f "$config_val" ]; then
                SSH_KEY_LOCATION=$config_val
            fi
            ;;
        kdump_pre)
            KDUMP_PRE="$config_val"
            ;;
        kdump_post)
            KDUMP_POST="$config_val"
            ;;
        default)
            case $config_val in
                shell)
                    DEFAULT_ACTION="_emergency_shell kdump"
                    ;;
                reboot)
                    DEFAULT_ACTION="reboot -f"
                    ;;
                halt)
                    DEFAULT_ACTION="halt -f"
                    ;;
                poweroff)
                    DEFAULT_ACTION="poweroff -f"
                    ;;
            esac
            ;;
        esac
    done < $conf_file

    # rescan for add code for dump target
    while read config_opt config_val;
    do
        case "$config_opt" in
        ext[234]|xfs|btrfs|minix|nfs)
            add_dump_code "dump_fs $config_val"
            ;;
        raw)
            add_dump_code "dump_raw $config_val"
            ;;
        ssh)
            wait_for_net_ok
            add_dump_code "dump_ssh $SSH_KEY_LOCATION $config_val"
            ;;
        esac
    done < $conf_file
}

read_kdump_conf

if [ -z "$CORE_COLLECTOR" ];then
    CORE_COLLECTOR=$DEFAULT_CORE_COLLECTOR
    if is_ssh_dump_target || is_raw_dump_target; then
        CORE_COLLECTOR="$CORE_COLLECTOR -F"
    fi
fi

if [ -z "$DUMP_INSTRUCTION" ]; then
    add_dump_code "dump_rootfs"
fi

do_kdump_pre
if [ $? -ne 0 ]; then
    echo "kdump_pre script exited with non-zero status!"
    $FINAL_ACTION
fi

$DUMP_INSTRUCTION
DUMP_RETVAL=$?

do_kdump_post $DUMP_RETVAL
if [ $? -ne 0 ]; then
    echo "kdump_post script exited with non-zero status!"
fi

if [ $DUMP_RETVAL -ne 0 ]; then
    do_default_action
fi

$FINAL_ACTION