## README

The current version of **localstamp** code has some software dependencies that can not be currently resolved due to restricted access. For this reason, in this version you cannot build **localstamp** from the source code. Nevertheless, in the **dist** folder you will have access to two packaged distributions of **localstamp** ready to be used, one for Linux systems and another for Mac systems. Enjoy yourself!

### Documentation

In this [link](User_Guide_en.adoc) you can find info about how to use localstamp tool.

## Introduction

LocalStamp is a class that facilitates the development and testing of components and services for the *ECloud* framework. This tool enables the instantiation of components through *Docker* containers and using bundles.

## Local Stamp Creation

In order to use _LocalStamp_ you have first to create an instance and then call its method _init_ for initializing it. _init_ is asynchronous and returns a promise (it is based on the promise paradigm).

```javascript
LocalStamp = require 'local-stamp'

stamp = new LocalStamp()
stamp.init()
.then ->
  console.log 'Workspace ready'
```

The *LocalStamp* constructor accepts optional parameter the stamp identifier. By default it is identified as 'test'. This identifier is the name given to the folder in /tmp where the files related to the deployment will be located.

```
class LocalStamp

  constructor: (@id = 'test', @config = {})->
```

Extra stamp configuration details can be given through a second optional parameter. Currently this configuration accepts:

* *runtimeFolder*: Path where is located a functional copy of `runtime-agent` with all its dependencies installed. It is mounted in the instances launched using docker containers. By default, this parameter takes as value '/tmp/runtime-agent'. It is necessary that this parameter value points to a folder containing the functional copy of `runtime-agent` in order _LocalStamp_ works properly. A functional local copy of the `runtime-agent` is created as follows:

```bash
cd /tmp # folder that will contain the runtimeFolder
git clone git@gitlab.com:ECloud/sep-agent.git
cd runtime-agent
npm install
```

If the path provided does not exist, _LocalStamp_ executes the previous instructions preparing a functional `runtime-agent` ready for being used.

During the _LocalStamp_ instance initialization the following actions take place:

* Removal of docker instances of previous executions with the same local stamp id.
* Removal of previous files located in the stamp directory (/tmp/<stamp_id>).
* Creation of the basic folder structure for enabling stamp execution.
* Copy `runtime-agent` folder in the stamp folder.

## Component Instance Creation

Component instances inside a local stamp are grouped by deployments. The deployment identifier is a string. If no deployment identifier is specified when deploying a component instance the instance is associated to the '_default_' deployment. There are several ways of deploying an instance inside a deployment.

### Classes

This is the most low level method. It assumes that there is access to the `NodeJS` class (first parameter) with the component code to be instantiated. This method launches a runtime-agent instance, that later on will create the component class instance.

```
launch: (klass, config, deploymentId = 'default')->
```

The second parameter is also mandatory and is used for specifying the component configuration to be used during its constructor execution. The structure of this initial configuration corresponds to the constructor parameters of an ECloud component. Those parameters are described in the ECloud specification documentation. The next example shows a possible component initial configuration:

```
REPLY_CHANNEL =
  id:'reply'
  type:'Reply'

RECEIVE_CHANNEL =
  id:'rcv'
  type:'Receive'

DUPLEX_CHANNEL =
  id: 'dup'
  type: 'Duplex'

COMPONENT_CONFIG =
  iid: 'tested'
  incnum: 1
  localData: '/tmp'
  parameters: {}
  resources: {}
  role: 'TESTED'
  offerings: [REPLY_CHANNEL, RECEIVE_CHANNEL]
  dependencies: [DUPLEX_CHANNEL]
```

The component class can be complex or simple, specifically used for tests:

```javascript
class ComponentTested extends Component
  constructor: (@runtime, @role, @iid, @incnum, @localData, @resources
  , @parameters, @dependencies, @offerings) ->
    @state = ''

  run: ->
    @running = true
    @offerings.reply.handleRequest = (m)->
      q [['This is my answer',m[0]]]

    @offerings.rcv.on 'message', (m)=>
      @state = m.toString()

    @dependencies.dup.on 'message', (m)=>
      @state = m.toString()

  shutdown: ->
    @running = false
```

Creating the component instance in the stamp could be done as follows:

```javascript
# Creating the local stamp instance
stamp = new LocalStamp()
...
# Creating the component instance
stamp.launch ComponentTested, COMPONENT_CONFIG
.then ->
  # For testing purposes this can be useful
  instance = stamp.instances[COMPONENT_CONFIG.iid].instance
  config =   stamp.instances[COMPONENT_CONFIG.iid].config
```

In this example, _instance_ is the class instance that has been created. It can be useful for checking the component instance status or for executing instance methods that send messages to other instances. This way of launching an instance is the only one that allows such low level access to it.

### Docker

In this case instead of providing a reference to the component class it is passed a docker container configuration. This is the configuration of the docker container that will execute the component instance using its associated runtime. The component configuration is done as in the Classes way.

```
launchDocker: (localConfig, config, deployment = 'default')->
```

The minimal docker configuration must contain the following elements:

```
DOCKER_CONFIG =
  runtime :       'eslap.cloud/runtime/java:1_0_1',
  componentPath : "#{COMPONENTS_PATH}/myComponent/code/src/tests/build"
```

`runtime` is the name of the docker image to be used for launching the container. If this image is not available in the system an error informing about it will be triggered.

`componentPath` is the path where component files are available. The component files disposal has to correspond to what expects the runtime being used. As it is detailed in the ECloud manual specification NodeJS based components have to provide in _componentPath_ folder the module component files. The module only has to export the component class, and dependencies have to be already installed. In this specification is also explained the Java component files disposal.

```
stamp.launchDocker DOCKER_CONFIG, COMPONENT_CONFIG
```

Additionally, the docker configuration also can specify informatin about folder binding and TCP ports.

```
DOCKER_CONFIG =
  runtime :       'eslap.cloud/runtime/java:1_0_1',
  componentPath : "#{COMPONENTS_PATH}/myComponent/code/src/tests/build"
  ports: ['9000:8000']
  volumes: ['/tmp/folder:/eslap/folder']
```

_ports_ key is used for specifying a ports mapping list. Each mapping is detailed with an string where both are separated by means of ':'. The second port in the string is the internal docker port to be mapped, while the first is the external port to be mapped to the internal.

Usually this key can be used for accessing a REST API offered by the component. NodeJS components that use 'http-message' for offering HTTP services can be accessed through port 8000. Java components that integrate (contain) a web application offer their functionality through port 8080.

_volumes_ key works similarly to _ports_. Two paths are separated by ':'. The first is the path in the file system where the stamp is being executed. The second is the path where the former has to be available inside the docker container.

Additionally to what is specified through _volumes_ key there are other set of paths that are mapped automatically by the Local Stamp. The default mappings are:

* The system folder (where the stamp is being executed) pointed by the docker configuration `componentPath` value is mapped to '/eslap/component' inside the container.

* '/eslap/data' is the container folder for component instance local files. Any value assigned in the component configuration is ignored. This '/eslap/data' container folder is mapped (where the stamp is being executed) to a folder inside '/tmp/<stamp_id>/'.

```
  @lsRepo = "/tmp/#{@id}"
  @runtimeFolder = "#{@lsRepo}/runtime-agent"

  instanceFolder = "#{@lsRepo}/#{config.iid}"
  socketFolder="#{instanceFolder}/gw-sockets"
  tmpFolder = "#{instanceFolder}/tmp"
```

 * The runtime-agent inside a docker container is located in '/eslap/runtime-agent'. LocalStamp creates a copy of the configured runtime-agent, places it inside the stamp folder '/tmp/<stamp_id>' and then is mapped to '/eslap/runtime-agent'.

 * In order to facilitate runtime-agent logs reading, the 'slap.log' file in each docker container (one per component instance) is mapped to the stamp working folder ('/tmp/<stamp_id>/<component_instance_id>/')

```
stamp = new LocalStamp()
...
stamp.launchDocker DOCKER_CONFIG, COMPONENT_CONFIG
.then ->
  # This is helpful
  config =   stamp.instances[COMPONENT_CONFIG.iid].config
  dockerName = stamp.instances[COMPONENT_CONFIG.iid].dockerName
  logging =   stamp.instances[COMPONENT_CONFIG.iid].logging
```

A docker instance has accessible its configuration, its container identifier and logging mode. If _logging_ is _true_ its standard output will point to the logs, in case of _false_ it will be ignored. At container creation time it is _true_, but can be changed later on.

### Connectors

Local Stamp offers connectors for linking roles (remember that components play roles in a service application). The way of specifying those connections is similar to the way of doing it in the service application manifest.

```
  connect: (connector, provided, depended, deploymentId = 'default')->
```

The _connector_ parameter is a text string that specifies the connector type. Accepted values are _loadbalancer_, _pubsub_ and _complete_. Their semantics is the same to those in service application manifest.

_provided_ and _dependend_ parameters are arrays with a list of pairs <role, channel> to link. Additionally, a _deployment_ field can be specified in the entries in order to link roles in different deployments in the same stamp. By default, it is assumed that the entry belongs to the deployment specified in the _deploymentId_ parameter.

Sample invocations to _connect_ method:

```
    stamp.connect 'loadbalancer',
      [{role:'TESTED', endpoint:'reply'}],
      [{role:'TESTER', endpoint:'req'}]

    stamp.connect 'pubsub',
      [{role:'TESTED', endpoint: 'rcv'}],
      [{role:'TESTER', endpoint: 'send'}]

    stamp.connect 'complete',
      [{role:'TESTED', endpoint: 'dup'}],
      [{role:'TESTER', endpoint: 'dup'}]
```

There is a explicit method for connecting service channels of two deployments:

```
  connectDeployments: (join)->
```

Next example shows the structure that `join` expects:

```
  stamp.connectDeployments
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
```


### Bundle

This deployment option is the closest one to use a real stamp. With this option it is deployed a complete bundle in the same way as it will be done using the testing integration framework (check the Quick Start Guide). Typically, the bundle will contain docker images and component manifests, service application manifest and deployment manifest. It also allows to include resources.

```
  launchBundle: (path)->
```

In this case there is only the _path_ parameter which contains the path to the place where is located the bundle zip file to be deployed. In this way, there is no option to name the deployment and the deployment names are generated automatically.

If the bundle contains a deployment manifest, the deployment configuration is generated automatically from bundle manifests. Initial configuration values are generated, both for parameters and resources. Instance connections are created accordingly to service application manifest. `__instances` value for each role is considered in the deployment manifest.

_launchBundle_ returns a promise that is solved when all instances are deployed. Instances are deployed using docker containers. Usually this do not mean that all instances are operative because this can take some time. It is convenient to make a pause of several seconds before launching requests to the instances, or implement a phase for testing if the service is available. The promise is solved informing that the service is deployed with other interesting data.

Structure example returned when a _launchBundle_ promise is solved:

```json
{
  "successful": [
    "Registered element: eslap://jrwe.examples.ecloud/resources/volumes/persistent",
    "Registered element: eslap://jrwe.examples.ecloud/components/cfe/0_0_1",
    "Registered element: eslap://jrwe.examples.ecloud/components/data/0_0_1",
    "Registered element: eslap://jrwe.examples.ecloud/services/jrwe/0_0_2"
  ],
  "errors": [],
  "deployments": {
    "errors": [],
    "successful": [
      {
        "deploymentURN": "slap://jrwe.examples.ecloud/deployments/20161003_130315/2c3db903"",
        "roles": {
          "data": {
            "instances": [
              "data-5"
            ]
          },
          "cfe": {
            "instances": [
              "cfe-6"
            ]
          }
        },
        "portMapping": [
          {
            "iid": "cfe-6",
            "role": "cfe",
            "port": 9003
          }
        ],
        "volumes": {
          "data-5": {
            "forever": "/tmp/test/volumes/volume-1",
            "temporal": "/tmp/test/volumes/volume-2"
          }
        }
      }
    ]
  }
}
```

The list of active deployments can by consulted at any moment through the _deployments_ property of stamp object.

The volumes (for storing purposes) assigned to an instance (role) are done accordingly to the resources listed in its configuration. There is no distinction in the way are handled the persistent and transient volumes. The volumes an instance sees are directories created sequentially in the stamp directory ('/tmp/<stamp_id>/').

Ports mapped automatically are implemented accordingly to the existence of service channels in the deployed instance. If it has a service channel a docker port is mapped to a host port. Host ports are assigned sequentially starting from 9000, while docker ports are assigned depending on the runtime, usually 8000 or 8080 in case of Java runtime.

##Local Stamp Shutdown

```
  shutdown: ->
```

Erases all instances launched in the stamp, independently of the method used to launch them.

### Disclaimer

The current version of **localstamp** code has some software dependencies that can not be currently resolved due to restricted access. For this reason, in this version you cannot build **localstamp** from the source code. Nevertheless, in the **dist** folder you will have access to two packaged distributions of **localstamp** ready to be used, one for Linux systems and another for Mac systems.

### Support advice

The **localstamp** software has been developed in the project *SaaSDK: Tools & Services for developing and managing software as a service over a PaaS (SaaSDK: Herramientas y servicios para el desarrollo y gestión de software como servicio sobre un PaaS)* jointly financed by Instituto Valenciano de Competitividad Empresarial (IVACE) and European Union through the European Regional Development Fund with grant number IMDEEA/2017/141.