Launcher             = require './component-launcher'
MockPlanner          = require './mock-planner'
MockRouterAgent      = require './mock-ra'
WebsocketPublisher   = require './websocket-publisher'
Resources            = require './resources'
State                = require './state'

q  = require 'q'
net = require 'net'
child = require 'child_process'
spawn = child.spawn
exec = require('child_process').exec
execSync = require('child_process').execSync
spawnSync = require('child_process').spawnSync
fs = require 'fs'
http = require 'http'
path = require 'path'
Docker = require 'dockerode'

GW = require 'gateway-component'
AdmissionM = (require 'admission')
AdmissionRestAPI = AdmissionM.AdmissionRestAPI
supertest = require 'supertest'
ksockets = require 'k-sockets'
klogger = require 'k-logger'
kutils = require 'k-utils'

KIBANA_IMAGE='eslap.cloud/elk:1_0_0'
KIBANA_DOCKER='local-stamp-logger'

DEFAULT_CONFIG =
  daemon: true
  kibana: true
  stopLogger: false
  destroyLogger: false
  autoUnregister: false
  autoUndeploy: false

CONTAINER_USABLE_MEMORY_PER_UNIT = 512*1024*1024 # 512MB
CONTAINER_SWAP_MEMORY_PER_UNIT = CONTAINER_USABLE_MEMORY_PER_UNIT / 2 # 256MB
CONTAINER_TOTAL_MEMORY_PER_UNIT = CONTAINER_USABLE_MEMORY_PER_UNIT+
                                  CONTAINER_SWAP_MEMORY_PER_UNIT
CONTAINER_RESERVED_MEMORY_PER_UNIT = CONTAINER_USABLE_MEMORY_PER_UNIT / 2 #256MB
CONTAINER_KERNEL_MEMORY_PER_UNIT = CONTAINER_USABLE_MEMORY_PER_UNIT / 2 # 256MB
CONTAINER_DEV_SHM_SIZE_PER_MEMORY_UNIT = CONTAINER_RESERVED_MEMORY_PER_UNIT / 2
SWAP_WARNING='WARNING: Your kernel does not support swap limit capabilities'

DealerSocket = ksockets.DealerSocket
DealerReqRep = ksockets.DealerReqRep

express = require 'express'
bodyParser = require 'body-parser'
multer = require 'multer'
cors = require 'cors'
app = null
initialMappedPort = 9000
silencedClasses = [
  'Admission'
  'AdmissionRestAPI'
  'DealerReqRep'
  'ServiceRegistry'
  'ComponentRegistry'
  'BundleRegistry'
  'ManifestStoreRsync'
  'ManifestConverter'
  'ManifestValidator'
  'ManifestStore'
  'ManifestHelper'
  'RuntimeAgent'
]

class LocalStamp

  constructor: (@id = 'test', @config = {})->
    @logger = klogger.getLogger 'LocalStamp'
    @repos =
      logFile: '/eslap/runtime-agent/slap.log'
      manifests: '/eslap/manifest-storage'
      images: '/eslap/image-storage'
      instances: '/eslap/instances'
      volumes: '/eslap/volumes'
    filterLog @logger, silencedClasses, ['error']
    # Hace un rsync de prueba que genera un error. Lo silencio del todo.
    filterLog @logger, ['ImageFetcher', 'DealerSocket']
    @dockerIP = getDocker0IfaceHostIPAddress.call this
    @state = new State()
    @routerAgent = new MockRouterAgent this
    @launcher = new Launcher this
    # Keeps track of used resources (related to services deployed or deploying)
    @resourcesInUse = new Resources()
    @state.addDeployment 'default'
    @deploymentCounter = 1
    @instanceCounter = 1
    @busyPorts = {}
    @links = {}
    @docker = new Docker()
    @graceTime = 1000
    @admissionPort = @config.admissionPort ? 8090
    @domain = @config.domain ? 'local-stamp.slap53.iti.es'
    @configLogger = @config.logger ?
      vm: 'local-stamp'
      transports:
        file:
          level: 'debug'
          filename: 'slap.log'
        console:
          level: 'warn'
    @develBindings = @config.develBindings ? {}
    @admission_conf =
      imageFetcher :
        type : 'blob'
        config:
          remoteImageStore:
            path : "#{@repos.images}/remote"
            imageFilename : 'image.tgz'
          localImageStore :
            path : "#{@repos.images}/local"
            imageFilename : 'image.tgz'
      manifestRepository:
        type : 'rsync'
        config :
          remoteImageStore:
            path : "#{@repos.manifests}/remote"
            imageFilename : 'manifest.json'
          localImageStore:
            path : "#{@repos.manifests}/local"
            imageFilename : 'manifest.json'
      acs:
        'anonymous-user':
          id: 'local-stamp',
          roles: ['ADMIN']
        'addresses': ["127.0.0.1"]
        'port': @admissionPort
      domains:
        refDomain: @domain
      limitChecker:
        limits:
          max_bundle_size: 10
          max_storage_space: 10
          deployment_lifespan_days: 10
          allow_resources: true
          allow_domains: true
          allow_certificates: true
          allow_volumes: true
          allow_iopsintensive: true
          deployments:
            simultaneous: -1
          entrypoints:
            simultaneous: -1
          roles:
            deployment: -1
            simultaneous: -1
          maxinstances:
            arrangement: -1
            deployment: -1
            simultaneous: -1
          cpu:
            arrangement: -1
            deployment: -1
            simultaneous: -1
          memory:
            arrangement: -1
            deployment: -1
            simultaneous: -1
          ioperf:
            arrangement: -1
            deployment: -1
            simultaneous: -1
          bandwidth:
            arrangement: -1
            deployment: -1
            simultaneous: -1
    # To avoid errors with instances that do not launch an admission instance
    @wsp = {publishEvt: -> true}

  init: ->
    deferred = q.defer()

    socket = process.env.DOCKER_SOCKET || '/var/run/docker.sock'
    stats  = fs.statSync(socket)

    if !stats.isSocket()
      return q.reject new Error 'Are you sure the docker is running?'

    @docker.listContainers {all:true}, (err, containers)=>
      return deferred.reject err if err
      promises = []
      for c in containers
        if c.Names?[0]? and kutils.startsWith(c.Names[0], "/local-stamp_#{@id}_")
          @logger.debug "Removing previous docker instance #{c.Names[0]}"
          fc = @docker.getContainer(c.Id)
          do (fc)->
            promises.push (q.ninvoke fc, 'remove', {force: true})
      q.all promises
      .then ->
        deferred.resolve true
    deferred.promise
    .then =>
      # q.ninvoke child, 'exec', " \
      #   rm -rf #{@lsRepo}; \
      #   rm -rf /tmp/slap; \
      #   mkdir -p #{@lsRepo}/manifest-storage/local/; \
      #   mkdir -p #{@lsRepo}/manifest-storage/remote/; \
      #   cp -R /eslap/manifest-storage/* #{@lsRepo}/manifest-storage/remote/; \
      #   mkdir -p #{@lsRepo}/image-storage/local/; \
      #   mkdir -p #{@lsRepo}/image-storage/remote/; \
      #   cp -R /eslap/image-storage/* #{@lsRepo}/image-storage/remote/;"
      q true
    .then =>
      if @configValue 'kibana'
        launchKibana.call this
    .then =>
      if @configValue 'daemon'
        launchAdmission.call this

  launchBundle: (path)->
    (if not @admAPI
      launchAdmission.call this
    else
      q true
    )
    .then =>
      @logger.debug "Processing bundle in #{path}"
      deferred = q.defer()
      @admRest.post '/bundles'
        .attach 'bundlesZip', path
        .end (err, res)=>
          if err?
            deferred.reject err
            return
          if res.status != 200
            @logger.error JSON.stringify res, null, 2
            deferred.reject new Error 'Unexpected result registering bundle'
            return
          # se.log JSON.stringify text, null, 2
          @logger.debug 'Bundle correctly deployed'
          if res.text?
            res = JSON.parse res.text
            res = res.data
            # if res?.deployments?.errors?[0]?
            #   return deferred.reject \
            #   new Error JSON.stringify res.deployments.errors[0]
          setTimeout ->
            deferred.resolve res#.deployments.successful[0]
          , 3500
      deferred.promise


  launch: (klass, config, deploymentId = 'default')->
    @launcher.launch(klass, config, deploymentId)
    .then (result)=>
      @state.addInstance deploymentId, result, config
      result

  launchGW: (localConfig, config, deploymentId = 'default')->
    config.parameters['__gw_local_config'] = localConfig
    @launcher.launch(GW, config, deploymentId)
    .then (result)=>
      result.isGW = true
      @state.addInstance deploymentId, result, config
      result

  launchDocker: (localConfig, config, deployment = 'default')->
    console.log "Launching instance #{config.iid}"
    iid = config.iid
    ifolder = @instanceFolder iid
    promiseSocket = promiseStarted = null
    dealer = control = name = null
    instanceFolder = socketFolder = tmpFolder = null
    # First we check if runtime specified is available
    checkDockerImage.call this, localConfig.runtime
    .then (found)=>
      if not found
        console.error "Docker image for runtime #{localConfig.runtime} is \
          not available. Check the platform documentation for information \
          on obtaining images of runtimes"
        return q.reject new Error "Runtime #{localConfig.runtime} \
          is not available"

      [promiseSocket, promiseStarted] = \
        @routerAgent.setupInstance config, deployment

      promiseSocket
    .then (setupData)=>
      [control, dealer, sockets] = setupData
      name = "local-stamp_#{@id}_#{iid}"

      result = {
        dealer: dealer
        control: control
        isDocker: true
        dockerName: name
        logging: true
        deployment: deployment
      }
      @state.addInstance deployment, result, config


      # This is "simply" a touch slap.log
      fs.closeSync(fs.openSync(ifolder.local.log, 'w'))

      tmpPath =
      commandLine="\
        run \
        --rm \
        --name #{name} \
        -v #{ifolder.host.component}:#{localConfig.sourcedir} \
        -v #{ifolder.host.data}:/eslap/data \
        -v #{ifolder.host.log}:#{@repos.logFile} \
        -e RA_CONTROL_SOCKET_URI=#{sockets.control.uri} \
        -e RA_DATA_SOCKET_URI=#{sockets.data.uri} \
        -e IID=#{config.iid}"

      agentFolder = null
      if localConfig.agentPath
        agentFolder = localConfig.agentPath.host
      if agentFolder?
        commandLine = commandLine + " -v #{agentFolder}:/eslap/runtime-agent"
      if localConfig?.resources?.__memory?
        m = localConfig.resources.__memory
        memoryConstraints = [
          {constraint: 'memory', factor: CONTAINER_USABLE_MEMORY_PER_UNIT}
          {constraint: 'memory-swap', factor: CONTAINER_TOTAL_MEMORY_PER_UNIT}
          {constraint: 'memory-reservation', \
            factor: CONTAINER_RESERVED_MEMORY_PER_UNIT}
          {constraint: 'kernel-memory', \
            factor: CONTAINER_KERNEL_MEMORY_PER_UNIT}
          {constraint: 'shm-size', \
            factor: CONTAINER_DEV_SHM_SIZE_PER_MEMORY_UNIT}
        ]
        memoryCmd = ""
        for mc in memoryConstraints
          memoryCmd = " #{memoryCmd} --#{mc.constraint} #{m * mc.factor}"
        commandLine = commandLine + memoryCmd + ' '

      # if localConfig.runtime is 'eslap.cloud/runtime/java:1_0_1'
      # commandLine = "#{commandLine}
      # -v /workspaces/slap/git/gateway-component/src:/eslap/gateway-component/src \
      # -v /workspaces/slap/git/runtime-agent/src:/eslap/runtime-agent/src \
      # -v /workspaces/slap/git/slap-utils/src:/eslap/runtime-agent/node_modules/slaputils/src \
      # -v /workspaces/slap/git/gateway-component/node_modules:/eslap/gateway-component/node_modules \
      # -v /workspaces/slap/git/slap-utils/src:/eslap/gateway-component/node_modules/slaputils/src \
      # -v /workspaces/slap/git/slap-utils/src:/eslap/component/node_modules/slaputils/src "
      for v in @config.develBindings?.__all ? []
        commandLine = "#{commandLine} -v #{v}"
      for v in @config.develBindings?[config.role] ? []
        commandLine = "#{commandLine} -v #{v}"

      if localConfig.volumes?
        for v in localConfig.volumes
          commandLine = "#{commandLine} -v #{v}"
      if localConfig.ports?
        for p in localConfig.ports
          commandLine = "#{commandLine} -p #{p}"
      if localConfig.entrypoint?
        commandLine = "#{commandLine} --entrypoint #{localConfig.entrypoint}"
      commandLine = "#{commandLine} #{localConfig.runtime}"
      if localConfig.configdir
        commandLine = "#{commandLine} #{localConfig.configdir}"
      commandLine = commandLine.replace(/ +(?= )/g,'')
      @logger.debug "Creating instance #{config.iid}..."
      @logger.debug "Docker command line: docker #{commandLine}"
      # console.log "Docker command line: docker #{commandLine}"

      try
        client = spawn 'docker',commandLine.split(' ')
        client.stdout.on 'data', (data)=>
          return if not data?
          # return if not (@instances?[config.iid]?.logging is true)
          data = data + ''
          data = data.replace(/[\r\r]+/g, '\r').trim()
          return if data.length is 0
          @logger.debug "DC #{config.iid}: #{data}"
          console.log "DC #{config.iid}: #{data}"
        client.stderr.on 'data', (data)=>
          return if not data?
          # return if not (@instances?[config.iid]?.logging is true)
          return if data.indexOf(SWAP_WARNING) is 0
          @logger.error "DC error #{config.iid}: #{data}"
          #console.error "DC error #{config.iid}: #{data}"
      catch e
        @logger.error "Error launching Docker #{e} #{e.stack}"

      promiseStarted.timeout 60 * 1000, "Instance #{config.iid} did not \
        started properly, this problem is probably related with its runtime.#{ \
          if not localConfig.agentPath? then \
            ' Maybe an agent for this runtime should be configured.' \
          else \
            '' \
          }"
    .then =>
      @state.setInstanceStatus config.iid, {timestamp: (new Date()).getTime()}
      q.delay 3000
    .then =>
      localIP = undefined
      cmd = ['inspect', '-f', '\"{{ .NetworkSettings.IPAddress }}\"', name]
      result = spawnSync 'docker', cmd
      if result.status is 0
        localIP = result.stdout.toString().trim().replace(/(^"|"$)/g, '')
      else if result.stderr?.indexOf 'No such image or container'
        console.log "Instance #{name} finished unexpectedly. Maybe you \
        should examine its log."
      @state.getInstance(iid).dockerIp = localIP
      @wsp.publishEvt 'instance', 'created', {instance: iid}

  shutdownInstance: (iid)->
    deferred = q.defer()
    ref = @state.getInstance iid
    return if not ref?
    ref.logging = false

    (if ref.isDocker
      ref.control.sendRequest {action: 'instance_stop'}
      q true
    else
      ref.runtime.close()
    ).then =>
      setTimeout =>
        if ref.isGW
          ref.instance.destroy()
        else if ref.isDocker
          commandLine="stop #{ref.dockerName}"
          console.log "Shutting down instance #{iid}"
          client = spawn 'docker',commandLine.split(' ')
        ref.dealer.close()
        ref.control.close()
        @state.removeInstance iid
        @wsp.publishEvt 'instance', 'removed', {instance: iid}
        setTimeout ->
          deferred.resolve true
        , 1500
      , @graceTime
    deferred.promise


  loadRuntimes: (runtimes)->
    promise = q true
    for r in runtimes
      do (r)=>
        promise = promise.then =>
          @loadRuntime r
    promise

  loadRuntime: (runtime)->
    rruntime = runtimeURNtoImageName runtime
    checkDockerImage.call this, rruntime
    .then (found)=>
      return true if found
      himgfile = "#{@imageFolder().host}/#{runtimeURNtoPath runtime}"
      limgfile = "#{@imageFolder().local}/#{runtimeURNtoPath runtime}"
      if not fs.existsSync limgfile
        throw new Error "Runtime #{runtime} is not available. Check the \
        platform documentation for information \
        on obtaining images of runtimes"
      commandLine="docker \
          load \
          -i \
          #{limgfile}"
      console.log "Loading runtime #{runtime}..."
      @logger.debug "Loading runtime #{himgfile}..."
      @logger.debug "Docker command line: #{commandLine}"
      try
        code = execSync commandLine
      catch e
        @logger.error "Error loading runtime #{runtime} #{e} #{e.stack}"
        throw e


  shutdown: ->
    promises = []
    for c of @state.getInstances()
      promises.push @shutdownInstance c
    q.all promises
    .then =>
      if @config.destroyLogger
        removeDockerKibana.call this
      else if @config.stopLogger
        stopDockerKibana.call this

  launchAdmission = ->
    @planner = new MockPlanner this
    # @logger.debug 'Creating Admission'
    setMutedLogger [AdmissionRestAPI.prototype,
          AdmissionM.Admission.prototype]
    @admAPI = new AdmissionRestAPI @admission_conf, @planner
    @admAPI.init()
    .then =>
      storage = multer.diskStorage {
        destination: '/tmp/multer'
        filename: (req, file, cb) ->
          name = file.fieldname + '-' + \
                kutils.generateId() + \
                path.extname(file.originalname)
          cb null, name
      }
      upload = multer({ storage: storage }).any()
      app = express()
      app.use bodyParser.json()
      app.use bodyParser.urlencoded({ extended: true })
      app.use upload
      app.use cors()

      app.use '/admission', @admAPI.getRouter()
      app.use '/acs', getMockAcsRouter.call(this)

      # Basic error handler
      app.use (req, res, next) ->
        return res.status(404).send('Not Found')
      # @logger.debug "ADMISSION listening at port #{admissionPort}"
      httpServer = http.createServer(app)
      @wsp = new WebsocketPublisher httpServer, @admAPI.httpAuthentication

      httpServer.listen @admissionPort
    .then =>
      @admRest = supertest "http://localhost:#{@admissionPort}/admission"
      q.delay 2000

  configValue: (key)->
    result = @config[key] ? DEFAULT_CONFIG[key] ? null
    # console.log "Config #{key}: #{result}"
    result

  # allocPort: ->
  #     result = initialMappedPort
  #     while true
  #       sport = result+''
  #       if not @busyPorts[sport]?
  #         @busyPorts[sport] = true
  #         return sport
  #       result++

  # freePort: (port)->
  #   port = port+''
  #   if @busyPorts[port]?
  #     delete @busyPorts[port]

  allocPort: ->
    getNextAvailablePort = (currentPort, cb) ->
      server = net.createServer()
      handleError = ->
        getNextAvailablePort ++currentPort, cb
      try
        server.listen currentPort, '0.0.0.0', ->
          server.once 'close', ->
            cb currentPort
          server.close()
        server.on 'error', handleError
      catch e
        handleError()
    return new Promise (resolve)->
      getNextAvailablePort initialMappedPort, resolve

  # Now ports are handled finding real free ports because docker, many
  # times, does not free bound ports as expected
  freePort: ->
    nowThisFunctionIsUseless = true

  instanceFolder: (iid) ->
    {
      host:
        component: "#{@config.instanceFolder}/#{iid}/component"
        runtime: "#{@config.instanceFolder}/#{iid}/runtime-agent"
        data: "#{@config.instanceFolder}/#{iid}/data"
        log: "#{@config.instanceFolder}/#{iid}/slap.log"
      local:
        component: "#{@repos.instances}/#{iid}/component"
        runtime: "#{@repos.instances}/#{iid}/runtime-agent"
        data: "#{@repos.instances}/#{iid}/data"
        log: "#{@repos.instances}/#{iid}/slap.log"

    }

  volumeFolder: () ->
    {
      host: "#{@config.volumeFolder}"
      local: "#{@repos.volumes}"
    }

  manifestFolder: () ->
    {
      host: "#{@config.manifestStorage}"
      local: "#{@repos.manifests}/remote"
    }

  imageFolder: () ->
    {
      host: "#{@config.imageStorage}"
      local: "#{@repos.images}/remote"
    }

getPort = (cb)->
  port = initialMappedPort
  server = net.createServer()
  server.listen port, (err)->
    server.once 'close', -> cb(port)
    server.close()
  server.on 'error', -> getPort(cb)

launchKibana = ->
  container = @docker.getContainer KIBANA_DOCKER
  q.ninvoke container, 'inspect'
  .then (data)=>
    if not (data?.HostConfig?.PortBindings?['28777/tcp']?)
      console.log 'Restarting logger'
      q.ninvoke container, 'remove', {force: true}
      .then =>
        q.delay 3000
      .then =>
        container = @docker.getContainer KIBANA_DOCKER
        q.ninvoke container, 'inspect'
    else
      data
  .then (data)=>
    return if data?.State?.Status is 'running'
    @logger.debug "Removing docker instance #{KIBANA_DOCKER}..."
    q.ninvoke container, 'remove', {force: true}
    .then =>
      launchDockerKibana.call this
  .fail (e)=>
    return throw e if e.message?.indexOf('404') < 0
    launchDockerKibana.call this
  .then =>
    retries = q.reject false
    for i in [1..5]
      do (i)=>
        retries = retries.fail (e) =>
          q.delay 5000
          .then =>
            container = @docker.getContainer KIBANA_DOCKER
            q.ninvoke container, 'inspect'
    retries
  .then (data)=>
    @loggerIP = data.NetworkSettings.Networks.bridge.IPAddress
    # With iic=false we can't communicate directly to other container
    # We communicate using host docker ip
    @loggerIP = @dockerIP
    ip = @loggerIP
    deferred = q.defer()
    exec = require('child_process').exec;
    counter = 0
    check_logstash = ()->
      nc = exec "nc -z #{ip} 28777", ->
        dummy = 0
      nc.on 'exit', (code)->
        if code is 0
          deferred.resolve()
        else
          if counter>20
            deferred.reject new Error 'Can\'t contact with logstash'
          else
            counter++
            console.log "Local-stamp initialization - Waiting for logstash..."
            setTimeout ->
              check_logstash()
            , 5000
    do check_logstash
    deferred.promise
  .then =>
    deferred = q.defer()
    @configLogger.transports.logstash =
      level: 'debug'
      host: @loggerIP
      port: 28777
    retrier = =>
      @logger.info "Local-stamp connected to logger"
    @logger.configure @configLogger
    consoleSilent = @logger._logger.transports.console.silent
    @logger._logger.transports.console.silent = true
    @logger._logger.transports.logstash.socket.once 'connect', =>
      cl = @logger._logger.transports.console.log
      wcl = (level, msg) =>
        return if msg.startsWith 'Logstash Winston transport warning'
        return if msg.startsWith 'acsStub has no info about acs Location'
        cl.apply @logger._logger.transports.console, arguments
      @logger._logger.transports.console.log = wcl
      setTimeout =>
        @logger._logger.transports.console.log = cl
      , 30000
      @logger._logger.transports.console.silent = consoleSilent
      @logger._logger.transports.logstash.socket.removeListener 'error', retrier
      console.log "Connected with logger"
      console.log "Available Logger in #{@loggerIP}"
      console.log 'Available Kibana on port 5601'
      deferred.resolve true

    @logger._logger.transports.logstash.socket.on 'error', ->
      setTimeout retrier, 500

    retrier()
    deferred.promise

getDocker0IfaceHostIPAddress = ->
  # os.networkInterfaces() doesn't report DOWN ifaces,
  # so a less elegant solution is required
  address = execSync(
    "ip address show docker0| grep 'inet ' | awk '{print $2}' \
      | sed 's/\\/.*//' | tr -d '\\n'").toString()
  if (not address?) or (address.length is 0 )
    @logger.error 'docker0 interface could not be found. Using 172.17.0.1 as fallback.'
    address = '172.17.0.1'
  address

launchDockerKibana = ->
  checkDockerImage.call this, KIBANA_IMAGE
  .then (found)=>
    if not found
      console.error "Docker image for #{KIBANA_IMAGE} is \
          not available. Check the platform documentation for information \
          on obtaining docker images."
      return q.reject new Error "Docker image not available: #{KIBANA_IMAGE}"
    commandLine="\
        run \
        --rm \
        --name #{KIBANA_DOCKER} \
        -p 5601:5601 \
        -p 28777:28777 \
        #{KIBANA_IMAGE}"
    @logger.debug "Creating docker instance #{KIBANA_DOCKER}..."
    @logger.debug "Docker command line: #{commandLine}"
    # console.log "Docker command line: #{commandLine}"
    try
      client = spawn 'docker',commandLine.split(' ')
    catch e
      @logger.error "Error launching Docker #{e} #{e.stack}"
  .then ->
    console.log "Local-stamp initialization - \
      Waiting for logstash initialization..."
    #q.delay 15000

removeDockerKibana = ->
  container = @docker.getContainer KIBANA_DOCKER
  q.ninvoke container, 'remove', {force: true}
  .fail ->
    true

stopDockerKibana = ->
  container = @docker.getContainer KIBANA_DOCKER
  q.ninvoke container, 'stop'
  .fail ->
    true

checkDockerImage = (name)->
  # console.log "checkDockerImage this:#{this?} docker:#{this.docker?} #{name}"
  q.ninvoke @docker, 'listImages'
  .then (images)->
    found = false
    # console.log "Buscando a #{name}"
    for i in images
      # console.log JSON.stringify i, null, 2
      for t in i.RepoTags ? []
        # console.log "Comparando con #{t}"
        if t is name
          found = true
          break
    found

folderExists =(filePath)->
  try
    fs.statSync(filePath).isDirectory()
  catch err
    false

fileExists =(filePath)->
  try
    fs.statSync(filePath).isFile()
  catch err
    false

runtimeURNtoImageName =(runtimeURN) ->
  imageName = runtimeURN.replace('eslap://', '').toLowerCase()
  index = imageName.lastIndexOf('/')
  imageName = imageName.substr(0, index) + ':' + imageName.substr(index + 1)
  imageName

runtimeURNtoPath =(runtimeURN) ->
  imageName = runtimeURN.replace('eslap://', '').toLowerCase()
  index = imageName.lastIndexOf('/')
  imageName = imageName.substr(0, index).replace(/_/g, '') + '/' +
    imageName.substr(index + 1) + '/image.tgz'
  imageName


fakeLogger =
  debug: ->
  info: ->
  error: ->
  warn: ->
  log: ->
  verbose: ->
  silly: ->

setMutedLogger = (refs)->
  return
  for ref in refs
    ref.logger = fakeLogger if ref?

filterLog =  (logger, classes, levels = [])->
  original = logger._logger.log.bind logger._logger
  modified = (level, message, metadata)->
    if metadata.clazz in classes and level not in levels
      return
    original level, message, metadata
  logger._logger.log = modified


getMockAcsRouter = ->
  mockToken = {
      "access_token":"a7b41398-0027-4e96-a864-9a7c28f9a0cf",
      "token_type":"Bearer",
      "expires_in":3600,
      "refresh_token":"53ea0719-9758-41e4-9eca-101347f8a3cf",
      "user":{"name":"SAASDK Local Stamp","roles":["ADMIN"],"id":"local-stamp"}
  }
  @acsRouter = express.Router()
  @acsRouter.get '/login', (req, res) =>
    res.json  mockToken
  @acsRouter.get '/tokens/:token', (req, res) =>
    res.json  mockToken


module.exports = LocalStamp
