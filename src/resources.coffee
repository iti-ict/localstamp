kutils = require 'k-utils'
klogger = require 'k-logger'

VOLUME_PREFIX = 'eslap://eslap.cloud/resource/volume/'
CERT_TYPE = "slap//eslap.cloud/resource/cert/server/1_0_0"

# Resources in use -- [full example below]
#
# TODO:
#   - In a service, does a resource only appear in one component?
#     Does it only have one local name?
#
class Resources


  # Constructor.
  # Resource dictionary is indexed by the resource URN, but a second dictionary
  # is indexed by deployment.
  # In some cases the resource will contain "items" (a subdictionary indexed by
  # item id) - for example: volumes.
  #
  # resource_urn
  #   type
  #   owner
  #   parameters
  #    param1
  #    [..]
  #   deployment
  #   name (local name in deployment)
  #   items (optional - depends of resource type)
  #     item_id
  #       param1
  #       [..]
  #
  # Note: Volatile-volume resources doesn't have URN, whereas they are
  # dynamically created. In order to represent these resources in the
  # dictionary, a temporary ID is assigned.
  #
  constructor: () ->
    @logger = klogger.getLogger 'resources'
    meth = 'Resources.constructor'
    @logger.info meth
    @resources = {}
    @deployments = {}


  # Initialization.
  # There may be services initiated, so we update the resource dictionary
  #
  init: (tcState) ->
    meth = 'Resources.init'
    @logger.info meth
    for depUrn, deploy of tcState.deployedServices
      depManifest = deploy.manifest
      @addDeployment depManifest
      ic = depManifest['instance-configuration']
      if ic?
        for iid, config of ic
          for name, resource of config.resources
            # Each resource type has its own item treatment - for now, only
            # volume resources have 'items'
            if @_isVolumeType resource.type
              @addItem depUrn, resource.type, {
                resourceName: name,
                id: resource.parameters.id,
                instanceId: iid
              }


  # From a deployment manifest, determines which resources will be used in
  # the service, and adds them to dictionary.
  # Must be invoked at the beginning of the deployment process.
  # - deploymentManifest: complete manifest ('manifiestaco')
  #
  addDeployment: (deploymentManifest) ->
    deploymentUrn = deploymentManifest.name
    meth = "Resources.addDeployment deployment=#{deploymentUrn}"
    @logger.info meth
    owner = deploymentManifest.owner
    @deployments[deploymentUrn] ?= {}
    for localname, resource of deploymentManifest.resources
      # SPECIAL CASE: due to v0->v1 http-manifests conversion, resources of
      # type 'cert' appear in manifest... even when there isnt a cert!
      # We can identify this case and ignore it
      if (resource.type is CERT_TYPE) and (not resource.resource.name?)
        continue

      # Take into account resources like volatile volumes, with no urn
      # TODO: to change, when ticket1153 is solved
      urn = null
      if resource.resource.name?                 # Persistent volumes, vhost...
        urn = resource.resource.name
      else if @_isVolumeType resource.type       # Volatile volumes
        # If it is a new deployment, urn should be generated.
        # If it is a deployment from injected state, urn has been generated
        # previosly
        urn = @_injectedUrn(localname, deploymentManifest)
        if not urn?
          urn = kutils.generateId()
      else                                       # Default (never occur)
        urn = kutils.generateId()

      @resources[urn] = {
        type: resource.type,
        owner: owner,
        parameters: resource.resource.parameters,
        deployment: deploymentUrn,
        name: localname,
        items: {}
      }
      @deployments[deploymentUrn][urn] = @resources[urn]


  # From a deployment manifest, determines which resources are being used in
  # the service, and removes them from dictionary.
  # Must be invoked at the end of the undeployment process, or when a deployment
  # process fails
  # - deploymentUrn: deployment urn
  #
  removeDeployment: (deploymentUrn) ->
    meth = "Resources.removeDeployment deployment=#{deploymentUrn}"
    @logger.info meth
    if not @deployments[deploymentUrn]?
      @logger.warn "#{meth} Deployment not found"
      return
    delete @resources[urn] for urn, resource of @deployments[deploymentUrn]
    delete @deployments[deploymentUrn]


  # Add an item to a resource. For now this only affects "volume" resources.
  # - deploymentUrn: deployment urn
  # - type: resource type
  # - info: resource item info (type dependent)
  #
  # Returns URN of resource where item is added
  #
  addItem: (deploymentUrn, type, info) ->
    meth = "Resources.addItem deployment=#{deploymentUrn}"
    @logger.info meth
    resourceUrn = null
    if not @deployments[deploymentUrn]?
      @logger.warn "#{meth} Deployment not found"
    else if @_isVolumeType type
      resourceUrn = @_addVolumeItem deploymentUrn, type, info
    else
      @logger.warn "#{meth} Only volume resources allowed"
    return resourceUrn

  # Removes an item to a resource. For now this only affects "volume" resources
  # when it is unassigned from an instance (undeploying or scaling down).
  # - deploymentName: deployment urn
  # - type: resource type
  # - info: resource item info (type dependent)
  #
  removeItem: (deploymentUrn, type, info) ->
    meth = "Resources.removeItem deployment=#{deploymentUrn}"
    @logger.info meth
    if not @deployments[deploymentUrn]?
      @logger.warn "#{meth} Deployment not found"
    else if @_isVolumeType type
      @_removeVolumeItem deploymentUrn, type, info
    else
      @logger.warn "#{meth} Only volume resources allowed"


  # New volume-metrics has been received in Planner, so 'usage' field must be
  # updated in volume resources
  #
  # TODO: inneficient. Will be improved when ticket1153 is solved
  #
  update: (metrics) ->
    if not metrics?.item? or not metrics?.data?.usage?.mean? then return
    resource = @getByVolumeItem metrics.item
    if resource?
      item = resource.items[metrics.item]
      if item?
        item.usage = metrics.data.usage.mean


  # Returns resource by urn (null, if it isn't found)
  #
  get: (urn) ->
    return @resources[urn]


  # Returns resource by item.
  # Is valid only for volume resources.
  # TODO: inneficient. This method will be removed when ticket1153 is solved
  #
  getByVolumeItem: (item) ->
    if not item? then return null
    for urn, resource of @resources
      if resource.items?[item]?
        return @resources[urn]
    return null


  # Checks if a resource is in use.
  #
  inUse: (urn) ->
    return @resources[urn]?


  # From a deployment manifest, checks if any resource is already in use
  #
  checkResourcesInUse: (deploymentManifest) ->
    inUse = []
    for localname, resource of deploymentManifest.resources
      urn = resource.resource.name
      if urn? and @inUse(urn) then inUse.push urn
    return inUse


  # Returns a subset of resources.
  # Options:
  # - owner: Takes into account only the resources of owner
  # - urn: Takes into account only the resources of deployment
  #
  filter: (options) ->
    _filter = (res) ->
      if options?.owner? and (res.owner isnt options.owner)
        return false
      if options?.urn? and (res.deployment isnt options.urn)
        return false
      return true
    result = {}
    for urn, resource of @resources when _filter(resource)
      result[urn] = resource
    return result


  # Returns true if resource type is some kind of volume resource
  #
  _isVolumeType: (type) ->
    return kutils.startsWith type, VOLUME_PREFIX


  # Add an item to a volume resource (when it is assigne to an instance:
  # deploying or scaling up).
  # - deploymentName: deployment urn
  # - type: resource type
  # - info:
  #   - resourceName (resource local name)
  #   - instanceId
  #   - id (item id)
  #
  # Returns URN of resource where item is added
  #
  _addVolumeItem: (deploymentUrn, type, info) ->
    meth = "Resources.addVolumeItem deployment=#{deploymentUrn}"
    @logger.info meth
    resourceUrn = null
    for urn, resource of @deployments[deploymentUrn]
      if resource.name is info.resourceName
        resource.items[info.id] = {
          instanceId: info.instanceId,
          usage: null
        }
        resourceUrn = urn
        break
    return resourceUrn


  # Removes an item to a resource. For now this only affects "volume" resources
  # when it is unassigned from an instance (undeploying or scaling down).
  # - deploymentName: deployment urn
  # - type: resource type
  # - info:
  #   - resourceName (resource local name)
  #   - instanceId
  #   - id (item id)
  #
  _removeVolumeItem: (deploymentUrn, type, info) ->
    meth = "Resources.removeVolumeItem deployment=#{deploymentUrn}"
    @logger.info meth
    for resourceUrn, resource of @deployments[deploymentUrn]
      if resource.name is info.resourceName
        if resource.items[info.id]? then delete resource.items[info.id]
        break


  # Inefficient and confusing! this method will be removed when ticket1153 is
  # solved
  #
  # In the case of deployments of injected state (Adm, Mon, Acs), in the
  # manifest we already have an URN related to volatile volumes, generated by
  # BaseDeployer/prepareStamp.
  _injectedUrn: (resourceLocalName, deploymentManifest) ->
    urn = null
    for instanceId, instance of deploymentManifest['instance-configuration']
      for localName, resource of instance.resources
        if localName is resourceLocalName
          urn = resource.name
          break
    return urn


module.exports = Resources


# Sample (persistent volume + volatil volume + vhost + cert)
#
# @resources = {
#   "eslap://mydomain/resources/volume/mongodb/persistent": {
#     "type": "eslap://eslap.cloud/resource/volume/persistent/1_0_0",
#     "owner": "john@kumori.systems",
#     "parameters": {
#       "filesystem": "ext4",
#       "size": "1000000"
#     },
#     "deployment": "slap://radiatus.jupyterspark/deployments/123456",
#     "name": "mongovolume",
#     "items": {
#       "mydomain_resources_volume_mongodb_persistent_000000001": {
#         "instanceId": "cfe51",
#         "usage": "0.65"
#       },
#       "mydomain_resources_volume_mongodb_persistent_000000002": {
#         "instanceId": "cfe52",
#         "usage": "0.33"
#       }
#     }
#   },
#   "d5fb1472-300f-46dd-ae83-df512a25d401": {
#     "type": "eslap://eslap.cloud/resource/volume/volatile/1_0_0",
#     "owner": "john@kumori.systems",
#     "parameters": {
#       "filesystem": "fsx",
#       "size": "2000000"
#     },
#     "deployment": "slap://radiatus.jupyterspark/deployments/123456",
#     "name": "workvolume",
#     "items": {
#       "3a7a1bfa-4cf0-46e1-9641-3f14c8b5e976": {
#         "instanceId": "worker12",
#         "usage": "0.65"
#       }
#     }
#   },
#   "eslap://eslap.cloud/resources/vhost/frontend": {
#     "type": "eslap://eslap.cloud/resource/vhost/1_0_0",
#     "owner": "john@kumori.systems",
#     "parameters": {
#       "vhost": "frontend.argo.kumori.cloud"
#     },
#     "deployment": "slap://radiatus.jupyterspark/deployments/123456",
#     "name": "myvhost"
#   },
#   "eslap://eslap.cloud/resources/cert/server/frontend": {
#     "type": "eslap://eslap.cloud/resource/cert/server/1_0_0",
#     "owner": "john@kumori.systems",
#     "parameters": {
#       "content": {
#         "key": "LSS..0K",
#         "cert": "LS0..0K"
#       }
#     },
#     "deployment": "slap://radiatus.jupyterspark/deployments/123456",
#     "name": "mycert"
#   },
#   [...]
# }
# @deployments = {
#   "slap://radiatus.jupyterspark/deployments/123456": {
#     "eslap://mydomain/resources/volume/mongodb/persistent": { [ref] },
#     "d5fb1472-300f-46dd-ae83-df512a25d401": { [ref] },
#     "eslap://eslap.cloud/resources/vhost/frontend": { [ref] },
#     "eslap://eslap.cloud/resources/cert/server/frontend": { [ref] }
#   },
#   [...]
# }
