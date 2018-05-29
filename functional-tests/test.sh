#!/bin/bash
export SLAP_GIT_BRANCH="master"
SLAP_GIT_REPOSITORY="ECloud"
SETUP_IMAGES=true
SAVE_IMAGES=false
DEVELOPING=false
KILL_INSTANCES=true
H=$PWD
BUILD=$H/functional-tests/build
TMP=$BUILD/temp
URL_ADM=http://localhost:8090/admission
GIT=$H/functional-tests/egit-clone
export LS_LIKE_OLD=true
export DEVELOPING

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
echo "TTY=$TTY"

function log() {
    echo -e $(date +"%T")" ------ ""$1"
}

# SETUP GIT
log "Preparando repositorios git necesarios para el test"
[ -d $BUILD ] && rm -rf $BUILD
mkdir -p $BUILD
[ ! -d $TMP ] && mkdir -p $TMP
cd $BUILD
[ ! -d examples ] && $GIT examples ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
[ ! -d http-sep ] && $GIT http-sep ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}


# SETUP IMAGES
log "Preparando imagen docker"
docker rm -f local-stamp 2>/dev/null
if [ "$SETUP_IMAGES" == "true" ]; then
  export tag="eslap.cloud/local-stamp:99_0_0"
  docker rmi -f $tag 2>/dev/null
  cd $H/server/image
  . dockerBuild.sh
fi
# SETUP LOCAL-STAMP
log "Iniciando local-stamp"

cd $H
version=$(docker images|grep local-stamp| awk '{gsub("_"," ",$2);print $2" "$3}'|sort -k 1rn -k 2rn -k 3rn|head -n 1|cut -d\  -f4)
LS_DOCKER_NAME=eslap.cloud/local-stamp:$(docker images|grep $version|awk '{print $2}')
export LS_DOCKER_NAME
log "Using image $LS_DOCKER_NAME"

SCRIPT_DIR=''

function endTest {
  cd $H
  fase=$1
  if [ -n "$fase" ]; then
    log "Error en fase $fase"
  else
    log "Finalizó correctamente la ejecución completa del test"
  fi
  ([ "$KILL_INSTANCES" == true ] || [ -z "$fase" ] ) && (docker ps -a|grep "local-stamp"|grep -v "local-stamp-logger"|cut -f1 -d\ |xargs -r docker rm -f)
  [ -n "$fase" ] && exit 1
  exit 0
}

function find_port {
  tmpfile=$2
  SERVICE=$1
  jq -r '.data.deployments.successful|map(select(.topology.service | contains("'$SERVICE'")))[0].topology.portMapping[0].port' $tmpfile
}

function find_deployment {
  tmpfile=$2
  SERVICE=$1
  echo "find_deployment $1 $2" 1>&2
  jq -r '.data.deployments.successful|map(select(.topology.service | contains("'$SERVICE'")))[0].deploymentURN' $tmpfile 1>&2
  jq -r '.data.deployments.successful|map(select(.topology.service | contains("'$SERVICE'")))[0].deploymentURN' $tmpfile
}

function find_domain {
  tmpfile=$2
  SERVICE=$1
  domain=$(  jq -r '.data.deployments.successful|map(select(.topology.service | contains("'$SERVICE'")))[0].topology.roles.sep_service.entrypoint.domain' $tmpfile)
  if [ "$domain" == "null" ]; then
    echo $domain
  else
    echo "$domain:8090"
  fi
}

function deploy {
  BUNDLE=$1
  tmpfile=$2
  curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE|tee $tmpfile|jq .
}

function undeploy {
  deployment=$1
  curl -X DELETE -sk -m 60000  $URL_ADM/deployments?urn=$deployment|jq .
}

pushd "$(dirname "$(readlink -f "$BASH_SOURCE")")" > /dev/null && {
    SCRIPT_DIR="$PWD"
    popd > /dev/null
}
LOCAL_STAMP_DIR="$SCRIPT_DIR/.."

$LOCAL_STAMP_DIR/server/scripts/_local-stamp-start.sh &

sleep 40
COUNTER=0
while : ;do
  [ $COUNTER == 100 ] && endTest 'LAUNCH-LOCALSTAMP'
  [ "$(curl -s $URL_ADM/deployments|jq -r '.success')" == "true" ] && break
  COUNTER=$[COUNTER+1]
  echo "Intento de conexión a local-stamp $COUNTER..."
  sleep 10
done

sleep 10

# log "Populating storage"
# MSTORAGE="/tmp/local-stamp/manifest-storage/remote"
# sourceF="$BUILD/http-sep"
# echo "docker run --rm $TTY -v $MSTORAGE:/tmp/storage -v $sourceF:/tmp/sourceF --entrypoint bash eslap.cloud/runtime/native:1_0_0 -c '
#   cd /tmp/storage
#   mkdir -p slapdomain/components/httpsep/0_0_1
#   cp /tmp/sourceF/manifests/manifest.json slapdomain/components/httpsep/0_0_1
# '"

# docker run --rm -v $MSTORAGE:/tmp/storage -v $sourceF:/tmp/sourceF --entrypoint bash eslap.cloud/runtime/native:1_0_0 -c '
#   cd /tmp/storage
#   mkdir -p slapdomain/components/httpsep/0_0_1
#   cp /tmp/sourceF/manifests/manifest.json slapdomain/components/httpsep/0_0_1
# '
# find $MSTORAGE/|grep http
log "Executing tests"

TESTS=$H/functional-tests/tests
cd $TESTS

tests=$(find|grep "/only$"|head -n 1|sed 's/\/only//g;s/^\.\///g')
[ -z "$tests" ] && tests=$(ls|sort)

for test in $tests;do
  if [ -d "${TESTS}/${test}" ]; then
    [ -f $TESTS/$test/skip ] && continue
    log "Starting execution of test $test"
    NAME=$(echo $test)
    cd $TESTS/$test
    . functional-test.sh
    log "Test $test ended correctly"
    sleep 10
  fi
done

endTest
