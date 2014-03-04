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
    if msg.status
      console.log msg
      process.exit 0
    console.error msg
    process.exit 1
.fail (msg) ->
  console.error msg
  process.exit 2