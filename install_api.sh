#!/usr/bin/env bash

# Copyright (C) 2015-2016 Wazuh, Inc.All rights reserved.
# Wazuh.com
# This program is a free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public
# License (version 2) as published by the FSF - Free Software
# Foundation.

# Installer for Wazuh API
# Wazuh Inc.
#
# Usage:
#  ./install_api.sh [dependencies|download|dev]
#  ./install_api.sh                Install API from current path
#  ./install_api.sh dependencies   List dependencies
#  ./install_api.sh download       Download and install lastest release (stable branch)
#  ./install_api.sh dev            Install API from current path in development mode


arg=$1  # emtpy, help, dependencies, download or dev

# Aux functions
print() {
    echo -e $1
}

error_and_exit() {
    print "Error executing command: '$1'.\n"

    if [ "X${API_BACKUP}" == "Xyes" ]; then
        print "Backup directory: $API_PATH_BACKUP"
        print "Restore backup:"
        print "\t1. rm -r $API_PATH"
        print "\t2. mv $API_PATH_BACKUP $API_PATH"
        print "\t3. chown ossec:ossec $API_PATH"
    fi

    if [ -d "/root/wazuh-api-tmp" ]; then
        exec_cmd "rm -rf /root/wazuh-api-tmp"
    fi

    print "\nExiting."
    exit 1
}

exec_cmd() {
    eval $1 > /dev/null 2>&1 || error_and_exit "$1"
}

exec_cmd_bash() {
    bash -c "$1" || error_and_exit "$1"
}

get_configuration_value () { # $1 setting
    cat "$API_PATH/configuration/config.js" | grep -P "config.$1\s*=\s*\"" | grep -P '".*"' -o | tr -d '"'
}

edit_configuration() { # $1 -> setting,  $2 -> value
    sed -i "s/^config.$1\s=.*/config.$1 = \"$2\";/g" "$API_PATH/configuration/config.js" || error_and_exit "sed (editing configuration)"
}

get_type_service() {
    if [ -n "$(ps -e | egrep ^\ *1\ .*systemd$)" ]; then
        echo "systemctl"
    else
        echo "service"
    fi
}

url_lastest_release () {
    LATEST_RELEASE=$(curl -L -s -H 'Accept: application/json' https://github.com/$1/$2/releases/latest)
    #LATEST_VERSION=$(echo $LATEST_RELEASE | sed -e 's/.*"tag_name":"\(.*\)".*/\1/')
    LATEST_VERSION=$(echo $LATEST_RELEASE | grep -P "\"tag_name\":\".+\"update_url" -o | grep -P "v\d+\.\d+\.\d" -o)
    ARTIFACT_URL="https://github.com/$1/$2/archive/$LATEST_VERSION.tar.gz"
    echo $ARTIFACT_URL
}

check_program_installed() {
    hash $1 > /dev/null 2>&1
    if [ "$?" != "0" ]; then
        print "$1 not found. is it installed?."
        print "Check the dependencies executing: ./install_api.sh dependencies"
        exit 1
    fi
}

min_version() {
    # $1: Minimal supported version
    # $2: Current version (to test)

    if [ -z "$1" ] || [ -z "$2" ]
    then
        return 2
    fi

    [ "$((echo $1; echo $2) | sort -V | head -n 1)" == "$1" ]
}

compile_sqlite() {
    LIB_PATH="$API_PATH/framework/lib"
    SONAME="libsqlite3.so.0"
    SOURCE="framework/database/sqlite3.c"

    print "\nInstalling SQLite library."
    exec_cmd "gcc -pipe -O2 -shared -fPIC -o $LIB_PATH/$SONAME $SOURCE"
    exec_cmd "chmod -R 750 $LIB_PATH"
    exec_cmd "chown -R root:ossec $LIB_PATH"
}


# END Aux functions

show_info () {
    https=$(get_configuration_value "https")
    port=$(get_configuration_value "port")
    basic_auth=$(get_configuration_value "basic_auth")

    if [ "X${https}" == "Xyes" ]; then
        proto="https"
    else
        proto="http"
    fi

    print "\nAPI URL: $proto://host_ip:$port/"
    if [ "X${update}" != "Xyes" ]; then
        print "user: 'foo'"
        print "password: 'bar'"
    fi
    if [ "X${basic_auth}" == "Xno" ]; then
        print "Authentication disabled (not secure)."
    fi
    print "Configuration: $API_PATH/configuration"
}

help() {
    echo "./install_api.sh [dependencies|download|dev]"
    echo "./install_api.sh                Install API from current path"
    echo "./install_api.sh dependencies   List dependencies"
    echo "./install_api.sh download       Download and install lastest release (stable branch)"
    echo "./install_api.sh dev            Install API from current path in development mode"
}

required_packages() {
    print "\nDebian and Ubuntu based Linux distributions:"
    print "\tNodeJS 4.x or newer:"
    print "\t\tcurl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -"
    print "\t\tsudo apt-get install -y nodejs"
    print "\t\tsudo apt-get install -y gcc"

    print "\nRed Hat, CentOS and Fedora:"
    print "\tNodeJS 4.x or newer:"
    print "\t\tcurl --silent --location https://rpm.nodesource.com/setup_6.x | bash -"
    print "\t\tsudo yum -y install nodejs"
    print "\t\tsudo yum -y install gcc"
}

previous_checks() {
    # Arguments
    if [ "X${arg}" == "Xdependencies" ]; then  # dependencies argument
        required_packages
        exit 0
    elif [ "X${arg}" == "Xhelp" ]; then  # help argument
        help
        exit 0
    elif [ "X${arg}" == "Xdev" ]; then  # dev argument
        API_SOURCES=`pwd`
    elif [ "X${arg}" == "Xdownload" ]; then   # download argument
        API_SOURCES="/root"
        DOWNLOAD_PATH=$(url_lastest_release "wazuh" "wazuh-api")
    else
        API_SOURCES="."  # empty argument
    fi

    # Test root permissions
    if [ "$EUID" -ne 0 ]; then
        print "Please run this script with root permissions.\nExiting."
        exit 1
    fi

    # Paths
    OSSEC_CONF="/etc/ossec-init.conf"
    DEF_OSSDIR="/var/ossec"

    if ! [ -f $OSSEC_CONF ]; then
        print "Can't find $OSSEC_CONF. Is OSSEC installed?.\nExiting."
        exit 1
    fi

    . $OSSEC_CONF

    if [ -z "$DIRECTORY" ]; then
        DIRECTORY=$DEF_OSSDIR
    fi

    API_PATH="${DIRECTORY}/api"
    API_PATH_BACKUP="${DIRECTORY}/~api"
    FRAMEWORK_PATH="${DIRECTORY}/framework"
    API_BACKUP='no'
    serv_type=$(get_type_service)

    # Dependencies
    check_program_installed "tar"
    check_program_installed "curl"
    check_program_installed "gcc"

    NODE_DIR=$(which nodejs 2> /dev/null)

    if [ "X$NODE_DIR" = "X" ]; then
        NODE_DIR=$(which node 2> /dev/null)

        if [ "X$NODE_DIR" = "X" ]; then
            echo "NodeJS binaries not found. Is NodeJS installed?"
            exit 1
        fi
    fi

    NODE_VERSION=`$NODE_DIR --version | grep -P '^v\d+' -o | grep -P '\d+' -o`

    if [ $NODE_VERSION -lt 4 ]; then
        print "The current version of NodeJS installed is not supported. Wazuh API requires NodeJS 4.x or newer."
        print "Review the dependencies executing: ./install_api.sh dependencies"
        exit 1
    fi

    check_program_installed "npm"

    # Check Python 2.7

    check_program_installed "python"
    python_version=$(python -V 2>&1 | cut -d' ' -f2)

    if ! min_version "2.7" $python_version
    then
        echo "Warning: Python $python_version detected, minimal supported version is 2.7"
    fi
}

get_api () {
    if [ "X$DOWNLOAD_PATH" != "X" ]; then
        print "\nDownloading API from $DOWNLOAD_PATH"

        if [ -d "$API_SOURCES/wazuh-api-tmp" ]; then
            exec_cmd "rm -rf $API_SOURCES/wazuh-api-tmp"
        fi
        exec_cmd "mkdir -p $API_SOURCES/wazuh-api-tmp"

        exec_cmd "curl -sL $DOWNLOAD_PATH | tar xvz -C $API_SOURCES/wazuh-api-tmp"

        API_SOURCES="$API_SOURCES/wazuh-api-tmp/wazuh-api-*.*"

        API_NEW_VERSION=`cat $API_SOURCES/package.json | grep "version\":" | grep -P "\d+(?:\.\d+){0,2}" -o`
        print "\nInstalling Wazuh API $API_NEW_VERSION"
    else
        API_NEW_VERSION=`cat $API_SOURCES/package.json | grep "version\":" | grep -P "\d+(?:\.\d+){0,2}" -o`
        if [ "X${arg}" == "Xdev" ]; then
            print "\nInstalling Wazuh API $API_NEW_VERSION from current directory [DEV MODE]."
        else
            print "\nInstalling Wazuh API $API_NEW_VERSION from current directory."
        fi
    fi

}

install_framework() {
    exec_cmd "mkdir -pm 700 $API_PATH/framework/lib"
    exec_cmd "chown ossec:ossec $API_PATH/framework/lib"
    compile_sqlite
}

backup_api () {
    if [ -e $API_PATH_BACKUP ]; then
        exec_cmd "rm -rf $API_PATH_BACKUP"
    fi

    exec_cmd "cp -rLfp $API_PATH $API_PATH_BACKUP"
    exec_cmd "chown root:root $API_PATH_BACKUP"
    API_BACKUP='yes'
    API_OLD_VERSION=`cat $API_PATH_BACKUP/package.json | grep "version\":" | grep -P "\d+(?:\.\d+){0,2}" -o`
}

restore_configuration () {

    if [ "X${API_OLD_VERSION}" == "X2.0.0" ]; then
        exec_cmd "rm -rf $API_PATH/configuration"
        exec_cmd "cp -rfp $API_PATH_BACKUP/configuration $API_PATH/configuration"
    elif [ "X${API_OLD_VERSION}" == "X1.1" ] || [ "X${API_OLD_VERSION}" == "X1.2.0" ] || [ "X${API_OLD_VERSION}" == "X1.2.1" ]; then
        exec_cmd "cp -rfp $API_PATH_BACKUP/ssl/htpasswd $API_PATH/configuration/auth/user"
        exec_cmd "cp -p $API_PATH_BACKUP/ssl/*.key $API_PATH_BACKUP/ssl/*.crt $API_PATH/configuration/ssl/"
        exec_cmd "chown -R root:root $API_PATH/configuration"
        exec_cmd "chmod -R 750 $API_PATH/configuration"
        exec_cmd "chmod u-x $API_PATH/configuration/ssl/*"
        RESTORE_WARNING="1"
    else
        RESTORE_WARNING="2"
    fi
}

setup_api() {
    # Check if API is installed
    update="no"
    if [ -d $API_PATH ]; then
        backup_api
        print ""
        while true; do
            read -p "Wazuh API is already installed (version $API_OLD_VERSION). Do you want to update it? [y/n]: " yn
            case $yn in
                [Yy] ) update="yes"; break;;
                [Nn] ) update="no"; break;;
            esac
        done

        if [ "X${update}" == "Xno" ]; then
            while true; do
                print ""
                read -p "The installation directory already exists. Should I delete it? [y/n]: " yn
                case $yn in
                    [Yy] ) break;;
                    [Nn] ) print "Not possible to install the API.\nExiting."; exit 1; break;;
                esac
            done
        fi

        exec_cmd "rm -rf $API_PATH"
    fi

    # Copy files
    if [ "X${update}" == "Xyes" ]; then
        print "\nUpdating API ['$API_PATH']."
        e_msg="updated"
    else
        print "\nInstalling API ['$API_PATH']."
        e_msg="installed"
    fi
    if [ "X${arg}" == "Xdev" ]; then
        exec_cmd "ln -s $API_SOURCES $API_PATH"
    else
        exec_cmd "mkdir $API_PATH"
        exec_cmd "cp --parents -r $API_SOURCES/app.js $API_SOURCES/configuration $API_SOURCES/controllers $API_SOURCES/examples $API_SOURCES/framework/examples $API_SOURCES/framework/wazuh $API_SOURCES/helpers $API_SOURCES/models $API_SOURCES/package.json $API_SOURCES/scripts $API_PATH"

        # General permissions
        exec_cmd "chown -R root:ossec $API_PATH"
        exec_cmd "chown -R root:root $API_PATH/scripts"
        exec_cmd "chown -R root:root $API_PATH/configuration"
        exec_cmd "chmod -R 750 $API_PATH"

        # Remove execution permissions
        exec_cmd "chmod ugo-x $API_PATH/package.json"
        exec_cmd "chmod ugo-x $API_PATH/scripts/wazuh-api*"
    fi

    if [ "X${update}" == "Xyes" ]; then
        restore_configuration
    fi

    install_framework

    print "\nInstalling NodeJS modules."
    if [ "X${arg}" == "Xdev" ]; then
        exec_cmd "cd $API_PATH && npm install"
    else
        exec_cmd "cd $API_PATH && npm install --production"
    fi
    exec_cmd "chown -R root:ossec $API_PATH/node_modules"
    exec_cmd "chmod -R 750 $API_PATH/node_modules"

    if [ ! -f $API_PATH/configuration/auth/htpasswd ]; then
        exec_cmd "ln -s $API_PATH/node_modules/htpasswd/bin/htpasswd $API_PATH/configuration/auth/htpasswd"
    fi

    # Set OSSEC directory in API configuration
    if [ "X${DIRECTORY}" != "X/var/ossec" ]; then
        repl="\\\/"
        escaped_ossec_path=`echo "$DIRECTORY" | sed -e "s#\/#$repl#g"`
        edit_configuration "ossec_path" $escaped_ossec_path

    fi

    # Create/check api.log
    APILOG_PATH="${DIRECTORY}/logs/api.log"
    if [ ! -f $APILOG_PATH ]; then
        touch $APILOG_PATH
    fi
    exec_cmd "chown root:ossec $APILOG_PATH"
    exec_cmd "chmod 660 $APILOG_PATH"

    print "\nInstalling service."
    echo "----------------------------------------------------------------"
    exec_cmd_bash "$API_PATH/scripts/install_daemon.sh"
    echo "----------------------------------------------------------------"
}

main() {
    print "### Wazuh API ###"
    previous_checks
    get_api
    setup_api
    show_info

    if [ "X${RESTORE_WARNING}" == "X1" ]; then
        print "\nWarning: Some problems occured when restoring your previous configuration ($API_PATH/configuration/config.js). Please, review it manually. Backup directory: $API_PATH_BACKUP."
    elif [ "X${RESTORE_WARNING}" == "X2" ]; then
        print "\nWarning: Some problems occured when restoring your previous configuration. Please, review it manually. Backup directory: $API_PATH_BACKUP."
    fi

    print "Note: You can configure the API executing $API_PATH/scripts/configure_api.sh"

    print "\n### [API $e_msg successfully] ###"
    exit 0
}

# Main
main
