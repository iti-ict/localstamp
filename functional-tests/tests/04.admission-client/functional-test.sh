#!/bin/bash
NODE_IMAGE=eslap.cloud/runtime/native/dev/privileged:2_0_0
ACT_CONFIG=$PWD/admission-client/test/test-config.json
EXAMPLES=$BUILD/examples
DIR=$PWD

function setValue {
  file=$1
  key=$2
  value=$3
  cat $file |
  jq 'to_entries |
       map(if .key == "'$key'"
          then . + {"value":"'$value'"}
          else .
          end
         ) |
      from_entries' > $file.tmp
  mv $file.tmp $file
}

[ -d admission-client ] && docker run --rm --entrypoint bash -v $PWD:/stuff $NODE_IMAGE -c "cd /stuff/;rm -rf admission-client"

[ -d admission-client ] && rm -rf admission-client
$GIT admission-client ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
cd admission-client

docker run --rm --entrypoint bash -v $PWD:/stuff $NODE_IMAGE -c "cd /stuff; npm install"
setValue test/test-config.json acsUri http://172.17.0.1:8090/acs
setValue test/test-config.json admissionUri http://172.17.0.1:8090/admission

[ ! -f $EXAMPLES/calculator_1_0_0/deploy_bundle.zip ] && cd $EXAMPLES/calculator_1_0_0 && ./rezip.sh
[ ! -f $EXAMPLES/interservice-example/front/bundles/deploy_bundle.zip ] && cd $EXAMPLES/interservice-example && ./rezip.sh

cd $DIR/admission-client
docker run --rm --entrypoint bash -v $PWD:/stuff -v $EXAMPLES:/examples $NODE_IMAGE -c "cd /stuff;npm run spec"
result=$?
cd $DIR
docker run --rm --entrypoint bash -v $PWD:/stuff $NODE_IMAGE -c "cd /stuff/;rm -rf admission-client"
[ "$result" != "0" ] && endTest "ADMISSION-CLIENT"
