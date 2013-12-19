Config = require '../config'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret')
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv
OrderDistribution = require('../main').OrderDistribution
Rest = require('sphere-node-connect').Rest

Config.showProgress = true

options =
  config:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret

impl = new OrderDistribution Config
rest = new Rest options
impl.getUnexportedOrders(rest).then (orders) ->
  impl.run orders, (msg) ->
    console.log msg
.fail (msg) ->
  process.exit 1
  console.log msg