#!/bin/bash

TEST_FOLDER=$PWD
SERVICE="eslap://httphelloworld/services/httpechoreflexduplex/1_0_0"
COMPONENT_CFE="eslap://httphelloworld/components/cfeherd/1_0_0"


cd $BUILD/examples/http-echo-reflex-duplex
BUNDLE="$PWD/bundles/deploy_bundle.zip"
[ ! -f $BUNDLE ] && ./rezip.sh

tmpfile=$TMP/deploy-$NAME.json
curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE|tee $tmpfile|jq .

port=$(find_port $SERVICE $tmpfile)
deployment=$(find_deployment $SERVICE $tmpfile)
sleep 30
log "$NAME. Lanzando petición de prueba de membresia."
MSHIP=""
for inc in `seq 0 2`;do
  PMSHIP=$(curl -s "localhost:$[port+inc]?cmd=workers")
  if [ -n "$MSHIP" ]; then
    if [ "$PMSHIP" != "$MSHIP" ]; then
      endTest "$NAME. Membership inconsistent: $MSHIP -- $PMSHIP"
    fi
  fi
  MSHIP=$PMSHIP
done
if [ -z "$MSHIP" ]; then
  endTest "$NAME. Membership was not obtained"
fi

echo "MSHIP: $MSHIP"


declare -a workers=$(echo $MSHIP|sed 's/\[/(/;s/\]/)/;s/,/ /g')

log "$NAME. Lanzando peticion de prueba de echo"
for inc in `seq 0 2`;do
  for worker in `seq 0 2`;do
    [ "$response" != "$expected" ] && endTest "$NAME. Unexpected response. Expected: $expected. Obtained: $response"
  done
done

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

escapedUrn=$(echo -n "$COMPONENT_CFE"|jq -s -R -r @uri)
tmpfile=$TMP/unregister-cfe-$NAME.json
curl -s -X DELETE $URL_ADM/registries/$escapedUrn|tee $tmpfile|jq .
success=$(jq -r '.success' $tmpfile)
[ "$success" != "true" ] && endTest "UNREGISTER-cfe-$NAME"
cd $TEST_FOLDER