should            = require 'should'
q                 = require 'q'
http              = require 'http'
qs                = require 'querystring'
LocalStamp        = require '..'
Component         = require 'component'

clockPort = null
frontPort = null
volumePort = null
a = null

EXAMPLES='/workspaces/slap/git/examples'
BUNDLE="#{EXAMPLES}/java-example/bundles/deploy_bundle.zip"
INTERSERVICE="#{EXAMPLES}/interservice-example"
INTERSERVICE_BACK="#{INTERSERVICE}/back/bundles/deploy_bundle.zip"
INTERSERVICE_FRONT="#{INTERSERVICE}/front/bundles/deploy_bundle.zip"
RESOURCES_BUNDLE="#{EXAMPLES}/java-web-example/bundles/deploy_bundle.zip"

TEST_BUNDLE ="#{process.cwd()}/tests/bundle-test.zip"

describe 'Local stamp - Bundle Support', ->

  @timeout 40 * 1000
  before ->
    a = new LocalStamp('test',{runtimeFolder:'/tmp/runtime-agent'})
    a.init()
    .then ->
      console.log 'Workspace ready'

  after (done)->
    a.shutdown()
    .then ->
      done()

  it 'Normal bundle', ->
    a.launchBundle BUNDLE
    .then (result)->
      console.log "DEPLOYMENT: #{JSON.stringify result, null, 2}"
      deployment = result.deployments.successful[0]
      clockPort = deployment.portMapping[0].port
      q.delay 3500
    .then ->
      deferred = q.defer()
      console.log 'Haciendo petición a clockAPI'
      clockAPI =
        hostname: '127.0.0.1'
        method: 'GET'
        port: clockPort
        path: '/mola?username=Peras&password=Peras'
      http.request clockAPI, (res) ->
        res.on 'data', (chunk) ->
          result = chunk.toString()
          console.log result
          result = JSON.parse result
          result.should.have.property 'clock'
          deferred.resolve true
      .end()
      deferred.promise

  describe 'Interconnecting services', ->

    frontDeployment = backDeployment = null

    it 'Normal connection', ->
      @timeout 60 * 1000
      a.launchBundle INTERSERVICE_BACK
      .then (result)->
        console.log "DEPLOYMENT: #{JSON.stringify result, null, 2}"
        deployment = result.deployments.successful[0]
        backDeployment = deployment.deploymentURN
        a.launchBundle INTERSERVICE_FRONT
      .then (result)->
        console.log "DEPLOYMENT: #{JSON.stringify result, null, 2}"
        deployment = result.deployments.successful[0]
        frontDeployment = deployment.deploymentURN
        frontPort = deployment.portMapping[0].port
        q.delay 3500
      .then ->
        console.log 'Conectando canales...'
        a.connectDeployments
          spec: 'http://eslap.cloud/manifest/link/1_0_0'
          endpoints: [
            {
              deployment: frontDeployment
              channel: 'back'
            },
            {
              deployment: backDeployment
              channel: 'service'
            }
          ]
        console.log 'Servicios conectados'
        console.log 'Haciendo petición a calculatorAPI'
        deferred = q.defer()
        calculatorAPI =
          hostname: '127.0.0.1'
          method: 'POST'
          port: frontPort
          headers: {'Content-Type': 'application/json'}
          path: '/restapi/add'
        req = http.request calculatorAPI, (res) ->
          res.on 'data', (chunk) ->
            result = chunk.toString()
            console.log result
            result = JSON.parse result
            result.result.should.be.eql 80
            deferred.resolve true
        req.write JSON.stringify {value1:45,value2:35}
        req.end()
        deferred.promise

    it 'Connects a tester to a bundle', ->
      TESTER_COMPONENT_CONFIG =
        iid: 'IS-tester'
        incnum: 1
        parameters: {}
        role: 'tester'
        offerings: []
        dependencies: [{id:'test',type:'Request'}]
      a.launch InterserviceTester, TESTER_COMPONENT_CONFIG, frontDeployment
      .then ->
        a.connect 'loadbalancer',
          [{role:'cfe', endpoint:'test'}],
          [{role:'tester', endpoint:'test'}],
          frontDeployment
        a.instances['IS-tester'].instance.case0(21, 37)
      .then (result)->
        console.log "Vía IS-tester se obtiene #{JSON.stringify result}"
        result.result.should.be.eql 58

  it 'Works with resources', ->
    @timeout 45 * 1000 * 500
    a.launchBundle RESOURCES_BUNDLE
    .then (result)->
      console.log "DEPLOYMENT: #{JSON.stringify result, null, 2}"
      deployment = result.deployments.successful[0]
      volumePort = deployment.portMapping[0].port
      q.delay 3500
    .then ->
      deferred = q.defer()
      query =
        operation: 'read'
        volume: 'volatile'
      volumeAPI =
        hostname: '127.0.0.1'
        method: 'GET'
        port: volumePort
        path: "/java-resources-web-example/rest?#{qs.stringify query}"
      console.log "Haciendo petición a volumeAPI: #{JSON.stringify volumeAPI}"
      req = http.request volumeAPI, (res) ->
        res.statusCode.should.be.eql 400
        res.on 'data', (chunk) ->
          result = chunk.toString()
          console.log result
          result = JSON.parse result
          result.success.should.be.eql false
          result.error.should.be.eql 'No data'
          deferred.resolve true
      req.end()
      deferred.promise
    .then ->
      deferred = q.defer()
      query =
        operation: 'write'
        volume: 'volatile'
        data: 'Hello Donald'
      volumeAPI =
        hostname: '127.0.0.1'
        method: 'GET'
        port: volumePort
        path: "/java-resources-web-example/rest?#{qs.stringify query}"
      console.log "Haciendo petición a volumeAPI: #{JSON.stringify volumeAPI}"
      req = http.request volumeAPI, (res) ->
        res.statusCode.should.be.eql 200
        res.on 'data', (chunk) ->
          result = chunk.toString()
          console.log result
          result = JSON.parse result
          result.success.should.be.eql true
          result.data.should.be.eql 'OK'
          deferred.resolve true
      req.end()
      deferred.promise
    .then ->
      deferred = q.defer()
      query =
        operation: 'read'
        volume: 'volatile'
      volumeAPI =
        hostname: '127.0.0.1'
        method: 'GET'
        port: volumePort
        path: "/java-resources-web-example/rest?#{qs.stringify query}"
      console.log "Haciendo petición a volumeAPI: #{JSON.stringify volumeAPI}"
      req = http.request volumeAPI, (res) ->
        res.statusCode.should.be.eql 200
        res.on 'data', (chunk) ->
          result = chunk.toString()
          console.log result
          result = JSON.parse result
          result.success.should.be.eql true
          result.data.should.be.eql 'Hello Donald'
          deferred.resolve true
      req.end()
      deferred.promise

  it.skip 'Test bundle', (done)->
    @timeout 120 * 60 * 1000
    a.launchBundle TEST_BUNDLE
    .then (result)->
      console.log "DEPLOYMENT: #{JSON.stringify result, null, 2}"
      do done

class InterserviceTester extends Component
  constructor: (@runtime, @role, @iid, @incnum, @localData, @resources
  , @parameters, @dependencies, @offerings) ->
    # NOTHING
  run: ->
    @running = true

  case0: (s1, s2)->
    @dependencies.test.sendRequest JSON.stringify {value1:s1, value2:s2}
    .then (value)->
      JSON.parse value.message.toString()


process.on 'uncaughtException', (e)->
  console.error 'uncaughtException:', e.stack

process.on 'unhandledRejection', (reason, p)->
  console.log 'Unhandled Rejection at: Promise', p, 'reason:', reason