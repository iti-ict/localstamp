#!/bin/bash

CONFIG=$1

IMAGE_REPO="http://ecloud.iti.upv.es:8080"
LS_RT="$LS_DOCKER_NAME"

if [ "$CONFIG" == "--help" ]; then
  echo ""
  echo "local-stamp-start.sh [configuration file]"
  echo ""
  echo "Configuration file is an optional parameter with the path to a JSON file "
  echo " with configuration for Local Stamp. The defaults are:"
  echo "{"
  echo "  \"daemon\":true,"
  echo "  \"kibana\": true,"
  echo "  \"autoUnregister\": false,"
  echo "  \"autoUndeploy\": false,"
  echo "  \"stopLogger\": false,"
  echo "  \"destroyLogger\": false"
  echo "}"
  echo ""
  echo "The meaning of these options when they are true is:"
  echo ""
  echo "daemon: Local Stamp starts as a daemon and waits for http requests."
  echo ""
  echo "kibana: Local Stamp logs are available from kibana."
  echo ""
  echo "autoUnregister: Local Stamp unregisters every component and service after a deployment."
  echo ""
  echo "autoUndeploy: Local Stamp, before a deployment, undeploys any existent deployment for the same service URN."
  echo ""
  echo "stopLogger: Local Stamp, on exit, stops logger docker instance."
  echo ""
  echo "destroyLogger: Local Stamp, on exit, destroys logger docker instance. This option has priority over stopLogger."
  echo ""
  exit 0
fi

LS_LATEST=$(wget -q -O - $IMAGE_REPO/eslap.cloud/local-stamp/latest)
if [ -n "$LS_LATEST" ] && [ -z "$LS_LIKE_OLD" ]; then
  if [ "$LS_RT" == "$LS_LATEST" ]; then
    echo "You are up to date"
  elif [[ "$LS_RT" > "$LS_LATEST" ]]; then
    echo "You are using a development version"
  else
    echo -n "Current stable version is $LS_LATEST."
    read -p " Do you want to update? [Y/n]" response
    response=${response,,} # tolower
    if [[ $response =~ ^(yes|y| ) ]] || [[ -z $response ]]; then

      latestPath=$(echo $LS_LATEST|sed 's/\(.*\):/\1\//')
      # Install docker-image
      echo -n "Downloading image ..."
      CURRENT=$PWD
      DOWNLOAD=$(mktemp -d)
      cd $DOWNLOAD
      wget -q $IMAGE_REPO/$latestPath/image.tgz
      echo "done"
      echo -n "Installing - this can take several minutes... "
      docker load -i image.tgz
      cd $CURRENT
      rm -rf $DOWNLOAD
      if [ $(docker images $LS_LATEST | wc -l) != "2" ]; then
        echo "Error: Image $latestPath not installed"
        exit 1
      fi
      echo "done"
      LS_RT=$LS_LATEST
      echo "Using image $LS_RT"
      docker run --rm --entrypoint bash -v /tmp:/tmp $LS_RT -c "cp /eslap/component/server/scripts/_local-stamp-start.sh /tmp"
      export LS_DOCKER_NAME=$LS_RT
      /tmp/_local-stamp-start.sh $@
      exit
    fi
  fi
fi

# LOG=/tmp/local-stamp.log
# [ -d $LOG ] && docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "rm -rf $LOG"
# [ -f $LOG ] && docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "rm $LOG"

# [ -d /tmp/local-stamp ] && docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "rm -rf /tmp/local-stamp"
# [ -d /tmp/runtime-agent ] && docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "rm -rf /tmp/runtime-agent"
# [ -d /tmp/gateway-component ] && docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "rm -rf /tmp/gateway-component"

# docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "cp -R /eslap/agents/runtime-agent /tmp"
# docker run --rm  -v /tmp:/tmp --entrypoint sh $LS_RT -c "cp -R /eslap/agents/gateway-component /tmp"

# touch $LOG
# echo "Local Stamp log in $LOG"
# echo "Local Stamp workdir in /tmp/local-stamp"
[ -z "$LOCAL_STAMP_DIR" ] && LOCAL_STAMP_DIR="/workspaces/slap/git/local-stamp"
[ -z "$ADMISSION_DIR" ] && ADMISSION_DIR="/workspaces/slap/git/admission"
DEVEL_OPTIONS=" -v $LOCAL_STAMP_DIR/src:/eslap/component/src  -v $LOCAL_STAMP_DIR/node_modules:/eslap/component/node_modules -v $ADMISSION_DIR/src:/eslap/component/node_modules/admission/src "
[ -z "$DEVELOPING" ] && DEVEL_OPTIONS=""
[ "$DEVELOPING" == "false" ] && DEVEL_OPTIONS=""

CONFIG_OPTIONS=""
if [ -n "$CONFIG" ];then
  if [ ! -f $CONFIG ]; then
    echo "File $CONFIG does not exist"
    exit 1
  else
    CONFIG_FULLPATH="$(cd "$(dirname "$CONFIG")"; pwd)/$(basename "$CONFIG")"
    CONFIG_OPTIONS=" -v $CONFIG_FULLPATH:/eslap/component/scripts/local-stamp.json"
  fi
fi
TTY=""
if tty -s
then
   TTY="-it"
fi
case $(ps -o stat= -p $$) in
  *+*) ;;
  *) TTY="";;
esac
export TTY

logFileMapping="/eslap/component/slap.log"
manifestStorageMapping="/eslap/manifest-storage/remote"
imageStorageMapping="/eslap/image-storage/remote"
instanceFolderMapping="/eslap/instances"
volumeFolderMapping="/eslap/volumes"
logFileClear=true
instanceFolderClear=true
manifestStorageMerge=true
imageStorageMerge=true
CONFIG_DEFAULT="/eslap/component/scripts/local-stamp.json"
FOLDERS=""
for k in logFile manifestStorage imageStorage instanceFolder volumeFolder; do
  unset v
  kclear=$k"Clear"
  kmapping=$k"Mapping"
  kmerge=$k"Merge"
  if [ -f "$CONFIG" ]; then
    v=$(cat $CONFIG|docker run --rm -i --entrypoint bash $LS_RT -c "jq -r .$k")
    [ "$v" == "null" ] && unset v
  fi
  if [ -z "$v" ];then
    v=$(docker run --rm --entrypoint bash $LS_RT -c "jq -r .$k $CONFIG_DEFAULT")
  fi
  [ "$v" == "/" ] && echo "Root folder can't be used configuring local-stamp" && exit -1
  [[ "${v:0:1}" != "/" ]] && echo "Incorrect configuration value for $k. Paths must be absolute" && exit -1
  if (echo "$k"|grep -qvi "file"); then  #parameter is a folder path
    if [ "${!kclear}" == "true" ] && [ -d "$v" ]; then
      docker run --rm  -v /:/jost --entrypoint bash $LS_RT -c "rm -rf /jost$v"
    fi
    if [ ! -d $v ]; then
      docker run --rm  -v /:/jost --entrypoint bash $LS_RT -c "mkdir -p /jost$v"
    fi
    if [ "${!kmerge}" == "true" ]; then
      docker run --rm  -v /:/jost --entrypoint bash $LS_RT -c "cp -Rn ${!kmapping}/* /jost$v"
    fi
  else  # parameter is a file path
    if [ "${!kclear}" == "true" ] && [ -f "$v" ]; then
      docker run --rm  -v /:/jost --entrypoint bash $LS_RT -c "rm /jost$v"
    fi
    if [ ! -f $v ]; then
      docker run --rm  -v /:/jost --entrypoint bash $LS_RT -c "mkdir -p \$(dirname /jost$v);touch /jost$v"
    fi
  fi
  declare $k=$v
  FOLDERS="-v ${!k}:${!kmapping} $FOLDERS"
done

declare -a IMAGES=(
  "eslap.cloud/runtime/native/1_0_1"
  "eslap.cloud/runtime/native/1_1_1"
  "eslap.cloud/runtime/native/2_0_0"
  "eslap.cloud/runtime/native/dev/1_1_1"
  "eslap.cloud/runtime/native/dev/2_0_0"
  "eslap.cloud/runtime/java/1_0_1"
  "eslap.cloud/runtime/java/dev/1_0_1"
  "eslap.cloud/elk/1_0_0"
)

dimages=$(mktemp)
docker images --format '{{.Repository}}/{{.Tag}}' > $dimages
IMGTARGET=$imageStorage
IMAGE_REPO="http://ecloud.slap53.iti.es:8080"
for i in "${IMAGES[@]}"; do
  grep -q $i $dimages && continue
  if [ ! -f $IMGTARGET/$i/image.tgz ]; then
    docker run --rm -it -v /:/jost --entrypoint bash $LS_RT -c "\
      mkdir -p /jost$IMGTARGET/$i;\
      cd /jost$IMGTARGET/$i;\
      echo \"Downloading $i\";\
      wget -q $IMAGE_REPO/$i/image.tgz\
      "
  fi
  docker load -i $IMGTARGET/$i/image.tgz
done
rm $dimages

#remove old-fashioned elk
# portl=28777
# docker ps -a|grep $portl/tcp|grep -v $portl"->"$portl|cut -f1 -d\ |xargs -r docker rm -f

[ -n "$(docker ps -q -f name=^/local-stamp$)" ] && echo "Local Stamp is already running" && exit -1

echo "docker run $TTY --rm --name local-stamp --net=host -p 8844:8844 -p 8090:8090 -v /tmp:/tmp $FOLDERS -v /var/run/docker.sock:/var/run/docker.sock $CONFIG_OPTIONS $DEVEL_OPTIONS $LS_RT"

docker run $TTY --rm --name local-stamp --net=host -p 8090:8090 -v /tmp:/tmp $FOLDERS -v /var/run/docker.sock:/var/run/docker.sock $CONFIG_OPTIONS $DEVEL_OPTIONS $LS_RT

