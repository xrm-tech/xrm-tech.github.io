#!/bin/bash

BASE_PATH="https://raw.githubusercontent.com/StackStorm/st2-packages"
BOOTSTRAP_FILE='st2bootstrap.sh'

ARCH=`arch`
DEBTEST=`lsb_release -a 2> /dev/null | grep Distributor | awk '{print $3}'`
RHTEST=`cat /etc/redhat-release 2> /dev/null | sed -e "s~\(.*\)release.*~\1~g"`
VERSION=''
RELEASE='stable'
REPO_TYPE=''
ST2_PKG_VERSION=''
DEV_BUILD=''
USERNAME=''
PASSWORD=''
EXTRA_OPTS=''
