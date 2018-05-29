#!/bin/bash

TEST_FOLDER=$PWD
SERVICE_FRONT="eslap://sampleinterservice/services/samplefrontend/1_0"
SERVICE_BACK="eslap://sampleinterservice/services/samplebackend/1_0"

cd $BUILD/examples/interservice-example
BUNDLE_FRONT="$PWD/front/bundles/deploy_bundle.zip"
BUNDLE_BACK="$PWD/back/bundles/deploy_bundle.zip"
[ ! -f $BUNDLE_FRONT ] && ./rezip.sh

log "Desplegando front"
tmpfile=$TMP/deploy-$NAME-front.json
curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE_FRONT|tee $tmpfile|jq .

port=$(find_port $SERVICE_FRONT $tmpfile)
deployment_front=$(find_deployment $SERVICE_FRONT $tmpfile)

[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-FRONT"

log "Desplegando segundo front"
tmpfile=$TMP/deploy-$NAME-front2.json
BUNDLE_FRONT2=$TMP/deploy-front2.zip
zip $BUNDLE_FRONT2 $BUILD/examples/interservice-example/front/Manifest.json
curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE_FRONT2|tee $tmpfile|jq .

port2=$(find_port $SERVICE_FRONT $tmpfile)
deployment_front2=$(find_deployment $SERVICE_FRONT $tmpfile)
[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-FRONT2"

log "Desplegando back"
tmpfile=$TMP/deploy-$NAME-back.json
curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE_BACK|tee $tmpfile|jq .
deployment_back=$(find_deployment $SERVICE_BACK $tmpfile)

[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-BACK"


echo '{
  "spec": "http://eslap.cloud/manifest/link/1_0_0",
  "endpoints": [
    {
      "deployment": "'$deployment_front'",
      "channel": "back"
    },
    {
      "deployment": "'$deployment_back'",
      "channel": "service"
    }
  ]
}
' > $TMP/$NAME-link.json


log "Realizando primer link back-front"
tmpfile=$TMP/deploy-$NAME-link.json
curl -s $URL_ADM/links -F linkManifest=@$TMP/$NAME-link.json|tee $tmpfile|jq .
[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-LINK"

function calcRequest {
  pPORT=$1
  pTMP=$2
  pPHASE=$3
  for i in $(seq 1 5); do
    log "Haciendo petición a entry point en puerto $pPORT. Intento $i"
    rm $pTMP 2>/dev/null
    curl --silent  --show-error --max-time 30 -H "Content-Type: application/json" -X POST -d '{"value1":45,"value2":35}' http://localhost:$pPORT/restapi/add |tee $pTMP
    echo ""
    if (( $(grep -c '"result":80' $pTMP) == 1 ));then break; else sleep 15;fi
  done
  if (( $(grep -c '"result":80' $pTMP) == 0 ));then endTest "$pPHASE";fi
}

log "$NAME. Lanzando petición de prueba con 1 link."

calcRequest $port "$TMP/http-result-$NAME" "$TMP/http-result-$NAME-1" "TEST-$NAME"

echo '{
  "spec": "http://eslap.cloud/manifest/link/1_0_0",
  "endpoints": [
    {
      "deployment": "'$deployment_front2'",
      "channel": "back"
    },
    {
      "deployment": "'$deployment_back'",
      "channel": "service"
    }
  ]
}
' > $TMP/$NAME-link2.json

log "Realizando segundo link back-front2"
tmpfile=$TMP/deploy-$NAME-link2.json
curl -s $URL_ADM/links -F linkManifest=@$TMP/$NAME-link2.json|tee $tmpfile|jq .
[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-LINK2"

calcRequest $port2 "$TMP/http-result-$NAME_2" "$TMP/http-result-$NAME-2" "TEST-$NAME_2"

calcRequest $port "$TMP/http-result-$NAME_1_2" "$TMP/http-result-$NAME-1-2" "TEST-$NAME_1_2"

log "Deshaciendo primer link back-front"
curl -s -X DELETE $URL_ADM/links -F linkManifest=@$TMP/$NAME-link.json|tee $tmpfile|jq .
[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-UNLINK"

calcRequest $port2 "$TMP/http-result-$NAME_2" "$TMP/http-result-$NAME-2-2" "TEST-$NAME_2_2"

curl -s -X DELETE $URL_ADM/links -F linkManifest=@$TMP/$NAME-link2.json|tee $tmpfile|jq .
[ "$(jq -r '.success' $tmpfile)" != "true" ] && endTest "DEPLOY-$NAME-UNLINK2"

tmpfile=$TMP/undeploy-$NAME-FRONT.json
log "$NAME. Replegando a $deployment_front"
curl -s -X DELETE $URL_ADM/deployments?urn=$deployment_front|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNDEPLOY-$NAME-FRONT"

tmpfile=$TMP/undeploy-$NAME-FRONT2.json
log "$NAME. Replegando a $deployment_front2"
curl -s -X DELETE $URL_ADM/deployments?urn=$deployment_front2|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNDEPLOY-$NAME-FRONT2"


tmpfile=$TMP/undeploy-$NAME-BACK.json
log "$NAME. Replegando a $deployment_back"
curl -s -X DELETE $URL_ADM/deployments?urn=$deployment_back|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNDEPLOY-$NAME-BACK"