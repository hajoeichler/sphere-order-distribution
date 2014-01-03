Config = require '../config'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret')
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv
OrderDistribution = require('../main').OrderDistribution

Config.showProgress = true

options =
  master: Config.config
  retailer:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret

impl = new OrderDistribution options
impl.getUnexportedOrders(rest).then (orders) ->
  impl.run orders, (msg) ->
    console.log msg
.fail (msg) ->
  console.log msg
  process.exit 1