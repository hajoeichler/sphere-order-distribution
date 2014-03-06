Config = require '../config'
Logger = require './logger'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir')
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv
OrderDistribution = require('../main').OrderDistribution

logDir = argv.logDir or '.'

logger = new Logger
  streams: [
    { level: 'warn', stream: process.stderr }
    { level: 'warn', type: 'rotating-file', period: '1d', count: 90, path: "#{logDir}/sphere-order-distribution-#{argv.projectKey}.log" }
  ]

options =
  master: Config.config
  retailer:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret
  logConfig:
    logger: logger

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