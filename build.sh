#!/bin/bash
# shellcheck disable=SC2086,SC2046

export LC_ALL=en_US.UTF-8

usage () {
    cat <<EOF
    
Flags:
    -s, --source [PATH]          
        [必填] 源码，支持zip/tgz/源码目录

    -d, --dest [PATH]
        [必填] 输出路径

    --app-code app_code
        app code

    --app-version app_version
        saas 版本号

    --do-not-download-pkgs
        不自动补全 python 依赖库，默认按 requirements.txt 补全 python 依赖库

    --ignore-rsync-args
        不使用项目的 .gitignore 来排除无用的文件，避免敏感信息、无用的文件外泄

    --python2-home [PATH]
        python2 路径

    --python3-home [PATH]
        python3 路径

    -h, --help
        显示此页

EOF
exit 1
}

IS_TRACE=${IS_TRACE:-false}
[[ "$IS_TRACE" == "true" ]] && set -x

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE=/tmp/saas_builder-$(date +%F-%s).log

exec 2> >(trap '' INT; tee -a $LOG_FILE >&2)
trap '>&2 ec=$?; (( ec != 0 )) && echo "[ERROR $(date +%F/%T) $BASH_LINENO] Exited with failure: $ec"; exit $ec' EXIT
ok () { echo "[OK $(date +%F/%T) $BASH_LINENO] $@" | tee -a $LOG_FILE 2>&1; return 0; }
info () { echo "[INFO $(date +%F/%T) $BASH_LINENO] $@" | tee -a $LOG_FILE 2>&1; return $?; }
fail () { echo "[FAIL $(date +%F/%T) $BASH_LINENO] $@" | tee -a $LOG_FILE 2>&1; return $?; }
err () { echo "[ERROR $(date +%F/%T) $BASH_LINENO] $@" | tee -a $LOG_FILE 2>&1; exit 1; }
logstd () { while IFS= read -r line; do info "$line"; done; }

parse_yaml () {
    local prefix=$2
    local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" $1 |
    awk -F$fs '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
        }
    }'
}

# export arrays 
## PIP_OPTIONS=("-p" "123")
## BASH_ENV=<(declare -p PIP_OPTIONS)
PIP_OPTIONS=${PIP_OPTIONS:-''}

RELEASE_VERSION='-1'
IS_DOWNLOAD_PKGS=1
APP_CODE=''
ARG_NUM=$#
[[ $ARG_NUM == 0 ]] && usage
TEMP=$( getopt -o s:d:h --long help,source:,dest:,do-not-download-pkgs,python2-home:,python3-home:,app-code:,app-version:,ignore-rsync-args -- "$@" 2>/dev/null )
if [ $? != 0 ]; then
    fail "Unknown argument!"
    usage
fi
eval set -- "${TEMP}"
while :; do
    [ -z "$1" ] && break;
    case "$1" in
        -s|--source)
            FILE_SOURCE=$2
            shift 2
        ;;
        -d|--dest)
            FILE_OUTPUT=$2
            shift 2
        ;;
        --app-code)
            APP_CODE=$2
            shift 2
        ;;
        --app-version)
            RELEASE_VERSION=$2
            shift 2
        ;;
        --python2-home)
            PYTHON2_PATH=$2
            shift 2
        ;;
        --python3-home)
            PYTHON3_PATH=$2
            shift 2
        ;;
        --do-not-download-pkgs)
            IS_DOWNLOAD_PKGS=0
            shift
        ;;
        --ignore-rsync-args)
            IS_IGNORE_RSYNC_ARGS=0
            shift
        ;;
        -h|--help)
            usage
            shift
        ;;
        --) shift ;;
        *) fail "Unkonw argument!"; usage ;;
    esac
done

set -eo pipefail

WORK_DIR=$(mktemp -d /tmp/"$(date +%F)XXXXXXXXXX")

if [[ "$FILE_SOURCE" == '' ]]; then
    err '-s|--source 输入为空'
else
    if [ ! -e $FILE_SOURCE ]; then
        err "-s|--source 文件/目录不存在"
    fi
fi

if [ "$RELEASE_VERSION" == '' ]; then
    err "--app-version: 版本号为空"
fi

info "Install dependencies"
if apt-get -v &> /dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -qq libmysqlclient-dev rsync
elif which yum &> /dev/null; then
    yum install -y -q mysql-devel gcc python3-devel rsync
fi

info "Start running. work dir: $WORK_DIR"
FILE_MIMETYPE=$(file -Lb --mime-type $FILE_SOURCE)
case "X${FILE_MIMETYPE##*[/.-]}" in
    Xgzip)
        info "Extract $FILE_SOURCE"
        tar xf $FILE_SOURCE -C $WORK_DIR
    ;;
    Xzip)
        info "Extract $FILE_SOURCE"
        unzip -q $FILE_SOURCE -d $WORK_DIR
    ;;
    Xdirectory)
        info "Copy source to work dir"
        [ -z "$APP_CODE" ] && err 'source 为目录时需要指定 --app-code'
        rsync_args=''
        if [ "$IS_IGNORE_RSYNC_ARGS" == '1' ]; then
            if [ -f $FILE_SOURCE/.gitignore ]; then
                rsync_args="--exclude-from=$FILE_SOURCE/.gitignore"
            fi
        fi
        rsync -a ${rsync_args} --exclude '.git*' --exclude 'build.sh' $FILE_SOURCE $WORK_DIR/${APP_CODE}
    ;;
    *) err "Unknow mime-type: ${FILE_MIMETYPE}"
esac

info "Execute precheck items"
if [ "$(find $WORK_DIR -maxdepth 2 -type f -name 'app.yml' | wc -l)" -eq 1 ]; then
    yaml_string=$(parse_yaml $(find $WORK_DIR -maxdepth 2 -type f -name 'app.yml'))
    eval "$yaml_string"
    for var in "app_name is_use_celery author introduction version language date introduction_en app_name_en"; do
        if [ "$(eval echo \$$var)" == '' ]; then
            err "app.yml 中缺少这个 key： $var "
        fi
    done
    if [ "$( echo $app_code | grep -P '^[a-z][a-z0-9-_]{1,16}$' )" == "$app_code" ]; then
        APP_CODE=$app_code
        PROJECT_HOME="$WORK_DIR/$APP_CODE"
    else
        err "请检查 app_code 命名，使其满足^[a-z][a-z0-9-_]{1,16}$"
    fi
    if [ "$RELEASE_VERSION" != '-1' ]; then
        APP_VERSION=$RELEASE_VERSION
    else
        
        APP_VERSION=$version
    fi
else
    err "项目中必须包含 app.yml 文件"
fi



if [ ! -d "$PROJECT_HOME" ]; then
    err "未找到项目目录：app.yml 内 app_code 定义为：${APP_CODE}； 解压后的目录有：$(find $WORK_DIR -maxdepth 2 -type f -name 'app.yml' | sed -e 's#/app.yml##g' -e "s#$WORK_DIR/##")"
fi

if [ ! -f "$PROJECT_HOME"/requirements.txt ]; then
    err "项目中必须包含 requirements.txt"
fi

if [ ! -f "$PROJECT_HOME/${APP_CODE}.png" ]; then
    fail "项目中不存在 logo，命名格式为 \${APP_CODE}.png"
fi

if [ -f $PROJECT_HOME/runtime.txt ]; then
    case $(cat $PROJECT_HOME/runtime.txt) in
        python-3*) 
            PYTHON_PATH=${PYTHON3_PATH}
            PIP_PATH="${PYTHON3_PATH%/*}/pip"
        ;;
        python-2*)
            PYTHON_PATH=${PYTHON2_PATH}
            PIP_PATH="${PYTHON2_PATH%/*}/pip"
        ;;
        *) err "Python 版本无法识别：$(cat $PROJECT_HOME/runtime.txt)"
    esac
    info "runtime: $(cat $PROJECT_HOME/runtime.txt)"
else
    # 兼容老 SaaS 框架中无 runtime.txt 的情况，默认都设置为 python2
    fail "项目中不存在 runtime.txt"
    info "runtime 设置为 python2"
    PYTHON_PATH=${PYTHON2_PATH}
    PIP_PATH="${PYTHON2_PATH%/*}/pip"
fi

if [ ! -e "$PYTHON_PATH" ]; then
    err "Python 路径不存在"
fi

info "Rewrite app.yml"
sed -i -r -e "s/^(version:).*/\1 ${APP_VERSION}/" \
    -e "s/^(app_code:).*/\1 ${APP_CODE}/" \
    -e "s/^(language:).*/\1 python/" \
    -e "s/^(date:).*/\1 $(date +"%F %T")/"  $PROJECT_HOME/app.yml
cat $PROJECT_HOME/requirements.txt | grep -vE '^#|^$' | xargs -n1 \
    | awk -F'==' 'BEGIN {printf "\nlibraries:\n"} {printf "- name: %s\n  version: '\''%s'\''\n",$1,$2}' >> $PROJECT_HOME/app.yml

info "Sync settings templates"
if [ -f "$PROJECT_HOME/settings.py" ]; then
    cat >>$PROJECT_HOME/settings.py<<EOF
# check saas app  settings
try:
    saas_conf_module = "config.settings_saas"
    saas_module = __import__(saas_conf_module, globals(), locals(), ['*'])
    for saas_setting in dir(saas_module):
        if saas_setting == saas_setting.upper():
            locals()[saas_setting] = getattr(saas_module, saas_setting)
except Exception:
    pass


# check weixin settings
try:
    weixin_conf_module = "weixin.core.settings"
    weixin_module = __import__(weixin_conf_module, globals(), locals(), ['*'])
    for weixin_setting in dir(weixin_module):
        if weixin_setting == weixin_setting.upper():
            locals()[weixin_setting] = getattr(weixin_module, weixin_setting)
except Exception:
    pass


# check mini weixin settings
try:
    miniweixin_conf_module = "miniweixin.core.settings"
    miniweixin_module = __import__(
        miniweixin_conf_module, globals(), locals(), ['*']
    )
    for miniweixin_setting in dir(miniweixin_module):
        if miniweixin_setting == miniweixin_setting.upper():
            locals()[miniweixin_setting] = getattr(
                miniweixin_module, miniweixin_setting
            )
except Exception:
    pass
    # check saas app  settings
try:
    saas_conf_module = "config.settings_saas"
    saas_module = __import__(saas_conf_module, globals(), locals(), ['*'])
    for saas_setting in dir(saas_module):
        if saas_setting == saas_setting.upper():
            locals()[saas_setting] = getattr(saas_module, saas_setting)
except Exception:
    pass


# check weixin settings
try:
    weixin_conf_module = "weixin.core.settings"
    weixin_module = __import__(weixin_conf_module, globals(), locals(), ['*'])
    for weixin_setting in dir(weixin_module):
        if weixin_setting == weixin_setting.upper():
            locals()[weixin_setting] = getattr(weixin_module, weixin_setting)
except Exception:
    pass


# check mini weixin settings
try:
    miniweixin_conf_module = "miniweixin.core.settings"
    miniweixin_module = __import__(
        miniweixin_conf_module, globals(), locals(), ['*']
    )
    for miniweixin_setting in dir(miniweixin_module):
        if miniweixin_setting == miniweixin_setting.upper():
            locals()[miniweixin_setting] = getattr(
                miniweixin_module, miniweixin_setting
            )
except Exception:
    pass
EOF
fi
    cat >>$WORK_DIR/settings_saas.py<<_EOF
# -*- coding: utf-8 -*-
"""
SaaS上传部署的全局配置
"""
import os

# ===============================================================================
# 数据库设置, 正式环境数据库设置
# ===============================================================================
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME'),
        'USER': os.environ.get('DB_USERNAME'),
        'PASSWORD': os.environ.get('DB_PASSWORD'),
        'HOST': os.environ.get('DB_HOST'),
        'PORT': os.environ.get('DB_PORT'),
    },
}
_EOF

if [ -d "$PROJECT_HOME/conf" ]; then
    cp $WORK_DIR/settings_saas.py $PROJECT_HOME/conf/
elif [ -d "$PROJECT_HOME/config" ]; then
    cp $WORK_DIR/settings_saas.py $PROJECT_HOME/config/
else
    err "can not find ant conf home"
fi

info "Building saas"
mkdir -p $WORK_DIR/src/
cp -r $PROJECT_HOME/* $WORK_DIR/src/
rm -rf $PROJECT_HOME
mkdir $WORK_DIR/$APP_CODE
mv $WORK_DIR/src $WORK_DIR/$APP_CODE
mv $WORK_DIR/$APP_CODE/src/app.yml $WORK_DIR/$APP_CODE
if [ -f "$WORK_DIR/includefiles" ]; then
    shopt -s nullglo
    cat $WORK_DIR/includefiles | xargs -n1 -I {} mv $WORK_DIR/{} $WORK_DIR/$APP_CODE/
    shopt -u nullglob
    rm -f $WORK_DIR/includefiles
fi

info "Upgrade / downgrade pip version to 20.2.3"
if [[ "$(${PIP_PATH} --version | awk '{print $2}')" != '20.2.3' ]]; then
  ${PIP_PATH} install pip==20.2.3 | logstd 
fi
info "Download libraries"
if [ "$IS_DOWNLOAD_PKGS" == '1' ]; then
    ${PIP_PATH} download \
        ${PIP_OPTIONS} \
        -r $PROJECT_HOME/src/requirements.txt \
        -d $PROJECT_HOME/pkgs/ 2>&1 | logstd \
        || err "pip download $PROJECT_HOME/src/requirements.txt fail" 
else
    if [ -d $WORK_DIR/pkgs ]; then
        mv $WORK_DIR/pkgs $WORK_DIR/$APP_CODE
    else
        fail "未启用自动 python 库补全功能，同时未找到 pkgs，SaaS 部署时将无法通过，请注意。如需手动补全，请根据 requirements.txt 补全 python 依赖库，并放置在源码/pkgs 目录内"
    fi
fi

mkdir -p $WORK_DIR/dist
cd $WORK_DIR
PKG_NAME="${APP_CODE}_V${APP_VERSION}.tar.gz"
tar --owner=0 --group=0 -czf $WORK_DIR/dist/${PKG_NAME} ${APP_CODE} || err 'packing fail'

info "Sync file to dest path: $FILE_OUTPUT"
mkdir -p $FILE_OUTPUT
rsync -a --delete $WORK_DIR/dist/${PKG_NAME} $FILE_OUTPUT

# clean up
[[ "$IS_TRACE" == "true" ]] || rm -rf ${WORK_DIR}  
