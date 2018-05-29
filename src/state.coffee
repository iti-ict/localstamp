class State

  constructor: ()->
    @state = {
      # Manifiestacos
      manifests:{}
      # Info of an active deployment
      deployments:{}
      instances:{}
      status:{}
      connectors:[]
      links:{}
    }
    @manifests = @state.manifests
    @deployments = @state.deployments
    @instances = @state.instances
    @status = @state.status
    @connectors = @state.connectors
    @links = @state.links
    @interService = {}

  addManifest: (deployment)->
    @state.manifests[deployment.name] = deployment

  removeManifest: (urn)->
    delete @state.manifests[urn] if  @state.manifests[urn]?

  getManifest: (urn)->
    @state.manifests[urn]

  getManifests: ->
    @state.manifests

  addDeployment: (deploymentUri)->
    @deployments[deploymentUri] =
      roles:{}
      portMapping:[]
      volumes:{}
    @deployments[deploymentUri]

  getDeployment: (deploymentUri)->
    @deployments[deploymentUri]

  getDeployments: ()->
    @deployments

  removeDeployment: (deploymentUri)->
    newConnectors = []
    for c in @connectors
      if c.deploymentId isnt deploymentUri
        newConnectors.push c
    @state.connectors = @connectors = newConnectors
    for ep, epl of @links[deploymentUri] ? {}
      for l in epl
        @removeLink deploymentUri, ep, l[0], l[1]
    delete @deployments[deploymentUri] if @deployments[deploymentUri]?

  addInstance: (deploymentUri, data, config)->
    @instances[config.iid] = data
    @instances[config.iid].config = config
    deployment = @deployments[deploymentUri] ? @addDeployment deploymentUri
    deployment.roles[config.role] ?= {instances:{}}
    deployment.roles[config.role].instances[config.iid] ?= {}

  getInstance: (iid)->
    @instances[iid]

  getInstances: ()->
    @instances

  removeInstance: (iid)->
    newc = []
    for c in @connectors
      continue if c.iidFrom is iid or c.iidTo is iid
      newc.push c
    @state.connectors = @connectors = newc
    delete @instances[iid] if @instances[iid]?
    delete @status[iid] if @status[iid]
    for d, dinfo of @deployments
      for r, rinfo of dinfo.roles
        if rinfo.instances?[iid]?
          delete rinfo.instances[iid]
          break

  getInstanceStatus: (iid, init)->
    value = @status[iid]
    if not value?
      value = @status[iid] = init
    value

  setInstanceStatus: (iid, status)->
    @status[iid] = status

  addConnector: (c)->
    @connectors.push c

  getConnectors: ()->
    @connectors

  addLink: (deploymentId1, entrypoint1, deploymentId2, entrypoint2) ->
    @links[deploymentId1] ?= {}
    @links[deploymentId2] ?= {}
    @links[deploymentId1][entrypoint1] ?= []
    @links[deploymentId2][entrypoint2] ?= []

    @links[deploymentId1][entrypoint1].push [deploymentId2, entrypoint2]
    @links[deploymentId2][entrypoint2].push [deploymentId1, entrypoint1]

    links1 = @getDeployment(deploymentId1).links
    links2 = @getDeployment(deploymentId2).links
    links2[entrypoint2] ?= {}
    links1[entrypoint1] ?= {}
    links2[entrypoint2][deploymentId1] ?= {}
    links2[entrypoint2][deploymentId1][entrypoint1] = {}
    links1[entrypoint1][deploymentId2] ?= {}
    links1[entrypoint1][deploymentId2][entrypoint2] = {}

  removeLink: (deploymentId1, entrypoint1, deploymentId2, entrypoint2) ->
    if not @links?[deploymentId1]?[entrypoint1]?
      return

    links1 = @getDeployment(deploymentId1).links
    links2 = @getDeployment(deploymentId2).links

    delete links2[entrypoint2][deploymentId1][entrypoint1]
    if links2[entrypoint2][deploymentId1] is {}
      delete links2[entrypoint2][deploymentId1]
    delete links1[entrypoint1][deploymentId2][entrypoint2]
    if links1[entrypoint1][deploymentId2] is {}
      delete links1[entrypoint1][deploymentId2]

    @links[deploymentId1][entrypoint1] = \
      @links[deploymentId1][entrypoint1].filter (item)->
        item[0]!=deploymentId2 and item[1]!=entrypoint2

    @links[deploymentId2][entrypoint2] = \
      @links[deploymentId2][entrypoint2].filter (item)->
        item[0]!=deploymentId1 and item[1]!=entrypoint1

  getLinks: (deploymentId1, entrypoint1)->
    @links[deploymentId1]?[entrypoint1] ?  []

module.exports = State