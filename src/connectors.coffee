HashRing = require 'hashring'
_ = require 'lodash'

id=1

class Connector
  constructor: (@source, @target, @deploymentId, @ls)->
    @id = id++
    @logger = @ls.logger
    @type = 'complete'
    @cachedTarget = []
    @cachedSource = []
    @state = @ls.state
    @checkMembershipChange()
    console.log "ALERT: State is null" if not @state?
    # @sourceList = []
    # @targetList = []
    # deployment = @ls.deployments[@deploymentId]
    # for entry in @source ? []
    #   continue if not entry.role?
    #   for iid in deployment.roles[entry.role].instances ? []
    #     @sourceList.push
    #       iid:iid
    #       deployment: entry.deployment ? @deploymentId
    #       endpoint: entry.endpoint
    # for entry in @target ? []
    #   continue if not entry.role?
    #   for iid in deployment.roles[entry.role].instances ? []
    #     @targetList.push
    #       iid:iid
    #       deployment: entry.deployment ? @deploymentId
    #       endpoint: entry.endpoint

  sourceList: (checkActive = true)->
    result = generateEndPointList.call this, @source, checkActive
    result

  targetList: (checkActive = true)->
    result = generateEndPointList.call this, @target, checkActive
    result

  generateEndPointList = (entries, checkActive)->
    # @logger.debug "generateEndPointList de #{JSON.stringify entries}: start"
    result = []
    # deployment = @ls.deployments[@deploymentId]
    for entry in entries ? []
      entryDeploymentId = entry.deployment ? @deploymentId
      if not entry.role?
        # @logger.debug "Encontrada entrada sin role #{entry.endpoint}"
        links = @state.getLinks entryDeploymentId, entry.endpoint
        if links? and links.length > 0
          # @logger.debug "Canal de servicio conectado."
          l = findEPGetter links, @state.getConnectors()
          # @logger.debug "Al otro lado de la conexión está #{JSON.stringify l}"
          result = result.concat l
        continue
      deployment = @state.getDeployment entryDeploymentId
      if not deployment?
        # console.log "Warning: deployment #{entryDeploymentId} does not exist"
        continue
      # @logger.debug "entry: #{JSON.stringify entry}"
      # @logger.debug "@deploymentId #{@deploymentId}"
      # @logger.debug "entryDeploymentId: #{entryDeploymentId}"
      # @logger.debug "deployment: #{JSON.stringify deployment, null, 2}"
      for iid, info of deployment.roles[entry.role]?.instances ? {}
        if checkActive
          continue if (info?.connected != true)
          continue if not @state.getInstance(iid)?
        result.push
          iid:iid
          deployment:entryDeploymentId
          endpoint: entry.endpoint
    # console.log "generateEndPointList de #{JSON.stringify entries}: \
    #     end -> #{JSON.stringify result}"
    result

  findEPGetter = (links, connectors)->
    result = []
    for link in links
      partial = []
      [deploymentId, entrypoint] = link
      for c in connectors
        continue if not (deploymentId is c.deploymentId)
        for s in c.source
          # @logger.debug "Evaluando #{JSON.stringify s}"
          if s.endpoint is entrypoint
            # @logger.debug "Encontrado conector con un origen #{deploymentId} \
            # - #{entrypoint}. Actualmente su targetList es #{JSON.stringify \
            # c.targetList()}"
            partial = c.targetList()
      for p in partial
        dupl = false
        for r in result
          if p.iid is r.iid and p.deployment is r.deployment and \
          p.endpoint is r.endpoint
            dupl = true
            break
        result.push p if not dupl
    result


  affects: (deployment, instance, channel, target)->
    sources = @sourceList(false)
    targets = @targetList(false) if target?
    for member in sources
      if member.iid is instance and member.endpoint is channel and \
      deployment is member.deployment
        if target?
          found = false
          for membert in targets
            if membert.iid is target.iid and \
            membert.endpoint is target.endpoint and \
            membert.deployment is target.service
              found = true
              break
          continue if not found
        return true
    return false

  # Estos parametros opcionales se corresponde con un canal que ha hecho
  # un getMembership sin caché previa. Calculamos las membresías. Si se tercia
  # enviamos novedades a toda la membresía. Pero al que la pidió no se la
  # enviamos, se la devolvemos como respuesta de su getMembership
  checkMembershipChange: (deployment, instance, channel)->
    targets = @targetList false
    sources = @sourceList false
    # console.log "sources: #{JSON.stringify (e.iid for e in sources ? [])}"
    # console.log "targets: #{JSON.stringify (e.iid for e in targets ? [])}"
    if not equalsEntryList targets, @cachedTarget
      # send 'change_membership' to each member of sourceList source
      @cachedTarget = targets
      @cachedSource = sources
      for s in sources
        if not deployment? or s.endpoint isnt channel or s.iid isnt instance
          sendMembership.call this, s, targets
    targets

  equalsEntryList = (l1 = [], l2 = [])->
    # TODO: Hacer una comparación como toca
    l1.length is l2.length

  sendMembership = (target, membership)->
    # Verificar que es duplex el target
    return if not @state.getInstance(target.iid)?
    config = @state.getInstance(target.iid).config
    found = false
    for c in (config.offerings ? []).concat(config.dependencies ? [])
      if c.id is target.endpoint
        found = true
        if not (c.type is 'Duplex')
          # Solo trabajamos con membership en canales duplex
          # console.log "#{@id} Me salgo porque no es duplex"
          return
    if not found
      @logger.warn 'Something weird happened handling channel memberships'
      # console.log "#{@id} Me salgo porque no lo he encontrado"
      return
    list = []
    # console.log "#{@id} Enviando membresía a #{JSON.stringify target}"
    for entry in membership
      list.push
        iid: entry.iid
        endpoint: entry.endpoint
        service: entry.deployment
    command =
      action: 'changeMembership'
      parameters:
        channel: target.endpoint
        destinations: list
    if @state.getInstance(target.iid)?.control?.connected is true
      @logger.info "Membership sent to #{target.iid} \
        #{JSON.stringify command, null, 2}"
      @state.getInstance(target.iid).control.sendRequest command

  send: (m, deploymentFrom, iidFrom)->
    header = JSON.parse m[0]
    # @logger.debug "Mensaje de #{deploymentFrom} #{iidFrom} con cabecera \
    #   #{JSON.stringify header, null, 2}"
    header.source =
      service: deploymentFrom
      endpoint: header.name
      iid: iidFrom
    targets = @targetList()
    if (not targets?) or targets.length <= 0
      @logger.error "No destinations available for message from source \
        #{JSON.stringify header.source}"
      destinationUnavailable.call this, m, iidFrom
      return
    target = header.target
    if target?
      # @logger.debug 'Destino explicito. Comprobando ruta'
      # console.log "Destino explicito: #{JSON.stringify target}"
      routeOK = false
      for entry in targets
        if entry.iid is target
          # Rehacemos target por compatibilidad con runtimes anteriores
          target =
            iid: entry.iid
            endpoint: entry.endpoint
            service: entry.deployment
        if (entry.iid is target.iid) and (target.endpoint is entry.endpoint)
          routeOK = true
          break
      if not routeOK
        @logger.error "Target invalid #{JSON.stringify target} from source \
          #{JSON.stringify header.source}. Target list valid was \
          #{JSON.stringify targets, null, 2}"
        destinationUnavailable.call this, m, iidFrom
        return
      header.name = target.endpoint
      delete header.target
      m[0]= JSON.stringify header
      @logger.debug "Sending message to target #{target.service} \
         #{target.iid}: |#{m[0]}|#{m[1]}|#{m[2]}|"
      sendMessage.call this, m, target.service, target.iid
    else
      @_send m, targets, iidFrom, deploymentFrom

  _send: (m)=>
    @logger.warn "Incorrect use of connector detected. No target specified. \
      Connector data: \
      type = #{@type} \
      source = #{JSON.stringify @sourceList()}, \
      target = #{JSON.stringify @targetList()}"


class LBConnector extends Connector
  constructor: (@source, @target, @deploymentId, @ls)->
    super
    @type = 'loadbalancer'

  _send: (m, targets, iidFrom, deploymentFrom)->
    header = JSON.parse m[0]
    header.source =
      service: deploymentFrom
      endpoint: header.name
      iid: iidFrom
    if targets.length is 0
      @logger.error 'No target available from',
        iidFrom, header.name
      destinationUnavailable.call this, m, iidFrom
      return
    choosen = null
    if header.key?
      ring = new HashRing()
      aux = {}
      for target in targets
        aux[target.iid] = target
        ring.add target.iid
      choosen = aux[ring.get(header.key)]
    else
      choosen = selectRandomly targets
    @logger.debug "Choosen #{JSON.stringify choosen}"
    header.name = choosen.endpoint
    m[0]= JSON.stringify header
    sendMessage.call this, m, choosen.deployment, choosen.iid


class PSConnector extends Connector
  constructor: (@source, @target, @deploymentId, @ls)->
    super
    @type = 'pubsub'

  _send: (m, targets, iidFrom, deploymentFrom)->
    header = JSON.parse m[0]
    header.source =
      service: deploymentFrom
      endpoint: header.name
      iid: iidFrom
    if targets.length is 0
      console.error 'No connector to send message from',
        iidFrom, header.name
      destinationUnavailable.call this, m, iidFrom
      return
    for choosen in targets
      header.name = choosen.endpoint
      m[0]= JSON.stringify header
      sendMessage.call this, m, choosen.deployment, choosen.iid

class FCConnector
  constructor: (@depended, @provided, @ls)->
    super


sendMessage = (message, deployment, iid)->
  if not @state.getInstance(iid)?.dealer?
    @logger.error "Target instance #{iid} has not been setup yet"
    return
  @state.getInstance(iid).dealer.send message

destinationUnavailable = (m, instance)->
  command = {action: 'destinationUnavailable'}
  control = @state.getInstance(instance)?.control
  if control?.connected is true
    m.unshift command
    control.sendRequest.apply control, m

selectRandomly = (items) ->
  if items?.length > 0
    selected = _.random 0, (items.length-1)
    items[selected]
  else
    undefined

module.exports.Connector = Connector
module.exports.PSConnector = PSConnector
module.exports.LBConnector = LBConnector
