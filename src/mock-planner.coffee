kutils = require 'k-utils'
klogger = require 'k-logger'
q = require 'q'
fs = require 'fs'
child = require 'child_process'
assert = require 'assert'
VolumeHandler = require './volume-handler'

connectors = require './connectors'
Connector = connectors.Connector
PSConnector = connectors.PSConnector
LBConnector = connectors.LBConnector

SOURCEDIR_PREFIX         = '/eslap/codeblobs/'

class MockPlanner

  constructor: (@ls)->
    @logger = klogger.getLogger 'planner'
    @state = @ls.state
    @repos = @ls.repos
    @volumeCounter = 1
    @volumeHandler = new VolumeHandler @ls

  execDeployment: (manifest)->
    method = 'Planner.execDeployment'
    @logger.info "#{method} #{manifest.service.name}"

    if not @buildSetup
      @ls.wsp.local.on 'event', (buildDomainServersList.bind this)
    @buildSetup = true

    m1 = manifest.versions['http://eslap.cloud/manifest/deployment/1_0_0']

    # Check if any resource are already in use
    usedResources = @ls.resourcesInUse.checkResourcesInUse m1
    if usedResources.length > 0
      return q.reject new Error "There are resources already in use: \
                                 #{JSON.stringify usedResources}"

    @ls.resourcesInUse.addDeployment m1
    manifest = m1

    # console.log 'Processing MANIFESTACO...', JSON.stringify manifest, null, 2
    # if manifest.service?.name is
    #   'eslap://eslap.cloud/services/http/inbound/1_0_0'
    #   return q {}
    deploymentId = manifest.name ? "deployment-#{@ls.deploymentCounter++}"
    deployment = null
    q true
    .then =>
      if @ls.configValue 'autoUndeploy'
        for urn, info of @state.getDeployments()
          if info.service is manifest.service.name
            @execUndeployment urn
            .then =>
              q.delay 5000
    .then =>
      @logger.debug "Deployment #{deploymentId} is starting..."
      console.log "Deployment #{deploymentId} is starting..."
      # Setup runtimes
      runtimes = []
      for r of manifest.runtimes
        continue if r is 'slap://slapdomain/runtimes/managed/nodejs/0_0_1'
        runtimes.push r
      @ls.loadRuntimes runtimes
    .then =>
      deployment = @state.addDeployment deploymentId
      deployment.service = manifest.service.name
      deployment.links = {}
      deployment.resources = manifest?['components-resources']?.__service ? {}
      promises = []
      console.log "Deployment for service #{manifest.service?.name}"
      @ls.wsp.publishEvt 'service', 'deploying', {
        deployment: deploymentId
        service: deployment.service
      }

      for entry in manifest.service.connectors ? []
        type = entry.type.split('/')[4]
        @logger.debug "New connector with type #{type}"
        @connect type, entry.provided, entry.depended, deploymentId
      @logger.debug "Connectors configured."

      @state.addManifest manifest

      for entry in manifest.service?.roles ? []
        k = entry.name
        urn = entry.component
        arrangement = manifest.roles[k].resources
        deployment.roles ?= {}
        deployment.roles[k] = {
          instances:{}
          arrangement: arrangement
          component: urn
        }
        if urn is 'slap://slapdomain/components/httpsep/0_0_1'
          ep = {}
          if manifest['components-configuration'][k]?.domain
            ep = manifest['components-configuration'][k]
          else
            r = manifest.resources
            ep.domain = r.vhost.resource.parameters.vhost
            ep.instancePath = false
            if r.server_cert?.resource?.parameters?.content?.cert?
              ep.sslonly = true
              ep.secrets =r.server_cert.resource.parameters.content
            else
              ep.sslonly = false
              ep.secrets = {}
          deployment.roles[k].entrypoint = ep
          # continue
        else
          deployment.roles[k].configuration =
            manifest['components-configuration'][k]
        # @logger.debug "minInstances #{k} \
        #   #{JSON.stringify manifest.roles[k].resources}"
        for nInstance in [1..minInstances(manifest, k)]
          promises.push launchInstance.call this, manifest, k
      q.all promises
    .then =>
      q.delay 2000
    .then =>
      @logger.debug "Port Mapping: #{JSON.stringify @ls.portMapping}"
      # @logger.debug "SERVICE"
      # @logger.debug JSON.stringify manifest.service, null, 2
    .finally =>
      @checkMembershipChange()
      if @ls.configValue 'autoUnregister'
        q.ninvoke child, 'exec', " \
          mv #{@ls.repos.manifests}/remote/eslap.cloud /tmp;\
          mv #{@ls.repos.manifests}/remote/slapdomain /tmp;\
          rm -rf #{@ls.repos.manifests}/local/*;\
          rm -rf #{@ls.repos.manifests}/remote/*;\
          mv /tmp/eslap.cloud #{@ls.repos.manifests}/remote;\
          mv /tmp/slapdomain #{@ls.repos.manifests}/remote;\
          mv #{@ls.repos.images}/remote/eslap.cloud /tmp;\
          mv #{@ls.repos.images}/remote/slapdomain /tmp;\
          rm -rf #{@ls.repos.images}/local/*;\
          rm -rf #{@ls.repos.images}/remote/*;\
          mv /tmp/eslap.cloud #{@ls.repos.images}/remote;\
          mv /tmp/slapdomain #{@ls.repos.images}/remote;"
    .then =>
      @ls.wsp.publishEvt 'service', 'deployed', {
        deploymentURN: deploymentId
        deployment: deployment
      }
      {
        deploymentURN: deploymentId
        topology: deployment
      }

  execUndeployment: (urn)->
    method = 'Planner.execUndeployment'
    @logger.info "#{method} #{urn}"
    console.log "Undeploying #{urn}"
    promises = []
    deployment = @state.getDeployment urn
    deployment0 = JSON.parse(JSON.stringify(deployment))

    killed = {}
    if not deployment?
      return q.reject new Error "Deployment #{urn} does not exist"
    @ls.wsp.publishEvt 'service', 'undeploying', {
      deployment: urn
      service: deployment.service
    }
    for role, info of deployment.roles ? {}
      for instance, instanceInfo of info.instances ? {}
        killed[instance] =
          cnid: 'localhost'
          component: info.component
          incnum: instanceInfo.incnum ? 0
          connected: instanceInfo.connected
        promises.push @ls.shutdownInstance instance
    q.all promises
    .then =>
      for pm in deployment.portMapping ? []
        if pm.port?
          @ls.freePort pm.port
      @ls.wsp.publishEvt 'service', 'undeployed', {
        deploymentURN: urn
        deployment: deployment0
      }
      @state.removeDeployment urn
      @state.removeManifest urn
      @ls.resourcesInUse.removeDeployment urn
      @volumeHandler.undeploy urn
      @checkMembershipChange()
      {killedInstances: killed}

  checkMembershipChange: ->
    for c in @state.getConnectors()
      c.checkMembershipChange()

  deploymentInfo: (urn) ->
    method = 'Planner.deploymentInfo'
    @logger.info "#{method} #{urn}"
    if urn?
      deployment = @state.getDeployment urn
      if not deployment?
        return q.reject new Error "Deployment #{urn} does not exist"
      result = {}
      result[urn] = deployment
      return q result
    q @state.getDeployments()

  deploymentQuery: (query = {})->
    urn = query.urn
    @deploymentInfo urn

  deploymentInfoEx: (urn)->
    result = manifest:
      versions:
        'http://eslap.cloud/manifest/deployment/1_0_0':
          @state.getManifest urn
    q result

  # Returns the list of resources in use
  #
  # Parameter "filter":
  # filter = {
  #   owner: x, (resources owner, optional)
  #   urn: x, (deployment urn, optional)
  # }
  #
  listResourcesInUse: (filter) ->
    return @ls.resourcesInUse.filter(filter)

  isElementInUse: (urn) ->
    if @ls.resourcesInUse.inUse urn
      return q true
    for deploymentURN, depMan of @state.getManifests()
      if depMan.servicename is urn
        return q true
      else
        if depMan.service?.components?
          for role, compURN of depMan.service.components
            if compURN is urn
              return q true
        if depMan.service?.roles?
          for role in depMan.service.roles
            if role.component is urn
              return q true
    return q false

  connect: (connector, provided, depended, deploymentId = 'default')->
    # TODO: Check channels compatibility            ***********!!!
    reflexive = false
    if connector is 'pubsub'
      [provided, depended] = [ depended, provided]
    if connector is 'complete'
      if (not provided?) || (provided.length == 0)
        provided = depended
        reflexive = true
    c = new Connector provided, depended, deploymentId, this
    @state.addConnector c
    if connector is 'loadbalancer'
      c = new LBConnector depended, provided, deploymentId, this
    else if connector is 'pubsub'
      c =new PSConnector depended, provided, deploymentId, this
    else if connector is 'complete'
      if not reflexive
        c = new Connector depended, provided, deploymentId, this
    else
      console.log "Unexpected type of connector: #{connector}"
      return
    @state.addConnector(c) if not reflexive
    @ls.wsp.publishEvt 'instance', 'connected', {service: deploymentId}

  connectDeployments: (join)->
    deploymentId1 = join.endpoints[0].deployment
    entrypoint1 = join.endpoints[0].channel
    deploymentId2 = join.endpoints[1].deployment
    entrypoint2 = join.endpoints[1].channel

    @state.addLink deploymentId1, entrypoint1, deploymentId2, entrypoint2
    {
      deployment1: deploymentId1
      channel1: entrypoint1
      deployment2: deploymentId2
      channel2: entrypoint2
    }

  unconnectDeployments: (join)->
    deploymentId1 = join.endpoints[0].deployment
    entrypoint1 = join.endpoints[0].channel
    deploymentId2 = join.endpoints[1].deployment
    entrypoint2 = join.endpoints[1].channel

    @state.removeLink deploymentId1, entrypoint1, deploymentId2, entrypoint2
    {
      deployment1: deploymentId1
      channel1: entrypoint1
      deployment2: deploymentId2
      channel2: entrypoint2
    }

  linkServices: (linkManifest)->
    # console.log "linkServices #{JSON.stringify linkManifest, null, 2}"
    result = @connectDeployments linkManifest
    # console.log "result: #{JSON.stringify result, null, 2}"
    e0 = linkManifest.endpoints[0]
    e1 = linkManifest.endpoints[1]

    linkData = {
      endpoints: [{
        deployment: e0.deployment,
        channel: e0.channel
      }, {
        deployment: e1.deployment
        channel: e1.channel
      }]
    }
    @checkMembershipChange()
    @ls.wsp.publishEvt 'service', 'link', {
      deploymentURN: e0.deployment
      deployment: @state.getDeployment e0.deployment
      linkData: linkData
    }
    @ls.wsp.publishEvt 'service', 'link', {
      deploymentURN: e1.deployment
      deployment:  @state.getDeployment e1.deployment
      linkData: linkData
    }
    result

  unlinkServices: (linkManifest)->
    result = @unconnectDeployments linkManifest
    e0 = linkManifest.endpoints[0]
    e1 = linkManifest.endpoints[1]

    linkData = {
      endpoints: [{
        deployment: e0.deployment,
        channel: e0.channel
      }, {
        deployment: e1.deployment
        channel: e1.channel
      }]
    }

    @checkMembershipChange()
    @ls.wsp.publishEvt 'service', 'unlink', {
      deploymentURN: e0.deployment
      deployment: @state.getDeployment(e0.deployment)
      linkData: linkData
    }
    @ls.wsp.publishEvt 'service', 'unlink', {
      deploymentURN: e1.deployment
      deployment: @state.getDeployment(e1.deployment)
      linkData: linkData
    }
    result

  modifyDeploy: (params) ->
    method = 'Planner.modifyDeploy'
    @logger.info "#{method} #{JSON.stringify params}"
    try
      deploymentUrn = params?.deploymentUrn
      if not deploymentUrn? or not @state.getManifest(deploymentUrn)?
        throw new Error "Deployment #{deploymentUrn} doesnt exists"
      switch params?.action
        when 'reconfig' then @reconfigDeploy params
        when 'manualScaling' then manualScaling.call this,params
        else throw new Error "Invalid action #{params.action}"
    catch e
      @logger.error "#{method} #{e.stack}"
      q.reject e

  reconfigDeploy: (config)->
    # console.log "reconfigDeploy: #{JSON.stringify config, null, 2}"
    cf = config['components-configuration'] ? {}
    cr = config['components-resources'] ? {}
    for r, rinfo of @state.getDeployment(config.deploymentUrn)?.roles ? {}
      if cf[r]?
        rinfo.configuration = cf[r]
        for iid, iinfo of rinfo.instances
          ref = @state.getInstance iid
          return if not ref?
          if ref.isDocker
            ref.control.sendRequest {
              action: 'instance_reconfig'
              parameters:
                config:
                  resources: cr[r]
                  parameters: cf[r]
            }

launchInstance = (manifest, role)->
  method = 'Planner.launchInstance'
  @logger.info "#{method} #{manifest.name} #{role}"
  k = role
  urn = null
  for r in manifest.service.roles
    if r.name is role
      urn = r.component
      break
  if not urn?
    @logger.error "launchInstance. Invalid role #{role} request in \
      deployment #{manifest.name}"

  servicePrefix = _servicePrefix manifest.service.name
  deploymentId = manifest.name
  arrangement = manifest.roles[k].resources
  deployment = @state.getDeployment deploymentId
  @logger.debug "Processing role #{k} with component #{urn}"
  # deployment.roles[k] = {instances:[]}
  info = manifest.components[urn]
  # @logger.debug JSON.stringify info, null, 2
  hasSep = []
  for c in manifest.service.connectors ? []
    continue if c.type.indexOf('loadbalancer') < 0
    for d in c.depended ? []
      goodDepended = not d.role?
      if not goodDepended
        for r in manifest.service.roles
          if r.name is d.role
            if r.component is 'slap://slapdomain/components/httpsep/0_0_1'
              goodDepended = true
              break
      if goodDepended
        for e in c.provided ? []
          if e.role is k
            if not hasSep.find ((item)-> item is e.endpoint)
              hasSep.push e.endpoint  # Create instance
  componentConfig =
    iid: "#{servicePrefix}_#{k}_#{@ls.instanceCounter++}"
    incnum: 0
    localData: '/eslap/data'
    parameters: manifest['components-configuration'][k]
    resources: {}
    role: k
    offerings: []
    dependencies: []
  iid = componentConfig.iid
  secretPort = 8000
  if (info.runtime.indexOf 'java')>0
    secretPort = 8080
  sepPorts = {}
  for c in info.channels?.provides ? []
    entry =
      id: c.name
      type: titleCase((c.type.split '/')[4])
    if entry.id in hasSep
      if (info.runtime.indexOf 'java')<0
        entry.config = port:secretPort
      sepPorts[entry.id] = secretPort
      secretPort++
    componentConfig.offerings.push entry
  for c in info.channels?.requires ? []
    componentConfig.dependencies.push
      id: c.name
      type: titleCase((c.type.split '/')[4])

  dockerConfig =
    'runtime' : runtimeURNtoImageName info.runtime
    'componentPath' :
      host: @ls.instanceFolder(componentConfig.iid).host.component
      local: @ls.instanceFolder(componentConfig.iid).local.component
    'resources' : arrangement
    # 'volumes': [ develLib, develCfeSlapLog ]
    # 'ports': [ '8080:8080' ]

  dockerConfig.ports = []
  promises = []
  for i in hasSep
    do (i)=>
      promises.push (@ls.allocPort()
        .then (port)->
          dockerConfig.ports.push ["#{port}:#{sepPorts[i]}"]
          deployment.portMapping.push
            iid: componentConfig.iid
            role: k
            endpoint: i
            port: port
      )
  q.all promises
  .then =>
    deployment.roles[k].instances[componentConfig.iid] = {
      arrangement: arrangement
      publicIp: '127.0.0.1'
      privateIp: '127.0.0.1'
      id: 'localhost'
    }
    for key, value of manifest['components-resources']?[k] ? {}
      # TODO: Comprobar que es de tipo resource/volume
      if value?.type?.indexOf('resource/volume') > 0
        persistent = value?.type?.indexOf('resource/volume/persistent') > 0
        folder = if persistent\
          then @volumeHandler.getPersistentPath(deploymentId, iid, value) \
          else  @volumeHandler.getVolatilePath(deploymentId, iid, value)
        dockerConfig.volumes ?= []
        dockerConfig.volumes.push  \
          ["#{folder.host}:#{folder.local}"]
        dv = deployment.volumes[iid] ?= {}
        dv[key] = folder.host
      componentConfig.resources[key] = folder.local
      deployment.roles[k].instances[iid].configuration ?= {resources:{}}
      deployment.roles[k].instances[iid].configuration.\
        resources[key] = folder.host
    # @logger.debug ".................. #{componentConfig.iid}"
    # @logger.debug "COMPONENTE"
    # @logger.debug JSON.stringify componentConfig, null, 2
    # @logger.debug "DOCKER"
    # @logger.debug JSON.stringify dockerConfig, null, 2

    # console.log "NEW INSTANCE: #{JSON.stringify componentConfig, null, 2}"

    # Vamos a descomprimir los zip a las carpetas de cada componente
    if urn is 'slap://slapdomain/components/httpsep/0_0_1'
      deployment.roles[k].instances[iid].connected = true
      @ls.wsp.publishEvt 'instance', 'status', {
        deployment: manifest.name
        service: deployment.service
        role: k
        instance: componentConfig.iid
        status: 'connected'
        }
      q true
    else
      # Setup runtime-agent
      runtimeManifest = null
      try
        runtimeManifest = require "#{@ls.manifestFolder().local}\
                     /#{componentURNtoImageName info.runtime}/manifest.json"
      catch error
        console.log "There was a problem processing runtime manifest for \
          #{info.runtime}. Component #{urn}: #{error.message? error}"
        throw error
      dockerConfig.entrypoint = runtimeManifest.entrypoint
      dockerConfig.sourcedir = runtimeManifest.sourcedir # ? '/eslap/component'
      if dockerConfig.sourcedir?
        # If sourcedir is relative, add a default root path
        if dockerConfig.sourcedir[0] isnt '/'
          dockerConfig.sourcedir = SOURCEDIR_PREFIX + dockerConfig.sourcedir
      dockerConfig.configdir = runtimeManifest.configdir
      if runtimeManifest.agent?
        dockerConfig.agentPath =
          host: @ls.instanceFolder(iid).host.runtime
          local: @ls.instanceFolder(iid).local.runtime

      tgzfile = "#{@ls.imageFolder().local}\
                /#{componentURNtoImageName urn}/image.tgz"
      do (dockerConfig, componentConfig)=>
        return (kutils.untgz tgzfile, dockerConfig.componentPath.local
        .then =>
          if dockerConfig.agentPath?
            agentTgzfile = "#{@ls.imageFolder().local}\
                /#{componentURNtoImageName runtimeManifest.agent}/image.tgz"
            kutils.untgz agentTgzfile, dockerConfig.agentPath.local
        .then =>
          @ls.launchDocker dockerConfig, componentConfig, deploymentId
        .then =>
          deployment.roles[k].instances[iid].privateIp =
            @state.getInstance(iid).dockerIp
        )

manualScaling = (params)->
  method = 'Planner._manualScaling'
  @logger.info "#{method} #{JSON.stringify params}"

  deploymentUrn = params?.deploymentUrn
  manifest = @state.getManifest deploymentUrn
  q true
  .then =>
    if not manifest? # Deployment undeployed while waiting semaphore?
      q.reject new Error "Deploy #{deploymentUrn} has been undeployed"
    else
      deploy = @state.getDeployment deploymentUrn
      # Calculates how many instances should be added/deleted per each role
      numInstancesToAdd = {}
      numInstancesToDelete = {}
      changed = false
      for role, numInstances of params.roles
        if deploy.roles[role]?
          arrangement = deploy.roles[role].arrangement
          mininstances = arrangement.mininstances ?
            arrangement.__mininstances ? 0
          maxinstances = arrangement?.maxinstances ? arrangement.__maxinstances
          if mininstances <= numInstances <= maxinstances
            currentInstances = Object.keys(deploy.roles[role].instances)
            aux = numInstances - currentInstances.length
            if aux > 0
              numInstancesToAdd[role] = aux
              changed = true
            else if aux < 0
              numInstancesToDelete[role] = -aux
              changed = true
          else
            @logger.warn "#{method} role[#{role}].#{numInstances} out of \
                          range [#{mininstances}..#{maxinstances}]"
        else
          @logger.warn "#{method} role #{role} not found"
      # Adds and removes instances
      if changed
        adjustNumInstances.call this, manifest, numInstancesToAdd, \
                             numInstancesToDelete, 'manual'
  .then () =>
    @checkMembershipChange()
    @logger.info "#{method} finished"
    q()
  .fail (err) =>
    @logger.error "#{method} #{err.stack}"
    q.reject err

adjustNumInstances = (manifest, numInstancesToAdd, numInstancesToDelete, cause) ->
  method = 'Planner._adjustNumInstances'
  @logger.debug "#{method} deploy=#{manifest.name}, \
                 numInstancesToAdd=#{JSON.stringify numInstancesToAdd}, \
                 numInstancesToDelete=#{JSON.stringify numInstancesToDelete}"
  scaleEvent =
    type: cause
    instances:
      add: numInstancesToAdd
      remove: numInstancesToDelete
  @ls.wsp.publishEvt 'service', 'scale',
    manifest: manifest
    event: scaleEvent
  addCollection = null
  deleteCollection = null
  addInstances.call this, manifest, numInstancesToAdd
  .then (_addCollection) =>
    addCollection = _addCollection
    @logger.debug "#{method} addCollection = #{JSON.stringify \
                    addCollection}"
    deleteInstances.call this, manifest, numInstancesToDelete
  .then (_deleteCollection) =>
    deleteCollection = _deleteCollection
    @logger.debug "#{method} deleteCollection = #{JSON.stringify \
                    deleteCollection}"
    if Object.keys(addCollection).length > 0 or
        Object.keys(deleteCollection).length > 0
      result = @deploymentInfo manifest.name
      @logger.debug "#{method} topology = #{JSON.stringify result}"
      result
    else
      q()

deleteInstances =(manifest, instancesToDelete, isCnFailure = false) ->
  if Object.keys(instancesToDelete).length is 0 then return q {}
  methodName = 'Planner._deleteInstances'
  @logger.info "#{methodName} instances=#{JSON.stringify instancesToDelete}" +
    " isCnFailure=#{isCnFailure}"
  deleteCollection = {}
  removeResult = null
  promises = []
  deployment = @state.getDeployment manifest.name
  for roleName, toDelete of instancesToDelete
    continue if not toDelete?
    if typeof toDelete is 'number' and toDelete > 0
      for iid, instance of deployment.roles[roleName].instances
        deleteCollection[iid] = instance
        toDelete--
        break if toDelete is 0
    else
      for iid, instance of instanceList when iid in toDelete
        deleteCollection[iid] = instance
  for iid of deleteCollection
    promises.push (@ls.shutdownInstance iid
    .then =>
      @volumeHandler.removeInstance manifest.name, iid
    )
  q.all promises

addInstances = (manifest, instancesToAdd) ->
  if Object.keys(instancesToAdd).length is 0 then return q {}
  methodName = 'Planner._addInstances'
  @logger.info "#{methodName} #{JSON.stringify instancesToAdd}"

  addCollection = {}
  involvedCNs = []
  iids = null
  promises = []
  for roleName, toAdd of instancesToAdd
    continue if not toAdd?
    numInstances = null
    if typeof toAdd is 'number' and toAdd > 0
      numInstances = toAdd
      iids = null
    else
      numInstances = toAdd.length
    for i in [1..numInstances]
      promises.push launchInstance.call this, manifest, roleName
  q.all promises


titleCase = (string)->
  string.charAt(0).toUpperCase() + string.slice(1)

componentURNtoImageName = (componentURN) ->
  componentURN
  .replace('eslap://', '')

runtimeURNtoImageName =(runtimeURN) ->
  imageName = runtimeURN.replace('eslap://', '').toLowerCase()
  index = imageName.lastIndexOf('/')
  imageName = imageName.substr(0, index) + ':' + imageName.substr(index + 1)
  imageName

minInstances = (manifest, role) ->
  r = manifest.roles[role].resources
  r.__instances ? r.instances ? r.failurezones ? 1

_servicePrefix = (name) ->
  t = (name.split '/services')[0].split('/')
  t[t.length-1]

buildDomainServersList = ->
  # console.log 'buildDomainServersList'
  result = {}
  for dname, d of @state.getDeployments()
    # console.log "   deployment #{dname}"
    for role, r of d.roles
      # console.log "  role: #{role}"
      # console.log "  r.component: #{r.component}"
      if r.component is 'slap://slapdomain/components/httpsep/0_0_1'
        ep = r.entrypoint
        # console.log "  SEP #{JSON.stringify ep}"
        for c in @state.getConnectors()
          # console.log "  Me encuentro a #{c.deploymentId}"
          continue if c.deploymentId isnt dname
          sepPresent = false
          # console.log "  Buscando #{role} en #{dname}... #{c.source}"
          for s in c.source
            if s.role is role
              sepPresent = true
              break
          continue if not sepPresent
          # console.log '    source', JSON.stringify c.source
          tl = c.targetList()
          # console.log '    targetList', JSON.stringify tl
          for t in tl
            pms = @state.getDeployment(t.deployment).portMapping
            for pm in pms
              continue if pm.iid isnt t.iid
              continue if pm.endpoint isnt t.endpoint
              result[ep.domain] ?= []
              found = false
              for p in result[ep.domain]
                if pm.port is p
                  found = true
                  break
              if not found
                result[ep.domain].push
                  port: pm.port
                  ip: @state.getInstance(t.iid).dockerIp
  # console.log "result=#{JSON.stringify result, null, 2}"
  @domainServerList ?= {}
  if not deepEqual @domainServerList, result
    @domainServerList = result
    @ls.wsp.directPublish 'upstream-event', {data:result}
    # console.log JSON.stringify result, null, 2

deepEqual = (a, b)->
  try
    assert.deepEqual(a, b)
  catch error
    if error?.name?.indexOf?('AssertionError')>=0
      return false
    console.log "message: #{error.message}"
    console.log "name: #{error.name?.indexOf?('AssertionError')} #{error.name}"
    throw error
  return true

module.exports = MockPlanner
