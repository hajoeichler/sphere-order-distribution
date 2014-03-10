package_json = require '../package.json'
Config = require '../config'
Logger = require './logger'
OrderDistribution = require '../lib/orderdistribution'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .default('logLevel', 'info')
  .default('logDir', '.')
  .default('timeout', 60000)
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv

logger = new Logger
  streams: [
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, type: 'rotating-file', period: '1d', count: 90, path: "#{argv.logDir}/sphere-order-distribution-#{argv.projectKey}.log" }
  ]

options =
  baseConfig:
    timeout: argv.timeout
    user_agent: "#{package_json.name} - #{package_json.version}"
    logConfig:
      logger: logger
  master: Config.config
  retailer:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret

impl = new OrderDistribution options
impl.getUnSyncedOrders(impl.masterRest).then (orders) ->
  impl.run orders, (msg) ->
    if msg.status
      logger.info msg
      process.exit 0
    logger.error msg
    process.exit 1
.fail (msg) ->
  logger.error msg
  process.exit 2
