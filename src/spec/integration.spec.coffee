Q = require 'q'
_ = require 'underscore'
_.mixin require('sphere-node-utils')._u
{ExtendedLogger} = require 'sphere-node-utils'
package_json = require '../package.json'
Config = require '../config'
OrderDistribution = require '../lib/orderdistribution'

uniqueId = (prefix) ->
  _.uniqueId "#{prefix}#{new Date().getTime()}_"

updatePublish = (version) ->
  version: version
  actions: [
    {action: 'publish'}
  ]

updateUnpublish = (version) ->
  version: version
  actions: [
    {action: 'unpublish'}
  ]

cleanup = (client, logger) ->
  logger.debug 'Cleaning up...'
  logger.debug 'Unpublishing all products'
  client.products.sort('id').where('masterData(published = "true")').process (payload) ->
    Q.all _.map payload.body.results, (product) ->
      client.products.byId(product.id).update(updateUnpublish(product.version))
  .then (results) ->
    logger.debug "Unpublished #{results.length} products"
    logger.debug 'About to delete all products'
    client.products.perPage(0).fetch()
  .then (payload) ->
    logger.debug "Deleting #{payload.body.total} products"
    Q.all _.map payload.body.results, (product) ->
      client.products.byId(product.id).delete(product.version)
  .then (results) ->
    logger.debug "Deleted #{results.length} products"
    logger.debug 'About to delete all product types'
    client.productTypes.perPage(0).fetch()
  .then (payload) ->
    logger.debug "Deleting #{payload.body.total} product types"
    Q.all _.map payload.body.results, (productType) ->
      client.productTypes.byId(productType.id).delete(productType.version)
  .then (results) ->
    logger.debug "Deleted #{results.length} product types"
    Q()

describe '#distributeOrders', ->

  beforeEach (done) ->
    @logger = new ExtendedLogger
      additionalFields:
        project_key: Config.config.project_key
      logConfig:
        name: "#{package_json.name}-#{package_json.version}"
        streams: [
          { level: 'info', stream: process.stdout }
        ]

    options =
      baseConfig:
        logConfig:
          logger: @logger.bunyanLogger
      master: Config.config
      retailer: Config.config
    @distribution = new OrderDistribution @logger, options
    @client = @distribution.masterClient

    @logger.info 'About to setup...'
    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done _.prettify error
  , 30000 # 30sec

  afterEach (done) ->
    @logger.info 'About to cleanup...'
    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done _.prettify error
  , 30000 # 30sec

  it 'Nothing to do', (done) ->
    @distribution.distributeOrders []
    .then (msg) =>
      expect(msg).not.toBeDefined()
      expect(@distribution.summary.master.unsynced).toBe 0
      done()
    .fail (err) -> done _.prettify err

  it 'should distribute one order', (done) ->
    pt =
      name: uniqueId 'PT-'
      description: 'bla'
      attributes: [
        { name: 'mastersku', label: { de: 'Master SKU' }, type: { name: 'text' }, isRequired: false, inputHint: 'SingleLine' }
      ]
    @logger.debug 'About to create product type'
    @client.productTypes.save(pt)
    .then (result) =>
      @productType = result.body
      @masterSku = uniqueId 'masterSku-'
      pMaster =
        productType:
          typeId: 'product-type'
          id: @productType.id
        name:
          en: uniqueId 'masterP-'
        slug:
          en: uniqueId 'masterS-'
        masterVariant:
          sku: @masterSku
      @logger.debug {product: pMaster}, 'About to save master product'
      @client.products.save(pMaster)
    .then =>
      pRetailer =
        productType:
          typeId: 'product-type'
          id: @productType.id
        name:
          en: uniqueId 'P-'
        slug:
          en: uniqueId 'S-'
        masterVariant:
          sku: uniqueId 'retailerSku-'
          attributes: [
            { name: 'mastersku', value: @masterSku }
          ]
      @logger.debug {product: pRetailer}, 'About to save retailer product'
      @client.products.save(pRetailer)
    .then =>
      @client.channels.ensure(@distribution.retailerProjectKey, ['InventorySupply', 'OrderExport', 'OrderImport'])
    .then (result) =>
      channel = result.body
      order =
        lineItems: [ {
          supplyChannel:
            id: channel.id
            typeId: 'channel'
          variant:
            sku: @masterSku
          name:
            de: 'foo'
          taxRate:
            name: 'myTax'
            amount: 0.10
            includedInPrice: false
            country: 'DE'
          quantity: 1
          price:
            value:
              centAmount: 999
              currencyCode: 'EUR'
        } ]
        totalPrice:
          currencyCode: 'EUR'
          centAmount: 999
      @client.orders.import(order)
    .then (result) =>
      importedOrder = result.body
      @distribution.run()
      .then (msg) =>
        expect(msg).toMatch /Summary\: there were (\d)+ unsynced orders in master and 1 were successfully synced back to master \(0 were bad and 0 failed to sync\), 1 were synced to retailers \((\d)+ were not matched by SKUs and 0 failed to sync\)/
        @client.orders.byId(importedOrder.id).fetch()
      .then (result) =>
        syncedOrder = result.body
        expect(syncedOrder.syncInfo).toBeDefined()
        @client.orders.where("syncInfo(externalId = \"#{syncedOrder.id}\")").fetch()
      .then (result) ->
        expect(result.body.total).toBe 1
        done()
    .fail (err) -> done _.prettify err
  , 30000 # 30sec
