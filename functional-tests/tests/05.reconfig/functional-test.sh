#!/bin/bash

TEST_FOLDER=$PWD
SERVICE="eslap://sampleinterservice/services/samplefrontend/1_0_12"

cd $BUILD/examples/interservice-example
BUNDLE="$PWD/front/bundles/deploy_bundle.zip"
[ ! -f $BUNDLE ] && ./rezip.sh

tmpfile=$TMP/deploy-$NAME.json
curl -s $URL_ADM/bundles -F bundlesZip=@$BUNDLE|tee $tmpfile|jq .

port=$(find_port $SERVICE $tmpfile)
deployment=$(find_deployment $SERVICE $tmpfile)
sleep 30
log "$NAME. Lanzando petición de recogida de configuracion."
curl -s "localhost:$port/restapi/config"|jq . > $TMP/$NAME-config0
diff $TMP/$NAME-config0 $TEST_FOLDER/config0
status=$?
echo ""
[ $status != 0 ] && endTest "INITIAL_CONFIG-$NAME"

jq '.deploymentUrn = "'$deployment'"' $TEST_FOLDER/inline.json > $TMP/reconfig-inline.json

log "$NAME. Reconfigurando servicio"
curl -s -X PUT localhost:8090/admission/deployments/configuration -F inline=@$TMP/reconfig-inline.json|jq .

log "$NAME. Lanzando segunda petición de recogida de configuracion."
curl -s "localhost:$port/restapi/config"|jq . > $TMP/$NAME-config1
echo ""
diff $TMP/$NAME-config1 $TEST_FOLDER/config1
status=$?
echo ""
[ $status != 0 ] && endTest "MODIFIED_CONFIG-$NAME"

cd $TEST_FOLDER