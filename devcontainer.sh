#!/bin/bash

if ! [ -x "$(command -v jq)" ]; then
    printf "\x1B[31m[ERROR] jq is not installed.\x1B[0m\n"
    exit 1
fi

if ! [ -x "$(command -v sed)" ]; then
    printf "\x1B[31m[ERROR] sed is not installed (only GNU sed works).\x1B[0m\n"
    exit 1
fi

if ! sed --version | grep "sed (GNU sed)" &>/dev/null; then
    printf "\x1B[31m[ERROR] GNU sed is not installed.\x1B[0m\n"
    exit 1
fi

VERBOSE=0
DOCKER_OPTS=""

debug() {
    if [ $VERBOSE == 1 ]; then
        printf "\x1B[33m[DEBUG] %s\x1B[0m\n" "${1}"
    fi
}

optspec=":v-:"
while getopts "$optspec" opt; do
    case ${opt} in
        v ) 
            val="${!OPTIND}"
            VERBOSE=1
            ;;
        -)
            case "${OPTARG}" in
                docker-opts)
                    val="${!OPTIND}"; OPTIND=$((OPTIND + 1))
                    DOCKER_OPTS=$val
                    if [[ $VERBOSE  = 1 ]]; then
                        debug "Setting DOCKER_OPTS $DOCKER_OPTS"
                    fi
                    ;;
                docker-opts=*)
                    val=${OPTARG#*=}
                    opt=${OPTARG%=$val}
                    DOCKER_OPTS=$val
                    if [[ $VERBOSE = 1 ]]; then
                        debug "Setting DOCKER_OPTS $DOCKER_OPTS"
                    fi
                    debug "docker-opts=* optind $OPTIND"
                    ;;
                
                *)
                    if [ "$OPTERR" = 1 ]; then
                        echo "Unknown option --${OPTARG}" >&2
                        exit 5
                    fi
                    ;;
            esac;;
        *)
            if [ "$OPTERR" = 1 ]; then
                echo "Unknown option -${OPTARG}" >&2
                exit 5
            fi
            ;;
    esac
done

PROJECT_ROOT=$(git rev-parse --show-toplevel)

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "Directory $PROJECT_ROOT does not exist!" >&2
    exit 6
fi

echo "Using workspace ${PROJECT_ROOT}"

CONFIG_DIR=./.devcontainer
debug "CONFIG_DIR: ${CONFIG_DIR}"

CONFIG_FILE=devcontainer.json
debug "CONFIG_FILE: ${CONFIG_FILE}"
if ! [ -e "$CONFIG_DIR/$CONFIG_FILE" ]; then
    # Config file may also be ".devcontainer.json" on the project folder.
    CONFIG_DIR=.
    debug "CONFIG_DIR: ${CONFIG_DIR}"
    CONFIG_FILE=.devcontainer.json
    debug "CONFIG_FILE: ${CONFIG_FILE}"
    if ! [ -e "$CONFIG_DIR/$CONFIG_FILE" ]; then
        echo "Folder contains no devcontainer configuration"
        exit
    fi
fi

CONFIG="$(cat "$CONFIG_DIR/$CONFIG_FILE")"

# Replacing variables in the config file
localWorkspaceFolderBasename="$(basename "$(realpath "$CONFIG_DIR/..")")"
# shellcheck disable=SC2001
CONFIG="$(echo "$CONFIG" | sed "s#\${localWorkspaceFolderBasename}#$localWorkspaceFolderBasename#g")"

localWorkspaceFolder="$(dirname "$localWorkspaceFolderBasename")"
# shellcheck disable=SC2001
CONFIG="$(echo "$CONFIG" | sed "s#\${localWorkspaceFolder}#$localWorkspaceFolder#g")"

# Remove trailing comma's with sed
CONFIG=$(echo "$CONFIG" | grep -v // | sed -Ez 's#,([[:space:]]*[]}])#\1#gm')
debug "CONFIG: \n${CONFIG}"


if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "Config dir '$CONFIG_DIR' does not exist!" >&2
    exit 7
fi

cd "$CONFIG_DIR" || return

DOCKER_FILE=$(echo "$CONFIG" | jq -r .dockerFile)
if [ "$DOCKER_FILE" == "null" ]; then 
    DOCKER_FILE=$(echo "$CONFIG" | jq -r .build.dockerfile)
fi
DOCKER_FILE="$(readlink -f "$DOCKER_FILE")"
debug "DOCKER_FILE: ${DOCKER_FILE}"
if ! [ -e "$DOCKER_FILE" ]; then
    echo "Can not find dockerfile ${DOCKER_FILE}"
    exit
fi

REMOTE_USER="$(echo "$CONFIG" | jq -r .remoteUser)"
debug "REMOTE_USER: ${REMOTE_USER}"

ARGS=$(echo "$CONFIG" | jq -r '.build.args | to_entries? | map("--build-arg \(.key)=\"\(.value)\"")? | join(" ")')
debug "ARGS: ${ARGS}"

SHELL=$(echo "$CONFIG" | jq -r '.settings."terminal.integrated.shell.linux"')
if [ "$SHELL" == "null" ]; then
    SHELL="/bin/bash"
fi
debug "SHELL: ${SHELL}"

PORTS=$(echo "$CONFIG" | jq -r '.forwardPorts | map("-p \(.):\(.)")? | join(" ")')
debug "PORTS: ${PORTS}"

POST_CREATE_COMMAND=$(echo "$CONFIG" | jq -r .postCreateCommand)
debug "POST_CREATE_COMMAND: ${POST_CREATE_COMMAND}"

ENVS=$(echo "$CONFIG" | jq -r '.remoteEnv | to_entries? | map("-e \(.key)=\(.value)")? | join(" ")')
debug "ENVS: ${ENVS}"

TARGET_PROJECT_ROOT="/workspace/$(basename $PROJECT_ROOT)"
debug "TARGET_PROJECT_ROOT: ${TARGET_PROJECT_ROOT}"

MOUNT="${MOUNT} --mount type=bind,source=${PROJECT_ROOT},target=${TARGET_PROJECT_ROOT}"
debug "MOUNT: ${TARGET_PROJECT_ROOT}"

WORK_DIR=$(echo "$TARGET_PROJECT_ROOT${PWD#"$PROJECT_ROOT"}")
debug "WORK_DIR: ${WORK_DIR}"

echo "Building and starting container"

DOCKER_TAG=$(echo "$DOCKER_FILE" | md5sum - | awk '{ print $1 }')

# Check if tag already exists, if not than do post actions after build.
(docker inspect --type=image $DOCKER_TAG 2> /dev/null && SHOULD_RUN_POST_ACTIONS=0 || SHOULD_RUN_POST_ACTIONS=1) > /dev/null

# shellcheck disable=SC2086
BUILD_OUTPUT=$(docker build -f "$DOCKER_FILE" -t "$DOCKER_TAG" $ARGS .)
build_status=$?
debug $BUILD_OUTPUT

if [[ $build_status -ne 0 ]]; then
    echo "Building docker image failed..." >&2
    exit 7
fi

debug "DOCKER_TAG: ${DOCKER_TAG}"

set -e
PUID=$(id -u)
PGID=$(id -g)

if [ $SHOULD_RUN_POST_ACTIONS ]; then
    echo "running post actions...";

    CONFIGURE_USER_ID="\
    REMOTE_PUID=\$(id -u); \
    REMOTE_PGID=\$(id -g); \
    if [ '$REMOTE_USER' != '' ] && command -v usermod &>/dev/null && [ \"$PUID\" != \"\$REMOTE_PUID\" ] && [ \"$PGID\" != \"\$REMOTE_PGID\" ]; \
    then \
        sudo=''
        if [ \"$(stat -f -c '%u' "$(which sudo)")\" = '0' ]; then
            sudo=sudo
        fi;
        \$sudo usermod -u $PUID $REMOTE_USER && \
        \$sudo groupmod -g $PGID $REMOTE_USER && \
        \$sudo passwd -d $REMOTE_USER && \
        \$sudo chown $REMOTE_USER:$REMOTE_USER -R ~$REMOTE_USER $TARGET_PROJECT_ROOT; \
    fi;"

    docker run -it $DOCKER_OPTS $PORTS $ENVS $MOUNT -w "$WORK_DIR" "$DOCKER_TAG" "$SHELL" -c "$CONFIGURE_USER_ID"
    docker run -it $DOCKER_OPTS $PORTS $ENVS $MOUNT -w "$WORK_DIR" "$DOCKER_TAG" $POST_CREATE_COMMAND
fi

# shellcheck disable=SC2086

docker run -it $DOCKER_OPTS $PORTS $ENVS $MOUNT -w "$WORK_DIR" "$DOCKER_TAG" "$SHELL"
