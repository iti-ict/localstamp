#!/bin/bash

NAME2="$NAME-phase2"
SERVICE="eslap://volumesexample.examples.ecloud/services/volumeTester/0_0_1"
export KEY=$RANDOM

cd $BUILD/examples/volumes-example
./rezip.sh
# El deploy bundle se genera en ./bundles/deploy_bundle.zip
BUNDLE="$PWD/bundles/deploy_bundle.zip"
tmpfile=$TMP/deploy-$NAME.json
deploy $BUNDLE $tmpfile

# El test recoge los datos de a donde debe hacer las peticiones mediante
# variables de entorno
export DEPLOY_DOMAIN=$(find_domain $SERVICE $tmpfile)
export DEPLOY_IP=$DEPLOY_DOMAIN

[ "$DEPLOY_DOMAIN" == "null" ] && endTest "$DEPLOY-$NAME"

deployment=$(find_deployment $SERVICE $tmpfile)

sleep 5

cd tests
MOCHA="./node_modules/.bin/mocha"
while true; do
  [ -f $MOCHA ] && break
  [ -d node_modules ] && rm -rf node_modules
  npm install
done

log "Utilizando key aleatoria $KEY"
log "Utilizando dominio $DEPLOY_DOMAIN"
log "Utilizando IP $DEPLOY_IP"

for i in $(seq 1 5); do
    log "Test Mocha $NAME. Intento $i"
    rm $TMP/test-$NAME 2>/dev/null
    $MOCHA --compilers coffee:coffee-script/register --reporter spec functional/functional-phase1.test.coffee &> $TMP/test-$NAME
    RESULT=$?
    cat $TMP/test-$NAME
    [ $RESULT == 0 ] && break || sleep 15
done
[ $RESULT != 0 ] && endTest "TEST-$NAME"

undeploy $deployment

#Iniciamos fase 2
cd ..
deploy $BUNDLE $tmpfile
export DEPLOY_DOMAIN=$(find_domain $SERVICE $tmpfile)
export DEPLOY_IP=$DEPLOY_DOMAIN
deployment=$(find_deployment $SERVICE $tmpfile)
[ "$DEPLOY_DOMAIN" == "null" ] && endTest "$DEPLOY-$NAME-2"
sleep 5
cd tests
for i in $(seq 1 5); do
    log "Test Mocha $NAME2. Intento $i"
    rm $TMP/test-$NAME2 2>/dev/null
    $MOCHA --compilers coffee:coffee-script/register --reporter spec functional/functional-phase2.test.coffee &> $TMP/test-$NAME2
    RESULT=$?
    cat $TMP/test-$NAME2
    [ $RESULT == 0 ] && break || sleep 15
done
[ $RESULT != 0 ] && endTest "TEST-$NAME-2"

undeploy $deployment
