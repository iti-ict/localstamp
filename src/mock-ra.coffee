q = require 'q'
net = require 'net'
ksockets = require 'k-sockets'

DealerSocket = ksockets.DealerSocket
DealerReqRep = ksockets.DealerReqRep
fs = require 'fs'
# Timeout for interval between pings
PING_TIMEOUT = 15000
# Timeout for the first ping of an instance
START_TIMEOUT= 180000

class MockRouterAgent

  constructor: (@ls)->
    @logger = @ls.logger
    @state = @ls.state

    @instanceSocketsBindIPAddress = @ls.dockerIP
    checker = checkPingTimeouts.bind this
    setInterval checker, 1000
    true

  setupInstance: (config, deployment, configLogger = @ls.configLogger)->
    dealer = control = name = null
    instanceFolder = socketFolder = tmpFolder = null

    deferred1 = q.defer()
    deferred2 = q.defer()
    instanceFolder = @ls.instanceFolder(config.iid)
    try
      fs.mkdirSync instanceFolder.local.data
    catch e
      @logger.error "Error creating folder #{instanceFolder.host.data}. \
        #{e}"
      true
    controlHandler = (req)=>
      if req.ping?
        handlePing.call this, config.iid
        return q PING:'pong'
      if req.action is 'getMembership'
        channel = req.parameters.channel
        # @logger.warn "Membership request arrives to local stamp: \
        #   #{JSON.stringify arguments}. Sending empty membership. Real \
        #   membership will be sent eventually."
        return q {
          result:'OK'
          data: @getMembership(deployment, config.iid, req.parameters.channel)
        }
      @logger.warn "LocalStamp Control Socket Handler can't handle \
        #{JSON.stringify arguments}"

      q true
    control = new DealerReqRep controlHandler, 1000

    handleDealer =  (piping deployment, config.iid).bind @ls
    dealer = new DealerSocket true, 1000
    dealer.on 'message', handleDealer

    control.socket.on 'disconnected', =>
      control.connected = false

    control.socket.on 'connected', =>
      control.connected = true
      @logger.debug "Instance #{config.iid} connected to stamp"
      # command =
      #   action: 'instance_config_logger'
      #   parameters:
      #     loggerCfg: configLogger
      # (if @ls.configValue 'kibana'
      #   control.sendRequest command
      # else
      q true
      .then =>
        # @logger.debug "Instance #{config.iid} logger configured"
        command =
          action: 'instance_start'
          parameters: config
        control.sendRequest command
      .then =>
        @logger.debug "Instance #{config.iid} started"

        deferred2.resolve true

    sockets = null
    _createInstanceSockets.call this
    .then (result)->
      sockets = result
      dealer.bind sockets.data.uri
    .then ->
      control.bind sockets.control.uri
    .then ->
      deferred1.resolve \
        [control, dealer, sockets]
    .catch (error)->
      deferred1.reject error

    [deferred1.promise, deferred2.promise]

  getMembership: (deployment, iid, channel)->
    for c in @state.getConnectors()
      # Solo trabajamos con membership en canales duplex
      continue if c.type isnt 'complete'
      if c.affects deployment, iid, channel
        membership = c.checkMembershipChange deployment, iid, channel
        list = []
        for entry in membership
          list.push
            iid: entry.iid
            endpoint: entry.endpoint
            service: entry.deployment
        return list
    return []

createInstanceStatusEvent = (iid, previous, current)->
  # deployment = @ls.instances[iid].deployment
  # role = @ls.instances[iid].config.role
  # @ls.deployments[deployment].roles[role].instances[iid].connected = current
  for k1,deployment of @state.getDeployments()
    for k2, role of deployment.roles
      for k3, instance of role.instances
        if k3 is iid
          instance.connected = current
          @ls.wsp.publishEvt 'instance', 'status', {
            deployment: k1
            service: deployment.service
            role: k2
            instance: k3
            status: if current then 'connected' else 'disconnected'
          }
          # @ls.instances[iid].connected = current
          return

handlePing = (iid)->
  status = @state.getInstanceStatus iid, {}
  old = status.state
  status.state = true
  status.timestamp = (new Date).getTime()
  if old != true
    console.log "Instance #{iid} has changed active status. \
      From #{old} to #{true}"
    createInstanceStatusEvent.call this, iid, old, true

checkPingTimeouts = ->
  now = (new Date).getTime()
  for iid of @state.getInstances()
    status = @state.getInstanceStatus iid
    continue if not status?.timestamp?
    interval = now - status.timestamp
    threshold = PING_TIMEOUT
    if not status.state?
      threshold = START_TIMEOUT
    if (interval > threshold) and (status.state != false)
      old = status.state
      status.state = false
      console.log "Instance #{iid} has changed active status. \
        From #{old} to #{false}"
      createInstanceStatusEvent.call this, iid, old, false

piping = (deployment, instance)->
  ->
    @logger.debug 'Piping message...'
    # @logger.debug "*** conectores actuales: #{@state.getConnectors().length}"
    # for c in @state.getConnectors
    #   @logger.debug "Conector source: #{JSON.stringify c.source}"
    #   @logger.debug "Conector target: #{JSON.stringify c.target}"
    #   @logger.debug "***"
    # @logger.debug "*** Interservice #{JSON.stringify @lsinterServiceGetters}"
    m = Array.prototype.slice.call(arguments)
    header = JSON.parse m[0]
    channel = header.name
    found = false
    @logger.silly "*** Piping message for source #{deployment} - \
        #{instance} - #{channel}"
    if @state.getInstanceStatus(instance)?.state isnt true
      @logger.error "Instance #{instance} is not active but is trying to \
        send a message"
      if @state.getInstance(instance)?.control.connected is true
        @logger.error "Sending destinationUnavailable event to instance"
        command = {action: 'destinationUnavailable'}
        control = @state.getInstance(instance).control
        m.unshift command
        control.sendRequest.apply control, m
      return
    for c in @state.getConnectors()
      if c.affects deployment, instance, channel, header.target
        c.send m, deployment, instance
        found = true
        break
    if not found
      @logger.error "Not found any connection for source #{deployment} - \
        #{instance} - #{channel}"

_getFreePorts = (numberOfPorts) ->
  ports = []
  servers = []
  q.Promise (resolve, reject) =>
    for i in [1..numberOfPorts]
      do () =>
        try
          server = net.createServer()
          servers.push server
          server.listen 0, @instanceSocketsBindIPAddress, () ->
            ports.push server.address().port
            if ports.length is numberOfPorts
              resolve()
        catch error
          reject error
  .then () ->
    q.Promise (resolve) ->
      for server in servers
        server.close () ->
          servers.shift()
          if servers.length is 0
            resolve ports

_createInstanceSockets = (containerId) ->
  _getFreePorts.call this, 2
  .then (ports) =>
    result = {
      control:
        uri: "tcp://#{@instanceSocketsBindIPAddress}:#{ports[0]}"
        ip: @instanceSocketsBindIPAddress
        port: ports[0]
      data:
        uri: "tcp://#{@instanceSocketsBindIPAddress}:#{ports[1]}"
        ip: @instanceSocketsBindIPAddress
        port: ports[1]
    }
    result

module.exports = MockRouterAgent
