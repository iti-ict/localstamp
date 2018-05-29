#!/bin/bash

TEST_FOLDER=$PWD
SERVICE="eslap://sampleservicecalculator/services/sampleservicecalculator/1_0_0"
COMPONENT_CFE="eslap://sampleservicecalculator/components/cfe/1_0_0"
COMPONENT_WORKER="eslap://sampleservicecalculator/components/worker/1_0_0"


cd $BUILD/examples/calculator_1_0_0
BUNDLE="$PWD/deploy_calc_bundle.zip"
[ ! -f $BUNDLE ] && ./rezip.sh

tmpfile=$TMP/deploy-$NAME.json
curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE|tee $tmpfile|jq .

port=$(find_port $SERVICE $tmpfile)
deployment=$(find_deployment $SERVICE $tmpfile)

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

log "$NAME. Lanzando petición de prueba."

calcRequest $port "$TMP/http-result-$NAME" "$TMP/http-result-$NAME-1" "TEST-$NAME"

tmpfile=$TMP/undeploy-$NAME.json
log "$NAME. Replegando a $deployment"
curl -s -X DELETE $URL_ADM/deployments?urn=$deployment|tee $tmpfile|jq .

success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNDEPLOY-$NAME"

escapedUrn=$(echo -n "$SERVICE"|jq -s -R -r @uri)
tmpfile=$TMP/unregister-service-$NAME.json
curl -s -X DELETE $URL_ADM/registries/$escapedUrn|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNREGISTER-SERVICE-$NAME"

escapedUrn=$(echo -n "$COMPONENT_WORKER"|jq -s -R -r @uri)
tmpfile=$TMP/unregister-worker-$NAME.json
curl -s -X DELETE $URL_ADM/registries/$escapedUrn|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNREGISTER-WORKER-$NAME"

escapedUrn=$(echo -n "$COMPONENT_CFE"|jq -s -R -r @uri)
tmpfile=$TMP/unregister-cfe-$NAME.json
curl -s -X DELETE $URL_ADM/registries/$escapedUrn|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNREGISTER-cfe-$NAME"