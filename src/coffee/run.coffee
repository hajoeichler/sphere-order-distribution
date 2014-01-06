Config = require '../config'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret')
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv
OrderDistribution = require('../main').OrderDistribution

options =
  master: Config.config
  retailer:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret

impl = new OrderDistribution options
impl.getUnSyncedOrders(impl.masterRest).then (orders) ->
  impl.run orders, (msg) ->
    console.log msg
    process.exit 1 unless msg.status
.fail (msg) ->
  console.log msg
  process.exit 1