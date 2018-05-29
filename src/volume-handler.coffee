kutils = require 'k-utils'
klogger = require 'k-logger'
q = require 'q'
child = require 'child_process'
assert = require 'assert'


class VolumeHandler

  constructor: (@ls)->
    @logger = klogger.getLogger 'planner'
    @state = {}
    @volumeCounter = 1
    @volumeFolder = @ls.repos.volumes
    @hostVolumeFolder = @ls.config.volumeFolder
    @volatile = "#{@volumeFolder}/volatile"
    child.execSync "rm -rf #{@volatile}/*"
    @persistent = "#{@volumeFolder}/persistent"

  absolutePersistent: (path)->
    {
      host: "#{@hostVolumeFolder}/persistent/#{path}"
      local: "#{@volumeFolder}/persistent/#{path}"
    }

  absoluteVolatile: (path)->
    {
      host: "#{@hostVolumeFolder}/volatile/#{path}"
      local: "#{@volumeFolder}/volatile/#{path}"
    }

  getPersistentPath: (deploymentUri, iid, resource)->
    prefix = @_idFromUrn resource.name
    @state[deploymentUri] ?= {instances:{},prefix:{}}
    @state[deploymentUri].instances[iid] ?= []
    n = 1
    folder = ''
    while true
      s = "00000000#{n}"
      s.substring(s.length - 5)
      seq = "#{prefix}-#{s}"
      folder = @absolutePersistent seq
      found = false
      for k, fs of @state[deploymentUri].instances
        for f in fs
          if f.local is folder.local
            found = true
            break
        break if found
      break if not found
      n++
    child.execSync "mkdir -p #{folder.local}"
    @state[deploymentUri].instances[iid].push folder
    folder

  getVolatilePath: (deploymentUri, iid, info)->
    id = @_idFromDeploymentUrn deploymentUri
    folder = @absoluteVolatile id
    child.execSync "mkdir -p #{folder.local}"
    @state[deploymentUri] ?= {instances:{},prefix:{}}
    @state[deploymentUri].instances[iid] ?= []
    @state[deploymentUri].instances[iid].push folder
    folder

  undeploy: (deploymentUri)->
    delete @state[deploymentUri] if @state[deploymentUri]?

  removeInstance: (deploymentUri, iid)->
    delete @state[deploymentUri][iid] if @state[deploymentUri]?[iid]?

  # Using the urn of a volume resource, creates a valid (and unique) ID.
  # For example:
  # urn = eslap://eslap.cloud/resources/volume/acs_super/persistent
  # id =  eslap_cloud_resources_volume_acs__super_persistent
  #
  _idFromUrn: (urn) ->
    strippedUrn = urn.replace /e?slap:\/\//, ''
    id = ''
    initSlice = 0
    for c in strippedUrn
      if c in ['.', ':', '/'] then id = id + '_'
      else if c is '_'  then id = id + '__'
      else id = id + c
    return id


  _idFromDeploymentUrn: (urn) ->
    # Volume names cannot exceed 127 bytes at LVM level (including VG name),
    # so we should ensure that IDs stay in a safe range
    id = @_idFromUrn urn.replace 'deployments/', ''
    id +=  '_' + kutils.generateId()
    id.substring id.length - 100, id.length

  # volumePrefix = (uri)->
  #   uri = uri[8..]
  #   left = uri[..uri.indexOf('/resources/volumes/persistent')-1]
  #   p='/resources/volumes/persistent'.length+1
  #   right = uri[uri.indexOf('/resources/volumes/persistent')+p..]
  #   result = left
  #   result = "#{left}--#{right}" if right.length
  #   result = result.replace '/','-'

module.exports = VolumeHandler